import SwiftUI
import UIKit

struct RoomAnnotationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RoomAnnotationModel
    @State private var interactionMode: AnnotationInteractionMode = .draw
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var activeVertex: VertexSelection?
    @State private var mapLayer: AnnotationMapLayer = .pointCloud
    @State private var reviewMode: AnnotationReviewMode = .topDown

    init(sceneURL: URL) {
        _model = StateObject(wrappedValue: RoomAnnotationModel(sceneURL: sceneURL))
    }

    var body: some View {
        GeometryReader { proxy in
            annotationLayout(size: proxy.size)
        }
        .background(Color(.systemBackground))
        .font(SidarFont.body)
        .onAppear {
            model.load()
        }
        .alert("Validation warnings", isPresented: $model.showSaveAnywayConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Save anyway", role: .destructive) {
                model.save(confirmingWarnings: true)
            }
        } message: {
            Text(model.validationWarnings.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func annotationLayout(size: CGSize) -> some View {
        if size.width > size.height {
            HStack(alignment: .top, spacing: 10) {
                controlPanel
                    .frame(width: min(310, max(250, size.width * 0.28)))
                    .frame(maxHeight: .infinity)

                reviewSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                header
                toolbar
                reviewSurface
                    .frame(minHeight: 360)
                statusPanel
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .font(SidarFont.demi(15, relativeTo: .callout))
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Text("Room GT")
                .font(SidarFont.heavy(21, relativeTo: .title3))

            Spacer()

            Color.clear
                .frame(width: 88, height: 30)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 7) {
            Picker("Review", selection: $reviewMode) {
                ForEach(AnnotationReviewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Picker("Mode", selection: $interactionMode) {
                    ForEach(AnnotationInteractionMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                Picker("Label", selection: $model.selectedLabel) {
                    ForEach(model.availableLabels, id: \.self) { label in
                        Text(label.roomLabelDisplayName).tag(label)
                    }
                }
                .pickerStyle(.menu)
                .font(SidarFont.demi(15, relativeTo: .callout))
                .frame(minWidth: 128, maxWidth: 220, alignment: .leading)

                Spacer()

                Text("\(model.rooms.count) rooms")
                    .font(SidarFont.footnote)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AnnotationIconButton(
                        title: "Undo Point",
                        systemImage: "arrow.uturn.backward",
                        disabled: model.draftPoints.isEmpty
                    ) {
                        model.undoPoint()
                    }

                    AnnotationIconButton(
                        title: "Finish Room",
                        systemImage: "checkmark.circle",
                        disabled: model.draftPoints.count < 3
                    ) {
                        model.finishRoom()
                    }

                    AnnotationIconButton(
                        title: "Delete Room",
                        systemImage: "trash",
                        tint: .red,
                        disabled: model.selectedRoomID == nil
                    ) {
                        model.deleteSelectedRoom()
                    }

                    AnnotationIconButton(
                        title: "Save GT",
                        systemImage: "square.and.arrow.down",
                        tint: .blue,
                        prominent: true,
                        disabled: model.rooms.isEmpty
                    ) {
                        model.save()
                    }

                    if !model.draftPoints.isEmpty {
                        Text("\(model.draftPoints.count) points")
                            .font(SidarFont.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.rooms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.rooms.enumerated()), id: \.element.id) { index, room in
                            Button {
                                model.selectedRoomID = room.id
                            } label: {
                                Text("\(index): \(room.label.roomLabelDisplayName)")
                                    .font(SidarFont.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.selectedRoomID == room.id ? .blue : .gray)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                compactHeader
                viewPanel
                modePanel
                floorPanel
                labelPanel
                actionPanel
                roomListPanel
                statusPanel
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .font(SidarFont.medium(14, relativeTo: .callout))
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Room GT")
                .font(SidarFont.medium(18, relativeTo: .headline))
                .lineLimit(1)
        }
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(SidarFont.caption)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $interactionMode) {
                ForEach(AnnotationInteractionMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var viewPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("View")
                .font(SidarFont.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                MapLayerButton(
                    title: AnnotationReviewMode.topDown.title,
                    systemImage: AnnotationReviewMode.topDown.systemImage,
                    isSelected: reviewMode == .topDown
                ) {
                    reviewMode = .topDown
                }

                MapLayerButton(
                    title: AnnotationReviewMode.mesh3D.title,
                    systemImage: AnnotationReviewMode.mesh3D.systemImage,
                    isSelected: reviewMode == .mesh3D
                ) {
                    reviewMode = .mesh3D
                    model.buildMeshPreviewIfNeeded()
                }
            }

            if reviewMode == .topDown {
                HStack(spacing: 8) {
                    MapLayerButton(
                        title: AnnotationMapLayer.pointCloud.title,
                        systemImage: AnnotationMapLayer.pointCloud.systemImage,
                        isSelected: mapLayer == .pointCloud
                    ) {
                        mapLayer = .pointCloud
                    }

                    MapLayerButton(
                        title: AnnotationMapLayer.mesh.title,
                        systemImage: AnnotationMapLayer.mesh.systemImage,
                        isSelected: mapLayer == .mesh,
                        disabled: model.meshImage == nil
                    ) {
                        mapLayer = .mesh
                    }
                }
            } else {
                meshPreviewControls
            }
        }
    }

    private var meshPreviewControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AnnotationControlButton(
                    title: "Build 3D",
                    systemImage: "cube.transparent",
                    disabled: model.meshPreviewState.isWorking
                ) {
                    model.rebuildMeshPreview()
                }

                AnnotationControlButton(
                    title: "RGB Color",
                    systemImage: "paintpalette",
                    tint: .blue,
                    prominent: model.meshPreviewGeometry != nil,
                    disabled: model.meshPreviewGeometry == nil || model.meshPreviewState.isWorking
                ) {
                    model.colorizeMeshPreview()
                }
            }

            if let progress = model.meshPreviewState.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            Text(model.meshPreviewState.message)
                .font(SidarFont.caption)
                .foregroundStyle(model.meshPreviewState.isWorking ? .blue : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.meshPreviewGeometry == nil {
                Text("3D preview is optional. If it fails, top-down annotation still works.")
                    .font(SidarFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var floorPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Floor")
                    .font(SidarFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.addFloor()
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .font(SidarFont.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Menu {
                ForEach(model.floors) { floor in
                    Button {
                        model.selectFloor(floor.id)
                    } label: {
                        if floor.id == model.selectedFloorID {
                            Label(floor.name, systemImage: "checkmark")
                        } else {
                            Text(floor.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d")
                    Text(model.activeFloor.name)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(SidarFont.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .font(SidarFont.medium(14, relativeTo: .callout))
            .buttonStyle(.bordered)

            Text(String(format: "z %.1f - %.1f m", model.activeFloor.min_z, model.activeFloor.max_z))
                .font(SidarFont.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Stepper(
                    value: Binding(
                        get: { model.activeFloor.min_z },
                        set: { model.setActiveFloorMinZ($0) }
                    ),
                    in: -20.0...20.0,
                    step: 0.25
                ) {
                    Text(String(format: "Min z %.2f m", model.activeFloor.min_z))
                        .font(SidarFont.caption)
                }

                Stepper(
                    value: Binding(
                        get: { model.activeFloor.max_z },
                        set: { model.setActiveFloorMaxZ($0) }
                    ),
                    in: -20.0...20.0,
                    step: 0.25
                ) {
                    Text(String(format: "Max z %.2f m", model.activeFloor.max_z))
                        .font(SidarFont.caption)
                }
            }
        }
    }

    private var labelPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Room Type")
                .font(SidarFont.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(model.availableLabels, id: \.self) { label in
                    Button {
                        model.selectedLabel = label
                    } label: {
                        if label == model.selectedLabel {
                            Label(label.roomLabelDisplayName, systemImage: "checkmark")
                        } else {
                            Text(label.roomLabelDisplayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                    Text(model.selectedLabel.roomLabelDisplayName)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(SidarFont.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .font(SidarFont.medium(14, relativeTo: .callout))
            .buttonStyle(.bordered)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.availableLabels.prefix(8), id: \.self) { label in
                        RoomLabelChip(
                            label: label,
                            isSelected: label == model.selectedLabel
                        ) {
                            model.selectedLabel = label
                        }
                    }
                }
            }
        }
    }

    private var actionPanel: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            AnnotationControlButton(
                title: "Undo",
                systemImage: "arrow.uturn.backward",
                disabled: model.draftPoints.isEmpty && model.selectedRoomID == nil
            ) {
                model.undoPoint()
            }

            AnnotationControlButton(
                title: "Finish",
                systemImage: "checkmark.circle",
                disabled: model.draftPoints.count < 3
            ) {
                model.finishRoom()
            }

            AnnotationControlButton(
                title: "Delete",
                systemImage: "trash",
                tint: .red,
                disabled: model.selectedRoomID == nil
            ) {
                model.deleteSelectedRoom()
            }

            AnnotationControlButton(
                title: "Save",
                systemImage: "square.and.arrow.down",
                tint: .blue,
                prominent: true,
                disabled: model.rooms.isEmpty
            ) {
                model.save()
            }
        }
    }

    @ViewBuilder
    private var roomListPanel: some View {
        if !model.rooms.isEmpty || !model.draftPoints.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("\(model.rooms.count) rooms")
                        .font(SidarFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.draftPoints.isEmpty {
                        Text("\(model.draftPoints.count) draft points")
                            .font(SidarFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(Array(model.rooms.enumerated()), id: \.element.id) { index, room in
                    Button {
                        model.selectedRoomID = room.id
                    } label: {
                        HStack {
                            Text("\(index): \(room.label.roomLabelDisplayName)")
                                .lineLimit(1)
                            Spacer()
                            if model.selectedRoomID == room.id {
                                Image(systemName: "checkmark")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .font(SidarFont.medium(13, relativeTo: .footnote))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(model.selectedRoomID == room.id ? .blue : .gray)
                }
            }
        }
    }

    private var mapSurface: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.92)
                if let image = model.image(for: mapLayer), let payload = model.payload {
                    RoomAnnotationCanvas(
                        image: image,
                        payload: payload,
                        rooms: model.visibleRooms,
                        draftPoints: model.visibleDraftPoints,
                        selectedRoomID: model.selectedRoomID
                    )
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                } else {
                    ProgressView(model.status)
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(drawGesture(in: geometry.size))
            .simultaneousGesture(panGesture)
            .simultaneousGesture(zoomGesture)
        }
    }

    @ViewBuilder
    private var reviewSurface: some View {
        switch reviewMode {
        case .topDown:
            mapSurface
        case .mesh3D:
            meshPreviewSurface
                .onAppear {
                    model.buildMeshPreviewIfNeeded()
                }
        }
    }

    private var meshPreviewSurface: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.96)
            if let geometry = model.meshPreviewGeometry {
                MeshPreviewSceneView(geometry: geometry)
            } else {
                VStack(spacing: 12) {
                    if model.meshPreviewState.isWorking {
                        ProgressView(value: model.meshPreviewState.progress ?? 0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 320)
                    } else {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    }
                    Text(model.meshPreviewState.message)
                        .font(SidarFont.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if !model.meshPreviewState.isWorking {
                        Button {
                            model.rebuildMeshPreview()
                        } label: {
                            Label("Build 3D Preview", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("3D Preview", systemImage: "rotate.3d")
                        .font(SidarFont.demi(13, relativeTo: .footnote))
                    Spacer()
                    if let progress = model.meshPreviewState.progress {
                        Text("\(Int(progress * 100))%")
                            .font(SidarFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.meshPreviewState.message)
                    .font(SidarFont.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        model.colorizeMeshPreview()
                    } label: {
                        Label("Generate RGB Color Mesh", systemImage: "paintpalette")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.meshPreviewGeometry == nil || model.meshPreviewState.isWorking)

                    Button {
                        reviewMode = .topDown
                    } label: {
                        Label("Top-down", systemImage: "map")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status)
                .font(SidarFont.footnote)
                .lineLimit(2)

            if !model.trajectoryCounts.isEmpty {
                Text("Trajectory frames per room: \(model.trajectoryCounts.map(String.init).joined(separator: ", "))")
                    .font(SidarFont.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.validationWarnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.validationWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(SidarFont.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 88)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard interactionMode == .pan else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard interactionMode == .pan else { return }
                lastOffset = offset
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(8.0, max(0.75, lastScale * value))
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    private func drawGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard interactionMode == .draw,
                      let world = worldPoint(from: value.location, in: size) else {
                    return
                }
                let movement = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if activeVertex == nil && movement > 6.0 {
                    let startWorld = worldPoint(from: value.startLocation, in: size) ?? world
                    activeVertex = model.nearestVertex(to: startWorld, maxDistanceMeters: 0.45)
                }
                if let activeVertex {
                    model.updateVertex(activeVertex, to: world)
                }
            }
            .onEnded { value in
                guard interactionMode == .draw,
                      let world = worldPoint(from: value.location, in: size) else {
                    activeVertex = nil
                    return
                }
                let movement = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if activeVertex == nil && movement < 8.0 {
                    if model.closeDraftIfNeeded(at: world, maxDistanceMeters: 0.35) {
                        activeVertex = nil
                        return
                    }
                    if model.selectExistingVertexNear(world, maxDistanceMeters: 0.25) {
                        activeVertex = nil
                        return
                    }
                    model.addDraftPoint(world)
                }
                activeVertex = nil
            }
    }

    private func worldPoint(from location: CGPoint, in size: CGSize) -> CGPoint? {
        guard let payload = model.payload else { return nil }
        let contentLocation = inverseTransformed(location, in: size)
        let rect = MapProjection.imageRect(in: CGRect(origin: .zero, size: size), payload: payload)
        guard rect.contains(contentLocation) else { return nil }
        return MapProjection(payload: payload, rect: rect).viewToWorld(contentLocation)
    }

    private func inverseTransformed(_ location: CGPoint, in size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        return CGPoint(
            x: (location.x - center.x - offset.width) / scale + center.x,
            y: (location.y - center.y - offset.height) / scale + center.y
        )
    }
}

private struct AnnotationIconButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Group {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .tint(tint)
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidarFont.demi(15, relativeTo: .callout))
                .frame(width: 34, height: 28)
        }
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

private struct AnnotationControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Group {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .tint(tint)
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(SidarFont.medium(13, relativeTo: .footnote))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .disabled(disabled)
    }
}

private struct RoomLabelChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.mini)
    }

    private var button: some View {
        Button(action: action) {
            Text(label.roomLabelDisplayName)
                .font(SidarFont.medium(11, relativeTo: .caption2))
                .lineLimit(1)
        }
    }
}

private struct MapLayerButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(SidarFont.medium(12, relativeTo: .caption))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .disabled(disabled)
    }
}

private final class RoomAnnotationModel: ObservableObject {
    let sceneURL: URL

    @Published var payload: AnnotationPayload?
    @Published var mapImage: UIImage?
    @Published var meshImage: UIImage?
    @Published var rooms: [EditableRoom] = []
    @Published var draftPoints: [CGPoint] = []
    @Published var draftFloorID: String?
    @Published var selectedRoomID: UUID?
    @Published var floors: [AnnotationFloor] = [.defaultFloor]
    @Published var selectedFloorID = AnnotationFloor.defaultFloor.id
    @Published var availableLabels: [String]
    @Published var selectedLabel: String
    @Published var validationWarnings: [String] = []
    @Published var trajectoryCounts: [Int] = []
    @Published var status = "Loading annotation assets"
    @Published var showSaveAnywayConfirmation = false
    @Published var meshPreviewGeometry: MeshPreviewGeometry?
    @Published var meshPreviewState: MeshPreviewTaskState = .unavailable("3D preview not built yet.")

    private let decoder = JSONDecoder()
    private let meshPreviewBuilder = MeshPreviewAssetBuilder()

    init(sceneURL: URL) {
        self.sceneURL = sceneURL
        let labels = RoomLabelStore.load()
        availableLabels = labels
        selectedLabel = labels.contains(RoomLabel.office.rawValue) ? RoomLabel.office.rawValue : (labels.first ?? RoomLabel.office.rawValue)
    }

    var activeFloor: AnnotationFloor {
        floors.first(where: { $0.id == selectedFloorID }) ?? floors.first ?? .defaultFloor
    }

    var visibleRooms: [EditableRoom] {
        rooms.filter { $0.floorID == selectedFloorID }
    }

    var visibleDraftPoints: [CGPoint] {
        draftFloorID == nil || draftFloorID == selectedFloorID ? draftPoints : []
    }

    func image(for layer: AnnotationMapLayer) -> UIImage? {
        switch layer {
        case .pointCloud:
            return mapImage
        case .mesh:
            return meshImage ?? mapImage
        }
    }

    func load() {
        do {
            let annotationURL = try FrameWriter.annotationDirectory(for: sceneURL)
            let payloadURL = annotationURL.appendingPathComponent("annotation_payload.json")
            let imageURL = annotationURL.appendingPathComponent("topdown_map.png")
            payload = try decoder.decode(AnnotationPayload.self, from: Data(contentsOf: payloadURL))
            mapImage = UIImage(contentsOfFile: imageURL.path)
            meshImage = UIImage(contentsOfFile: annotationURL.appendingPathComponent("topdown_mesh.png").path)
            floors = payload?.floors ?? [.defaultFloor]
            if floors.isEmpty {
                floors = [.defaultFloor]
            }
            selectedFloorID = floors[0].id
            syncLabelsWithPayload()
            try loadExistingGTIfPresent(annotationURL: annotationURL)
            if floors.count > 1 {
                status = "Detected \(floors.count) z bands. Pick the right floor before drawing each room."
            } else {
                status = "Tap to add vertices. Tap the first vertex again to close the room. Drag handles to refine."
            }
            loadMeshPreviewIfPresent()
            buildMeshPreviewIfNeeded()
        } catch {
            status = "Annotation assets unavailable: \(error.localizedDescription)"
        }
    }

    func buildMeshPreviewIfNeeded() {
        guard meshPreviewGeometry == nil, !meshPreviewState.isWorking else { return }
        buildMeshPreview(force: false)
    }

    func rebuildMeshPreview() {
        guard !meshPreviewState.isWorking else { return }
        buildMeshPreview(force: true)
    }

    func colorizeMeshPreview() {
        guard meshPreviewGeometry != nil, !meshPreviewState.isWorking else { return }
        updateMeshPreviewState(.colorizing(MeshPreviewProgress(0.0, "Preparing RGB colorization")))
        let targetSceneURL = sceneURL
        let builder = meshPreviewBuilder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                _ = try builder.colorizePreviewAssets(sceneURL: targetSceneURL) { progress in
                    DispatchQueue.main.async {
                        self?.updateMeshPreviewState(.colorizing(progress))
                    }
                }
                let geometry = try builder.loadPreviewGeometry(sceneURL: targetSceneURL, preferColorized: true)
                DispatchQueue.main.async {
                    self?.meshPreviewGeometry = geometry
                    self?.updateMeshPreviewState(.colorized("RGB mesh preview ready. Rotate, pinch, and drag to inspect it."))
                }
            } catch {
                DispatchQueue.main.async {
                    self?.updateMeshPreviewState(.failed("RGB colorization failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    func addDraftPoint(_ point: CGPoint) {
        if draftPoints.isEmpty {
            draftFloorID = selectedFloorID
        }
        draftPoints.append(point)
        validationWarnings = []
    }

    func undoPoint() {
        if !draftPoints.isEmpty {
            _ = draftPoints.popLast()
            if draftPoints.isEmpty {
                draftFloorID = nil
            }
            return
        }

        guard let selectedRoomID,
              let roomIndex = rooms.firstIndex(where: { $0.id == selectedRoomID }) else {
            status = "Select a room or draw points before undo."
            return
        }
        guard rooms[roomIndex].vertices.count > 3 else {
            status = "A saved room needs at least 3 vertices."
            return
        }
        _ = rooms[roomIndex].vertices.popLast()
        _ = runValidation()
    }

    func finishRoom() {
        guard draftPoints.count >= 3 else { return }
        let normalizedLabel = RoomLabelStore.normalize(selectedLabel)
        let room = EditableRoom(
            label: normalizedLabel.isEmpty ? RoomLabel.office.rawValue : normalizedLabel,
            vertices: draftPoints,
            floorID: draftFloorID ?? selectedFloorID
        )
        rooms.append(room)
        selectedRoomID = room.id
        draftPoints = []
        draftFloorID = nil
        _ = runValidation()
    }

    func deleteSelectedRoom() {
        guard let selectedRoomID else { return }
        rooms.removeAll { $0.id == selectedRoomID }
        self.selectedRoomID = rooms.last?.id
        _ = runValidation()
    }

    func nearestVertex(to point: CGPoint, maxDistanceMeters: CGFloat) -> VertexSelection? {
        var best: (selection: VertexSelection, distance: CGFloat)?
        if draftFloorID == nil || draftFloorID == selectedFloorID {
            for index in draftPoints.indices {
                let distance = hypot(draftPoints[index].x - point.x, draftPoints[index].y - point.y)
                if distance <= maxDistanceMeters && (best == nil || distance < best!.distance) {
                    best = (VertexSelection(roomID: nil, vertexIndex: index, isDraft: true), distance)
                }
            }
        }
        for room in visibleRooms {
            for index in room.vertices.indices {
                let distance = hypot(room.vertices[index].x - point.x, room.vertices[index].y - point.y)
                if distance <= maxDistanceMeters && (best == nil || distance < best!.distance) {
                    best = (VertexSelection(roomID: room.id, vertexIndex: index, isDraft: false), distance)
                }
            }
        }
        if let roomID = best?.selection.roomID {
            selectedRoomID = roomID
        }
        return best?.selection
    }

    func selectExistingVertexNear(_ point: CGPoint, maxDistanceMeters: CGFloat) -> Bool {
        var best: (roomID: UUID, distance: CGFloat)?
        for room in visibleRooms {
            for vertex in room.vertices {
                let distance = hypot(vertex.x - point.x, vertex.y - point.y)
                if distance <= maxDistanceMeters && (best == nil || distance < best!.distance) {
                    best = (room.id, distance)
                }
            }
        }
        if let roomID = best?.roomID {
            selectedRoomID = roomID
            return true
        }
        return false
    }

    func closeDraftIfNeeded(at point: CGPoint, maxDistanceMeters: CGFloat) -> Bool {
        guard draftFloorID == nil || draftFloorID == selectedFloorID else { return false }
        guard draftPoints.count >= 3, let first = draftPoints.first else { return false }
        let distance = hypot(first.x - point.x, first.y - point.y)
        guard distance <= maxDistanceMeters else { return false }
        finishRoom()
        return true
    }

    func updateVertex(_ selection: VertexSelection, to point: CGPoint) {
        if selection.isDraft {
            guard draftPoints.indices.contains(selection.vertexIndex) else { return }
            draftPoints[selection.vertexIndex] = point
            return
        }
        guard let roomID = selection.roomID,
              let roomIndex = rooms.firstIndex(where: { $0.id == roomID }),
              rooms[roomIndex].vertices.indices.contains(selection.vertexIndex) else {
            return
        }
        rooms[roomIndex].vertices[selection.vertexIndex] = point
    }

    func selectFloor(_ floorID: String) {
        guard floors.contains(where: { $0.id == floorID }) else { return }
        guard draftPoints.isEmpty else {
            status = "Finish or undo the current draft before switching floors."
            return
        }
        selectedFloorID = floorID
        selectedRoomID = visibleRooms.last?.id
    }

    func addFloor() {
        guard draftPoints.isEmpty else {
            status = "Finish or undo the current draft before adding a floor."
            return
        }
        let number = floors.count + 1
        let lastMaxZ = floors.map(\.max_z).max() ?? AnnotationFloor.defaultFloor.max_z
        let floor = AnnotationFloor(
            id: "floor_\(number)",
            name: "Floor \(number)",
            min_z: lastMaxZ,
            max_z: lastMaxZ + 3.0
        )
        floors.append(floor)
        selectedFloorID = floor.id
        selectedRoomID = nil
        persistPayload()
        status = "Added \(floor.name)."
    }

    func setActiveFloorMinZ(_ minZ: Double) {
        guard let floorIndex = floors.firstIndex(where: { $0.id == selectedFloorID }) else { return }
        let boundedMinZ = min(minZ, floors[floorIndex].max_z - 0.1)
        floors[floorIndex].min_z = boundedMinZ
        persistPayload()
        _ = runValidation()
    }

    func setActiveFloorMaxZ(_ maxZ: Double) {
        guard let floorIndex = floors.firstIndex(where: { $0.id == selectedFloorID }) else { return }
        let boundedMaxZ = max(maxZ, floors[floorIndex].min_z + 0.1)
        floors[floorIndex].max_z = boundedMaxZ
        persistPayload()
        _ = runValidation()
    }

    func save(confirmingWarnings: Bool = false) {
        let result = runValidation()
        if result.hasWarnings && !confirmingWarnings {
            showSaveAnywayConfirmation = true
            return
        }

        do {
            guard let payload else {
                status = "Cannot save GT before payload is loaded."
                return
            }
            let gtRooms = rooms.enumerated().map { index, room in
                let floor = floor(for: room.floorID)
                return GTRoom(
                    room_id: index,
                    label: room.label,
                    polygon_xy: room.vertices.map { [Double($0.x), Double($0.y)] },
                    min_z: floor.min_z,
                    max_z: floor.max_z
                )
            }
            let gtFile = GTRoomFile(scene_id: payload.scene_id, rooms: gtRooms)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            persistPayload()
            let data = try encoder.encode(gtFile)
            try FrameWriter.writeAnnotationData(data, named: "gt_rooms.json", in: sceneURL)
            status = "Saved annotation/gt_rooms.json"
        } catch {
            status = "GT save failed: \(error.localizedDescription)"
        }
    }

    private func runValidation() -> RoomValidationResult {
        var warnings: [String] = []
        var counts: [Int] = []
        let trajectorySamples = validationTrajectorySamples()

        for floor in floors {
            let floorRooms = rooms.filter { $0.floorID == floor.id }
            guard !floorRooms.isEmpty else { continue }
            let candidates = floorRooms.map { room in
                RoomPolygonCandidate(label: room.label, vertices: room.vertices)
            }
            let result = RoomGTValidator.validate(
                rooms: candidates,
                trajectorySamples: trajectorySamples,
                zRange: floor.min_z...floor.max_z,
                allowedLabels: Set(availableLabels)
            )
            warnings.append(contentsOf: result.warnings.map { "\(floor.name): \($0)" })
            counts.append(contentsOf: result.trajectoryFrameCounts)
        }
        let result = RoomValidationResult(warnings: warnings, trajectoryFrameCounts: counts)
        validationWarnings = result.warnings
        trajectoryCounts = result.trajectoryFrameCounts
        return result
    }

    private func validationTrajectorySamples() -> [RoomTrajectorySample] {
        if let samples = payload?.trajectory_xyz.compactMap({ point -> RoomTrajectorySample? in
            guard point.count >= 3 else { return nil }
            return RoomTrajectorySample(
                xy: CGPoint(x: point[0], y: point[1]),
                z: point[2]
            )
        }), !samples.isEmpty {
            return samples
        }

        return payload?.trajectory_xy.compactMap { pair -> RoomTrajectorySample? in
            guard pair.count >= 2 else { return nil }
            return RoomTrajectorySample(xy: CGPoint(x: pair[0], y: pair[1]), z: activeFloor.min_z)
        } ?? []
    }

    private func loadMeshPreviewIfPresent() {
        do {
            let geometry = try meshPreviewBuilder.loadPreviewGeometry(sceneURL: sceneURL, preferColorized: true)
            meshPreviewGeometry = geometry
            if geometry.metadata.color_mode == .rgb {
                meshPreviewState = .colorized("RGB mesh preview ready. Rotate, pinch, and drag to inspect it.")
            } else {
                meshPreviewState = .ready("3D preview ready. Rotate, pinch, and drag to inspect it.")
            }
        } catch {
            meshPreviewState = .unavailable("3D preview will build in the background.")
        }
    }

    private func buildMeshPreview(force: Bool) {
        if !force, meshPreviewGeometry != nil {
            return
        }
        updateMeshPreviewState(.building(MeshPreviewProgress(0.0, "Building 3D preview")))
        let targetSceneURL = sceneURL
        let builder = meshPreviewBuilder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                if force {
                    _ = try builder.buildPreviewAssets(sceneURL: targetSceneURL) { progress in
                        DispatchQueue.main.async {
                            self?.updateMeshPreviewState(.building(progress))
                        }
                    }
                } else {
                    _ = try builder.ensurePreviewAssets(sceneURL: targetSceneURL) { progress in
                        DispatchQueue.main.async {
                            self?.updateMeshPreviewState(.building(progress))
                        }
                    }
                }
                let geometry = try builder.loadPreviewGeometry(sceneURL: targetSceneURL, preferColorized: true)
                DispatchQueue.main.async {
                    self?.meshPreviewGeometry = geometry
                    if geometry.metadata.color_mode == .rgb {
                        self?.updateMeshPreviewState(.colorized("RGB mesh preview ready. Rotate, pinch, and drag to inspect it."))
                    } else {
                        self?.updateMeshPreviewState(.ready("3D preview ready. Rotate, pinch, and drag to inspect it."))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.meshPreviewGeometry = nil
                    self?.updateMeshPreviewState(.failed("3D preview failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func updateMeshPreviewState(_ state: MeshPreviewTaskState) {
        meshPreviewState = state
    }

    private func syncLabelsWithPayload() {
        let payloadLabels = payload?.labels ?? []
        availableLabels = RoomLabelStore.normalizedList(RoomLabelStore.load() + payloadLabels)
        if availableLabels.isEmpty {
            availableLabels = RoomLabelStore.defaultLabels
        }
        if !availableLabels.contains(selectedLabel) {
            selectedLabel = availableLabels.contains(RoomLabel.office.rawValue) ? RoomLabel.office.rawValue : availableLabels[0]
        }
    }

    private func persistPayload() {
        guard let payload else { return }
        let updatedPayload = AnnotationPayload(
            scene_id: payload.scene_id,
            image_width: payload.image_width,
            image_height: payload.image_height,
            world_min_xy: payload.world_min_xy,
            world_max_xy: payload.world_max_xy,
            resolution_m_per_px: payload.resolution_m_per_px,
            trajectory_xy: payload.trajectory_xy,
            trajectory_xyz: payload.trajectory_xyz,
            labels: availableLabels,
            floors: floors
        )
        self.payload = updatedPayload
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(updatedPayload) else { return }
        _ = try? FrameWriter.writeAnnotationData(data, named: "annotation_payload.json", in: sceneURL)
    }

    private func floor(for floorID: String) -> AnnotationFloor {
        floors.first(where: { $0.id == floorID }) ?? floors.first ?? .defaultFloor
    }

    private func loadExistingGTIfPresent(annotationURL: URL) throws {
        let gtURL = annotationURL.appendingPathComponent("gt_rooms.json")
        guard FileManager.default.fileExists(atPath: gtURL.path) else { return }
        let gt = try decoder.decode(GTRoomFile.self, from: Data(contentsOf: gtURL))
        var labels = availableLabels
        syncFloorsWithGT(gt.rooms)
        rooms = gt.rooms.compactMap { room in
            let label = RoomLabelStore.normalize(room.label)
            guard !label.isEmpty else { return nil }
            if !labels.contains(label) {
                labels.append(label)
            }
            return EditableRoom(
                label: label,
                vertices: room.polygon_xy.compactMap { pair in
                    guard pair.count == 2 else { return nil }
                    return CGPoint(x: pair[0], y: pair[1])
                },
                floorID: floorID(forMinZ: room.min_z, maxZ: room.max_z)
            )
        }
        availableLabels = labels
        selectedFloorID = rooms.last?.floorID ?? floors[0].id
        selectedRoomID = visibleRooms.last?.id
        _ = runValidation()
    }

    private func syncFloorsWithGT(_ gtRooms: [GTRoom]) {
        var synced = floors
        for room in gtRooms {
            let hasFloor = synced.contains { floor in
                abs(floor.min_z - room.min_z) < 0.001 && abs(floor.max_z - room.max_z) < 0.001
            }
            guard !hasFloor else { continue }
            let number = synced.count + 1
            synced.append(AnnotationFloor(
                id: "floor_\(number)",
                name: "Floor \(number)",
                min_z: room.min_z,
                max_z: room.max_z
            ))
        }
        floors = synced.isEmpty ? [.defaultFloor] : synced
    }

    private func floorID(forMinZ minZ: Double, maxZ: Double) -> String {
        floors.first { floor in
            abs(floor.min_z - minZ) < 0.001 && abs(floor.max_z - maxZ) < 0.001
        }?.id ?? floors[0].id
    }
}

private struct RoomAnnotationCanvas: View {
    let image: UIImage
    let payload: AnnotationPayload
    let rooms: [EditableRoom]
    let draftPoints: [CGPoint]
    let selectedRoomID: UUID?

    var body: some View {
        Canvas { context, size in
            let canvasRect = CGRect(origin: .zero, size: size)
            let imageRect = MapProjection.imageRect(in: canvasRect, payload: payload)
            let projection = MapProjection(payload: payload, rect: imageRect)

            context.draw(Image(uiImage: image), in: imageRect)
            drawTrajectory(context: context, projection: projection)
            for (index, room) in rooms.enumerated() {
                drawRoom(context: context, projection: projection, room: room, index: index)
            }
            drawDraft(context: context, projection: projection)
        }
    }

    private func drawTrajectory(context: GraphicsContext, projection: MapProjection) {
        guard payload.trajectory_xy.count > 1 else { return }
        var path = Path()
        var didMove = false
        for pair in payload.trajectory_xy where pair.count == 2 {
            let point = projection.worldToView(CGPoint(x: pair[0], y: pair[1]))
            if didMove {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                didMove = true
            }
        }
        context.stroke(path, with: .color(.cyan), lineWidth: 2.0)
    }

    private func drawRoom(context: GraphicsContext, projection: MapProjection, room: EditableRoom, index: Int) {
        guard room.vertices.count >= 2 else { return }
        let color = roomColors[index % roomColors.count]
        var path = Path()
        for (pointIndex, world) in room.vertices.enumerated() {
            let point = projection.worldToView(world)
            if pointIndex == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        if room.vertices.count >= 3 {
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(0.28)))
        }
        context.stroke(path, with: .color(color), lineWidth: selectedRoomID == room.id ? 3.0 : 2.0)

        if let center = centroid(room.vertices) {
            context.draw(
                Text(room.label.roomLabelDisplayName).font(SidarFont.demi(10, relativeTo: .caption2)).foregroundStyle(.white),
                at: projection.worldToView(center)
            )
        }
        drawHandles(context: context, projection: projection, points: room.vertices, color: color)
    }

    private func drawDraft(context: GraphicsContext, projection: MapProjection) {
        guard !draftPoints.isEmpty else { return }
        var path = Path()
        for (index, world) in draftPoints.enumerated() {
            let point = projection.worldToView(world)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(.yellow), lineWidth: 2.0)
        if draftPoints.count >= 3, let first = draftPoints.first, let last = draftPoints.last {
            var closingPath = Path()
            closingPath.move(to: projection.worldToView(last))
            closingPath.addLine(to: projection.worldToView(first))
            context.stroke(
                closingPath,
                with: .color(.yellow.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
        }
        drawHandles(context: context, projection: projection, points: draftPoints, color: .yellow)
    }

    private func drawHandles(context: GraphicsContext, projection: MapProjection, points: [CGPoint], color: Color) {
        for world in points {
            let point = projection.worldToView(world)
            let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.7)))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2.0)
        }
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let x = points.reduce(CGFloat.zero) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(CGFloat.zero) { $0 + $1.y } / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    private var roomColors: [Color] {
        [.green, .orange, .purple, .pink, .mint, .red, .blue]
    }
}

private struct MapProjection {
    let payload: AnnotationPayload
    let rect: CGRect

    static func imageRect(in bounds: CGRect, payload: AnnotationPayload) -> CGRect {
        let imageAspect = CGFloat(payload.image_width) / CGFloat(max(payload.image_height, 1))
        let boundsAspect = bounds.width / max(bounds.height, 1)
        if imageAspect > boundsAspect {
            let width = bounds.width
            let height = width / imageAspect
            return CGRect(x: bounds.minX, y: bounds.midY - height * 0.5, width: width, height: height)
        } else {
            let height = bounds.height
            let width = height * imageAspect
            return CGRect(x: bounds.midX - width * 0.5, y: bounds.minY, width: width, height: height)
        }
    }

    func worldToView(_ world: CGPoint) -> CGPoint {
        let minX = CGFloat(payload.world_min_xy[0])
        let minY = CGFloat(payload.world_min_xy[1])
        let resolution = CGFloat(payload.resolution_m_per_px)
        let pixelX = (world.x - minX) / resolution
        let pixelY = CGFloat(payload.image_height - 1) - (world.y - minY) / resolution
        return CGPoint(
            x: rect.minX + pixelX * rect.width / CGFloat(max(payload.image_width, 1)),
            y: rect.minY + pixelY * rect.height / CGFloat(max(payload.image_height, 1))
        )
    }

    func viewToWorld(_ point: CGPoint) -> CGPoint {
        let pixelX = (point.x - rect.minX) * CGFloat(max(payload.image_width, 1)) / rect.width
        let pixelY = (point.y - rect.minY) * CGFloat(max(payload.image_height, 1)) / rect.height
        let minX = CGFloat(payload.world_min_xy[0])
        let minY = CGFloat(payload.world_min_xy[1])
        let resolution = CGFloat(payload.resolution_m_per_px)
        return CGPoint(
            x: minX + pixelX * resolution,
            y: minY + (CGFloat(payload.image_height - 1) - pixelY) * resolution
        )
    }
}

private struct EditableRoom: Identifiable {
    let id = UUID()
    var label: String
    var vertices: [CGPoint]
    var floorID: String = AnnotationFloor.defaultFloor.id
}

private struct VertexSelection {
    let roomID: UUID?
    let vertexIndex: Int
    let isDraft: Bool
}

private enum AnnotationReviewMode: String, CaseIterable, Identifiable {
    case topDown
    case mesh3D

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topDown: return "Top-down"
        case .mesh3D: return "3D"
        }
    }

    var systemImage: String {
        switch self {
        case .topDown: return "map"
        case .mesh3D: return "rotate.3d"
        }
    }
}

private enum AnnotationMapLayer: String, CaseIterable, Identifiable {
    case pointCloud
    case mesh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pointCloud: return "Points"
        case .mesh: return "Mesh"
        }
    }

    var systemImage: String {
        switch self {
        case .pointCloud: return "circle.grid.cross"
        case .mesh: return "cube.transparent"
        }
    }
}

private enum AnnotationInteractionMode: String, CaseIterable, Identifiable {
    case draw
    case pan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draw: return "Draw"
        case .pan: return "Pan"
        }
    }

    var systemImage: String {
        switch self {
        case .draw: return "pencil.tip"
        case .pan: return "hand.draw"
        }
    }
}
