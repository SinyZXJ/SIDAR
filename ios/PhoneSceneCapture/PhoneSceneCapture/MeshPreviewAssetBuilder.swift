import Foundation
import UIKit
import simd

enum MeshPreviewAssetBuilderError: LocalizedError {
    case missingMesh
    case invalidPLY
    case emptyPreview
    case missingPreview
    case invalidBinary
    case missingManifest
    case noRGBSamples

    var errorDescription: String? {
        switch self {
        case .missingMesh:
            return "No ARKit mesh was found for this scene."
        case .invalidPLY:
            return "The ARKit mesh file could not be parsed."
        case .emptyPreview:
            return "The mesh preview did not contain any usable vertices."
        case .missingPreview:
            return "Build the 3D preview before RGB colorization."
        case .invalidBinary:
            return "The cached 3D preview is unreadable."
        case .missingManifest:
            return "The scene manifest is missing."
        case .noRGBSamples:
            return "No RGB samples could be projected onto the preview mesh."
        }
    }
}

struct MeshPreviewAssetBuilder {
    var maxSourceVerticesForTriangles = 900_000
    var maxPreviewVertices = 140_000
    var maxPreviewTriangles = 90_000
    var maxRGBFrames = 50
    var maxRGBDepthMeters: Float = 10.0

    func ensurePreviewAssets(
        sceneURL: URL,
        progress: ((MeshPreviewProgress) -> Void)? = nil
    ) throws -> MeshPreviewMetadata {
        if let metadata = try? loadMetadata(sceneURL: sceneURL, preferColorized: false) {
            return metadata
        }
        return try buildPreviewAssets(sceneURL: sceneURL, progress: progress)
    }

    func buildPreviewAssets(
        sceneURL: URL,
        progress: ((MeshPreviewProgress) -> Void)? = nil
    ) throws -> MeshPreviewMetadata {
        progress?(MeshPreviewProgress(0.02, "Reading ARKit mesh"))
        let meshURL = sceneURL.appendingPathComponent("mesh/arkit_mesh_world.ply")
        guard FileManager.default.fileExists(atPath: meshURL.path) else {
            throw MeshPreviewAssetBuilderError.missingMesh
        }

        let parsed = try parsePreviewPLY(meshURL: meshURL, progress: progress)
        guard !parsed.vertices.isEmpty else {
            throw MeshPreviewAssetBuilderError.emptyPreview
        }

        progress?(MeshPreviewProgress(0.92, "Writing 3D preview cache"))
        let colors = heightColors(for: parsed.vertices)
        let metadata = MeshPreviewMetadata(
            sceneID: sceneURL.deletingPathExtension().lastPathComponent,
            primitive: parsed.indices.isEmpty ? .points : .triangles,
            colorMode: .height,
            vertexCount: parsed.vertices.count / 3,
            indexCount: parsed.indices.isEmpty ? parsed.vertices.count / 3 : parsed.indices.count,
            boundsMinXYZ: parsed.boundsMin,
            boundsMaxXYZ: parsed.boundsMax
        )
        try writePreview(
            sceneURL: sceneURL,
            metadata: metadata,
            vertices: parsed.vertices,
            colors: colors,
            indices: parsed.indices,
            colored: false
        )
        progress?(MeshPreviewProgress(1.0, "3D preview ready"))
        return metadata
    }

    func colorizePreviewAssets(
        sceneURL: URL,
        progress: ((MeshPreviewProgress) -> Void)? = nil
    ) throws -> MeshPreviewMetadata {
        progress?(MeshPreviewProgress(0.02, "Loading 3D preview"))
        let base = try loadPreviewGeometry(sceneURL: sceneURL, preferColorized: false)
        guard !base.vertices.isEmpty else {
            throw MeshPreviewAssetBuilderError.missingPreview
        }

        let manifest = try loadManifest(sceneURL: sceneURL)
        guard !manifest.isEmpty else {
            throw MeshPreviewAssetBuilderError.missingManifest
        }

        var accumulated = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: base.metadata.vertex_count)
        var counts = [UInt16](repeating: 0, count: base.metadata.vertex_count)
        let frameStride = max(1, Int(ceil(Double(manifest.count) / Double(max(maxRGBFrames, 1)))))
        let sampledFrames = manifest.enumerated().filter { $0.offset % frameStride == 0 }.map(\.element)

