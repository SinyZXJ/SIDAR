import ARKit
import CoreGraphics
import Foundation
import UIKit
import simd

enum TopDownMapBuilderError: Error {
    case emptyMapBounds
    case invalidImage
}

struct TopDownMapBuilder {
    var resolutionMetersPerPixel: Double = 0.02
    var paddingMeters: Double = 0.5
    var minROSZ: Double = -1.5
    var maxROSZ: Double = 2.5
    var depthFrameStride: Int = 10
    var depthPixelStride: Int = 16
    var maxDepthMeters: Float = 8.0
    var maxMapDimensionPixels: Int = 3072
    var maxDensityCellCount: Int = 8_000_000
    var maxDepthFrames: Int = 60
    var maxDepthPoints: Int = 120_000
    var maxMeshPoints: Int = 250_000
    var maxMeshTriangles: Int = 120_000
    var maxMeshVerticesForTriangleOverlay: Int = 700_000

    func ensureAnnotationAssets(
        sceneURL: URL,
        progress: ((SceneBuildProgress) -> Void)? = nil
    ) throws -> AnnotationPayload {
        progress?(SceneBuildProgress(0.02, "Checking annotation assets"))
        let annotationURL = try FrameWriter.annotationDirectory(for: sceneURL)
        let payloadURL = annotationURL.appendingPathComponent("annotation_payload.json")
        let imageURL = annotationURL.appendingPathComponent("topdown_map.png")
        let meshImageURL = annotationURL.appendingPathComponent("topdown_mesh.png")
        if FileManager.default.fileExists(atPath: payloadURL.path),
           FileManager.default.fileExists(atPath: imageURL.path) {
            let payloadData = try Data(contentsOf: payloadURL)
            let payload = try JSONDecoder().decode(AnnotationPayload.self, from: payloadData)
            guard payloadDataContainsKey(payloadData, key: "trajectory_xyz"),
                  payload.map_build_version >= AnnotationPayload.currentMapBuildVersion else {
                progress?(SceneBuildProgress(0.05, "Rebuilding annotation map"))
                return try buildFromExistingScene(sceneURL: sceneURL, progress: progress)
            }
            let sceneID = sceneURL.deletingPathExtension().lastPathComponent
            if !FileManager.default.fileExists(atPath: meshImageURL.path) {
                progress?(SceneBuildProgress(0.86, "Building optional mesh projection"))
                try? writeMeshOverlayFromExistingScene(sceneURL: sceneURL, payload: payload)
            }
            guard payload.scene_id != sceneID else { return payload }

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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(updatedPayload).write(to: payloadURL, options: [.atomic])
            progress?(SceneBuildProgress(1.0, "Annotation map ready"))
            return updatedPayload
        }
        return try buildFromExistingScene(sceneURL: sceneURL, progress: progress)
    }

    func buildFromExistingScene(
        sceneURL: URL,
        progress: ((SceneBuildProgress) -> Void)? = nil
    ) throws -> AnnotationPayload {
        progress?(SceneBuildProgress(0.04, "Loading recorded trajectory"))
        let entries = try loadManifest(sceneURL: sceneURL)
        let trajectoryXYZ = entries.map { entry in
            PhoneSceneCoordinateConversion.arkitCameraTransformToROSXYZ(
                matrix4x4(rows: entry.camera_to_world)
            )
        }
        let trajectoryXY = trajectoryXYZ.map { point in
            [point[0], point[1]]
        }
        return try build(
            sceneURL: sceneURL,
            meshAnchors: [],
            trajectoryXY: trajectoryXY,
            trajectoryXYZ: trajectoryXYZ,
            manifestEntries: entries,
            progress: progress
        )
    }

    func build(
        sceneURL: URL,
        meshAnchors: [ARMeshAnchor],
        trajectoryXY: [[Double]],
        trajectoryXYZ: [[Double]] = [],
        progress: ((SceneBuildProgress) -> Void)? = nil
    ) throws -> AnnotationPayload {
        progress?(SceneBuildProgress(0.03, "Loading capture manifest"))
        let entries = (try? loadManifest(sceneURL: sceneURL)) ?? []
        return try build(
            sceneURL: sceneURL,
            meshAnchors: meshAnchors,
            trajectoryXY: trajectoryXY,
            trajectoryXYZ: trajectoryXYZ,
            manifestEntries: entries,
            progress: progress
        )
    }

