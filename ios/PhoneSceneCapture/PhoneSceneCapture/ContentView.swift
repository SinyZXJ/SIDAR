import ARKit
import CoreMotion
import SceneKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: ARRecorder
    @State private var hasEnteredCapture = false
    @State private var showingInstructions = false
    @State private var showingGallery = false
    @State private var showingRoomTypes = false
    @State private var showingCaptureOptions = false
    @State private var showFeaturePoints = true
    @State private var annotationTarget: CaptureAnnotationTarget?
    @State private var lastAnnouncedAnnotationError: String?

    var body: some View {
        ZStack {
            if hasEnteredCapture {
                captureView
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                SidarIntroView(
                    onStart: {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            hasEnteredCapture = true
                        }
                    },
                    onInstructions: {
                        showingInstructions = true
                    },
                    onGallery: {
                        showingGallery = true
                    },
                    onRoomTypes: {
                        showingRoomTypes = true
                    }
                )
                .transition(.opacity)
            }
        }
        .font(SidarFont.body)
        .onAppear(perform: applyContentOrientation)
        .onChange(of: hasEnteredCapture) { _, _ in
            applyContentOrientation()
        }
        .sheet(isPresented: $showingInstructions) {
            SidarInstructionsView()
                .onAppear {
                    SidarOrientationLock.set(.portrait)
                }
                .onDisappear {
                    applyContentOrientation()
                }
        }
        .sheet(isPresented: $showingGallery) {
            SceneGalleryView()
                .environmentObject(recorder)
                .onAppear {
                    SidarOrientationLock.set(.portrait)
                }
                .onDisappear {
                    applyContentOrientation()
                }
        }
        .sheet(isPresented: $showingRoomTypes) {
            RoomLabelEditorView()
                .onAppear {
                    SidarOrientationLock.set(.portrait)
                }
                .onDisappear {
                    applyContentOrientation()
                }
        }
        .fullScreenCover(item: $annotationTarget) { target in
            RoomAnnotationView(sceneURL: target.url)
                .onAppear {
                    SidarOrientationLock.set(.landscape)
                }
                .onDisappear {
                    applyContentOrientation()
                }
        }
        .alert("Annotation Map Failed", isPresented: annotationFailureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.annotationBuildError ?? "SIDAR could not build the annotation map for this recording.")
        }
        .onChange(of: recorder.annotationBuildError) { _, message in
            guard let message,
                  !message.isEmpty,
                  message != lastAnnouncedAnnotationError else {
                return
            }
            lastAnnouncedAnnotationError = message
        }
    }

    private func applyContentOrientation() {
        SidarOrientationLock.set(hasEnteredCapture ? .landscape : .portrait)
    }

    private var captureView: some View {
        ZStack(alignment: .bottom) {
            ARSceneView(session: recorder.session, showFeaturePoints: showFeaturePoints)
                .ignoresSafeArea()
                .onAppear {
                    recorder.startSession()
                }
                .onDisappear {
                    if !recorder.isRecording {
                        recorder.pauseSession()
                    }
                }

            VStack(spacing: 0) {
                captureTopBar
                captureStatusBanner
                    .padding(.top, 12)
                Spacer()
                captureControlPanel
            }
            .padding()
        }
    }

    private var captureTopBar: some View {
        HStack(spacing: 10) {
            CaptureTopBarIconButton(
                systemImage: "chevron.left",
                disabled: recorder.isRecording
            ) {
                recorder.pauseSession()
                withAnimation(.easeInOut(duration: 0.35)) {
                    hasEnteredCapture = false
                }
            }

            CaptureTopBarChip {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(SidarFont.demi(15, relativeTo: .caption))
                    Text("SIDAR")
                        .font(SidarFont.heavy(17, relativeTo: .headline))
                }
            }

            CaptureTopBarChip {
                Text(recorder.trackingSummary)
                    .font(SidarFont.footnote)
                    .lineLimit(1)
            }

            CaptureTopBarChip {
                Text("\(recorder.frameCount) frames")
                    .font(SidarFont.footnote)
            }

            if recorder.droppedFrameCount > 0 {
                CaptureTopBarChip {
                    Text("\(recorder.droppedFrameCount) skipped")
                        .font(SidarFont.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if recorder.throttledFrameCount > 0 {
                CaptureTopBarChip {
                    Text("\(recorder.throttledFrameCount) throttled")
                        .font(SidarFont.footnote)
                        .foregroundStyle(.yellow)
                }
            }

            Spacer()

            CaptureTopBarIconButton(systemImage: "questionmark.circle") {
                showingInstructions = true
            }

            CaptureTopBarIconButton(systemImage: "slider.horizontal.3") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingCaptureOptions.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private var captureStatusBanner: some View {
        if recorder.trackingSummary == "saving" {
            CaptureStatusBanner(
                icon: "checkmark.circle.fill",
                title: "Recording Stopped",
                message: "SIDAR is saving the capture. Keep the app open.",
                tint: .blue
            )
        } else if recorder.trackingSummary == "building annotation map" {
            let progress = recorder.annotationMapBuildProgress
            let message = progress.map {
                "\($0.message) \(Int(round($0.fraction * 100.0)))%"
            } ?? "Building the annotation map. Large scenes can take a little longer."
            CaptureStatusBanner(
                icon: "map.fill",
                title: "Capture Saved",
                message: message,
                tint: .cyan,
                progress: progress?.fraction
            )
        } else if recorder.completedSceneForAnnotation != nil {
            CaptureStatusBanner(
                icon: "checkmark.seal.fill",
                title: "Map Ready",
                message: "You can review and annotate rooms now.",
                tint: .green
            )
        } else if recorder.trackingSummary.hasPrefix("saved; annotation map failed") {
            CaptureStatusBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Capture Saved",
                message: "The annotation map did not finish. Open Gallery and try Annotate again.",
                tint: .orange
            )
        }
    }

    private var annotationFailureBinding: Binding<Bool> {
        Binding(
            get: {
                guard let message = recorder.annotationBuildError, !message.isEmpty else {
                    return false
                }
                return message == lastAnnouncedAnnotationError
            },
            set: { isPresented in
                if !isPresented {
                    recorder.annotationBuildError = nil
                }
            }
        )
    }

    private var captureControlPanel: some View {
        VStack(spacing: 10) {
            if showingCaptureOptions {
                captureOptionsPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let sceneURL = recorder.currentSceneURL {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(sceneURL.lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                }
                .font(SidarFont.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if recorder.completedSceneForAnnotation != nil {
                HStack(spacing: 12) {
                    Button {
                        guard let sceneURL = recorder.completedSceneForAnnotation else { return }
                        annotationTarget = CaptureAnnotationTarget(url: sceneURL)
                    } label: {
                        Label("Review / Annotate Rooms", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        recorder.skipAnnotation()
                    } label: {
                        Label("Skip", systemImage: "forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                Button {
                    recorder.resetSession()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(recorder.isRecording)

                Button {
                    recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
                } label: {
                    Label(
                        recorder.isRecording ? "Stop" : "Record",
                        systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .blue)
            }
        }
    }

    private var captureOptionsPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Capture sample rate", systemImage: "speedometer")
                    .font(SidarFont.demi(15, relativeTo: .subheadline))
                Picker("Capture FPS", selection: $recorder.captureFrameRate) {
                    ForEach(CaptureFrameRate.allCases) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .disabled(recorder.isRecording)
            }

            HStack(spacing: 12) {
                Toggle(isOn: $showFeaturePoints) {
                    Label("Feature points", systemImage: "sparkles")
                }
                .toggleStyle(.switch)

                Spacer()

                Label("Depth + mesh + pose", systemImage: "cube.transparent")
                    .font(SidarFont.caption)
                    .foregroundStyle(.secondary)
                Label("Default 10 FPS", systemImage: "checkmark.seal")
                    .font(SidarFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CaptureAnnotationTarget: Identifiable {
    let id = UUID()
    let url: URL
}

private struct CaptureStatusBanner: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color
    var progress: Double? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(SidarFont.demi(20, relativeTo: .title3))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SidarFont.demi(15, relativeTo: .headline))
                Text(message)
                    .font(SidarFont.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(maxWidth: 360)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.32), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

private struct CaptureTopBarIconButton: View {
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidarFont.demi(18, relativeTo: .callout))
                .foregroundStyle(disabled ? Color.secondary : Color.blue)
                .frame(width: 50, height: 50)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.58 : 1.0)
    }
}

private struct CaptureTopBarChip<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
    }
}

struct SidarIntroView: View {
    let onStart: () -> Void
    let onInstructions: () -> Void
    let onGallery: () -> Void
    let onRoomTypes: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reflection = SidarJadeReflectionModel()

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom

            ZStack {
                SidarJadeBackground(
                    reflectionOffset: reduceMotion ? .zero : reflection.offset,
                    reflectionAngle: reduceMotion ? 0 : reflection.angle
                )

                VStack(spacing: 0) {
                    Spacer(minLength: max(24, safeTop + 12))

                    VStack(spacing: 8) {
                        VStack(spacing: 8) {
                            Text("SIDAR")
                                .font(.system(size: 54, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(SidarIntroPalette.ink)

                            Text("Capture LiDAR scenes for reconstruction and room annotation.")
                                .font(SidarFont.medium(16, relativeTo: .body))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(SidarIntroPalette.muted)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 32)

                    VStack(spacing: 10) {
                        SidarPrimaryCaptureButton(action: onStart)

                        VStack(spacing: 8) {
                            SidarIntroToolButton(title: "Instructions", systemImage: "book", action: onInstructions)
                            SidarIntroToolButton(title: "Gallery", systemImage: "rectangle.stack", action: onGallery)
                            SidarIntroToolButton(title: "Room Types", systemImage: "tag", action: onRoomTypes)
                        }
                    }

                    Spacer(minLength: max(24, safeBottom + 18))
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if reduceMotion {
                reflection.stop()
            } else {
                reflection.start()
            }
        }
        .onDisappear {
            reflection.stop()
        }
        .onChange(of: reduceMotion) { _, isReduced in
            isReduced ? reflection.stop() : reflection.start()
        }
    }
}

struct LabLogoView: View {
    var body: some View {
        Group {
            if let image = loadImage() {
                Image(uiImage: image.withRenderingMode(.alwaysTemplate))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("Perceptica Robotics")
                    .font(SidarFont.heavy(20, relativeTo: .title3))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func loadImage() -> UIImage? {
        if let image = UIImage(named: "LabIcon") {
            return image
        }
        guard let url = Bundle.main.url(forResource: "LabIcon", withExtension: "png") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }
}

private final class SidarJadeReflectionModel: ObservableObject {
    @Published var offset: CGSize = .zero
    @Published var angle: Double = 24

    private let motionManager = CMMotionManager()
    private var isRunning = false

    func start() {
        guard !isRunning, motionManager.isDeviceMotionAvailable else { return }
        isRunning = true
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll
            let pitch = motion.attitude.pitch
            let target = CGSize(
                width: clamp(CGFloat(roll) * 96, min: -82, max: 82),
                height: clamp(CGFloat(-pitch) * 74, min: -64, max: 64)
            )
            offset = CGSize(
                width: offset.width * 0.80 + target.width * 0.20,
                height: offset.height * 0.80 + target.height * 0.20
            )
            angle = 24 + clamp(roll * 12, min: -10, max: 10)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        offset = .zero
        angle = 24
    }

    private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
        Swift.min(Swift.max(value, lower), upper)
    }
}

private enum SidarIntroPalette {
    static let background = SidarTheme.jadeBackground
    static let surface = SidarTheme.jadeSurface
    static let ink = SidarTheme.jadeInk
    static let muted = SidarTheme.jadeMuted
    static let line = SidarTheme.jadeLine
    static let primary = SidarTheme.jadeAccent
}

private struct SidarJadeBackground: View {
    let reflectionOffset: CGSize
    let reflectionAngle: Double

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)

            ZStack {
                LinearGradient(
                    colors: [
                        SidarTheme.jadeSurface,
                        SidarTheme.jadeBackground,
                        SidarTheme.jadeSurfaceQuiet,
                        SidarTheme.jadeBackgroundDeep
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                SidarJadeVeins()
                    .opacity(0.88)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.66),
                                SidarTheme.jadeSurface.opacity(0.30),
                                .clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: side * 0.48
                        )
                    )
                    .frame(width: side * 0.92, height: side * 0.92)
                    .offset(x: -side * 0.24 + reflectionOffset.width, y: -side * 0.32 + reflectionOffset.height)
                    .blur(radius: 3)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                SidarTheme.jadeAccent.opacity(0.12),
                                SidarTheme.jadeLine.opacity(0.10),
                                .clear
                            ],
                            center: .center,
                            startRadius: 12,
                            endRadius: side * 0.42
                        )
                    )
                    .frame(width: side * 0.72, height: side * 0.72)
                    .offset(x: side * 0.30 - reflectionOffset.width * 0.45, y: side * 0.24 - reflectionOffset.height * 0.35)
                    .blur(radius: 8)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.54),
                                .white.opacity(0.20),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(118, proxy.size.width * 0.30), height: proxy.size.height * 1.7)
                    .rotationEffect(.degrees(reflectionAngle))
                    .offset(x: reflectionOffset.width * 1.9 + proxy.size.width * 0.15, y: reflectionOffset.height * 0.95)
                    .blendMode(.screen)
                    .opacity(0.90)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.30),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(28, proxy.size.width * 0.08), height: proxy.size.height * 1.5)
                    .rotationEffect(.degrees(reflectionAngle + 4))
                    .offset(x: reflectionOffset.width * 2.2 - proxy.size.width * 0.18, y: reflectionOffset.height * 0.7)
                    .blendMode(.screen)
                    .opacity(0.72)
            }
            .ignoresSafeArea()
        }
    }
}

private struct SidarJadeVeins: View {
    var body: some View {
        Canvas { context, size in
            let veins: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Color)] = [
                (0.04, 0.22, 0.46, 0.14, 0.86, SidarTheme.jadeAccent.opacity(0.15)),
                (0.10, 0.76, 0.40, 0.84, 0.92, SidarTheme.jadeLine.opacity(0.22)),
                (0.00, 0.48, 0.30, 0.38, 0.82, SidarTheme.jadeAccent.opacity(0.12)),
                (0.28, 0.08, 0.58, 0.20, 1.04, SidarTheme.jadeLine.opacity(0.18)),
                (-0.08, 0.62, 0.24, 0.56, 0.66, SidarTheme.jadeMuted.opacity(0.10)),
                (0.22, 0.36, 0.52, 0.44, 1.10, SidarTheme.jadeAccent.opacity(0.09))
            ]

            for vein in veins {
                var path = Path()
                let start = CGPoint(x: size.width * vein.0, y: size.height * vein.1)
                let c1 = CGPoint(x: size.width * vein.2, y: size.height * (vein.1 - 0.10))
                let c2 = CGPoint(x: size.width * vein.3, y: size.height * (vein.1 + 0.16))
                let end = CGPoint(x: size.width * vein.4, y: size.height * (vein.1 + 0.06))
                path.move(to: start)
                path.addCurve(to: end, control1: c1, control2: c2)
                context.stroke(path, with: .color(vein.5), style: StrokeStyle(lineWidth: 1.55, lineCap: .round))
            }
        }
        .blur(radius: 0.25)
    }
}

private struct SidarPrimaryCaptureButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("Enter Capture")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .opacity(0.82)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SidarIntroToolButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SidarIntroPalette.ink)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(SidarIntroPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SidarIntroPalette.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SidarInstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView {
                InstructionCard(
                    icon: "record.circle",
                    title: "Capture",
                    text: "Wait for tracking to become normal, tap Record, then walk through the scene slowly with steady turns."
                )

                InstructionCard(
                    icon: "stop.circle",
                    title: "Stop And Save",
                    text: "Tap Stop when the scan is complete. SIDAR saves RGB, LiDAR depth, confidence, intrinsics, poses, and ARKit mesh into a .phonescene folder."
                )

                InstructionCard(
                    icon: "map",
                    title: "Annotate Rooms",
                    text: "Open Review / Annotate Rooms. Tap vertices around one room, choose a label, drag handles to refine, then finish the room."
                ) {
                    AnnotationInstructionSketch()
                        .frame(height: 150)
                }

                InstructionCard(
                    icon: "square.and.arrow.down",
                    title: "Export",
                    text: "Tap Save GT to write annotation/gt_rooms.json. Use Skip when you only need the raw recording."
                )
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(SidarTheme.jadeBackground)
            .navigationTitle("SIDAR Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .font(SidarFont.body)
        .background(SidarTheme.jadeBackground.ignoresSafeArea())
        .tint(SidarTheme.jadeAccent)
        .presentationDetents([.large])
    }
}

struct InstructionCard<Accessory: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let accessory: Accessory

    init(icon: String, title: String, text: String, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(SidarFont.heavy(44, relativeTo: .largeTitle))
                    .foregroundStyle(SidarTheme.jadeAccent)
                Text(title)
                    .font(SidarFont.heavy(22, relativeTo: .title2))
                    .foregroundStyle(SidarTheme.jadeInk)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(SidarFont.regular(17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SidarTheme.jadeMuted)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                accessory
            }
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .background(SidarTheme.jadeBackground)
    }
}