        for (frameIndex, entry) in sampledFrames.enumerated() {
            let fraction = 0.08 + 0.78 * Double(frameIndex) / Double(max(sampledFrames.count, 1))
            progress?(MeshPreviewProgress(fraction, "Projecting RGB frame \(frameIndex + 1) / \(sampledFrames.count)"))
            guard let rgb = RGBPixelSampler(url: sceneURL.appendingPathComponent(entry.rgb)) else {
                continue
            }
            let depth = DepthFrame(sceneURL: sceneURL, entry: entry)
            let cameraToWorld = matrix4x4(rows: entry.camera_to_world)
            let worldToCamera = cameraToWorld.inverse
            let fx = Float(entry.intrinsics[safe: 0]?[safe: 0] ?? 0)
            let fy = Float(entry.intrinsics[safe: 1]?[safe: 1] ?? 0)
            let cx = Float(entry.intrinsics[safe: 0]?[safe: 2] ?? 0)
            let cy = Float(entry.intrinsics[safe: 1]?[safe: 2] ?? 0)
            guard fx > 0, fy > 0 else { continue }

            for vertexIndex in 0..<base.metadata.vertex_count {
                let baseOffset = vertexIndex * 3
                let world = SIMD4<Float>(
                    base.vertices[baseOffset],
                    base.vertices[baseOffset + 1],
                    base.vertices[baseOffset + 2],
                    1.0
                )
                let camera = worldToCamera * world
                let opticalZ = -camera.z
                guard opticalZ > 0.05, opticalZ < maxRGBDepthMeters else { continue }

                let u = fx * camera.x / opticalZ + cx
                let v = fy * (-camera.y) / opticalZ + cy
                guard u.isFinite, v.isFinite else { continue }
                let pixelX = Int(u.rounded())
                let pixelY = Int(v.rounded())
                guard pixelX >= 0, pixelX < rgb.width, pixelY >= 0, pixelY < rgb.height else {
                    continue
                }

                if let depth {
                    let depthX = Int((Float(depth.width) / Float(max(entry.image_width, 1)) * u).rounded())
                    let depthY = Int((Float(depth.height) / Float(max(entry.image_height, 1)) * v).rounded())
                    guard let depthMeters = depth.valueAt(x: depthX, y: depthY),
                          abs(depthMeters - opticalZ) <= max(0.18, 0.04 * opticalZ) else {
                        continue
                    }
                }

                let color = rgb.colorAt(x: pixelX, y: pixelY)
                accumulated[vertexIndex] += color
                counts[vertexIndex] = min(UInt16.max, counts[vertexIndex] + 1)
            }
        }

        progress?(MeshPreviewProgress(0.88, "Writing colored mesh preview"))
        var colors = base.colors
        var coloredCount = 0
        for vertexIndex in 0..<base.metadata.vertex_count where counts[vertexIndex] > 0 {
            let color = accumulated[vertexIndex] / Float(counts[vertexIndex])
            let colorOffset = vertexIndex * 4
            colors[colorOffset] = color.x
            colors[colorOffset + 1] = color.y
            colors[colorOffset + 2] = color.z
            colors[colorOffset + 3] = 1.0
            coloredCount += 1
        }
        guard coloredCount > 0 else {
            throw MeshPreviewAssetBuilderError.noRGBSamples
        }