    private func build(
        sceneURL: URL,
        meshAnchors: [ARMeshAnchor],
        trajectoryXY: [[Double]],
        trajectoryXYZ: [[Double]],
        manifestEntries: [TopDownManifestEntry],
        progress: ((SceneBuildProgress) -> Void)?
    ) throws -> AnnotationPayload {
        progress?(SceneBuildProgress(0.08, "Collecting mesh points"))
        var points: [TopDownPoint] = []
        points.reserveCapacity(64_000)
        var mesh = meshData(from: meshAnchors, progress: progress)
        if mesh.points.isEmpty, let existingMesh = try? meshDataFromPLY(sceneURL: sceneURL, progress: progress) {
            mesh = existingMesh
        }
        points.append(contentsOf: mesh.points)
        progress?(SceneBuildProgress(0.36, "Sampling depth points"))
        points.append(contentsOf: sampledDepthPoints(from: sceneURL, entries: manifestEntries, progress: progress))

        let normalizedTrajectoryXYZ = normalizedTrajectoryXYZ(
            trajectoryXY: trajectoryXY,
            trajectoryXYZ: trajectoryXYZ
        )
        let trajectoryPoints = normalizedTrajectoryXYZ.compactMap { point -> TopDownPoint? in
            guard point.count == 3 else { return nil }
            return TopDownPoint(x: point[0], y: point[1], z: point[2], weight: 6)
        }
        points.append(contentsOf: trajectoryPoints)
        let floors = inferredFloors(trajectoryXYZ: normalizedTrajectoryXYZ, points: points)
        let mapMinZ = floors.map(\.min_z).min().map { $0 - 0.5 } ?? minROSZ
        let mapMaxZ = floors.map(\.max_z).max().map { $0 + 0.5 } ?? maxROSZ

        let filteredPoints = points.filter { point in
            point.z >= mapMinZ && point.z <= mapMaxZ
        }
        let boundsPoints = filteredPoints.isEmpty ? trajectoryPoints : filteredPoints
        let bounds = mapBounds(for: boundsPoints)
        guard let bounds else {
            throw TopDownMapBuilderError.emptyMapBounds
        }

        progress?(SceneBuildProgress(0.66, "Rasterizing top-down density"))
        let mapResolution = effectiveMapResolution(for: bounds)
        let width = max(16, Int(ceil((bounds.maxX - bounds.minX) / mapResolution)) + 1)
        let height = max(16, Int(ceil((bounds.maxY - bounds.minY) / mapResolution)) + 1)
        let densities = densityGrid(
            points: filteredPoints,
            bounds: bounds,
            width: width,
            height: height,
            resolution: mapResolution
        )
        progress?(SceneBuildProgress(0.78, "Encoding top-down map"))
        let imageData = try pngData(from: densities, width: width, height: height)

        progress?(SceneBuildProgress(0.84, "Writing annotation map"))
        try FrameWriter.writeAnnotationData(
            imageData,
            named: "topdown_map.png",
            in: sceneURL
        )

        let payload = AnnotationPayload(
            scene_id: sceneURL.deletingPathExtension().lastPathComponent,
            image_width: width,
            image_height: height,
            world_min_xy: [bounds.minX, bounds.minY],
            world_max_xy: [bounds.maxX, bounds.maxY],
            resolution_m_per_px: mapResolution,
            trajectory_xy: trajectoryXY,
            trajectory_xyz: normalizedTrajectoryXYZ,
            floors: floors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payloadData = try encoder.encode(payload)
        progress?(SceneBuildProgress(0.90, "Writing annotation metadata"))
        try FrameWriter.writeAnnotationData(
            payloadData,
            named: "annotation_payload.json",
            in: sceneURL
        )

        if !mesh.triangles.isEmpty {
            do {
                progress?(SceneBuildProgress(0.94, "Building optional mesh projection"))
                let meshData = try meshOverlayPNGData(
                    triangles: mesh.triangles,
                    bounds: bounds,
                    width: width,
                    height: height,
                    minZ: mapMinZ,
                    maxZ: mapMaxZ
                )
                try FrameWriter.writeAnnotationData(
                    meshData,
                    named: "topdown_mesh.png",
                    in: sceneURL
                )
            } catch {
                NSLog("SIDAR top-down mesh overlay skipped: \(error)")
            }
        }
        progress?(SceneBuildProgress(1.0, "Annotation map ready"))
        return payload
    }

    private func payloadDataContainsKey(_ data: Data, key: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object[key] != nil
    }

    private func normalizedTrajectoryXYZ(
        trajectoryXY: [[Double]],
        trajectoryXYZ: [[Double]]
    ) -> [[Double]] {
        guard !trajectoryXYZ.isEmpty else {
            return trajectoryXY.map { pair in
                guard pair.count >= 2 else { return [] }
                return [pair[0], pair[1], 0.0]
            }
        }

        return trajectoryXYZ.enumerated().map { index, point in
            if point.count >= 3 {
                return [point[0], point[1], point[2]]
            }
            if trajectoryXY.indices.contains(index), trajectoryXY[index].count >= 2 {
                return [trajectoryXY[index][0], trajectoryXY[index][1], 0.0]
            }
            return []
        }
    }

    private func inferredFloors(
        trajectoryXYZ: [[Double]],
        points: [TopDownPoint]
    ) -> [AnnotationFloor] {
        let trajectoryZ = trajectoryXYZ.compactMap { point -> Double? in
            guard point.count >= 3, point[2].isFinite else { return nil }
            return point[2]
        }
        if !trajectoryZ.isEmpty {
            return floorBands(from: trajectoryZ, preferredName: "Level")
        }

        let pointZ = points.compactMap { point in
            point.z.isFinite ? point.z : nil
        }
        guard !pointZ.isEmpty else {
            return [.defaultFloor]
        }
        return floorBands(from: pointZ, preferredName: "Level")
    }

    private func floorBands(from zSamples: [Double], preferredName: String) -> [AnnotationFloor] {
        guard let minZ = zSamples.min(), let maxZ = zSamples.max() else {
            return [.defaultFloor]
        }
        let span = maxZ - minZ
        let singleFloorHalfHeight = max(1.8, span * 0.5 + 0.75)
        if span <= 2.6 {
            let center = (minZ + maxZ) * 0.5
            return [
                AnnotationFloor(
                    id: "floor_1",
                    name: "\(preferredName) 1",
                    min_z: center - singleFloorHalfHeight,
                    max_z: center + singleFloorHalfHeight
                )
            ]
        }

        let slabHeight = 3.4
        let slabStep = 2.6
        var floors: [AnnotationFloor] = []
        var lower = minZ - 0.7
        let targetMax = maxZ + 0.7
        while lower < targetMax && floors.count < 8 {
            let upper = lower + slabHeight
            let number = floors.count + 1
            floors.append(AnnotationFloor(
                id: "floor_\(number)",
                name: "\(preferredName) \(number)",
                min_z: lower,
                max_z: upper
            ))
            lower += slabStep
        }
        return floors.isEmpty ? [.defaultFloor] : floors
    }

    private func meshData(
        from meshAnchors: [ARMeshAnchor],
        progress: ((SceneBuildProgress) -> Void)? = nil
    ) -> TopDownMesh {
        var points: [TopDownPoint] = []
        var triangles: [TopDownTriangle] = []
        let totalVertices = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let totalFaces = meshAnchors.reduce(0) { $0 + $1.geometry.faces.count }
        let vertexStride = samplingStride(totalCount: totalVertices, budget: maxMeshPoints)
        let faceStride = samplingStride(totalCount: totalFaces, budget: maxMeshTriangles)
        var globalVertexIndex = 0
        var globalFaceIndex = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            var anchorPoints: [TopDownPoint] = []
            anchorPoints.reserveCapacity(geometry.vertices.count)
            for index in 0..<geometry.vertices.count {
                if globalVertexIndex % 20_000 == 0 {
                    let fraction = 0.10 + 0.18 * Double(globalVertexIndex) / Double(max(totalVertices, 1))
                    progress?(SceneBuildProgress(fraction, "Reading mesh vertices"))
                }
                let local = vertex(at: index, source: geometry.vertices)
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                let ros = PhoneSceneCoordinateConversion.arkitWorldToROS(
                    SIMD3<Float>(world4.x, world4.y, world4.z)
                )
                let point = TopDownPoint(x: ros.x, y: ros.y, z: ros.z, weight: 1)
                anchorPoints.append(point)
                if globalVertexIndex % vertexStride == 0 {
                    points.append(point)
                }
                globalVertexIndex += 1
            }

            let faceSource = geometry.faces
            for faceIndex in 0..<faceSource.count {
                defer { globalFaceIndex += 1 }
                if globalFaceIndex % 20_000 == 0 {
                    let fraction = 0.28 + 0.06 * Double(globalFaceIndex) / Double(max(totalFaces, 1))
                    progress?(SceneBuildProgress(fraction, "Sampling mesh faces"))
                }
                guard globalFaceIndex % faceStride == 0 else {
                    continue
                }
                let base = faceIndex * faceSource.indexCountPerPrimitive
                let i0 = Int(index(at: base, source: faceSource))
                let i1 = Int(index(at: base + 1, source: faceSource))
                let i2 = Int(index(at: base + 2, source: faceSource))
                guard anchorPoints.indices.contains(i0),
                      anchorPoints.indices.contains(i1),
                      anchorPoints.indices.contains(i2) else {
                    continue
                }
                triangles.append(TopDownTriangle(a: anchorPoints[i0], b: anchorPoints[i1], c: anchorPoints[i2]))
            }
        }
        return TopDownMesh(points: points, triangles: triangles)
    }

