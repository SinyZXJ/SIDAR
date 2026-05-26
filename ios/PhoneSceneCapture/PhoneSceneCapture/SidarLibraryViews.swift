import Foundation
import SwiftUI
import UIKit

struct SceneGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recorder: ARRecorder
    @State private var scenes: [SceneRecord] = []
    @State private var status: String?
    @State private var isLoadingScenes = false
    @State private var isPreparingAnnotation = false
    @State private var annotationProgress: SceneBuildProgress?
    @State private var preparingAnnotationSceneURL: URL?
    @State private var renameScene: SceneRecord?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var deleteScene: SceneRecord?
    @State private var showingDelete = false
    @State private var annotationTarget: SceneAnnotationTarget?
    @State private var uploadSettings = SceneUploadSettings.load()
    @State private var showingUploadSettings = false
    @State private var isUploading = false
    @State private var uploadProgress: SceneUploadProgress?
    @State private var uploadingSceneURL: URL?
    @State private var uploadedSceneIDs = SceneUploadHistory.load()
    @State private var failedUploadSceneIDs: Set<String> = []
    @State private var isPreparingShare = false
    @State private var shareProgress: SceneArchiveProgress?
    @State private var sharingSceneURL: URL?
    @State private var shareItem: SceneShareItem?

    var body: some View {
        NavigationStack {
            List {
                if scenes.isEmpty, isLoadingScenes {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading scenes...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if scenes.isEmpty {
                    ContentUnavailableView(
                        "No Scenes Yet",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Recorded .phonescene folders will appear here.")
                    )
                } else {
                    Section("Recorded Scenes") {
                        ForEach(scenes) { scene in
                            sceneRow(scene)
                        }
                    }
                }

                if let status {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(status, systemImage: isPreparingAnnotation || isLoadingScenes ? "hourglass" : "info.circle")
                                .font(SidarFont.footnote)
                            if let annotationProgress {
                                HStack(spacing: 10) {
                                    ProgressView(value: annotationProgress.fraction)
                                        .progressViewStyle(.linear)
                                        .tint(.blue)
                                    Text("\(Int(round(annotationProgress.fraction * 100.0)))%")
                                        .font(SidarFont.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let uploadProgress {
                                HStack(spacing: 10) {
                                    ProgressView(value: uploadProgress.fraction)
                                        .progressViewStyle(.linear)
                                        .tint(.green)
                                    Text("\(Int(round(uploadProgress.fraction * 100.0)))%")
                                        .font(SidarFont.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let shareProgress {
                                HStack(spacing: 10) {
                                    ProgressView(value: shareProgress.fraction)
                                        .progressViewStyle(.linear)
                                        .tint(.purple)
                                    Text("\(Int(round(shareProgress.fraction * 100.0)))%")
                                        .font(SidarFont.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button {
                            showingUploadSettings = true
                        } label: {
                            Image(systemName: "server.rack")
                        }

                        Button {
                            refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear(perform: refresh)
            .alert("Rename Scene", isPresented: $showingRename) {
                TextField("Scene name", text: $renameText)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    commitRename()
                }
            } message: {
                Text("The .phonescene suffix is kept automatically.")
            }
            .alert("Delete Scene?", isPresented: $showingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    commitDelete()
                }
            } message: {
                Text(deleteScene?.displayName ?? "This recording will be removed from this device.")
            }
            .fullScreenCover(item: $annotationTarget) { target in
                RoomAnnotationView(sceneURL: target.url)
            }
            .sheet(isPresented: $showingUploadSettings) {
                SceneUploadSettingsView(settings: $uploadSettings)
            }
            .sheet(item: $shareItem) { item in
                SceneShareSheet(items: [item.url])
            }
            .onChange(of: recorder.completedSceneForAnnotation) { _, _ in
                refresh()
            }
        }
        .font(SidarFont.body)
    }

    private func sceneRow(_ scene: SceneRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scene.displayName)
                        .font(SidarFont.heavy(17, relativeTo: .headline))
                        .lineLimit(1)
                    Text(scene.detailText)
                        .font(SidarFont.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button {
                        upload(scene)
                    } label: {
                        Label(uploadMenuTitle(for: scene), systemImage: "arrow.up.circle")
                    }
                    .disabled(isUploading)

                    Button {
                        share(scene)
                    } label: {
                        Label(shareMenuTitle(for: scene), systemImage: "square.and.arrow.up")
                    }
                    .disabled(isPreparingShare)

                    Button {
                        prepareAnnotation(for: scene)
                    } label: {
                        Label("Annotate", systemImage: "map")
                    }

                    Button {
                        renameScene = scene
                        renameText = scene.displayName
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        deleteScene = scene
                        showingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(SidarFont.demi(20, relativeTo: .title3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scene actions")
            }

            HStack(spacing: 8) {
                SceneBadge(text: scene.hasGT ? "GT saved" : "No GT", systemImage: scene.hasGT ? "checkmark.seal" : "tag")
                let mapStatus = mapBadgeStatus(for: scene)
                SceneBadge(text: mapStatus.text, systemImage: mapStatus.systemImage)
                SceneBadge(text: scene.hasColoredMeshPreview ? "RGB 3D" : (scene.hasMeshPreview ? "3D ready" : "3D pending"), systemImage: "cube.transparent")
                let uploadStatus = uploadBadgeStatus(for: scene)
                SceneBadge(text: uploadStatus.text, systemImage: uploadStatus.systemImage)
                if let frameCount = scene.frameCount {
                    SceneBadge(text: "\(frameCount) frames", systemImage: "film.stack")
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteScene = scene
                showingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                prepareAnnotation(for: scene)
            } label: {
                Label("Annotate", systemImage: "map")
            }
            .tint(.blue)
        }
    }

    private func refresh() {
        guard !isLoadingScenes else { return }
        isLoadingScenes = true
        if scenes.isEmpty {
            status = "Loading scenes..."
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try loadSceneRecords() }
            DispatchQueue.main.async {
                isLoadingScenes = false
                switch result {
                case .success(let loadedScenes):
                    scenes = loadedScenes
                    status = loadedScenes.isEmpty ? nil : "\(loadedScenes.count) scene\(loadedScenes.count == 1 ? "" : "s") on device"
                case .failure(let error):
                    status = "Gallery load failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadSceneRecords() throws -> [SceneRecord] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let urls = try FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "phonescene" }
            .compactMap(SceneRecord.init(url:))
            .sorted { left, right in
                (left.modifiedAt ?? .distantPast) > (right.modifiedAt ?? .distantPast)
            }
    }

    private func prepareAnnotation(for scene: SceneRecord) {
        guard !isPreparingAnnotation else { return }
        isPreparingAnnotation = true
        annotationProgress = SceneBuildProgress(0.0, "Preparing annotation map")
        preparingAnnotationSceneURL = scene.url
        status = "Preparing annotation map for \(scene.displayName)"
        let sceneURL = scene.url

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try TopDownMapBuilder().ensureAnnotationAssets(sceneURL: sceneURL) { progress in
                    DispatchQueue.main.async {
                        annotationProgress = progress
                        status = "\(progress.message) \(Int(round(progress.fraction * 100.0)))%"
                    }
                }
            }

            DispatchQueue.main.async {
                isPreparingAnnotation = false
                annotationProgress = nil
                preparingAnnotationSceneURL = nil
                switch result {
                case .success:
                    status = nil
                    annotationTarget = SceneAnnotationTarget(url: sceneURL)
                    refresh()
                case .failure(let error):
                    status = "Cannot annotate \(scene.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func mapBadgeStatus(for scene: SceneRecord) -> (text: String, systemImage: String) {
        if let progress = activeAnnotationProgress(for: scene) {
            return ("Map preparing: \(Int(round(progress.fraction * 100.0)))%", "hourglass")
        }
        if scene.hasAnnotationMap {
            return ("Map ready", "map")
        }
        return ("Map pending", "map")
    }

    private func activeAnnotationProgress(for scene: SceneRecord) -> SceneBuildProgress? {
        if let preparingAnnotationSceneURL,
           sameScene(preparingAnnotationSceneURL, scene.url),
           let annotationProgress {
            return annotationProgress
        }

        if recorder.trackingSummary == "building annotation map",
           let recordingSceneURL = recorder.currentSceneURL,
           sameScene(recordingSceneURL, scene.url),
           let progress = recorder.annotationMapBuildProgress {
            return progress
        }

        return nil
    }

    private func upload(_ scene: SceneRecord) {
        guard !isUploading else { return }
        guard uploadSettings.isConfigured else {
            status = "Set upload receiver URL before uploading."
            showingUploadSettings = true
            return
        }

        isUploading = true
        uploadingSceneURL = scene.url
        failedUploadSceneIDs.remove(scene.id)
        uploadProgress = SceneUploadProgress(fraction: 0.0, message: "Preparing upload")
        status = "Uploading \(scene.displayName)"
        let settings = uploadSettings

        Task {
            do {
                let result = try await SceneUploader(settings: settings).upload(scene: scene) { progress in
                    await MainActor.run {
                        uploadProgress = progress
                        status = "\(progress.message) \(Int(round(progress.fraction * 100.0)))%"
                    }
                }

                await MainActor.run {
                    isUploading = false
                    uploadingSceneURL = nil
                    uploadProgress = nil
                    uploadedSceneIDs.insert(scene.id)
                    SceneUploadHistory.save(uploadedSceneIDs)
                    status = "Uploaded \(scene.displayName) to \(result.scene_path)"
                    refresh()
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    uploadingSceneURL = nil
                    uploadProgress = nil
                    failedUploadSceneIDs.insert(scene.id)
                    status = "Upload failed for \(scene.displayName): \(SceneUploader.describe(error))"
                }
            }
        }
    }

    private func share(_ scene: SceneRecord) {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        sharingSceneURL = scene.url
        shareProgress = SceneArchiveProgress(fraction: 0.0, message: "Preparing ZIP")
        status = "Preparing ZIP for \(scene.displayName)"
        let sceneURL = scene.url

        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try SceneArchiveExporter.makeZIP(sceneURL: sceneURL) { progress in
                    DispatchQueue.main.async {
                        shareProgress = progress
                        status = "\(progress.message) \(Int(round(progress.fraction * 100.0)))%"
                    }
                }
            }

            DispatchQueue.main.async {
                isPreparingShare = false
                sharingSceneURL = nil
                shareProgress = nil
                switch result {
                case .success(let zipURL):
                    status = "ZIP ready: \(zipURL.lastPathComponent)"
                    shareItem = SceneShareItem(url: zipURL)
                case .failure(let error):
                    status = "Share failed for \(scene.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func uploadMenuTitle(for scene: SceneRecord) -> String {
        if let uploadingSceneURL, sameScene(uploadingSceneURL, scene.url) {
            return "Uploading..."
        }
        if failedUploadSceneIDs.contains(scene.id) {
            return "Retry Upload"
        }
        if uploadedSceneIDs.contains(scene.id) {
            return "Upload Again"
        }
        return "Upload"
    }

    private func shareMenuTitle(for scene: SceneRecord) -> String {
        if let sharingSceneURL, sameScene(sharingSceneURL, scene.url) {
            return "Preparing ZIP..."
        }
        return "Share ZIP"
    }

    private func uploadBadgeStatus(for scene: SceneRecord) -> (text: String, systemImage: String) {
        if let uploadingSceneURL,
           sameScene(uploadingSceneURL, scene.url),
           let uploadProgress {
            return ("Uploading: \(Int(round(uploadProgress.fraction * 100.0)))%", "arrow.up.circle")
        }
        if failedUploadSceneIDs.contains(scene.id) {
            return ("Upload failed", "exclamationmark.icloud")
        }
        if uploadedSceneIDs.contains(scene.id) {
            return ("Uploaded", "checkmark.icloud")
        }
        return ("Not uploaded", "icloud.and.arrow.up")
    }

    private func sameScene(_ left: URL, _ right: URL) -> Bool {
        left.standardizedFileURL.path == right.standardizedFileURL.path
    }

    private func commitRename() {
        guard let renameScene else { return }
        let baseName = sanitizedSceneName(renameText)
        guard !baseName.isEmpty else {
            status = "Scene name cannot be empty."
            return
        }

        let targetURL = renameScene.url
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName).phonescene", isDirectory: true)
        guard targetURL.path != renameScene.url.path else { return }
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            status = "\(baseName).phonescene already exists."
            return
        }

        do {
            try FileManager.default.moveItem(at: renameScene.url, to: targetURL)
            try updateSceneIDFiles(in: targetURL)
            status = "Renamed to \(baseName).phonescene"
            refresh()
        } catch {
            status = "Rename failed: \(error.localizedDescription)"
        }
    }

    private func updateSceneIDFiles(in sceneURL: URL) throws {
        let annotationURL = sceneURL.appendingPathComponent("annotation", isDirectory: true)
        let sceneID = sceneURL.deletingPathExtension().lastPathComponent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let payloadURL = annotationURL.appendingPathComponent("annotation_payload.json")
        if FileManager.default.fileExists(atPath: payloadURL.path),
           let payload = try? JSONDecoder().decode(AnnotationPayload.self, from: Data(contentsOf: payloadURL)) {
            let updatedPayload = AnnotationPayload(
                scene_id: sceneID,
                image_width: payload.image_width,
                image_height: payload.image_height,
                world_min_xy: payload.world_min_xy,
                world_max_xy: payload.world_max_xy,
                resolution_m_per_px: payload.resolution_m_per_px,
                trajectory_xy: payload.trajectory_xy,
                trajectory_xyz: payload.trajectory_xyz,
                labels: payload.labels,
                floors: payload.floors
            )
            try encoder.encode(updatedPayload).write(to: payloadURL, options: [.atomic])
        }

        let gtURL = annotationURL.appendingPathComponent("gt_rooms.json")
        if FileManager.default.fileExists(atPath: gtURL.path),
           let gt = try? JSONDecoder().decode(GTRoomFile.self, from: Data(contentsOf: gtURL)) {
            let updatedGT = GTRoomFile(
                dataset: gt.dataset,
                scene_id: sceneID,
                frame: gt.frame,
                rooms: gt.rooms
            )
            try encoder.encode(updatedGT).write(to: gtURL, options: [.atomic])
        }
    }

    private func commitDelete() {
        guard let deleteScene else { return }
        do {
            try FileManager.default.removeItem(at: deleteScene.url)
            status = "Deleted \(deleteScene.displayName)"
            refresh()
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func sanitizedSceneName(_ raw: String) -> String {
        let suffix = ".phonescene"
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_- "))
        let scalars = name.unicodeScalars.map { scalar -> UnicodeScalar in
            allowed.contains(scalar) ? scalar : UnicodeScalar("_")
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
    }
}

struct RoomLabelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var labels = RoomLabelStore.load()
    @State private var newLabel = ""
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Active Room Types") {
                    ForEach(labels, id: \.self) { label in
                        HStack {
                            Text(label.roomLabelDisplayName)
                            Spacer()
                            Text(label)
                                .font(SidarFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteLabels)
                }

                Section {
                    HStack {
                        TextField("custom_room", text: $newLabel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            addLabel()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(RoomLabelStore.normalize(newLabel).isEmpty)
                    }
                } header: {
                    Text("Add Room Type")
                } footer: {
                    Text("Labels are saved as lowercase snake_case in gt_rooms.json.")
                }

                if let status {
                    Section {
                        Text(status)
                            .font(SidarFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Room Types")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        labels = RoomLabelStore.defaultLabels
                        saveLabels()
                        status = "Reset to the default VRS-Hydra label list."
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .font(SidarFont.body)
        .presentationDetents([.medium, .large])
    }

    private func addLabel() {
        let normalized = RoomLabelStore.normalize(newLabel)
        guard !normalized.isEmpty else { return }
        guard !labels.contains(normalized) else {
            status = "\(normalized) is already in the list."
            newLabel = ""
            return
        }
        labels.append(normalized)
        newLabel = ""
        status = "Added \(normalized)."
        saveLabels()
    }

    private func deleteLabels(at offsets: IndexSet) {
        labels.remove(atOffsets: offsets)
        if labels.isEmpty {
            labels = [RoomLabel.office.rawValue]
            status = "Kept office so the list is not empty."
        } else {
            status = "Updated active room type list."
        }
        saveLabels()
    }

    private func saveLabels() {
        labels = RoomLabelStore.normalizedList(labels)
        RoomLabelStore.save(labels)
    }
}

private struct SceneUploadSettings: Equatable {
    static let serverURLKey = "sidar.upload.serverURL.v1"
    static let tokenKey = "sidar.upload.token.v1"

    var serverURL: String = ""
    var token: String = ""

    var isConfigured: Bool {
        normalizedBaseURL != nil
    }

    var normalizedBaseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        while withScheme.hasSuffix("/") {
            withScheme.removeLast()
        }
        guard let components = URLComponents(string: withScheme),
              components.scheme == "http",
              components.host != nil else {
            return nil
        }
        return components.url
    }

    static func load() -> SceneUploadSettings {
        SceneUploadSettings(
            serverURL: UserDefaults.standard.string(forKey: serverURLKey) ?? "",
            token: UserDefaults.standard.string(forKey: tokenKey) ?? ""
        )
    }

    func save() {
        UserDefaults.standard.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.serverURLKey)
        UserDefaults.standard.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tokenKey)
    }
}

private struct SceneUploadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var settings: SceneUploadSettings
    @State private var serverURL: String
    @State private var token: String
    @State private var isTesting = false
    @State private var testStatus: String?

    init(settings: Binding<SceneUploadSettings>) {
        _settings = settings
        _serverURL = State(initialValue: settings.wrappedValue.serverURL)
        _token = State(initialValue: settings.wrappedValue.token)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("http://192.168.1.20:8765", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Optional token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Receiver")
                } footer: {
                    Text("Run phone-scene receive on your workstation, then enter the receiver URL with http://. The built-in receiver is plain HTTP, not HTTPS.")
                }

                Section("Workstation Command") {
                    Text("phone-scene receive --output-dir /path/to/scenes --host 0.0.0.0 --port 8765 --token YOUR_TOKEN")
                        .font(SidarFont.caption)
                        .textSelection(.enabled)
                }

                Section {
                    if let healthURL {
                        Text("Health URL: \(healthURL.absoluteString)")
                            .font(SidarFont.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Button {
                            openURL(healthURL)
                        } label: {
                            Label("Open Health in Safari", systemImage: "safari")
                        }
                    }

                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Label("Test Receiver", systemImage: "network")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting || previewSettings.normalizedBaseURL == nil)

                    if let testStatus {
                        Text(testStatus)
                            .font(SidarFont.caption)
                            .foregroundStyle(testStatus.hasPrefix("Connected") ? .green : .orange)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Connection Test")
                } footer: {
                    Text("If Safari opens this exact URL but Test Receiver still fails, enable Local Network permission for SIDAR in iOS Settings, then reopen the app.")
                }

                if previewSettings.normalizedBaseURL == nil && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Label("Receiver URL is not valid. Use http://IP:8765, not https://.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Upload Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        settings = previewSettings
                        settings.save()
                        dismiss()
                    }
                    .disabled(previewSettings.normalizedBaseURL == nil)
                }
            }
        }
        .font(SidarFont.body)
        .presentationDetents([.medium, .large])
    }

    private var previewSettings: SceneUploadSettings {
        SceneUploadSettings(serverURL: serverURL, token: token)
    }

    private var healthURL: URL? {
        previewSettings.normalizedBaseURL?.appendingPathComponent("health")
    }

    private func testConnection() {
        let settings = previewSettings
        guard settings.normalizedBaseURL != nil else {
            testStatus = "Use http://IP:8765 before testing."
            return
        }

        isTesting = true
        testStatus = "Testing receiver..."
        Task {
            do {
                let summary = try await SceneUploader(settings: settings).testConnection()
                await MainActor.run {
                    isTesting = false
                    testStatus = summary
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testStatus = "Connection failed: \(SceneUploader.describe(error))"
                }
            }
        }
    }
}

private struct SceneUploadHistory {
    static let storageKey = "sidar.uploadedSceneIDs.v1"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static func save(_ sceneIDs: Set<String>) {
        UserDefaults.standard.set(Array(sceneIDs).sorted(), forKey: storageKey)
    }
}

private struct SceneUploadProgress {
    let fraction: Double
    let message: String
}

private struct SceneArchiveProgress {
    let fraction: Double
    let message: String
}

private struct SceneShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SceneShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SceneUploadFile {
    let url: URL
    let relativePath: String
    let size: Int64
}

private struct SceneUploader {
    let settings: SceneUploadSettings

    func testConnection() async throws -> String {
        guard let baseURL = settings.normalizedBaseURL else {
            throw SceneUploadError.invalidSettings
        }

        do {
            try await checkHealth(baseURL: baseURL)
        } catch {
            throw SceneUploadError.server("Health check failed at \(baseURL.appendingPathComponent("health").absoluteString): \(Self.describe(error))")
        }

        do {
            try await checkAuth(baseURL: baseURL)
        } catch {
            throw SceneUploadError.server("Token check failed at \(baseURL.appendingPathComponent("api/uploads/auth-check").absoluteString): \(Self.describe(error))")
        }

        return "Connected to \(baseURL.absoluteString). Receiver and token are OK."
    }

    static func describe(_ error: Error) -> String {
        if let uploadError = error as? SceneUploadError,
           let description = uploadError.errorDescription {
            return description
        }
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) (\(urlError.code.rawValue))"
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "\(nsError.localizedDescription) (\(nsError.code))"
        }
        return error.localizedDescription
    }

    func upload(
        scene: SceneRecord,
        progress: @escaping (SceneUploadProgress) async -> Void
    ) async throws -> SceneUploadFinishResponse {
        guard let baseURL = settings.normalizedBaseURL else {
            throw SceneUploadError.invalidSettings
        }

        let files = try collectFiles(sceneURL: scene.url)
        guard !files.isEmpty else {
            throw SceneUploadError.noFiles
        }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        await progress(SceneUploadProgress(fraction: 0.01, message: "Checking receiver"))
        try await checkHealth(baseURL: baseURL)
        await progress(SceneUploadProgress(fraction: 0.02, message: "Starting upload"))

        let startResponse: SceneUploadStartResponse = try await postJSON(
            SceneUploadStartRequest(
                scene_name: scene.url.lastPathComponent,
                file_count: files.count,
                total_bytes: totalBytes
            ),
            to: baseURL.appendingPathComponent("api/uploads/start")
        )

        var sentBytes: Int64 = 0
        do {
            for (index, file) in files.enumerated() {
                await progress(SceneUploadProgress(
                    fraction: totalBytes > 0
                        ? min(0.98, max(0.02, Double(sentBytes) / Double(totalBytes)))
                        : 0.02,
                    message: "Uploading \(index + 1)/\(files.count): \(file.relativePath)"
                ))
                try await uploadFile(
                    file,
                    uploadID: startResponse.upload_id,
                    baseURL: baseURL,
                    completedBytes: sentBytes,
                    totalBytes: totalBytes,
                    fileIndex: index + 1,
                    fileCount: files.count,
                    progress: progress
                )
                sentBytes += file.size
                let fraction = totalBytes > 0
                    ? min(0.98, max(0.02, Double(sentBytes) / Double(totalBytes)))
                    : 0.98
                await progress(SceneUploadProgress(
                    fraction: fraction,
                    message: "Uploading \(file.relativePath)"
                ))
            }

            await progress(SceneUploadProgress(fraction: 0.99, message: "Finalizing upload"))
            let finishResponse: SceneUploadFinishResponse = try await postJSON(
                SceneUploadFinishRequest(upload_id: startResponse.upload_id),
                to: baseURL.appendingPathComponent("api/uploads/finish")
            )
            await progress(SceneUploadProgress(fraction: 1.0, message: "Upload complete"))
            return finishResponse
            } catch {
                try? await postJSONNoResponse(
                    SceneUploadFinishRequest(upload_id: startResponse.upload_id),
                    to: baseURL.appendingPathComponent("api/uploads/cancel")
                )
            throw error
        }
    }

    private func collectFiles(sceneURL: URL) throws -> [SceneUploadFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sceneURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw SceneUploadError.noFiles
        }

        let basePath = sceneURL.standardizedFileURL.path
        var files: [SceneUploadFile] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(basePath + "/") else { continue }
            let relative = String(filePath.dropFirst(basePath.count + 1))
            files.append(SceneUploadFile(
                url: fileURL,
                relativePath: relative,
                size: Int64(values.fileSize ?? 0)
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func uploadFile(
        _ file: SceneUploadFile,
        uploadID: String,
        baseURL: URL,
        completedBytes: Int64,
        totalBytes: Int64,
        fileIndex: Int,
        fileCount: Int,
        progress: @escaping (SceneUploadProgress) async -> Void
    ) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/uploads/file"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "upload_id", value: uploadID),
            URLQueryItem(name: "path", value: file.relativePath)
        ]
        guard let url = components?.url else {
            throw SceneUploadError.invalidSettings
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        applyToken(to: &request)
        let delegate = SceneUploadTaskDelegate { sent in
            let totalSent = completedBytes + max(0, sent)
            let fraction = totalBytes > 0
                ? min(0.98, max(0.02, Double(totalSent) / Double(totalBytes)))
                : 0.98
            Task {
                await progress(SceneUploadProgress(
                    fraction: fraction,
                    message: "Uploading \(fileIndex)/\(fileCount): \(file.relativePath)"
                ))
            }
        }
        let session = URLSession(configuration: uploadSessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let result: (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file.url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: SceneUploadError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
        let (data, response) = result
        _ = try decodeUploadResponse(data: data, response: response, as: SceneUploadFileResponse.self)
    }

    private func checkHealth(baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await shortRequestData(for: request, retryWithSharedSession: true)
        let health = try decodeUploadResponse(data: data, response: response, as: SceneUploadHealthResponse.self)
        guard health.status == "ok" else {
            throw SceneUploadError.server("Receiver health check failed.")
        }
    }

    private func checkAuth(baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads/auth-check"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        applyToken(to: &request)
        let (data, response) = try await shortRequestData(for: request, retryWithSharedSession: true)
        let auth = try decodeUploadResponse(data: data, response: response, as: SceneUploadHealthResponse.self)
        guard auth.status == "ok" else {
            throw SceneUploadError.server("Receiver token check failed.")
        }
    }

    private func postJSON<T: Encodable, U: Decodable>(_ body: T, to url: URL) async throws -> U {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyToken(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await shortRequestData(for: request, retryWithSharedSession: false)
        return try decodeUploadResponse(data: data, response: response, as: U.self)
    }

    private func postJSONNoResponse<T: Encodable>(_ body: T, to url: URL) async throws {
        let _: SceneUploadFileResponse = try await postJSON(body, to: url)
    }

    private func applyToken(to request: inout URLRequest) {
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-SIDAR-Token")
        }
    }

    private func shortRequestData(
        for request: URLRequest,
        retryWithSharedSession: Bool
    ) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: shortRequestConfiguration)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await session.data(for: request)
        } catch {
            let primaryError = error
            guard retryWithSharedSession else {
                throw primaryError
            }
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                throw SceneUploadError.server("Primary request failed: \(Self.describe(primaryError)); shared session retry failed: \(Self.describe(error))")
            }
        }
    }

    private func decodeUploadResponse<T: Decodable>(
        data: Data,
        response: URLResponse,
        as type: T.Type
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw SceneUploadError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            if let error = try? JSONDecoder().decode(SceneUploadErrorResponse.self, from: data),
               let message = error.error {
                throw SceneUploadError.server(message)
            }
            throw SceneUploadError.server("HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private var shortRequestConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        return configuration
    }

    private var uploadSessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        return configuration
    }
}

private final class SceneUploadTaskDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Int64) -> Void

    init(onProgress: @escaping (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent)
    }
}

private struct SceneUploadStartRequest: Encodable {
    let scene_name: String
    let file_count: Int
    let total_bytes: Int64
}

private struct SceneUploadStartResponse: Decodable {
    let upload_id: String
}

private struct SceneUploadFinishRequest: Encodable {
    let upload_id: String
}

private struct SceneUploadFileResponse: Decodable {
    let status: String
}

private struct SceneUploadHealthResponse: Decodable {
    let status: String
}

private struct SceneUploadFinishResponse: Decodable {
    let status: String
    let scene_path: String
}

private struct SceneUploadErrorResponse: Decodable {
    let error: String?
}

private enum SceneUploadError: LocalizedError {
    case invalidSettings
    case noFiles
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Upload receiver URL must be http://IP:port."
        case .noFiles:
            return "The scene has no files to upload."
        case .invalidResponse:
            return "The receiver returned an invalid response."
        case .server(let message):
            return message
        }
    }
}

private enum SceneArchiveExporter {
    private struct ArchiveEntry {
        let url: URL
        let relativePath: String
        var size: UInt64 = 0
        var crc32: UInt32 = 0
        var localHeaderOffset: UInt64 = 0
    }

    static func makeZIP(
        sceneURL: URL,
        progress: (SceneArchiveProgress) -> Void
    ) throws -> URL {
        var entries = try collectFiles(sceneURL: sceneURL)
        guard !entries.isEmpty else {
            throw SceneArchiveError.emptyScene
        }

        for index in entries.indices {
            let fraction = entries.count > 0 ? Double(index) / Double(entries.count) * 0.35 : 0.0
            progress(SceneArchiveProgress(fraction: fraction, message: "Scanning files"))
            let stats = try checksumAndSize(for: entries[index].url)
            entries[index].crc32 = stats.crc32
            entries[index].size = stats.size
            _ = try checkedUInt32(stats.size, field: "file size")
        }

        let exportsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SIDARExports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let zipURL = exportsURL.appendingPathComponent("\(sceneURL.lastPathComponent).zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        guard FileManager.default.createFile(atPath: zipURL.path, contents: nil) else {
            throw SceneArchiveError.cannotCreateArchive
        }

        let output = try FileHandle(forWritingTo: zipURL)
        defer { try? output.close() }

        var offset: UInt64 = 0
        func write(_ data: Data) throws {
            try output.write(contentsOf: data)
            offset += UInt64(data.count)
            _ = try checkedUInt32(offset, field: "archive size")
        }

        for index in entries.indices {
            let fraction = 0.35 + (Double(index) / Double(entries.count) * 0.55)
            progress(SceneArchiveProgress(fraction: fraction, message: "Writing ZIP"))
            entries[index].localHeaderOffset = offset
            _ = try checkedUInt32(offset, field: "local header offset")
            try write(localHeader(for: entries[index]))
            try copyFile(entries[index].url, into: output) { bytesWritten in
                offset += bytesWritten
                _ = try checkedUInt32(offset, field: "archive size")
            }
        }

        progress(SceneArchiveProgress(fraction: 0.92, message: "Finalizing ZIP"))
        let centralDirectoryOffset = offset
        for entry in entries {
            try write(centralDirectoryHeader(for: entry))
        }
        let centralDirectorySize = offset - centralDirectoryOffset
        try write(endOfCentralDirectory(
            entryCount: entries.count,
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryOffset
        ))
        progress(SceneArchiveProgress(fraction: 1.0, message: "ZIP ready"))
        return zipURL
    }

    private static func collectFiles(sceneURL: URL) throws -> [ArchiveEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sceneURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw SceneArchiveError.emptyScene
        }

        let basePath = sceneURL.standardizedFileURL.path
        let rootName = sceneURL.lastPathComponent
        var entries: [ArchiveEntry] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(basePath + "/") else { continue }
            let relative = String(filePath.dropFirst(basePath.count + 1))
            entries.append(ArchiveEntry(
                url: fileURL,
                relativePath: "\(rootName)/\(relative)"
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private static func checksumAndSize(for url: URL) throws -> (crc32: UInt32, size: UInt64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc = CRC32()
        var size: UInt64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            crc.update(chunk)
            size += UInt64(chunk.count)
        }
        return (crc.checksum, size)
    }

    private static func copyFile(
        _ url: URL,
        into output: FileHandle,
        didWrite: (UInt64) throws -> Void
    ) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            try didWrite(UInt64(chunk.count))
        }
    }

    private static func localHeader(for entry: ArchiveEntry) throws -> Data {
        let name = try encodedName(entry.relativePath)
        var data = Data()
        data.appendUInt32LE(0x04034b50)
        data.appendUInt16LE(20)
        data.appendUInt16LE(0x0800)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt32LE(entry.crc32)
        data.appendUInt32LE(try checkedUInt32(entry.size, field: "compressed size"))
        data.appendUInt32LE(try checkedUInt32(entry.size, field: "uncompressed size"))
        data.appendUInt16LE(try checkedUInt16(name.count, field: "file name length"))
        data.appendUInt16LE(0)
        data.append(name)
        return data
    }

    private static func centralDirectoryHeader(for entry: ArchiveEntry) throws -> Data {
        let name = try encodedName(entry.relativePath)
        var data = Data()
        data.appendUInt32LE(0x02014b50)
        data.appendUInt16LE(20)
        data.appendUInt16LE(20)
        data.appendUInt16LE(0x0800)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt32LE(entry.crc32)
        data.appendUInt32LE(try checkedUInt32(entry.size, field: "compressed size"))
        data.appendUInt32LE(try checkedUInt32(entry.size, field: "uncompressed size"))
        data.appendUInt16LE(try checkedUInt16(name.count, field: "file name length"))
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt32LE(0)
        data.appendUInt32LE(try checkedUInt32(entry.localHeaderOffset, field: "local header offset"))
        data.append(name)
        return data
    }

    private static func endOfCentralDirectory(
        entryCount: Int,
        centralDirectorySize: UInt64,
        centralDirectoryOffset: UInt64
    ) throws -> Data {
        var data = Data()
        data.appendUInt32LE(0x06054b50)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(try checkedUInt16(entryCount, field: "entry count"))
        data.appendUInt16LE(try checkedUInt16(entryCount, field: "entry count"))
        data.appendUInt32LE(try checkedUInt32(centralDirectorySize, field: "central directory size"))
        data.appendUInt32LE(try checkedUInt32(centralDirectoryOffset, field: "central directory offset"))
        data.appendUInt16LE(0)
        return data
    }

    private static func encodedName(_ name: String) throws -> Data {
        guard let data = name.data(using: .utf8) else {
            throw SceneArchiveError.invalidFileName(name)
        }
        return data
    }

    private static func checkedUInt16(_ value: Int, field: String) throws -> UInt16 {
        guard value <= Int(UInt16.max) else {
            throw SceneArchiveError.zipLimitExceeded(field)
        }
        return UInt16(value)
    }

    private static func checkedUInt32(_ value: UInt64, field: String) throws -> UInt32 {
        guard value <= UInt64(UInt32.max) else {
            throw SceneArchiveError.zipLimitExceeded(field)
        }
        return UInt32(value)
    }
}

private enum SceneArchiveError: LocalizedError {
    case emptyScene
    case cannotCreateArchive
    case invalidFileName(String)
    case zipLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .emptyScene:
            return "The scene has no files to share."
        case .cannotCreateArchive:
            return "Could not create the ZIP archive."
        case .invalidFileName(let name):
            return "Could not encode file name \(name)."
        case .zipLimitExceeded(let field):
            return "The scene is too large for the built-in ZIP exporter (\(field) exceeds 4 GB). Use Files/iTunes file sharing for this capture."
        }
    }
}

private struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    private var value: UInt32 = 0xffffffff

    mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xff)
            value = (value >> 8) ^ Self.table[index]
        }
    }

    var checksum: UInt32 {
        value ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private struct SceneBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(SidarFont.medium(11, relativeTo: .caption2))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SceneRecord: Identifiable {
    let id: String
    let url: URL
    let displayName: String
    let modifiedAt: Date?
    let hasGT: Bool
    let hasAnnotationMap: Bool
    let hasMeshPreview: Bool
    let hasColoredMeshPreview: Bool
    let frameCount: Int?

    init?(url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        self.url = url
        id = url.path
        displayName = url.deletingPathExtension().lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        modifiedAt = values?.contentModificationDate
        let annotationURL = url.appendingPathComponent("annotation", isDirectory: true)
        hasGT = FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("gt_rooms.json").path)
        hasAnnotationMap = FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("topdown_map.png").path)
            && FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("annotation_payload.json").path)
        hasMeshPreview = FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("preview_mesh.bin").path)
            && FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("preview_mesh.json").path)
        hasColoredMeshPreview = FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("preview_mesh_colored.bin").path)
            && FileManager.default.fileExists(atPath: annotationURL.appendingPathComponent("preview_mesh_colored.json").path)
        frameCount = SceneRecord.countManifestFrames(sceneURL: url)
    }

    var detailText: String {
        if let modifiedAt {
            return modifiedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return url.lastPathComponent
    }

    private static func countManifestFrames(sceneURL: URL) -> Int? {
        let manifestURL = sceneURL.appendingPathComponent("manifest.jsonl")
        guard let stream = InputStream(url: manifestURL) else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var lineCount = 0
        var sawData = false
        var lastByte: UInt8?

        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }

            sawData = true
            lastByte = buffer[readCount - 1]
            for index in 0..<readCount where buffer[index] == 10 {
                lineCount += 1
            }
        }

        if sawData, lastByte != 10 {
            lineCount += 1
        }
        return sawData ? lineCount : 0
    }
}

private struct SceneAnnotationTarget: Identifiable {
    let id = UUID()
    let url: URL
}
