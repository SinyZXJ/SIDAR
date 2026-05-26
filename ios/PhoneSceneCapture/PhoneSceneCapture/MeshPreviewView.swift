import SceneKit
import SwiftUI

struct MeshPreviewSceneView: UIViewRepresentable {
    let geometry: MeshPreviewGeometry

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor.black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let signature = "\(geometry.metadata.color_mode.rawValue)-\(geometry.metadata.vertex_count)-\(geometry.metadata.index_count)"
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        view.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let meshNode = SCNNode(geometry: makeGeometry())
        scene.rootNode.addChildNode(meshNode)

        let span = max(
            geometry.metadata.bounds_max_xyz[safe: 0, default: 1] - geometry.metadata.bounds_min_xyz[safe: 0, default: -1],
            geometry.metadata.bounds_max_xyz[safe: 1, default: 1] - geometry.metadata.bounds_min_xyz[safe: 1, default: -1],
            geometry.metadata.bounds_max_xyz[safe: 2, default: 1] - geometry.metadata.bounds_min_xyz[safe: 2, default: -1],
            1.0
        )

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = Double(max(100.0, span * 8.0))
        cameraNode.position = SCNVector3(0, span * 0.45, span * 1.8)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 700
        key.position = SCNVector3(span * 0.6, span, span * 0.9)
        scene.rootNode.addChildNode(key)
        return scene
    }

    private func makeGeometry() -> SCNGeometry {
        let vertexCount = geometry.metadata.vertex_count
        let centeredVertices = centeredVertexFloats()
        let vertexData = Data(float32: centeredVertices)
        let colorData = Data(float32: geometry.colors)

        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )

        let primitiveType: SCNGeometryPrimitiveType
        let primitiveCount: Int
        let indexData: Data
        if geometry.metadata.primitive == .triangles, !geometry.indices.isEmpty {
            primitiveType = .triangles
            primitiveCount = geometry.indices.count / 3
            indexData = Data(uint32: geometry.indices)
        } else {
            primitiveType = .point
            let pointIndices = (0..<vertexCount).map { UInt32($0) }
            primitiveCount = pointIndices.count
            indexData = Data(uint32: pointIndices)
        }

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: primitiveType,
            primitiveCount: primitiveCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private func centeredVertexFloats() -> [Float] {
        let minX = geometry.metadata.bounds_min_xyz[safe: 0, default: 0]
        let minY = geometry.metadata.bounds_min_xyz[safe: 1, default: 0]
        let minZ = geometry.metadata.bounds_min_xyz[safe: 2, default: 0]
        let maxX = geometry.metadata.bounds_max_xyz[safe: 0, default: 0]
        let maxY = geometry.metadata.bounds_max_xyz[safe: 1, default: 0]
        let maxZ = geometry.metadata.bounds_max_xyz[safe: 2, default: 0]
        let center = SIMD3<Float>(
            (minX + maxX) * 0.5,
            (minY + maxY) * 0.5,
            (minZ + maxZ) * 0.5
        )
        var result: [Float] = []
        result.reserveCapacity(geometry.vertices.count)
        for index in stride(from: 0, to: geometry.vertices.count, by: 3) {
            result.append(geometry.vertices[index] - center.x)
            result.append(geometry.vertices[index + 1] - center.y)
            result.append(geometry.vertices[index + 2] - center.z)
        }
        return result
    }

    final class Coordinator {
        var signature: String?
    }
}

private extension Data {
    init(float32 values: [Float]) {
        self.init()
        reserveCapacity(values.count * MemoryLayout<Float>.size)
        values.withUnsafeBufferPointer { buffer in
            append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
    }

    init(uint32 values: [UInt32]) {
        self.init()
        reserveCapacity(values.count * MemoryLayout<UInt32>.size)
        values.withUnsafeBufferPointer { buffer in
            append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
    }
}

private extension Array where Element == Float {
    subscript(safe index: Int, default fallback: Float) -> Float {
        indices.contains(index) ? self[index] : fallback
    }
}