    private func sampledDepthPoints(
        from sceneURL: URL,
        entries: [TopDownManifestEntry],
        progress: ((SceneBuildProgress) -> Void)?
    ) -> [TopDownPoint] {
        guard !entries.isEmpty, maxDepthFrames > 0, maxDepthPoints > 0 else {
            return []
        }

        var result: [TopDownPoint] = []
        result.reserveCapacity(min(maxDepthPoints, 64_000))

        let dynamicFrameStride = max(
            max(depthFrameStride, 1),
            Int(ceil(Double(entries.count) / Double(maxDepthFrames)))
        )
        let sampledFrameCount = max(1, Int(ceil(Double(entries.count) / Double(dynamicFrameStride))))
        let pointBudgetPerFrame = max(1, maxDepthPoints / sampledFrameCount)

        for (entryIndex, entry) in entries.enumerated() where entryIndex % dynamicFrameStride == 0 {
            if result.count >= maxDepthPoints {
                break
            }
            let sampledIndex = entryIndex / dynamicFrameStride
            progress?(SceneBuildProgress(
                0.38 + 0.20 * Double(sampledIndex) / Double(max(sampledFrameCount, 1)),
                "Sampling depth frame \(min(sampledIndex + 1, sampledFrameCount)) / \(sampledFrameCount)"
            ))

            let depthURL = sceneURL.appendingPathComponent(entry.depth)
            guard let data = try? Data(contentsOf: depthURL) else {
                continue
            }
            let expectedBytes = entry.depth_width * entry.depth_height * MemoryLayout<Float32>.size
            guard data.count >= expectedBytes else {
                continue
            }

            let intrinsics = scaledIntrinsics(entry)
            let cameraToWorldARKit = matrix4x4(rows: entry.camera_to_world)
            let cameraToWorldROS = PhoneSceneCoordinateConversion.arkitCamToWorldToROSOptical(cameraToWorldARKit)
            let baseStep = max(depthPixelStride, 1)
            let approximatePointCount = max(1, (entry.depth_width / baseStep) * (entry.depth_height / baseStep))
            let budgetScale = sqrt(Double(approximatePointCount) / Double(max(pointBudgetPerFrame, 1)))
            let step = max(baseStep, baseStep * Int(ceil(budgetScale)))

            data.withUnsafeBytes { rawBuffer in
                for row in stride(from: 0, to: entry.depth_height, by: step) {
                    for col in stride(from: 0, to: entry.depth_width, by: step) {
                        guard result.count < maxDepthPoints else {
                            return
                        }
                        let linearIndex = row * entry.depth_width + col
                        let byteOffset = linearIndex * MemoryLayout<Float32>.size
                        let depth = rawBuffer.load(fromByteOffset: byteOffset, as: Float32.self)
                        guard depth.isFinite, depth > 0.05, depth < maxDepthMeters else {
                            continue
                        }

                        let xCamera = (Float(col) - intrinsics.cx) * depth / intrinsics.fx
                        let yCamera = (Float(row) - intrinsics.cy) * depth / intrinsics.fy
                        let world = cameraToWorldROS * SIMD4<Float>(xCamera, yCamera, depth, 1.0)
                        let z = Double(world.z)
                        guard z.isFinite else {
                            continue
                        }
                        result.append(TopDownPoint(
                            x: Double(world.x),
                            y: Double(world.y),
                            z: z,
                            weight: 1
                        ))
                    }
                }
            }
        }
        return result
    }

