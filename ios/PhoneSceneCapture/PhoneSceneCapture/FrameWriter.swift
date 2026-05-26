import ARKit
import CoreImage
import Foundation
import UIKit

enum FrameWriterError: Error {
    case notRecording
    case invalidDepthBuffer
    case invalidConfidenceBuffer
}

final class FrameWriter {
    private let queue = DispatchQueue(label: "phone-scene.frame-writer", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let pendingLock = NSLock()
    private var rootURL: URL?
    private var manifestHandle: FileHandle?
    private let encoder = JSONEncoder()
    private let maxPendingWrites = 6
    private var pendingWriteCount = 0
    private var totalDroppedWrites = 0
    private var totalFailedWrites = 0
    private var lastWriteErrorMessage: String?

    init() {
        encoder.outputFormatting = [.sortedKeys]
    }

    var pendingWrites: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingWriteCount
    }

    var droppedWrites: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return totalDroppedWrites
    }

    var failedWrites: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return totalFailedWrites
    }

    var lastWriteError: String? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return lastWriteErrorMessage
    }

    var highPressurePendingWrites: Int {
        max(1, maxPendingWrites - 2)
    }

    var lowPressurePendingWrites: Int {
        1
    }

    var canAcceptFrame: Bool {
        pendingWrites < maxPendingWrites
    }

    func start() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "scene_\(formatter.string(from: Date())).phonescene"
        let root = documents.appendingPathComponent(name, isDirectory: true)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("rgb", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("depth", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("confidence", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mesh", isDirectory: true), withIntermediateDirectories: true, attributes: nil)

        let metadata: [String: Any] = [
            "format": "phonescene",
            "format_version": 1,
            "device": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "world_alignment": "gravity",
            "camera_model": "arkit_lidar",
            "rgb_color_space": "sRGB",
            "depth_units": "meters",
            "pose": [
                "convention": "arkit_cam_to_world",
                "matrix_order": "row_major_4x4",
            ],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: root.appendingPathComponent("metadata.json"))

        FileManager.default.createFile(atPath: root.appendingPathComponent("manifest.jsonl").path, contents: nil)
        manifestHandle = try FileHandle(forWritingTo: root.appendingPathComponent("manifest.jsonl"))
        rootURL = root
        resetBackpressureCounters()
        return root
    }

    @discardableResult
    func write(frame: ARFrame, depthData: ARDepthData, frameID: Int) -> Bool {
        guard reserveWriteSlot() else {
            return false
        }

        queue.async {
            autoreleasepool {
                defer {
                    self.releaseWriteSlot()
                }

                do {
                    try self.writeSync(frame: frame, depthData: depthData, frameID: frameID)
                } catch {
                    self.recordWriteFailure(error)
                    NSLog("PhoneSceneCapture write failed: \(error)")
                }
            }
        }
        return true
    }

    func finish(meshAnchors: [ARMeshAnchor], completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let finishedSceneURL = self.rootURL
            var manifestCloseError: Error?
            var meshExportError: Error?

            do {
                try self.manifestHandle?.close()
            } catch {
                manifestCloseError = error
            }

            self.manifestHandle = nil
            self.rootURL = nil

            if let rootURL = finishedSceneURL, !meshAnchors.isEmpty {
                do {
                    let meshURL = rootURL.appendingPathComponent("mesh/arkit_mesh_world.ply")
                    try MeshPLYWriter.write(meshAnchors: meshAnchors, to: meshURL)
                } catch {
                    meshExportError = error
                    NSLog("PhoneSceneCapture mesh export failed after capture save: \(error)")
                }
            }

            if let rootURL = finishedSceneURL {
                do {
                    try self.writeCaptureStats(
                        to: rootURL,
                        manifestCloseError: manifestCloseError,
                        meshExportError: meshExportError
                    )
                } catch {
                    NSLog("PhoneSceneCapture capture_stats write failed: \(error)")
                }
            }

            if let manifestCloseError {
                completion(.failure(manifestCloseError))
            } else {
                completion(.success(()))
            }
        }
    }

    private func reserveWriteSlot() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard pendingWriteCount < maxPendingWrites else {
            totalDroppedWrites += 1
            return false
        }
        pendingWriteCount += 1
        return true
    }

    private func releaseWriteSlot() {
        pendingLock.lock()
        pendingWriteCount = max(0, pendingWriteCount - 1)
        pendingLock.unlock()
    }

    private func recordWriteFailure(_ error: Error) {
        pendingLock.lock()
        totalFailedWrites += 1
        lastWriteErrorMessage = error.localizedDescription
        pendingLock.unlock()
    }

    private func resetBackpressureCounters() {
        pendingLock.lock()
        pendingWriteCount = 0
        totalDroppedWrites = 0
        totalFailedWrites = 0
        lastWriteErrorMessage = nil
        pendingLock.unlock()
    }

    private func writeCaptureStats(
        to rootURL: URL,
        manifestCloseError: Error?,
        meshExportError: Error?
    ) throws {
        let stats: [String: Any?] = [
            "pending_writes_at_finish": pendingWrites,
            "dropped_writes": droppedWrites,
            "failed_writes": failedWrites,
            "last_write_error": lastWriteError,
            "manifest_close_error": manifestCloseError?.localizedDescription,
            "mesh_export_error": meshExportError?.localizedDescription,
            "base_capture_complete": manifestCloseError == nil,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: stats.compactMapValues { $0 },
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: rootURL.appendingPathComponent("capture_stats.json"), options: [.atomic])
    }

    static func annotationDirectory(for sceneURL: URL) throws -> URL {
        let annotationURL = sceneURL.appendingPathComponent("annotation", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationURL, withIntermediateDirectories: true, attributes: nil)
        return annotationURL
    }

    @discardableResult
    static func writeAnnotationData(_ data: Data, named filename: String, in sceneURL: URL) throws -> URL {
        let annotationURL = try annotationDirectory(for: sceneURL)
        let outputURL = annotationURL.appendingPathComponent(filename)
        try data.write(to: outputURL, options: [.atomic])
        return outputURL
    }

    private func writeSync(frame: ARFrame, depthData: ARDepthData, frameID: Int) throws {
        guard let rootURL, let manifestHandle else {
            throw FrameWriterError.notRecording
        }

        let stem = String(format: "%06d", frameID)
        let rgbURL = rootURL.appendingPathComponent("rgb/\(stem).png")
        let depthURL = rootURL.appendingPathComponent("depth/\(stem).f32")
        let confidenceURL = rootURL.appendingPathComponent("confidence/\(stem).u8")

        try writeRGB(frame.capturedImage, to: rgbURL)
        let depthSize = try writeDepth(depthData.depthMap, to: depthURL)
        let confidenceSize = try writeConfidence(depthData.confidenceMap, to: confidenceURL)
        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)

        let entry = FrameManifestEntry(
            frame_id: frameID,
            timestamp: frame.timestamp,
            rgb: "rgb/\(stem).png",
            depth: "depth/\(stem).f32",
            confidence: "confidence/\(stem).u8",
            image_width: imageWidth,
            image_height: imageHeight,
            depth_width: depthSize.width,
            depth_height: depthSize.height,
            intrinsics: MatrixJSON.rows(frame.camera.intrinsics),
            camera_to_world: MatrixJSON.rows(frame.camera.transform),
            tracking_state: trackingStateDescription(frame.camera.trackingState),
            confidence_width: confidenceSize.width,
            confidence_height: confidenceSize.height
        )
        let data = try encoder.encode(entry)
        manifestHandle.write(data)
        manifestHandle.write(Data([0x0A]))
    }

    private func writeRGB(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try ciContext.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: colorSpace)
    }

    private func writeDepth(_ pixelBuffer: CVPixelBuffer, to url: URL) throws -> (width: Int, height: Int) {
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
            let rowPtr = base.advanced(by: row * bytesPerRow)
            data.append(rowPtr.assumingMemoryBound(to: UInt8.self), count: width * MemoryLayout<Float32>.size)
        }
        try data.write(to: url)
        return (width, height)
    }

    private func writeConfidence(_ pixelBuffer: CVPixelBuffer?, to url: URL) throws -> (width: Int, height: Int) {
        guard let pixelBuffer else {
            try Data().write(to: url)
            return (0, 0)
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
            let rowPtr = base.advanced(by: row * bytesPerRow)
            data.append(rowPtr.assumingMemoryBound(to: UInt8.self), count: width)
        }
        try data.write(to: url)
        return (width, height)
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
}

struct FrameManifestEntry: Encodable {
    let frame_id: Int
    let timestamp: TimeInterval
    let rgb: String
    let depth: String
    let confidence: String
    let image_width: Int
    let image_height: Int
    let depth_width: Int
    let depth_height: Int
    let intrinsics: [[Float]]
    let camera_to_world: [[Float]]
    let tracking_state: String
    let confidence_width: Int
    let confidence_height: Int
}