        let metadata = MeshPreviewMetadata(
            sceneID: base.metadata.scene_id,
            primitive: base.metadata.primitive,
            colorMode: .rgb,
            vertexCount: base.metadata.vertex_count,
            indexCount: base.metadata.index_count,
            boundsMinXYZ: base.metadata.bounds_min_xyz,
            boundsMaxXYZ: base.metadata.bounds_max_xyz
        )
        try writePreview(
            sceneURL: sceneURL,
            metadata: metadata,
            vertices: base.vertices,
            colors: colors,
            indices: base.indices,
            colored: true
        )
        progress?(MeshPreviewProgress(1.0, "RGB mesh preview ready"))
        return metadata
    }

    func loadMetadata(sceneURL: URL, preferColorized: Bool = true) throws -> MeshPreviewMetadata {
        let urls = try previewURLs(sceneURL: sceneURL, colored: preferColorized)
        if preferColorized,
           FileManager.default.fileExists(atPath: urls.metadata.path),
           FileManager.default.fileExists(atPath: urls.binary.path) {
            return try JSONDecoder().decode(MeshPreviewMetadata.self, from: Data(contentsOf: urls.metadata))
        }

        let fallback = try previewURLs(sceneURL: sceneURL, colored: false)
        guard FileManager.default.fileExists(atPath: fallback.metadata.path),
              FileManager.default.fileExists(atPath: fallback.binary.path) else {
            throw MeshPreviewAssetBuilderError.missingPreview
        }
        return try JSONDecoder().decode(MeshPreviewMetadata.self, from: Data(contentsOf: fallback.metadata))
    }

    func loadPreviewGeometry(sceneURL: URL, preferColorized: Bool = true) throws -> MeshPreviewGeometry {
        let coloredURLs = try previewURLs(sceneURL: sceneURL, colored: true)
        let useColored = preferColorized
            && FileManager.default.fileExists(atPath: coloredURLs.metadata.path)
            && FileManager.default.fileExists(atPath: coloredURLs.binary.path)
        let urls = try previewURLs(sceneURL: sceneURL, colored: useColored)
        guard FileManager.default.fileExists(atPath: urls.metadata.path),
              FileManager.default.fileExists(atPath: urls.binary.path) else {
            throw MeshPreviewAssetBuilderError.missingPreview
        }
        let metadata = try JSONDecoder().decode(MeshPreviewMetadata.self, from: Data(contentsOf: urls.metadata))
        let data = try Data(contentsOf: urls.binary)
        let vertexFloatCount = metadata.vertex_count * 3
        let colorFloatCount = metadata.vertex_count * 4
        let indexCount = metadata.primitive == .points && metadata.index_count == vertexFloatCount / 3
            ? 0
            : metadata.index_count
        let expectedBytes = (vertexFloatCount + colorFloatCount) * MemoryLayout<Float>.size
            + indexCount * MemoryLayout<UInt32>.size
        guard data.count >= expectedBytes else {
            throw MeshPreviewAssetBuilderError.invalidBinary
        }

        var vertices = [Float]()
        vertices.reserveCapacity(vertexFloatCount)
        var colors = [Float]()
        colors.reserveCapacity(colorFloatCount)
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        data.withUnsafeBytes { raw in
            for index in 0..<vertexFloatCount {
                vertices.append(raw.load(fromByteOffset: index * 4, as: Float.self))
            }
            let colorOffset = vertexFloatCount * 4
            for index in 0..<colorFloatCount {
                colors.append(raw.load(fromByteOffset: colorOffset + index * 4, as: Float.self))
            }
            let indexOffset = colorOffset + colorFloatCount * 4
            for index in 0..<indexCount {
                indices.append(raw.load(fromByteOffset: indexOffset + index * 4, as: UInt32.self))
            }
        }
        return MeshPreviewGeometry(metadata: metadata, vertices: vertices, colors: colors, indices: indices)
    }

    private func parsePreviewPLY(
        meshURL: URL,
        progress: ((MeshPreviewProgress) -> Void)?
    ) throws -> ParsedPreviewMesh {
        let handle = try FileHandle(forReadingFrom: meshURL)
        defer {
            try? handle.close()
        }
        let reader = MeshPreviewPLYLineReader(handle: handle)
        var vertexCount = 0
        var faceCount = 0
        var didReadHeader = false

        while let line = try reader.nextLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("element vertex ") {
                vertexCount = Int(trimmed.split(separator: " ").last ?? "0") ?? 0
            } else if trimmed.hasPrefix("element face ") {
                faceCount = Int(trimmed.split(separator: " ").last ?? "0") ?? 0
            } else if trimmed == "end_header" {
                didReadHeader = true
                break
            }
        }

        guard didReadHeader, vertexCount > 0 else {
            throw MeshPreviewAssetBuilderError.invalidPLY
        }

        let keepTriangles = vertexCount <= maxSourceVerticesForTriangles && faceCount > 0
        var sourceVertices: [SIMD3<Float>] = []
        var sampledVertices: [Float] = []
        let vertexStride = max(1, Int(ceil(Double(vertexCount) / Double(max(maxPreviewVertices, 1)))))
        if keepTriangles {
            sourceVertices.reserveCapacity(vertexCount)
        } else {
            sampledVertices.reserveCapacity(min(vertexCount, maxPreviewVertices) * 3)
        }

        var bounds = PreviewBounds()
        for vertexIndex in 0..<vertexCount {
            guard let line = try reader.nextLine() else { break }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3,
                  let x = Float(parts[0]),
                  let y = Float(parts[1]),
                  let z = Float(parts[2]) else {
                continue
            }
            let vertex = SIMD3<Float>(x, y, z)
            bounds.include(vertex)
            if keepTriangles {
                sourceVertices.append(vertex)
            } else if vertexIndex % vertexStride == 0 {
                sampledVertices.append(contentsOf: [x, y, z])
            }
            if vertexIndex % 50_000 == 0 {
                progress?(MeshPreviewProgress(0.08 + 0.42 * Double(vertexIndex) / Double(max(vertexCount, 1)), "Reading mesh vertices"))
            }
        }

        guard keepTriangles else {
            return ParsedPreviewMesh(
                vertices: sampledVertices,
                indices: [],
                boundsMin: bounds.minArray,
                boundsMax: bounds.maxArray
            )
        }

        progress?(MeshPreviewProgress(0.54, "Sampling mesh triangles"))
        var previewVertices: [Float] = []
        var previewIndices: [UInt32] = []
        var vertexMap: [Int: UInt32] = [:]
        let faceStride = max(1, Int(ceil(Double(max(faceCount, 1)) / Double(max(maxPreviewTriangles, 1)))))

        func previewIndex(for sourceIndex: Int) -> UInt32? {
            if let mapped = vertexMap[sourceIndex] {
                return mapped
            }
            guard sourceVertices.indices.contains(sourceIndex) else {
                return nil
            }
            let vertex = sourceVertices[sourceIndex]
            let mapped = UInt32(previewVertices.count / 3)
            previewVertices.append(contentsOf: [vertex.x, vertex.y, vertex.z])
            vertexMap[sourceIndex] = mapped
            return mapped
        }

        for faceIndex in 0..<faceCount {
            guard let line = try reader.nextLine() else { break }
            guard faceIndex % faceStride == 0 else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4,
                  let count = Int(parts[0]),
                  count >= 3 else {
                continue
            }
            let faceIndices = parts.dropFirst().compactMap { Int($0) }
            guard faceIndices.count >= 3 else { continue }
            let first = faceIndices[0]
            for offset in 1..<(faceIndices.count - 1) {
                if previewIndices.count / 3 >= maxPreviewTriangles {
                    break
                }
                guard let i0 = previewIndex(for: first),
                      let i1 = previewIndex(for: faceIndices[offset]),
                      let i2 = previewIndex(for: faceIndices[offset + 1]) else {
                    continue
                }
                previewIndices.append(contentsOf: [i0, i1, i2])
            }
            if faceIndex % 50_000 == 0 {
                progress?(MeshPreviewProgress(0.55 + 0.32 * Double(faceIndex) / Double(max(faceCount, 1)), "Sampling mesh triangles"))
            }
        }

        if previewVertices.isEmpty {
            let fallbackStride = max(1, Int(ceil(Double(sourceVertices.count) / Double(max(maxPreviewVertices, 1)))))
            for (index, vertex) in sourceVertices.enumerated() where index % fallbackStride == 0 {
                previewVertices.append(contentsOf: [vertex.x, vertex.y, vertex.z])
            }
            previewIndices = []
        }

        return ParsedPreviewMesh(
            vertices: previewVertices,
            indices: previewIndices,
            boundsMin: bounds.minArray,
            boundsMax: bounds.maxArray
        )
    }

    private func heightColors(for vertices: [Float]) -> [Float] {
        let vertexCount = vertices.count / 3
        let heights = (0..<vertexCount).map { vertices[$0 * 3 + 1] }
        let minHeight = heights.min() ?? 0
        let maxHeight = heights.max() ?? minHeight + 1
        let span = max(maxHeight - minHeight, 0.001)
        var colors: [Float] = []
        colors.reserveCapacity(vertexCount * 4)
        for vertexIndex in 0..<vertexCount {
            let height = vertices[vertexIndex * 3 + 1]
            let t = min(1.0, max(0.0, (height - minHeight) / span))
            let shade = 0.42 + 0.42 * t
            let cool = 0.68 + 0.24 * (1.0 - abs(t - 0.5) * 2.0)
            colors.append(shade)
            colors.append(cool)
            colors.append(0.92)
            colors.append(1.0)
        }
        return colors
    }

    private func writePreview(
        sceneURL: URL,
        metadata: MeshPreviewMetadata,
        vertices: [Float],
        colors: [Float],
        indices: [UInt32],
        colored: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)
        let urls = try previewURLs(sceneURL: sceneURL, colored: colored)
        try metadataData.write(to: urls.metadata, options: [.atomic])
        var binary = Data()
        binary.reserveCapacity((vertices.count + colors.count) * 4 + indices.count * 4)
        binary.appendFloat32(vertices)
        binary.appendFloat32(colors)
        binary.appendUInt32(indices)
        try binary.write(to: urls.binary, options: [.atomic])
    }

    private func previewURLs(sceneURL: URL, colored: Bool) throws -> (metadata: URL, binary: URL) {
        let annotationURL = try FrameWriter.annotationDirectory(for: sceneURL)
        if colored {
            return (
                annotationURL.appendingPathComponent("preview_mesh_colored.json"),
                annotationURL.appendingPathComponent("preview_mesh_colored.bin")
            )
        }
        return (
            annotationURL.appendingPathComponent("preview_mesh.json"),
            annotationURL.appendingPathComponent("preview_mesh.bin")
        )
    }

    private func loadManifest(sceneURL: URL) throws -> [MeshPreviewManifestEntry] {
        let manifestURL = sceneURL.appendingPathComponent("manifest.jsonl")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MeshPreviewAssetBuilderError.missingManifest
        }
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { line in
                try decoder.decode(MeshPreviewManifestEntry.self, from: Data(line.utf8))
            }
    }

    private func matrix4x4(rows: [[Double]]) -> simd_float4x4 {
        var padded = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for row in 0..<min(4, rows.count) {
            for col in 0..<min(4, rows[row].count) {
                padded[row][col] = rows[row][col]
            }
        }
        return simd_float4x4(
            columns: (
                SIMD4<Float>(Float(padded[0][0]), Float(padded[1][0]), Float(padded[2][0]), Float(padded[3][0])),
                SIMD4<Float>(Float(padded[0][1]), Float(padded[1][1]), Float(padded[2][1]), Float(padded[3][1])),
                SIMD4<Float>(Float(padded[0][2]), Float(padded[1][2]), Float(padded[2][2]), Float(padded[3][2])),
                SIMD4<Float>(Float(padded[0][3]), Float(padded[1][3]), Float(padded[2][3]), Float(padded[3][3]))
            )
        )
    }
}

