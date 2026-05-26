import ARKit
import Foundation
import SwiftUI

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
    @Published var trackingSummary = "starting"
    @Published var frameCount = 0
    @Published var currentSceneURL: URL?
    @Published var completedSceneForAnnotation: URL?
    @Published var annotationBuildError: String?
    @Published var annotationMapBuildProgress: SceneBuildProgress?
    @Published var captureFrameRate: CaptureFrameRate = .fps10
    @Published var droppedFrameCount = 0
    @Published var throttledFrameCount = 0

    private let writer = FrameWriter()
    private var nextFrameID = 0
    private var lastCaptureTimestamp: TimeInterval = 0
    private var trajectoryXY: [[Double]] = []
    private var trajectoryXYZ: [[Double]] = []
    private var adaptiveCaptureMultiplier = 1.0
    private var totalThrottledFrames = 0
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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        }
        configuration.frameSemantics = semantics

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            configuration.environmentTexturing = .automatic
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            configuration.environmentTexturing = .automatic
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func resetSession() {
        startSession()
        frameCount = 0
        nextFrameID = 0
        trajectoryXY = []
        trajectoryXYZ = []
        droppedFrameCount = 0
        throttledFrameCount = 0
        totalThrottledFrames = 0
        adaptiveCaptureMultiplier = 1.0
        completedSceneForAnnotation = nil
        annotationBuildError = nil
        annotationMapBuildProgress = nil
        trackingSummary = "reset"
    }

    func pauseSession() {
        session.pause()
        trackingSummary = "paused"
    }

    func startRecording() {
        do {
            let sceneURL = try writer.start()
            currentSceneURL = sceneURL
            completedSceneForAnnotation = nil
            annotationBuildError = nil
            annotationMapBuildProgress = nil
            nextFrameID = 0
            frameCount = 0
            droppedFrameCount = 0
            throttledFrameCount = 0
            totalThrottledFrames = 0
            adaptiveCaptureMultiplier = 1.0
            trajectoryXY = []
            trajectoryXYZ = []
            lastCaptureTimestamp = 0
            isRecording = true
        } catch {
            trackingSummary = "record start failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let meshAnchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let sceneURL = currentSceneURL
        let trajectorySnapshot = trajectoryXY
        let trajectoryXYZSnapshot = trajectoryXYZ
        trackingSummary = "saving"
        writer.finish(meshAnchors: meshAnchors) { [weak self] result in
            switch result {
            case .success:
                if let sceneURL {
                    DispatchQueue.main.async {
                        self?.trackingSummary = "building annotation map"
                        self?.annotationMapBuildProgress = SceneBuildProgress(0.0, "Preparing annotation map")
                    }
                    do {
                        _ = try TopDownMapBuilder().build(
                            sceneURL: sceneURL,
                            meshAnchors: meshAnchors,
                            trajectoryXY: trajectorySnapshot,
                            trajectoryXYZ: trajectoryXYZSnapshot
                        ) { progress in
                            DispatchQueue.main.async {
                                self?.trackingSummary = "building annotation map"
                                self?.annotationMapBuildProgress = progress
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
                            self?.completedSceneForAnnotation = sceneURL
                            self?.annotationBuildError = nil
                            self?.annotationMapBuildProgress = SceneBuildProgress(1.0, "Annotation map ready")
                            self?.trackingSummary = "saved; annotation ready"
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.completedSceneForAnnotation = nil
                            self?.annotationBuildError = error.localizedDescription
                            self?.annotationMapBuildProgress = nil
                            self?.trackingSummary = "saved; annotation map failed: \(error.localizedDescription)"
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.trackingSummary = "saved"
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.annotationMapBuildProgress = nil
                    self?.trackingSummary = "save failed: \(error.localizedDescription)"
                }
            }
        }
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

        guard isRecording else { return }
        guard frame.timestamp - lastCaptureTimestamp >= captureInterval else { return }
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        guard let depthData else { return }

        if writer.pendingWrites >= writer.highPressurePendingWrites {
            totalThrottledFrames += 1
            increaseWritePressureBackoff()
            lastCaptureTimestamp = frame.timestamp
            DispatchQueue.main.async {
                self.throttledFrameCount = self.totalThrottledFrames
                self.droppedFrameCount = self.writer.droppedWrites
                self.trackingSummary = self.captureStatusSummary(trackingDescription)
            }
            return
        }

        let frameID = nextFrameID
        let accepted = writer.write(frame: frame, depthData: depthData, frameID: frameID)
        lastCaptureTimestamp = frame.timestamp
        guard accepted else {
            increaseWritePressureBackoff()
            DispatchQueue.main.async {
                self.droppedFrameCount = self.writer.droppedWrites
                self.trackingSummary = self.captureStatusSummary(trackingDescription)
            }
            return
        }

        relaxWritePressureBackoffIfPossible()
        nextFrameID += 1
        let rosTrajectory = PhoneSceneCoordinateConversion.arkitCameraTransformToROSXYZ(frame.camera.transform)
        trajectoryXY.append([rosTrajectory[0], rosTrajectory[1]])
        trajectoryXYZ.append(rosTrajectory)
        DispatchQueue.main.async {
            self.frameCount = frameID + 1
            self.droppedFrameCount = self.writer.droppedWrites
            self.throttledFrameCount = self.totalThrottledFrames
            self.trackingSummary = self.captureStatusSummary(trackingDescription)
        }
    }

    private func increaseWritePressureBackoff() {
        adaptiveCaptureMultiplier = min(
            maxAdaptiveCaptureMultiplier,
            max(1.25, adaptiveCaptureMultiplier * 1.25)
        )
    }

    private func relaxWritePressureBackoffIfPossible() {
        guard writer.pendingWrites <= writer.lowPressurePendingWrites else { return }
        adaptiveCaptureMultiplier = max(1.0, adaptiveCaptureMultiplier * 0.97)
    }

    private func captureStatusSummary(_ trackingDescription: String) -> String {
        guard isRecording, adaptiveCaptureMultiplier > 1.05 else {
            return trackingDescription
        }
        let effectiveFPS = Double(captureFrameRate.rawValue) / adaptiveCaptureMultiplier
        return "\(trackingDescription); write pressure \(String(format: "%.1f", effectiveFPS)) FPS"
    }

    private var isPostCaptureStatusActive: Bool {
        trackingSummary == "saving"
            || trackingSummary == "building annotation map"
            || trackingSummary.hasPrefix("saved")
    }

    private func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return "limited: motion"
            case .insufficientFeatures:
                return "limited: features"
            case .initializing:
                return "initializing"
            case .relocalizing:
                return "relocalizing"
            @unknown default:
                return "limited"
            }
        }
    }
}
