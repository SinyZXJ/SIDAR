import ARKit
import CoreImage
import Darwin
import Foundation
import UIKit

enum FrameWriterError: LocalizedError {
    case alreadyRecording
    case notRecording
    case finalizationInProgress
    case invalidDepthBuffer
    case invalidDepthPixelFormat(OSType)
    case invalidConfidenceBuffer
    case invalidConfidencePixelFormat(OSType)
    case captureIncomplete([String])

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A PhoneScene recording is already active."
        case .notRecording:
            return "No PhoneScene recording is active."
        case .finalizationInProgress:
            return "The PhoneScene recording is already being finalized."
        case .invalidDepthBuffer:
            return "ARKit returned an unreadable scene-depth buffer."
        case .invalidDepthPixelFormat(let format):
            return "ARKit scene depth has unsupported pixel format \(format)."
        case .invalidConfidenceBuffer:
            return "ARKit returned an unreadable depth-confidence buffer."
        case .invalidConfidencePixelFormat(let format):
            return "ARKit depth confidence has unsupported pixel format \(format)."
        case .captureIncomplete(let reasons):
            return "PhoneScene capture did not pass final integrity checks: \(reasons.joined(separator: ", "))"
        }
    }
}

enum SignBookmarkCueType: String, CaseIterable, Identifiable, Encodable {
    case unreviewed
    case directional
    case locational
    case directory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unreviewed: return "Unreviewed Sign"
        case .directional: return "Directional Sign"
        case .locational: return "Locational Sign"
        case .directory: return "Directory"
        }
    }
}

struct PhoneSceneCaptureConfiguration {
    let requestedFPS: Int
    let rawSceneDepthEnabled: Bool
    let smoothedSceneDepthEnabled: Bool
    let meshExpected: Bool
    let sceneReconstructionMode: String
}

struct PhoneSceneFinalizationContext {
    let throttledFrames: Int
    let rawDepthUnavailableFrames: Int
    let maximumAngularVelocityDegS: Double
}

struct SignBookmarkContext {
    let frameID: Int
    let timestamp: TimeInterval
    let cameraToWorld: simd_float4x4
    let trackingState: String
}

final class FrameWriter {
    private enum Lifecycle {
        case idle
        case recording
        case stopping
        case finished
        case failed
    }