private struct ParsedPreviewMesh {
    let vertices: [Float]
    let indices: [UInt32]
    let boundsMin: [Float]
    let boundsMax: [Float]
}

private struct PreviewBounds {
    var minX = Float.greatestFiniteMagnitude
    var minY = Float.greatestFiniteMagnitude
    var minZ = Float.greatestFiniteMagnitude
    var maxX = -Float.greatestFiniteMagnitude
    var maxY = -Float.greatestFiniteMagnitude
    var maxZ = -Float.greatestFiniteMagnitude

    mutating func include(_ vertex: SIMD3<Float>) {
        minX = min(minX, vertex.x)
        minY = min(minY, vertex.y)
        minZ = min(minZ, vertex.z)
        maxX = max(maxX, vertex.x)
        maxY = max(maxY, vertex.y)
        maxZ = max(maxZ, vertex.z)
    }

    var minArray: [Float] { [minX, minY, minZ] }
    var maxArray: [Float] { [maxX, maxY, maxZ] }
}

private final class MeshPreviewPLYLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }

            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: false)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }

            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}

private struct MeshPreviewManifestEntry: Decodable {
    let rgb: String
    let depth: String
    let image_width: Int
    let image_height: Int
    let depth_width: Int
    let depth_height: Int
    let intrinsics: [[Double]]
    let camera_to_world: [[Double]]
}