    private func mapBounds(for points: [TopDownPoint]) -> TopDownBounds? {
        guard var minX = points.map(\.x).min(),
              var maxX = points.map(\.x).max(),
              var minY = points.map(\.y).min(),
              var maxY = points.map(\.y).max() else {
            return nil
        }
        minX -= paddingMeters
        maxX += paddingMeters
        minY -= paddingMeters
        maxY += paddingMeters
        if abs(maxX - minX) < resolutionMetersPerPixel {
            minX -= 1.0
            maxX += 1.0
        }
        if abs(maxY - minY) < resolutionMetersPerPixel {
            minY -= 1.0
            maxY += 1.0
        }
        return TopDownBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func effectiveMapResolution(for bounds: TopDownBounds) -> Double {
        let spanX = max(bounds.maxX - bounds.minX, resolutionMetersPerPixel)
        let spanY = max(bounds.maxY - bounds.minY, resolutionMetersPerPixel)
        var resolution = resolutionMetersPerPixel

        if maxMapDimensionPixels > 1 {
            let maxDimension = Double(maxMapDimensionPixels - 1)
            resolution = max(resolution, spanX / maxDimension, spanY / maxDimension)
        }

        if maxDensityCellCount > 0 {
            let area = spanX * spanY
            resolution = max(resolution, sqrt(area / Double(maxDensityCellCount)))
        }

        return resolution
    }

    private func densityGrid(
        points: [TopDownPoint],
        bounds: TopDownBounds,
        width: Int,
        height: Int,
        resolution: Double
    ) -> [UInt16] {
        var densities = [UInt16](repeating: 0, count: width * height)
        for point in points {
            let col = Int((point.x - bounds.minX) / resolution)
            let rowFromBottom = Int((point.y - bounds.minY) / resolution)
            let row = height - 1 - rowFromBottom
            guard col >= 0, col < width, row >= 0, row < height else {
                continue
            }
            splat(densities: &densities, width: width, height: height, col: col, row: row, weight: point.weight)
        }
        return densities
    }

    private func splat(
        densities: inout [UInt16],
        width: Int,
        height: Int,
        col: Int,
        row: Int,
        weight: UInt16
    ) {
        for dy in -1...1 {
            for dx in -1...1 {
                let x = col + dx
                let y = row + dy
                guard x >= 0, x < width, y >= 0, y < height else {
                    continue
                }
                let index = y * width + x
                let newValue = UInt32(densities[index]) + UInt32(weight)
                densities[index] = UInt16(min(newValue, UInt32(UInt16.max)))
            }
        }
    }

    private func pngData(from densities: [UInt16], width: Int, height: Int) throws -> Data {
        let maxDensity = max(densities.max() ?? 0, 1)
        let pixels = densities.map { value -> UInt8 in
            if value == 0 {
                return 0
            }
            let normalized = log1p(Double(value)) / log1p(Double(maxDensity))
            return UInt8(min(255.0, max(32.0, normalized * 255.0)))
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TopDownMapBuilderError.invalidImage
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TopDownMapBuilderError.invalidImage
        }
        guard let png = UIImage(cgImage: image).pngData() else {
            throw TopDownMapBuilderError.invalidImage
        }
        return png
    }

    private func writeMeshOverlayFromExistingScene(sceneURL: URL, payload: AnnotationPayload) throws {
        let mesh = try meshDataFromPLY(sceneURL: sceneURL)
        guard !mesh.triangles.isEmpty,
              payload.world_min_xy.count == 2,
              payload.world_max_xy.count == 2 else {
            return
        }
        let bounds = TopDownBounds(
            minX: payload.world_min_xy[0],
            minY: payload.world_min_xy[1],
            maxX: payload.world_max_xy[0],
            maxY: payload.world_max_xy[1]
        )
        let minZ = payload.floors.map(\.min_z).min().map { $0 - 0.5 } ?? minROSZ
        let maxZ = payload.floors.map(\.max_z).max().map { $0 + 0.5 } ?? maxROSZ
        let data = try meshOverlayPNGData(
            triangles: mesh.triangles,
            bounds: bounds,
            width: payload.image_width,
            height: payload.image_height,
            minZ: minZ,
            maxZ: maxZ
        )
        try FrameWriter.writeAnnotationData(data, named: "topdown_mesh.png", in: sceneURL)
    }

    private func meshOverlayPNGData(
        triangles: [TopDownTriangle],
        bounds: TopDownBounds,
        width: Int,
        height: Int,
        minZ: Double,
        maxZ: Double
    ) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let stride = max(1, triangles.count / 80_000)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let cgContext = context.cgContext
            cgContext.setLineWidth(0.6)
            cgContext.setLineJoin(.round)

            for (index, triangle) in triangles.enumerated() where index % stride == 0 {
                let averageZ = (triangle.a.z + triangle.b.z + triangle.c.z) / 3.0
                guard averageZ >= minZ, averageZ <= maxZ else { continue }

                let a = imagePoint(triangle.a, bounds: bounds, width: width, height: height)
                let b = imagePoint(triangle.b, bounds: bounds, width: width, height: height)
                let c = imagePoint(triangle.c, bounds: bounds, width: width, height: height)
                let path = UIBezierPath()
                path.move(to: a)
                path.addLine(to: b)
                path.addLine(to: c)
                path.close()
                UIColor(white: 0.78, alpha: 0.24).setFill()
                path.fill()
                UIColor(white: 1.0, alpha: 0.34).setStroke()
                path.stroke()
            }
        }
        guard let data = image.pngData() else {
            throw TopDownMapBuilderError.invalidImage
        }
        return data
    }

    private func imagePoint(_ point: TopDownPoint, bounds: TopDownBounds, width: Int, height: Int) -> CGPoint {
        let resolutionX = (bounds.maxX - bounds.minX) / Double(max(width - 1, 1))
        let resolutionY = (bounds.maxY - bounds.minY) / Double(max(height - 1, 1))
        let col = (point.x - bounds.minX) / resolutionX
        let rowFromBottom = (point.y - bounds.minY) / resolutionY
        return CGPoint(x: col, y: Double(height - 1) - rowFromBottom)
    }

    private func samplingStride(totalCount: Int, budget: Int) -> Int {
        guard totalCount > 0, budget > 0 else { return 1 }
        return max(1, Int(ceil(Double(totalCount) / Double(budget))))
    }

    private func meshDataFromPLY(
        sceneURL: URL,
        progress: ((SceneBuildProgress) -> Void)? = nil
    ) throws -> TopDownMesh {
        let meshURL = sceneURL.appendingPathComponent("mesh/arkit_mesh_world.ply")
        let handle = try FileHandle(forReadingFrom: meshURL)
        defer {
            try? handle.close()
        }
        let reader = PLYLineReader(handle: handle)
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
            return TopDownMesh(points: [], triangles: [])
        }

        let keepTriangleOverlay = vertexCount <= maxMeshVerticesForTriangleOverlay
            && faceCount > 0
            && maxMeshTriangles > 0
        var vertices: [TopDownPoint] = []
        if keepTriangleOverlay {
            vertices.reserveCapacity(vertexCount)
        }
        var points: [TopDownPoint] = []
        points.reserveCapacity(min(vertexCount, maxMeshPoints))
        let vertexStride = samplingStride(totalCount: vertexCount, budget: maxMeshPoints)
        let faceStride = samplingStride(totalCount: faceCount, budget: maxMeshTriangles)
        for vertexIndex in 0..<vertexCount {
            if vertexIndex % 50_000 == 0 {
                let fraction = 0.10 + 0.18 * Double(vertexIndex) / Double(max(vertexCount, 1))
                progress?(SceneBuildProgress(fraction, "Reading mesh vertices"))
            }
            guard let line = try reader.nextLine() else { break }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3,
                  let x = Float(parts[0]),
                  let y = Float(parts[1]),
                  let z = Float(parts[2]) else {
                continue
            }
            let ros = PhoneSceneCoordinateConversion.arkitWorldToROS(SIMD3<Float>(x, y, z))
            let point = TopDownPoint(x: ros.x, y: ros.y, z: ros.z, weight: 1)
            if keepTriangleOverlay {
                vertices.append(point)
            }
            if vertexIndex % vertexStride == 0 {
                points.append(point)
            }
        }

        guard keepTriangleOverlay else {
            return TopDownMesh(points: points, triangles: [])
        }

        var triangles: [TopDownTriangle] = []
        triangles.reserveCapacity(min(faceCount, maxMeshTriangles))
        for faceIndex in 0..<faceCount {
            if faceIndex % 50_000 == 0 {
                let fraction = 0.28 + 0.06 * Double(faceIndex) / Double(max(faceCount, 1))
                progress?(SceneBuildProgress(fraction, "Sampling mesh faces"))
            }
            guard let line = try reader.nextLine() else { break }
            guard faceIndex % faceStride == 0 else {
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4,
                  let count = Int(parts[0]),
                  count >= 3 else {
                continue
            }
            let indices = parts.dropFirst().compactMap { Int($0) }
            guard indices.count >= 3 else { continue }
            let first = indices[0]
            for triangleIndex in 1..<(indices.count - 1) {
                let second = indices[triangleIndex]
                let third = indices[triangleIndex + 1]
                guard vertices.indices.contains(first),
                      vertices.indices.contains(second),
                      vertices.indices.contains(third) else {
                    continue
                }
                triangles.append(TopDownTriangle(a: vertices[first], b: vertices[second], c: vertices[third]))
            }
        }

        return TopDownMesh(points: points, triangles: triangles)
    }

    private func vertex(at index: Int, source: ARGeometrySource) -> SIMD3<Float> {
        let pointer = source.buffer.contents().advanced(by: source.offset + index * source.stride)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    private func index(at index: Int, source: ARGeometryElement) -> UInt32 {
        let pointer = source.buffer.contents().advanced(by: index * source.bytesPerIndex)
        if source.bytesPerIndex == MemoryLayout<UInt32>.size {
            return pointer.assumingMemoryBound(to: UInt32.self).pointee
        }
        return UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
    }

    private func loadManifest(sceneURL: URL) throws -> [TopDownManifestEntry] {
        let manifestURL = sceneURL.appendingPathComponent("manifest.jsonl")
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { line in
                try decoder.decode(TopDownManifestEntry.self, from: Data(line.utf8))
            }
    }

    private func scaledIntrinsics(_ entry: TopDownManifestEntry) -> DepthIntrinsics {
        let sx = Float(entry.depth_width) / Float(entry.image_width)
        let sy = Float(entry.depth_height) / Float(entry.image_height)
        return DepthIntrinsics(
            fx: Float(entry.intrinsics[0][0]) * sx,
            fy: Float(entry.intrinsics[1][1]) * sy,
            cx: Float(entry.intrinsics[0][2]) * sx,
            cy: Float(entry.intrinsics[1][2]) * sy
        )
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

private struct TopDownPoint {
    let x: Double
    let y: Double
    let z: Double
    let weight: UInt16
}

private struct TopDownTriangle {
    let a: TopDownPoint
    let b: TopDownPoint
    let c: TopDownPoint
}

private struct TopDownMesh {
    let points: [TopDownPoint]
    let triangles: [TopDownTriangle]
}

private final class PLYLineReader {
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

private struct TopDownBounds {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

private struct DepthIntrinsics {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

private struct TopDownManifestEntry: Decodable {
    let depth: String
    let image_width: Int
    let image_height: Int
    let depth_width: Int
    let depth_height: Int
    let intrinsics: [[Double]]
    let camera_to_world: [[Double]]
}