extension InstructionCard where Accessory == EmptyView {
    init(icon: String, title: String, text: String) {
        self.init(icon: icon, title: title, text: text) {
            EmptyView()
        }
    }
}

struct AnnotationInstructionSketch: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 30, y: 18, width: size.width - 60, height: size.height - 36)
            context.fill(Path(rect), with: .color(.black.opacity(0.9)))

            var trajectory = Path()
            trajectory.move(to: CGPoint(x: rect.minX + 22, y: rect.maxY - 28))
            trajectory.addCurve(
                to: CGPoint(x: rect.maxX - 34, y: rect.minY + 42),
                control1: CGPoint(x: rect.midX - 52, y: rect.maxY - 64),
                control2: CGPoint(x: rect.midX + 38, y: rect.minY + 88)
            )
            context.stroke(trajectory, with: .color(.cyan), lineWidth: 2)

            var room = Path()
            let vertices = [
                CGPoint(x: rect.minX + 68, y: rect.minY + 40),
                CGPoint(x: rect.midX + 50, y: rect.minY + 26),
                CGPoint(x: rect.maxX - 58, y: rect.midY + 28),
                CGPoint(x: rect.midX - 12, y: rect.maxY - 26),
                CGPoint(x: rect.minX + 48, y: rect.midY + 18)
            ]
            room.move(to: vertices[0])
            for vertex in vertices.dropFirst() {
                room.addLine(to: vertex)
            }
            room.closeSubpath()
            context.fill(room, with: .color(.blue.opacity(0.28)))
            context.stroke(room, with: .color(.blue), lineWidth: 2.5)

            for vertex in vertices {
                context.fill(Path(ellipseIn: CGRect(x: vertex.x - 5, y: vertex.y - 5, width: 10, height: 10)), with: .color(.white))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ARSceneView: UIViewRepresentable {
    let session: ARSession
    let showFeaturePoints: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.preferredFramesPerSecond = 30
        view.debugOptions = showFeaturePoints ? [.showFeaturePoints] : []
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
        uiView.debugOptions = showFeaturePoints ? [.showFeaturePoints] : []
    }
}
