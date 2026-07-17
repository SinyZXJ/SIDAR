import ARKit
import Foundation
import SwiftUI
import simd

enum CaptureFrameRate: Int, CaseIterable, Identifiable {
    case fps2 = 2
    case fps5 = 5
    case fps10 = 10
    case fps15 = 15

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue) FPS"
    }
}

final class ARRecorder: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var isRecording = false
    @Published var isFinalizing = false
    @Published var trackingSummary = "starting"
    @Published var frameCount = 0
    @Published var currentSceneURL: URL?
    @Published var completedSceneForAnnotation: URL?
    @Published var annotationBuildError: String?
    @Published var annotationMapBuildProgress: SceneBuildProgress?
    @Published var captureFrameRate: CaptureFrameRate = .fps10
    @Published var droppedFrameCount = 0
    @Published var throttledFrameCount = 0
    @Published var signBookmarkCount = 0
    @Published var canMarkSign = false
    @Published var motionWarning = false

    private let writer = FrameWriter()
    private let captureLock = NSLock()
    private var acceptingFrames = false
    private var nextFrameID = 0
    private var lastCaptureTimestamp: TimeInterval = 0
    private var trajectoryXY: [[Double]] = []
    private var trajectoryXYZ: [[Double]] = []
    private var latestBookmarkContext: SignBookmarkContext?
    private var adaptiveCaptureMultiplier = 1.0
    private var totalThrottledFrames = 0
    private var rawDepthUnavailableFrames = 0
    private var previousAcceptedTransform: simd_float4x4?
    private var previousAcceptedTimestamp: TimeInterval?
    private var currentAngularVelocityDegS = 0.0
    private var maximumAngularVelocityDegS = 0.0
    private var rawSceneDepthEnabled = false
    private var smoothedSceneDepthEnabled = false
    private var meshExpected = false
    private var sceneReconstructionMode = "none"
    private let maxAdaptiveCaptureMultiplier = 4.0

    private var captureInterval: TimeInterval {
        (1.0 / Double(captureFrameRate.rawValue)) * adaptiveCaptureMultiplier
    }

    override init() {
        super.init()
        session.delegate = self
    }

    func startSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]

        var semantics: ARConfiguration.FrameSemantics = []
        rawSceneDepthEnabled = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        smoothedSceneDepthEnabled = ARWorldTrackingConfiguration.supportsFrameSemantics(
            .smoothedSceneDepth
        )
        if rawSceneDepthEnabled {
            semantics.insert(.sceneDepth)
        }
        if smoothedSceneDepthEnabled {
            semantics.insert(.smoothedSceneDepth)
        }
        configuration.frameSemantics = semantics

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            configuration.environmentTexturing = .automatic
            meshExpected = true
            sceneReconstructionMode = "mesh_with_classification"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            configuration.environmentTexturing = .automatic
            meshExpected = true
            sceneReconstructionMode = "mesh"
        } else {
            meshExpected = false
            sceneReconstructionMode = "none"
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func resetSession() {
        guard !isRecording, !isFinalizing else { return }
        captureLock.lock()
        resetCaptureStateLocked()
        captureLock.unlock()
        startSession()
        frameCount = 0
        droppedFrameCount = 0
        throttledFrameCount = 0
        signBookmarkCount = 0
        canMarkSign = false
        motionWarning = false
        currentSceneURL = nil
        completedSceneForAnnotation = nil
        annotationBuildError = nil
        annotationMapBuildProgress = nil
        trackingSummary = "reset"
    }

    func pauseSession() {
        guard !isRecording, !isFinalizing else { return }
        session.pause()
        trackingSummary = "paused"
    }

    func startRecording() {
        guard !isRecording, !isFinalizing else { return }
        guard rawSceneDepthEnabled else {
            trackingSummary = "record start failed: raw scene depth is unavailable"
            return
        }
        do {
            let configuration = PhoneSceneCaptureConfiguration(
                requestedFPS: captureFrameRate.rawValue,
                rawSceneDepthEnabled: rawSceneDepthEnabled,
                smoothedSceneDepthEnabled: smoothedSceneDepthEnabled,
                meshExpected: meshExpected,
                sceneReconstructionMode: sceneReconstructionMode
            )
            let stagingURL = try writer.start(configuration: configuration)
            captureLock.lock()
            resetCaptureStateLocked()
            acceptingFrames = true
            captureLock.unlock()

            currentSceneURL = stagingURL
            completedSceneForAnnotation = nil
            annotationBuildError = nil
            annotationMapBuildProgress = nil
            frameCount = 0
            droppedFrameCount = 0
            throttledFrameCount = 0
            signBookmarkCount = 0
            canMarkSign = false
            motionWarning = false
            isRecording = true
            trackingSummary = "recording"
        } catch {
            trackingSummary = "record start failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording, !isFinalizing else { return }
        captureLock.lock()
        guard acceptingFrames else {
            captureLock.unlock()
            return
        }
        acceptingFrames = false
        let trajectorySnapshot = trajectoryXY
        let trajectoryXYZSnapshot = trajectoryXYZ
        let throttledSnapshot = totalThrottledFrames
        let rawDepthUnavailableSnapshot = rawDepthUnavailableFrames
        let maximumAngularVelocitySnapshot = maximumAngularVelocityDegS
        latestBookmarkContext = nil
        captureLock.unlock()

        isRecording = false
        isFinalizing = true
        canMarkSign = false
        motionWarning = false
        trackingSummary = "saving"
        writer.recordSessionEvent(
            type: "recording_stop_requested",
            details: ["accepted_frames": String(frameCount)]
        )

        let meshAnchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let context = PhoneSceneFinalizationContext(
            throttledFrames: throttledSnapshot,
            rawDepthUnavailableFrames: rawDepthUnavailableSnapshot,
            maximumAngularVelocityDegS: maximumAngularVelocitySnapshot
        )
        writer.finish(meshAnchors: meshAnchors, context: context) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sceneURL):
                DispatchQueue.main.async {
                    self.currentSceneURL = sceneURL
                    self.trackingSummary = "building annotation map"
                    self.annotationMapBuildProgress = SceneBuildProgress(
                        0.0,
                        "Preparing annotation map"
                    )
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.buildAnnotationArtifacts(
                        sceneURL: sceneURL,
                        meshAnchors: meshAnchors,
                        trajectoryXY: trajectorySnapshot,
                        trajectoryXYZ: trajectoryXYZSnapshot
                    )
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isFinalizing = false
                    self.annotationMapBuildProgress = nil
                    self.trackingSummary = "save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    func markSign(_ cueType: SignBookmarkCueType = .unreviewed) -> Bool {
        captureLock.lock()
        let context = acceptingFrames ? latestBookmarkContext : nil
        captureLock.unlock()
        guard let context, writer.markSign(context, cueType: cueType) else {
            return false
        }
        signBookmarkCount += 1
        return true
    }

    func skipAnnotation() {
        completedSceneForAnnotation = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let trackingDescription = describe(frame.camera.trackingState)
        DispatchQueue.main.async {
            if self.isRecording || !self.isPostCaptureStatusActive {
                self.trackingSummary = self.captureStatusSummary(trackingDescription)
            }
        }

        captureLock.lock()
        guard acceptingFrames else {
            captureLock.unlock()
            return
        }
        guard frame.timestamp - lastCaptureTimestamp >= captureInterval else {
            captureLock.unlock()
            return
        }
        guard let rawDepthData = frame.sceneDepth else {
            rawDepthUnavailableFrames += 1
            lastCaptureTimestamp = frame.timestamp
            captureLock.unlock()
            return
        }

        if writer.pendingWrites >= writer.highPressurePendingWrites {
            totalThrottledFrames += 1
            increaseWritePressureBackoffLocked()
            lastCaptureTimestamp = frame.timestamp
            let throttled = totalThrottledFrames
            let dropped = writer.droppedWrites
            captureLock.unlock()
            DispatchQueue.main.async {
                self.throttledFrameCount = throttled
                self.droppedFrameCount = dropped
                self.trackingSummary = self.captureStatusSummary(trackingDescription)
            }
            return
        }

        let frameID = nextFrameID
        let accepted = writer.write(
            frame: frame,
            rawDepthData: rawDepthData,
            smoothedDepthData: frame.smoothedSceneDepth,
            frameID: frameID
        )
        lastCaptureTimestamp = frame.timestamp
        guard accepted else {
            increaseWritePressureBackoffLocked()
            let dropped = writer.droppedWrites
            captureLock.unlock()
            DispatchQueue.main.async {
                self.droppedFrameCount = dropped
                self.trackingSummary = self.captureStatusSummary(trackingDescription)
            }
            return
        }

        relaxWritePressureBackoffIfPossibleLocked()
        updateMotionQualityLocked(transform: frame.camera.transform, timestamp: frame.timestamp)
        nextFrameID += 1
        let rosTrajectory = PhoneSceneCoordinateConversion.arkitCameraTransformToROSXYZ(
            frame.camera.transform
        )
        trajectoryXY.append([rosTrajectory[0], rosTrajectory[1]])
        trajectoryXYZ.append(rosTrajectory)
        latestBookmarkContext = SignBookmarkContext(
            frameID: frameID,
            timestamp: frame.timestamp,
            cameraToWorld: frame.camera.transform,
            trackingState: manifestTrackingState(frame.camera.trackingState)
        )
        let publishedFrameCount = frameID + 1
        let publishedDroppedCount = writer.droppedWrites
        let publishedThrottledCount = totalThrottledFrames
        let publishedMotionWarning = currentMotionWarningLocked()
        captureLock.unlock()

        DispatchQueue.main.async {
            self.frameCount = publishedFrameCount
            self.droppedFrameCount = publishedDroppedCount
            self.throttledFrameCount = publishedThrottledCount
            self.canMarkSign = true
            self.motionWarning = publishedMotionWarning
            self.trackingSummary = self.captureStatusSummary(trackingDescription)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        writer.recordSessionEvent(type: "session_interrupted")
        DispatchQueue.main.async {
            if self.isRecording {
                self.trackingSummary = "session interrupted"
            }
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        writer.recordSessionEvent(type: "session_interruption_ended")
        DispatchQueue.main.async {
            if self.isRecording {
                self.trackingSummary = "session resumed; verify tracking"
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        writer.recordSessionEvent(
            type: "session_failed",
            details: ["error": error.localizedDescription]
        )
        DispatchQueue.main.async {
            self.trackingSummary = "AR session failed: \(error.localizedDescription)"
        }
    }

    private func buildAnnotationArtifacts(
        sceneURL: URL,
        meshAnchors: [ARMeshAnchor],
        trajectoryXY: [[Double]],
        trajectoryXYZ: [[Double]]
    ) {
        do {
            _ = try TopDownMapBuilder().build(
                sceneURL: sceneURL,
                meshAnchors: meshAnchors,
                trajectoryXY: trajectoryXY,
                trajectoryXYZ: trajectoryXYZ
            ) { progress in
                DispatchQueue.main.async {
                    self.trackingSummary = "building annotation map"
                    self.annotationMapBuildProgress = progress
                }
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    _ = try MeshPreviewAssetBuilder().ensurePreviewAssets(sceneURL: sceneURL)
                } catch {
                    NSLog("SIDAR 3D mesh preview build skipped: \(error)")
                }
            }
            DispatchQueue.main.async {
                self.isFinalizing = false
                self.completedSceneForAnnotation = sceneURL
                self.annotationBuildError = nil
                self.annotationMapBuildProgress = SceneBuildProgress(1.0, "Annotation map ready")
                self.trackingSummary = "saved; annotation ready"
            }
        } catch {
            DispatchQueue.main.async {
                self.isFinalizing = false
                self.completedSceneForAnnotation = nil
                self.annotationBuildError = error.localizedDescription
                self.annotationMapBuildProgress = nil
                self.trackingSummary = "saved; annotation map failed: \(error.localizedDescription)"
            }
        }
    }

    private func resetCaptureStateLocked() {
        acceptingFrames = false
        nextFrameID = 0
        lastCaptureTimestamp = 0
        trajectoryXY = []
        trajectoryXYZ = []
        latestBookmarkContext = nil
        adaptiveCaptureMultiplier = 1.0
        totalThrottledFrames = 0
        rawDepthUnavailableFrames = 0
        previousAcceptedTransform = nil
        previousAcceptedTimestamp = nil
        currentAngularVelocityDegS = 0
        maximumAngularVelocityDegS = 0
    }

    private func increaseWritePressureBackoffLocked() {
        adaptiveCaptureMultiplier = min(
            maxAdaptiveCaptureMultiplier,
            max(1.25, adaptiveCaptureMultiplier * 1.25)
        )
    }

    private func relaxWritePressureBackoffIfPossibleLocked() {
        guard writer.pendingWrites <= writer.lowPressurePendingWrites else { return }
        adaptiveCaptureMultiplier = max(1.0, adaptiveCaptureMultiplier * 0.97)
    }

    private func updateMotionQualityLocked(
        transform: simd_float4x4,
        timestamp: TimeInterval
    ) {
        defer {
            previousAcceptedTransform = transform
            previousAcceptedTimestamp = timestamp
        }
        guard let previousTransform, let previousTimestamp else { return }
        let deltaTime = timestamp - previousTimestamp
        guard deltaTime > 0 else { return }
        let previousRotation = simd_float3x3(columns: (
            SIMD3(previousTransform.columns.0.x, previousTransform.columns.0.y, previousTransform.columns.0.z),
            SIMD3(previousTransform.columns.1.x, previousTransform.columns.1.y, previousTransform.columns.1.z),
            SIMD3(previousTransform.columns.2.x, previousTransform.columns.2.y, previousTransform.columns.2.z)
        ))
        let currentRotation = simd_float3x3(columns: (
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
        let relative = simd_transpose(previousRotation) * currentRotation
        let cosine = min(1.0, max(-1.0, Double((relative.trace - 1.0) * 0.5)))
        let angularVelocity = acos(cosine) * 180.0 / .pi / deltaTime
        currentAngularVelocityDegS = angularVelocity
        maximumAngularVelocityDegS = max(maximumAngularVelocityDegS, angularVelocity)
    }

    private func currentMotionWarningLocked() -> Bool {
        currentAngularVelocityDegS > 120.0
    }

    private func captureStatusSummary(_ trackingDescription: String) -> String {
        captureLock.lock()
        let multiplier = adaptiveCaptureMultiplier
        captureLock.unlock()
        guard isRecording, multiplier > 1.05 else {
            return trackingDescription
        }
        let effectiveFPS = Double(captureFrameRate.rawValue) / multiplier
        return "\(trackingDescription); write pressure \(String(format: "%.1f", effectiveFPS)) FPS"
    }

    private var isPostCaptureStatusActive: Bool {
        trackingSummary == "saving"
            || trackingSummary == "building annotation map"
            || trackingSummary.hasPrefix("saved")
            || trackingSummary.hasPrefix("save failed")
    }

    private func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "limited: motion"
            case .insufficientFeatures: return "limited: features"
            case .initializing: return "initializing"
            case .relocalizing: return "relocalizing"
            @unknown default: return "limited"
            }
        }
    }

    private func manifestTrackingState(_ state: ARCamera.TrackingState) -> String {
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

private extension simd_float3x3 {
    var trace: Float {
        columns.0.x + columns.1.y + columns.2.z
    }
}
