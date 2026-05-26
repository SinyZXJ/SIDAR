import ARKit
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
        .sheet(isPresented: $showingInstructions) {
            SidarInstructionsView()
        }
        .sheet(isPresented: $showingGallery) {
            SceneGalleryView()
                .environmentObject(recorder)
        }
        .sheet(isPresented: $showingRoomTypes) {
            RoomLabelEditorView()
        }
        .fullScreenCover(item: $annotationTarget) { target in
            RoomAnnotationView(sceneURL: target.url)
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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.025, blue: 0.035),
                    Color(red: 0.0, green: 0.0, blue: 0.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            SidarParticleField()
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                VStack(spacing: 10) {
                    Text("SIDAR")
                        .font(SidarFont.heavy(72, relativeTo: .largeTitle))
                        .tracking(1.2)
                        .foregroundStyle(.white)

                    Text("Spatial Indoor-outdoor Data Acquisition and Reconstruction")
                        .font(SidarFont.medium(20, relativeTo: .title3))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                }

                HStack(spacing: 14) {
                    Button {
                        onStart()
                    } label: {
                        Label("Enter Capture", systemImage: "arrow.forward.circle.fill")
                            .frame(width: 210)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        onInstructions()
                    } label: {
                        Label("Instructions", systemImage: "book")
                            .frame(width: 190)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.white)
                }
                .padding(.top, 8)

                HStack(spacing: 12) {
                    Button {
                        onGallery()
                    } label: {
                        Label("Gallery", systemImage: "rectangle.stack")
                            .frame(width: 158)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.white)

                    Button {
                        onRoomTypes()
                    } label: {
                        Label("Room Types", systemImage: "tag")
                            .frame(width: 158)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.white)
                }

                Spacer()

                LabLogoView()
                    .frame(maxWidth: 520, maxHeight: 152)
                    .foregroundStyle(.white.opacity(0.86))
                    .shadow(color: .cyan.opacity(0.22), radius: 18)
                    .shadow(color: .white.opacity(0.18), radius: 2)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 28)
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
                    .foregroundStyle(.white)
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

struct SidarParticleField: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let count = 120
                for index in 0..<count {
                    let seed = Double(index)
                    let xBase = fractional(sin(seed * 12.9898) * 43758.5453)
                    let yBase = fractional(sin(seed * 78.233) * 19341.123)
                    let drift = sin(time * 0.25 + seed * 0.37) * 22.0
                    let pulse = 0.45 + 0.55 * sin(time * 0.9 + seed)
                    let x = xBase * size.width + drift
                    let y = yBase * size.height + cos(time * 0.18 + seed) * 16.0
                    let radius = 1.2 + CGFloat(pulse) * 2.2
                    let alpha = 0.12 + 0.35 * pulse
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    let color = index % 3 == 0 ? Color.cyan : Color.white
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                }

                for index in stride(from: 0, to: count - 8, by: 8) {
                    let a = particlePoint(index, time: time, size: size)
                    let b = particlePoint(index + 5, time: time, size: size)
                    let distance = hypot(a.x - b.x, a.y - b.y)
                    guard distance < 180 else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.cyan.opacity(0.10)), lineWidth: 1)
                }
            }
        }
    }

    private func particlePoint(_ index: Int, time: TimeInterval, size: CGSize) -> CGPoint {
        let seed = Double(index)
        let xBase = fractional(sin(seed * 12.9898) * 43758.5453)
        let yBase = fractional(sin(seed * 78.233) * 19341.123)
        return CGPoint(
            x: xBase * size.width + sin(time * 0.25 + seed * 0.37) * 22.0,
            y: yBase * size.height + cos(time * 0.18 + seed) * 16.0
        )
    }

    private func fractional(_ value: Double) -> Double {
        value - floor(value)
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
                    .foregroundStyle(.blue)
                Text(title)
                    .font(SidarFont.heavy(22, relativeTo: .title2))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(SidarFont.regular(17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                accessory
            }
            .frame(maxWidth: .infinity)
            .padding(32)
        }
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
