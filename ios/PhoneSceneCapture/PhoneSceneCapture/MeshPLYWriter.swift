import ARKit
import Foundation
import simd

enum MeshPLYWriter {
    static func write(meshAnchors: [ARMeshAnchor], to url: URL) throws {
        let vertexCount = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let faceCount = meshAnchors.reduce(0) { $0 + $1.geometry.faces.count }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }

        var buffer = ""
        buffer.reserveCapacity(64 * 1024)

        func flush() {
            guard !buffer.isEmpty else { return }
            handle.write(Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        }

        func appendLine(_ line: String) {
            buffer += line
            buffer += "\n"
            if buffer.count >= 64 * 1024 {
                flush()
            }
        }

        appendLine("ply")
        appendLine("format ascii 1.0")
        appendLine("comment coordinates: ARKit world, meters, +Y up")
        appendLine("element vertex \(vertexCount)")
        appendLine("property float x")
        appendLine("property float y")
        appendLine("property float z")
        appendLine("element face \(faceCount)")
        appendLine("property list uchar int vertex_indices")
        appendLine("end_header")

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            for index in 0..<geometry.vertices.count {
                let local = vertex(at: index, source: geometry.vertices)
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                appendLine("\(world4.x) \(world4.y) \(world4.z)")
            }
        }

        var vertexOffset: UInt32 = 0
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let faceSource = geometry.faces
            for faceIndex in 0..<faceSource.count {
                let base = faceIndex * faceSource.indexCountPerPrimitive
                let i0 = index(at: base, source: faceSource) + vertexOffset
                let i1 = index(at: base + 1, source: faceSource) + vertexOffset
                let i2 = index(at: base + 2, source: faceSource) + vertexOffset
                appendLine("3 \(i0) \(i1) \(i2)")
            }
            vertexOffset += UInt32(geometry.vertices.count)
        }
        flush()
    }

    private static func vertex(at index: Int, source: ARGeometrySource) -> SIMD3<Float> {
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
}
