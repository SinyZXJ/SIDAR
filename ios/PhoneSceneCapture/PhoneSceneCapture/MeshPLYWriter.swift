import ARKit
import Foundation
import simd

struct MeshExportSummary {
    let vertices: Int
    let faces: Int
    let anchors: Int
    let hasNormals: Bool
    let hasClassifications: Bool
    let classificationCounts: [String: Int]

    var jsonObject: [String: Any] {
        [
            "vertices": vertices,
            "faces": faces,
            "anchors": anchors,
            "has_normals": hasNormals,
            "has_classifications": hasClassifications,
            "classification_counts": classificationCounts,
        ]
    }
}

enum MeshPLYWriter {
    static func write(meshAnchors: [ARMeshAnchor], to url: URL) throws -> MeshExportSummary {
        let vertexCount = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let faceCount = meshAnchors.reduce(0) { $0 + $1.geometry.faces.count }
        let hasNormals = meshAnchors.allSatisfy {
            $0.geometry.normals.count == $0.geometry.vertices.count
        }
        let hasClassifications = meshAnchors.contains { $0.geometry.classification != nil }
        let temporaryURL = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporaryURL)
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var shouldRemoveTemporary = true
        defer {
            try? handle.close()
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        var buffer = ""
        buffer.reserveCapacity(64 * 1024)

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        }

        func appendLine(_ line: String) throws {
            buffer += line
            buffer += "\n"
            if buffer.count >= 64 * 1024 {
                try flush()
            }
        }

        try appendLine("ply")
        try appendLine("format ascii 1.0")
        try appendLine("comment coordinates: ARKit world, meters, +Y up")
        try appendLine("comment face classification: ARMeshClassification raw value")
        try appendLine("element vertex \(vertexCount)")
        try appendLine("property float x")
        try appendLine("property float y")
        try appendLine("property float z")
        try appendLine("property float nx")
        try appendLine("property float ny")
        try appendLine("property float nz")
        try appendLine("element face \(faceCount)")
        try appendLine("property list uchar int vertex_indices")
        try appendLine("property uchar classification")
        try appendLine("end_header")

        var anchorRecords: [MeshAnchorRecord] = []
        var vertexOffset: UInt32 = 0
        var faceOffset = 0
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            anchorRecords.append(
                MeshAnchorRecord(
                    anchor_id: anchor.identifier.uuidString.lowercased(),
                    transform: MatrixJSON.rows(anchor.transform),
                    vertex_offset: Int(vertexOffset),
                    vertex_count: geometry.vertices.count,
                    face_offset: faceOffset,
                    face_count: geometry.faces.count,
                    has_normals: geometry.normals.count == geometry.vertices.count,
                    has_classification: geometry.classification != nil
                )
            )
            for index in 0..<geometry.vertices.count {
                let localVertex = vector3(at: index, source: geometry.vertices)
                let worldVertex4 = anchor.transform * SIMD4<Float>(
                    localVertex.x,
                    localVertex.y,
                    localVertex.z,
                    1.0
                )
                let localNormal = geometry.normals.count == geometry.vertices.count
                    ? vector3(at: index, source: geometry.normals)
                    : SIMD3<Float>(0, 0, 0)
                let worldNormal4 = anchor.transform * SIMD4<Float>(
                    localNormal.x,
                    localNormal.y,
                    localNormal.z,
                    0.0
                )
                let unnormalized = SIMD3<Float>(worldNormal4.x, worldNormal4.y, worldNormal4.z)
                let worldNormal = simd_length_squared(unnormalized) > 0
                    ? simd_normalize(unnormalized)
                    : SIMD3<Float>(0, 0, 0)
                try appendLine(
                    "\(worldVertex4.x) \(worldVertex4.y) \(worldVertex4.z) "
                        + "\(worldNormal.x) \(worldNormal.y) \(worldNormal.z)"
                )
            }
            vertexOffset += UInt32(geometry.vertices.count)
            faceOffset += geometry.faces.count
        }

        var classificationCounts: [String: Int] = [:]
        vertexOffset = 0
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let faces = geometry.faces
            for faceIndex in 0..<faces.count {
                let base = faceIndex * faces.indexCountPerPrimitive
                let i0 = index(at: base, source: faces) + vertexOffset
                let i1 = index(at: base + 1, source: faces) + vertexOffset
                let i2 = index(at: base + 2, source: faces) + vertexOffset
                let classification = classificationValue(
                    at: faceIndex,
                    source: geometry.classification
                )
                classificationCounts[classificationName(classification), default: 0] += 1
                try appendLine("3 \(i0) \(i1) \(i2) \(classification)")
            }
            vertexOffset += UInt32(geometry.vertices.count)
        }
        try flush()
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        shouldRemoveTemporary = false

        let sidecar = MeshAnchorSidecar(
            format: "phonescene_arkit_mesh_anchors",
            format_version: 1,
            coordinate_frame: "arkit_world_meters_y_up",
            ply: url.lastPathComponent,
            vertex_count: vertexCount,
            face_count: faceCount,
            anchors: anchorRecords
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(
            to: url.deletingLastPathComponent().appendingPathComponent("arkit_mesh_anchors.json"),
            options: [.atomic]
        )
        return MeshExportSummary(
            vertices: vertexCount,
            faces: faceCount,
            anchors: meshAnchors.count,
            hasNormals: hasNormals,
            hasClassifications: hasClassifications,
            classificationCounts: classificationCounts
        )
    }

    private static func vector3(at index: Int, source: ARGeometrySource) -> SIMD3<Float> {
        let pointer = source.buffer.contents().advanced(by: source.offset + index * source.stride)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    private static func index(at index: Int, source: ARGeometryElement) -> UInt32 {
        let pointer = source.buffer.contents().advanced(by: index * source.bytesPerIndex)
        if source.bytesPerIndex == MemoryLayout<UInt32>.size {
            return pointer.assumingMemoryBound(to: UInt32.self).pointee
        }
        return UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
    }

    private static func classificationValue(at index: Int, source: ARGeometrySource?) -> UInt8 {
        guard let source, index < source.count else { return 0 }
        let pointer = source.buffer.contents().advanced(by: source.offset + index * source.stride)
        return pointer.assumingMemoryBound(to: UInt8.self).pointee
    }

    private static func classificationName(_ rawValue: UInt8) -> String {
        guard let classification = ARMeshClassification(rawValue: Int(rawValue)) else {
            return "unknown_\(rawValue)"
        }
        switch classification {
        case .none: return "none"
        case .wall: return "wall"
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .table: return "table"
        case .seat: return "seat"
        case .window: return "window"
        case .door: return "door"
        @unknown default: return "unknown_\(rawValue)"
        }
    }
}

private struct MeshAnchorRecord: Encodable {
    let anchor_id: String
    let transform: [[Float]]
    let vertex_offset: Int
    let vertex_count: Int
    let face_offset: Int
    let face_count: Int
    let has_normals: Bool
    let has_classification: Bool
}

private struct MeshAnchorSidecar: Encodable {
    let format: String
    let format_version: Int
    let coordinate_frame: String
    let ply: String
    let vertex_count: Int
    let face_count: Int
    let anchors: [MeshAnchorRecord]
}