    private let queue = DispatchQueue(label: "phone-scene.frame-writer", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private let encoder = JSONEncoder()
    private let maxPendingWrites = 6

    private var lifecycle: Lifecycle = .idle
    private var stagingURL: URL?
    private var finalURL: URL?
    private var manifestHandle: FileHandle?
    private var bookmarkHandle: FileHandle?
    private var eventHandle: FileHandle?
    private var configuration: PhoneSceneCaptureConfiguration?
    private var captureID = ""
    private var recordingStartedAt: Date?

    private var pendingWriteCount = 0
    private var acceptedFrameCount = 0
    private var writtenFrameCount = 0
    private var totalDroppedWrites = 0
    private var totalRejectedAfterStop = 0
    private var totalFailedWrites = 0
    private var requestedBookmarkCount = 0
    private var writtenBookmarkCount = 0
    private var failedBookmarkCount = 0
    private var failedEventCount = 0
    private var lastWriteErrorMessage: String?
    private var writtenFrameIDs: Set<Int> = []
    private var firstFrameTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval?
    private var trackingStateCounts: [String: Int] = [:]

    init() {
        encoder.outputFormatting = [.sortedKeys]
    }

    var pendingWrites: Int {
        withStateLock { pendingWriteCount }
    }

    var droppedWrites: Int {
        withStateLock { totalDroppedWrites }
    }

    var failedWrites: Int {
        withStateLock { totalFailedWrites }
    }

    var lastWriteError: String? {
        withStateLock { lastWriteErrorMessage }
    }

    var highPressurePendingWrites: Int {
        max(1, maxPendingWrites - 2)
    }

    var lowPressurePendingWrites: Int {
        1
    }

    var canAcceptFrame: Bool {
        withStateLock { lifecycle == .recording && pendingWriteCount < maxPendingWrites }
    }

    func start(configuration: PhoneSceneCaptureConfiguration) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lifecycle != .recording && lifecycle != .stopping else {
            throw FrameWriterError.alreadyRecording
        }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let captureID = UUID().uuidString.lowercased()
        let stem = "scene_\(formatter.string(from: Date()))_\(captureID.prefix(8))"
        let final = documents.appendingPathComponent("\(stem).phonescene", isDirectory: true)
        let staging = documents.appendingPathComponent("\(stem).phonescene.partial", isDirectory: true)
        guard !fileManager.fileExists(atPath: final.path),
              !fileManager.fileExists(atPath: staging.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var setupComplete = false
        defer {
            if !setupComplete {
                try? manifestHandle?.close()
                try? bookmarkHandle?.close()
                try? eventHandle?.close()
                manifestHandle = nil
                bookmarkHandle = nil
                eventHandle = nil
                stagingURL = nil
                finalURL = nil
                self.configuration = nil
                captureID = ""
                recordingStartedAt = nil
                lifecycle = .idle
                try? fileManager.removeItem(at: staging)
            }
        }

        for directory in [
            "rgb", "depth", "confidence", "depth_smoothed", "confidence_smoothed",
            "mesh", "annotation",
        ] {
            try fileManager.createDirectory(
                at: staging.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let startedAt = Date()
        let metadata = metadataPayload(
            captureID: captureID,
            startedAt: startedAt,
            configuration: configuration
        )
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadataData.write(to: staging.appendingPathComponent("metadata.json"), options: [.atomic])

        let manifestURL = staging.appendingPathComponent("manifest.jsonl")
        let bookmarkURL = staging.appendingPathComponent("annotation/sign_bookmarks.jsonl")
        let eventURL = staging.appendingPathComponent("session_events.jsonl")
        guard fileManager.createFile(atPath: manifestURL.path, contents: nil),
              fileManager.createFile(atPath: bookmarkURL.path, contents: nil),
              fileManager.createFile(atPath: eventURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        manifestHandle = try FileHandle(forWritingTo: manifestURL)
        bookmarkHandle = try FileHandle(forWritingTo: bookmarkURL)
        eventHandle = try FileHandle(forWritingTo: eventURL)
        stagingURL = staging
        finalURL = final
        self.configuration = configuration
        self.captureID = captureID
        recordingStartedAt = startedAt
        resetCountersLocked()
        lifecycle = .recording

        let startEvent = CaptureSessionEvent(
            event_id: UUID().uuidString.lowercased(),
            event_type: "recording_started",
            wall_time_utc: Self.iso8601(startedAt),
            frame_timestamp: nil,
            details: ["requested_fps": String(configuration.requestedFPS)]
        )
        try append(startEvent, to: eventHandle)
        setupComplete = true
        return staging
    }

    @discardableResult
    func write(
        frame: ARFrame,
        rawDepthData: ARDepthData,
        smoothedDepthData: ARDepthData?,
        frameID: Int
    ) -> Bool {
        stateLock.lock()
        guard lifecycle == .recording else {
            totalRejectedAfterStop += 1
            stateLock.unlock()
            return false
        }
        guard pendingWriteCount < maxPendingWrites else {
            totalDroppedWrites += 1
            stateLock.unlock()
            return false
        }
        pendingWriteCount += 1
        acceptedFrameCount += 1
        queue.async {
            self.writeQueued(
                frame: frame,
                rawDepthData: rawDepthData,
                smoothedDepthData: smoothedDepthData,
                frameID: frameID
            )
        }
        stateLock.unlock()
        return true
    }

    @discardableResult
    func markSign(_ context: SignBookmarkContext, cueType: SignBookmarkCueType) -> Bool {
        stateLock.lock()
        guard lifecycle == .recording else {
            stateLock.unlock()
            return false
        }
        requestedBookmarkCount += 1
        queue.async {
            self.writeSignBookmarkQueued(context, cueType: cueType)
        }
        stateLock.unlock()
        return true
    }

    func recordSessionEvent(
        type: String,
        frameTimestamp: TimeInterval? = nil,
        details: [String: String] = [:]
    ) {
        stateLock.lock()
        guard lifecycle == .recording else {
            stateLock.unlock()
            return
        }
        let event = CaptureSessionEvent(
            event_id: UUID().uuidString.lowercased(),
            event_type: type,
            wall_time_utc: Self.iso8601(Date()),
            frame_timestamp: frameTimestamp,
            details: details
        )
        queue.async {
            do {
                try self.append(event, to: self.eventHandle)
            } catch {
                self.stateLock.lock()
                self.failedEventCount += 1
                self.lastWriteErrorMessage = error.localizedDescription
                self.stateLock.unlock()
            }
        }
        stateLock.unlock()
    }

    func finish(
        meshAnchors: [ARMeshAnchor],
        context: PhoneSceneFinalizationContext,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        stateLock.lock()
        guard lifecycle == .recording else {
            let error: FrameWriterError = lifecycle == .stopping
                ? .finalizationInProgress
                : .notRecording
            stateLock.unlock()
            completion(.failure(error))
            return
        }
        lifecycle = .stopping
        queue.async {
            self.finishQueued(meshAnchors: meshAnchors, context: context, completion: completion)
        }
        stateLock.unlock()
    }

    static func annotationDirectory(for sceneURL: URL) throws -> URL {
        let annotationURL = sceneURL.appendingPathComponent("annotation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: annotationURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return annotationURL
    }

    @discardableResult
    static func writeAnnotationData(_ data: Data, named filename: String, in sceneURL: URL) throws -> URL {
        let annotationURL = try annotationDirectory(for: sceneURL)
        let outputURL = annotationURL.appendingPathComponent(filename)
        try data.write(to: outputURL, options: [.atomic])
        return outputURL
    }

    private func writeQueued(
        frame: ARFrame,
        rawDepthData: ARDepthData,
        smoothedDepthData: ARDepthData?,
        frameID: Int
    ) {
        autoreleasepool {
            defer {
                stateLock.lock()
                pendingWriteCount = max(0, pendingWriteCount - 1)
                stateLock.unlock()
            }
            do {
                let trackingState = trackingStateDescription(frame.camera.trackingState)
                try writeSync(
                    frame: frame,
                    rawDepthData: rawDepthData,
                    smoothedDepthData: smoothedDepthData,
                    frameID: frameID,
                    trackingState: trackingState
                )
                stateLock.lock()
                writtenFrameCount += 1
                writtenFrameIDs.insert(frameID)
                firstFrameTimestamp = firstFrameTimestamp ?? frame.timestamp
                lastFrameTimestamp = frame.timestamp
                trackingStateCounts[trackingState, default: 0] += 1
                stateLock.unlock()
            } catch {
                stateLock.lock()
                totalFailedWrites += 1
                lastWriteErrorMessage = error.localizedDescription
                stateLock.unlock()
                NSLog("PhoneSceneCapture write failed: \(error)")
            }
        }
    }

    private func writeSignBookmarkQueued(
        _ context: SignBookmarkContext,
        cueType: SignBookmarkCueType
    ) {
        let bookmark = SignBookmarkEntry(
            bookmark_id: UUID().uuidString.lowercased(),
            frame_id: context.frameID,
            frame_timestamp: context.timestamp,
            created_at_utc: Self.iso8601(Date()),
            source_rgb: String(format: "rgb/%06d.png", context.frameID),
            cue_type: cueType,
            camera_to_world: MatrixJSON.rows(context.cameraToWorld),
            tracking_state: context.trackingState,
            review_status: "unreviewed"
        )
        do {
            try append(bookmark, to: bookmarkHandle)
            stateLock.lock()
            writtenBookmarkCount += 1
            stateLock.unlock()
        } catch {
            stateLock.lock()
            failedBookmarkCount += 1
            lastWriteErrorMessage = error.localizedDescription
            stateLock.unlock()
            NSLog("PhoneSceneCapture sign bookmark write failed: \(error)")
        }
    }

    private func finishQueued(
        meshAnchors: [ARMeshAnchor],
        context: PhoneSceneFinalizationContext,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let stagingURL, let finalURL, let configuration else {
            completion(.failure(FrameWriterError.notRecording))
            return
        }

        var closeErrors: [String] = []
        for (name, handle) in [
            ("manifest", manifestHandle),
            ("sign_bookmarks", bookmarkHandle),
            ("session_events", eventHandle),
        ] {
            do {
                try handle?.synchronize()
                try handle?.close()
            } catch {
                closeErrors.append("\(name)_close_error")
                NSLog("PhoneSceneCapture \(name) close failed: \(error)")
            }
        }
        manifestHandle = nil
        bookmarkHandle = nil
        eventHandle = nil

        var meshSummary: MeshExportSummary?
        var meshExportError: String?
        if !meshAnchors.isEmpty {
            do {
                meshSummary = try MeshPLYWriter.write(
                    meshAnchors: meshAnchors,
                    to: stagingURL.appendingPathComponent("mesh/arkit_mesh_world.ply")
                )
            } catch {
                meshExportError = error.localizedDescription
                NSLog("PhoneSceneCapture mesh export failed: \(error)")
            }
        }

        let snapshot = counterSnapshot()
        var integrityFailures = closeErrors
        if snapshot.pendingWrites != 0 { integrityFailures.append("pending_writes_nonzero") }
        if snapshot.acceptedFrames != snapshot.writtenFrames {
            integrityFailures.append("accepted_written_frame_count_mismatch")
        }
        if snapshot.failedWrites != 0 { integrityFailures.append("failed_frame_writes_nonzero") }
        if snapshot.droppedWrites != 0 { integrityFailures.append("dropped_frame_writes_nonzero") }
        if snapshot.rejectedAfterStop != 0 { integrityFailures.append("post_stop_frame_attempts_nonzero") }
        if snapshot.requestedBookmarks != snapshot.writtenBookmarks {
            integrityFailures.append("sign_bookmark_count_mismatch")
        }
        if snapshot.failedBookmarks != 0 { integrityFailures.append("failed_sign_bookmarks_nonzero") }
        if snapshot.failedEvents != 0 { integrityFailures.append("failed_session_events_nonzero") }
        if snapshot.writtenFrames == 0 { integrityFailures.append("no_frames_written") }
        let expectedFrameIDs = Set(0..<snapshot.writtenFrames)
        if snapshot.writtenFrameIDs != expectedFrameIDs {
            integrityFailures.append("frame_ids_not_contiguous")
        }
        if configuration.meshExpected && meshAnchors.isEmpty {
            integrityFailures.append("expected_arkit_mesh_missing")
        }
        if meshExportError != nil { integrityFailures.append("mesh_export_failed") }

        let stats = captureStatsPayload(
            snapshot: snapshot,
            context: context,
            configuration: configuration,
            meshSummary: meshSummary,
            meshExportError: meshExportError,
            integrityFailures: integrityFailures
        )
        do {
            let data = try JSONSerialization.data(
                withJSONObject: stats,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: stagingURL.appendingPathComponent("capture_stats.json"), options: [.atomic])
        } catch {
            integrityFailures.append("capture_stats_write_failed")
            stateLock.lock()
            lifecycle = .failed
            stateLock.unlock()
            completion(.failure(error))
            return
        }

        guard integrityFailures.isEmpty else {
            stateLock.lock()
            lifecycle = .failed
            stateLock.unlock()
            completion(.failure(FrameWriterError.captureIncomplete(integrityFailures)))
            return
        }

        do {
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
            stateLock.lock()
            lifecycle = .finished
            self.stagingURL = nil
            self.finalURL = nil
            stateLock.unlock()
            completion(.success(finalURL))
        } catch {
            stateLock.lock()
            lifecycle = .failed
            lastWriteErrorMessage = error.localizedDescription
            stateLock.unlock()
            completion(.failure(error))
        }
    }

    private func writeSync(
        frame: ARFrame,
        rawDepthData: ARDepthData,
        smoothedDepthData: ARDepthData?,
        frameID: Int,
        trackingState: String
    ) throws {
        guard let stagingURL, let manifestHandle else {
            throw FrameWriterError.notRecording
        }

        let stem = String(format: "%06d", frameID)
        let rgbURL = stagingURL.appendingPathComponent("rgb/\(stem).png")
        let depthURL = stagingURL.appendingPathComponent("depth/\(stem).f32")
        let confidenceURL = stagingURL.appendingPathComponent("confidence/\(stem).u8")
        let smoothedDepthURL = stagingURL.appendingPathComponent("depth_smoothed/\(stem).f32")
        let smoothedConfidenceURL = stagingURL.appendingPathComponent("confidence_smoothed/\(stem).u8")
        var materializedFiles: [URL] = []
        var completed = false
        defer {
            if !completed {
                for path in materializedFiles {
                    try? FileManager.default.removeItem(at: path)
                }
            }
        }

        try writeRGB(frame.capturedImage, to: rgbURL)
        materializedFiles.append(rgbURL)
        let depthSize = try writeDepth(rawDepthData.depthMap, to: depthURL)
        materializedFiles.append(depthURL)
        let confidenceSize = try writeConfidence(rawDepthData.confidenceMap, to: confidenceURL)
        if confidenceSize != nil { materializedFiles.append(confidenceURL) }

        var smoothedDepthSize: PixelSize?
        var smoothedConfidenceSize: PixelSize?
        if let smoothedDepthData {
            smoothedDepthSize = try writeDepth(smoothedDepthData.depthMap, to: smoothedDepthURL)
            materializedFiles.append(smoothedDepthURL)
            smoothedConfidenceSize = try writeConfidence(
                smoothedDepthData.confidenceMap,
                to: smoothedConfidenceURL
            )
            if smoothedConfidenceSize != nil { materializedFiles.append(smoothedConfidenceURL) }
        }

        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
        let rawConfidencePixelFormat = rawDepthData.confidenceMap.map {
            pixelFormatDescription($0)
        }
        let smoothedConfidencePixelFormat = smoothedDepthData.flatMap { depthData in
            depthData.confidenceMap.map { pixelFormatDescription($0) }
        }
        let entry = FrameManifestEntry(
            frame_id: frameID,
            timestamp: frame.timestamp,
            rgb: "rgb/\(stem).png",
            depth: "depth/\(stem).f32",
            confidence: confidenceSize == nil ? nil : "confidence/\(stem).u8",
            depth_source: "scene_depth_raw",
            smoothed_depth: smoothedDepthSize == nil ? nil : "depth_smoothed/\(stem).f32",
            smoothed_confidence: smoothedConfidenceSize == nil
                ? nil
                : "confidence_smoothed/\(stem).u8",
            image_width: imageWidth,
            image_height: imageHeight,
            image_pixel_format: pixelFormatDescription(frame.capturedImage),
            depth_width: depthSize.width,
            depth_height: depthSize.height,
            depth_pixel_format: pixelFormatDescription(rawDepthData.depthMap),
            confidence_width: confidenceSize?.width,
            confidence_height: confidenceSize?.height,
            confidence_pixel_format: rawConfidencePixelFormat,
            smoothed_depth_width: smoothedDepthSize?.width,
            smoothed_depth_height: smoothedDepthSize?.height,
            smoothed_depth_pixel_format: smoothedDepthData.map {
                pixelFormatDescription($0.depthMap)
            },
            smoothed_confidence_width: smoothedConfidenceSize?.width,
            smoothed_confidence_height: smoothedConfidenceSize?.height,
            smoothed_confidence_pixel_format: smoothedConfidencePixelFormat,
            intrinsics: MatrixJSON.rows(frame.camera.intrinsics),
            camera_to_world: MatrixJSON.rows(frame.camera.transform),
            tracking_state: trackingState
        )
        try append(entry, to: manifestHandle)
        completed = true
    }

    private func writeRGB(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let temporaryURL = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporaryURL)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        do {
            try ciContext.writePNGRepresentation(
                of: image,
                to: temporaryURL,
                format: .RGBA8,
                colorSpace: colorSpace
            )
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func writeDepth(_ pixelBuffer: CVPixelBuffer, to url: URL) throws -> PixelSize {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_DepthFloat32 else {
            throw FrameWriterError.invalidDepthPixelFormat(format)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FrameWriterError.invalidDepthBuffer
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var data = Data()
        data.reserveCapacity(width * height * MemoryLayout<Float32>.size)
        for row in 0..<height {
            let rowPointer = base.advanced(by: row * bytesPerRow)
            data.append(
                rowPointer.assumingMemoryBound(to: UInt8.self),
                count: width * MemoryLayout<Float32>.size
            )
        }
        try data.write(to: url, options: [.atomic])
        return PixelSize(width: width, height: height)
    }

    private func writeConfidence(_ pixelBuffer: CVPixelBuffer?, to url: URL) throws -> PixelSize? {
        guard let pixelBuffer else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_OneComponent8 else {
            throw FrameWriterError.invalidConfidencePixelFormat(format)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FrameWriterError.invalidConfidenceBuffer
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var data = Data()
        data.reserveCapacity(width * height)
        for row in 0..<height {
            let rowPointer = base.advanced(by: row * bytesPerRow)
            data.append(rowPointer.assumingMemoryBound(to: UInt8.self), count: width)
        }
        try data.write(to: url, options: [.atomic])
        return PixelSize(width: width, height: height)
    }

    private func append<T: Encodable>(_ value: T, to handle: FileHandle?) throws {
        guard let handle else { throw FrameWriterError.notRecording }
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func captureStatsPayload(
        snapshot: CounterSnapshot,
        context: PhoneSceneFinalizationContext,
        configuration: PhoneSceneCaptureConfiguration,
        meshSummary: MeshExportSummary?,
        meshExportError: String?,
        integrityFailures: [String]
    ) -> [String: Any] {
        let duration: TimeInterval
        if let first = snapshot.firstFrameTimestamp, let last = snapshot.lastFrameTimestamp {
            duration = max(0, last - first)
        } else {
            duration = 0
        }
        var payload: [String: Any] = [
            "capture_id": captureID,
            "format_version": 2,
            "recording_started_at_utc": recordingStartedAt.map(Self.iso8601) ?? "unknown",
            "recording_finished_at_utc": Self.iso8601(Date()),
            "requested_fps": configuration.requestedFPS,
            "duration_s": duration,
            "accepted_frames": snapshot.acceptedFrames,
            "written_frames": snapshot.writtenFrames,
            "pending_writes_at_finish": snapshot.pendingWrites,
            "dropped_writes": snapshot.droppedWrites,
            "rejected_after_stop": snapshot.rejectedAfterStop,
            "failed_writes": snapshot.failedWrites,
            "throttled_frames": context.throttledFrames,
            "raw_depth_unavailable_frames": context.rawDepthUnavailableFrames,
            "maximum_angular_velocity_deg_s": context.maximumAngularVelocityDegS,
            "requested_sign_bookmarks": snapshot.requestedBookmarks,
            "written_sign_bookmarks": snapshot.writtenBookmarks,
            "failed_sign_bookmarks": snapshot.failedBookmarks,
            "failed_session_events": snapshot.failedEvents,
            "tracking_state_counts": snapshot.trackingStateCounts,
            "base_capture_complete": integrityFailures.isEmpty,
            "integrity_failures": integrityFailures,
        ]
        if duration > 0 {
            payload["actual_written_fps"] = Double(max(0, snapshot.writtenFrames - 1)) / duration
        }
        if let lastWriteError = snapshot.lastWriteError {
            payload["last_write_error"] = lastWriteError
        }
        if let meshExportError {
            payload["mesh_export_error"] = meshExportError
        }
        if let meshSummary {
            payload["mesh"] = meshSummary.jsonObject
        }
        return payload
    }

    private func metadataPayload(
        captureID: String,
        startedAt: Date,
        configuration: PhoneSceneCaptureConfiguration
    ) -> [String: Any] {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let gitCommit = bundle.object(forInfoDictionaryKey: "SIDARGitCommit") as? String
            ?? "unknown"
        return [
            "format": "phonescene",
            "format_version": 2,
            "capture_id": captureID,
            "created_at_utc": Self.iso8601(startedAt),
            "device": UIDevice.current.model,
            "device_info": [
                "hardware_identifier": Self.hardwareIdentifier(),
                "model": UIDevice.current.model,
                "system_name": UIDevice.current.systemName,
                "system_version": UIDevice.current.systemVersion,
            ],
            "app": [
                "name": "SIDAR",
                "version": appVersion,
                "build": buildNumber,
                "git_commit": gitCommit,
            ],
            "capture": [
                "requested_fps": configuration.requestedFPS,
                "raw_scene_depth_enabled": configuration.rawSceneDepthEnabled,
                "smoothed_scene_depth_enabled": configuration.smoothedSceneDepthEnabled,
                "mesh_expected": configuration.meshExpected,
                "scene_reconstruction_mode": configuration.sceneReconstructionMode,
            ],
            "world_alignment": "gravity",
            "camera_model": "arkit_lidar",
            "rgb_color_space": "sRGB",
            "rgb_orientation": "native_sensor",
            "depth_units": "meters",
            "primary_depth_stream": "scene_depth_raw",
            "pose": [
                "convention": "arkit_cam_to_world",
                "matrix_order": "row_major_4x4",
            ],
        ]
    }

    private func counterSnapshot() -> CounterSnapshot {
        withStateLock {
            CounterSnapshot(
                pendingWrites: pendingWriteCount,
                acceptedFrames: acceptedFrameCount,
                writtenFrames: writtenFrameCount,
                droppedWrites: totalDroppedWrites,
                rejectedAfterStop: totalRejectedAfterStop,
                failedWrites: totalFailedWrites,
                requestedBookmarks: requestedBookmarkCount,
                writtenBookmarks: writtenBookmarkCount,
                failedBookmarks: failedBookmarkCount,
                failedEvents: failedEventCount,
                lastWriteError: lastWriteErrorMessage,
                writtenFrameIDs: writtenFrameIDs,
                firstFrameTimestamp: firstFrameTimestamp,
                lastFrameTimestamp: lastFrameTimestamp,
                trackingStateCounts: trackingStateCounts
            )
        }
    }

    private func resetCountersLocked() {
        pendingWriteCount = 0
        acceptedFrameCount = 0
        writtenFrameCount = 0
        totalDroppedWrites = 0
        totalRejectedAfterStop = 0
        totalFailedWrites = 0
        requestedBookmarkCount = 0
        writtenBookmarkCount = 0
        failedBookmarkCount = 0
        failedEventCount = 0
        lastWriteErrorMessage = nil
        writtenFrameIDs = []
        firstFrameTimestamp = nil
        lastFrameTimestamp = nil
        trackingStateCounts = [:]
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func trackingStateDescription(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not_available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .initializing: return "limited_initializing"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_unknown"
            }
        }
    }

    private func pixelFormatDescription(_ pixelBuffer: CVPixelBuffer) -> String {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bytes = [
            UInt8((format >> 24) & 0xff),
            UInt8((format >> 16) & 0xff),
            UInt8((format >> 8) & 0xff),
            UInt8(format & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return String(format: "0x%08x", UInt32(format))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func hardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: machine)
    }
}

private struct PixelSize {
    let width: Int
    let height: Int
}

private struct CounterSnapshot {
    let pendingWrites: Int
    let acceptedFrames: Int
    let writtenFrames: Int
    let droppedWrites: Int
    let rejectedAfterStop: Int
    let failedWrites: Int
    let requestedBookmarks: Int
    let writtenBookmarks: Int
    let failedBookmarks: Int
    let failedEvents: Int
    let lastWriteError: String?
    let writtenFrameIDs: Set<Int>
    let firstFrameTimestamp: TimeInterval?
    let lastFrameTimestamp: TimeInterval?
    let trackingStateCounts: [String: Int]
}

private struct CaptureSessionEvent: Encodable {
    let event_id: String
    let event_type: String
    let wall_time_utc: String
    let frame_timestamp: TimeInterval?
    let details: [String: String]
}

private struct SignBookmarkEntry: Encodable {
    let bookmark_id: String
    let frame_id: Int
    let frame_timestamp: TimeInterval
    let created_at_utc: String
    let source_rgb: String
    let cue_type: SignBookmarkCueType
    let camera_to_world: [[Float]]
    let tracking_state: String
    let review_status: String
}

private struct FrameManifestEntry: Encodable {
    let frame_id: Int
    let timestamp: TimeInterval
    let rgb: String
    let depth: String
    let confidence: String?
    let depth_source: String
    let smoothed_depth: String?
    let smoothed_confidence: String?
    let image_width: Int
    let image_height: Int
    let image_pixel_format: String
    let depth_width: Int
    let depth_height: Int
    let depth_pixel_format: String
    let confidence_width: Int?
    let confidence_height: Int?
    let confidence_pixel_format: String?
    let smoothed_depth_width: Int?
    let smoothed_depth_height: Int?
    let smoothed_depth_pixel_format: String?
    let smoothed_confidence_width: Int?
    let smoothed_confidence_height: Int?
    let smoothed_confidence_pixel_format: String?
    let intrinsics: [[Float]]
    let camera_to_world: [[Float]]
    let tracking_state: String
}
