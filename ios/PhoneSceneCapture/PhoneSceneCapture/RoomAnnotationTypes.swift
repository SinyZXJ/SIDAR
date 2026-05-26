import Foundation
import simd

enum RoomLabel: String, Codable, CaseIterable, Identifiable {
    case living_room
    case bedroom
    case bathroom
    case kitchen
    case dining_room
    case office
    case hallway
    case staircase
    case balcony
    case home_theater
    case gym
    case pool_area
    case laundry_room
    case junk
    case garage

    var id: String { rawValue }

    var displayName: String {
        RoomLabelStore.displayName(for: rawValue)
    }
}

enum RoomLabelStore {
    static let storageKey = "sidar.roomLabels.v1"
    static let defaultLabels = RoomLabel.allCases.map(\.rawValue)

    static func load() -> [String] {
        guard let stored = UserDefaults.standard.array(forKey: storageKey) as? [String] else {
            return defaultLabels
        }
        let labels = normalizedList(stored)
        return labels.isEmpty ? defaultLabels : labels
    }

    static func save(_ labels: [String]) {
        let normalized = normalizedList(labels)
        UserDefaults.standard.set(normalized.isEmpty ? defaultLabels : normalized, forKey: storageKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static func normalizedList(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in labels {
            let normalized = normalize(label)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    static func normalize(_ label: String) -> String {
        let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }

        var scalars: [UnicodeScalar] = []
        var lastWasUnderscore = false
        for scalar in lowered.unicodeScalars {
            let isAlphanumeric = CharacterSet.alphanumerics.contains(scalar)
            let isSeparator = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == UnicodeScalar("-")
                || scalar == UnicodeScalar("_")

            if isAlphanumeric {
                scalars.append(scalar)
                lastWasUnderscore = false
            } else if isSeparator, !lastWasUnderscore {
                scalars.append("_")
                lastWasUnderscore = true
            }
        }

        var normalized = String(String.UnicodeScalarView(scalars))
        while normalized.hasPrefix("_") {
            normalized.removeFirst()
        }
        while normalized.hasSuffix("_") {
            normalized.removeLast()
        }
        return normalized
    }

    static func displayName(for label: String) -> String {
        label
            .split(separator: "_")
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}

extension String {
    var roomLabelDisplayName: String {
        RoomLabelStore.displayName(for: self)
    }
}

struct AnnotationPayload: Codable {
    static let currentMapBuildVersion = 2

    let scene_id: String
    let map_build_version: Int
    let image_width: Int
    let image_height: Int
    let world_min_xy: [Double]
    let world_max_xy: [Double]
    let resolution_m_per_px: Double
    let trajectory_xy: [[Double]]
    let trajectory_xyz: [[Double]]
    let labels: [String]
    let floors: [AnnotationFloor]

    init(
        scene_id: String,
        map_build_version: Int = AnnotationPayload.currentMapBuildVersion,
        image_width: Int,
        image_height: Int,
        world_min_xy: [Double],
        world_max_xy: [Double],
        resolution_m_per_px: Double,
        trajectory_xy: [[Double]],
        trajectory_xyz: [[Double]] = [],
        labels: [String] = RoomLabelStore.load(),
        floors: [AnnotationFloor] = [.defaultFloor]
    ) {
        self.scene_id = scene_id
        self.map_build_version = map_build_version
        self.image_width = image_width
        self.image_height = image_height
        self.world_min_xy = world_min_xy
        self.world_max_xy = world_max_xy
        self.resolution_m_per_px = resolution_m_per_px
        self.trajectory_xy = trajectory_xy
        self.trajectory_xyz = trajectory_xyz.isEmpty
            ? trajectory_xy.map { pair in
                guard pair.count >= 2 else { return [] }
                return [pair[0], pair[1], 0.0]
            }
            : trajectory_xyz
        self.labels = labels
        self.floors = floors.isEmpty ? [.defaultFloor] : floors
    }

    enum CodingKeys: String, CodingKey {
        case scene_id
        case map_build_version
        case image_width
        case image_height
        case world_min_xy
        case world_max_xy
        case resolution_m_per_px
        case trajectory_xy
        case trajectory_xyz
        case labels
        case floors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scene_id = try container.decode(String.self, forKey: .scene_id)
        map_build_version = try container.decodeIfPresent(Int.self, forKey: .map_build_version) ?? 1
        image_width = try container.decode(Int.self, forKey: .image_width)
        image_height = try container.decode(Int.self, forKey: .image_height)
        world_min_xy = try container.decode([Double].self, forKey: .world_min_xy)
        world_max_xy = try container.decode([Double].self, forKey: .world_max_xy)
        resolution_m_per_px = try container.decode(Double.self, forKey: .resolution_m_per_px)
        trajectory_xy = try container.decode([[Double]].self, forKey: .trajectory_xy)
        trajectory_xyz = try container.decodeIfPresent([[Double]].self, forKey: .trajectory_xyz)
            ?? trajectory_xy.map { pair in
                guard pair.count >= 2 else { return [] }
                return [pair[0], pair[1], 0.0]
            }
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? RoomLabelStore.load()
        let decodedFloors = try container.decodeIfPresent([AnnotationFloor].self, forKey: .floors) ?? [.defaultFloor]
        floors = decodedFloors.isEmpty ? [.defaultFloor] : decodedFloors
    }
}

struct AnnotationFloor: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var min_z: Double
    var max_z: Double

    static let defaultFloor = AnnotationFloor(
        id: "floor_1",
        name: "Floor 1",
        min_z: 0.0,
        max_z: 3.0
    )
}

struct GTRoom: Codable {
    let room_id: Int
    let label: String
    let polygon_xy: [[Double]]
    let min_z: Double
    let max_z: Double
}

struct GTRoomFile: Codable {
    let dataset: String
    let scene_id: String
    let frame: String
    let rooms: [GTRoom]

    init(dataset: String = "real", scene_id: String, frame: String = "world", rooms: [GTRoom]) {
        self.dataset = dataset
        self.scene_id = scene_id
        self.frame = frame
        self.rooms = rooms
    }
}

enum PhoneSceneCoordinateConversion {
    static func arkitWorldToROS(_ point: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(
            -Double(point.z),
            -Double(point.x),
            Double(point.y)
        )
    }

    static func arkitCameraTransformToROSXY(_ transform: simd_float4x4) -> [Double] {
        let ros = arkitCameraTransformToROSXYZ(transform)
        return [ros[0], ros[1]]
    }

    static func arkitCameraTransformToROSXYZ(_ transform: simd_float4x4) -> [Double] {
        let arkitPosition = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let ros = arkitWorldToROS(arkitPosition)
        return [ros.x, ros.y, ros.z]
    }

    static var arkitWorldToROSWorldMatrix: simd_float4x4 {
        simd_float4x4(
            columns: (
                SIMD4<Float>(0.0, -1.0, 0.0, 0.0),
                SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
                SIMD4<Float>(-1.0, 0.0, 0.0, 0.0),
                SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
            )
        )
    }

    static var rosOpticalToARKitCameraMatrix: simd_float4x4 {
        simd_float4x4(
            columns: (
                SIMD4<Float>(1.0, 0.0, 0.0, 0.0),
                SIMD4<Float>(0.0, -1.0, 0.0, 0.0),
                SIMD4<Float>(0.0, 0.0, -1.0, 0.0),
                SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
            )
        )
    }

    static func arkitCamToWorldToROSOptical(_ cameraToWorldARKit: simd_float4x4) -> simd_float4x4 {
        arkitWorldToROSWorldMatrix * cameraToWorldARKit * rosOpticalToARKitCameraMatrix
    }
}