private struct DepthFrame {
    let width: Int
    let height: Int
    private let data: Data

    init?(sceneURL: URL, entry: MeshPreviewManifestEntry) {
        let url = sceneURL.appendingPathComponent(entry.depth)
        guard let data = try? Data(contentsOf: url),
              data.count >= entry.depth_width * entry.depth_height * MemoryLayout<Float32>.size else {
            return nil
        }
        width = entry.depth_width
        height = entry.depth_height
        self.data = data
    }

    func valueAt(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let byteOffset = (y * width + x) * MemoryLayout<Float32>.size
        return data.withUnsafeBytes { raw in
            let value = raw.load(fromByteOffset: byteOffset, as: Float32.self)
            return value.isFinite && value > 0 ? value : nil
        }
    }
}

private final class RGBPixelSampler {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(url: URL) {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else {
            return nil
        }
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.pixels = pixels
    }

    func colorAt(x: Int, y: Int) -> SIMD3<Float> {
        let offset = (y * width + x) * 4
        return SIMD3<Float>(
            Float(pixels[offset]) / 255.0,
            Float(pixels[offset + 1]) / 255.0,
            Float(pixels[offset + 2]) / 255.0
        )
    }
}

private extension Data {
    mutating func appendFloat32(_ values: [Float]) {
        values.withUnsafeBufferPointer { buffer in
            append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
    }

    mutating func appendUInt32(_ values: [UInt32]) {
        values.withUnsafeBufferPointer { buffer in
            append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
