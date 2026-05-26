import Foundation

enum MeshPreviewPrimitive: String, Codable {
    case triangles
    case points
}

enum MeshPreviewColorMode: String, Codable {
    case height
    case rgb
}

struct MeshPreviewMetadata: Codable {
    let format: String
    let version: Int
    let scene_id: String
    let primitive: MeshPreviewPrimitive
    let color_mode: MeshPreviewColorMode
    let vertex_count: Int
    let index_count: Int
    let coordinate_frame: String
    let source_mesh: String
    let bounds_min_xyz: [Float]
    let bounds_max_xyz: [Float]

    init(
        sceneID: String,
        primitive: MeshPreviewPrimitive,
        colorMode: MeshPreviewColorMode,
        vertexCount: Int,
        indexCount: Int,
        boundsMinXYZ: [Float],
        boundsMaxXYZ: [Float],
        sourceMesh: String = "mesh/arkit_mesh_world.ply"
    ) {
        format = "sidar_mesh_preview"
        version = 1
        scene_id = sceneID
        self.primitive = primitive
        color_mode = colorMode
        vertex_count = vertexCount
        index_count = indexCount
        coordinate_frame = "arkit_world_y_up"
        source_mesh = sourceMesh
        bounds_min_xyz = boundsMinXYZ
        bounds_max_xyz = boundsMaxXYZ
    }
}

struct MeshPreviewGeometry {
    let metadata: MeshPreviewMetadata
    let vertices: [Float]
    let colors: [Float]
    let indices: [UInt32]
}

struct MeshPreviewProgress: Equatable {
    let fraction: Double
    let message: String

    init(_ fraction: Double, _ message: String) {
        self.fraction = min(1.0, max(0.0, fraction))
        self.message = message
    }
}

typealias SceneBuildProgress = MeshPreviewProgress

enum MeshPreviewTaskState: Equatable {
    case unavailable(String)
    case building(MeshPreviewProgress)
    case ready(String)
    case failed(String)
    case colorizing(MeshPreviewProgress)
    case colorized(String)

    var message: String {
        switch self {
        case .unavailable(let message),
             .ready(let message),
             .failed(let message),
             .colorized(let message):
            return message
        case .building(let progress),
             .colorizing(let progress):
            return progress.message
        }
    }

    var progress: Double? {
        switch self {
        case .building(let progress), .colorizing(let progress):
            return progress.fraction
        case .unavailable, .ready, .failed, .colorized:
            return nil
        }
    }

    var isWorking: Bool {
        switch self {
        case .building, .colorizing:
            return true
        case .unavailable, .ready, .failed, .colorized:
            return false
        }
    }

    var hasPreview: Bool {
        switch self {
        case .ready, .colorized:
            return true
        case .unavailable, .building, .failed, .colorizing:
            return false
        }
    }
}
