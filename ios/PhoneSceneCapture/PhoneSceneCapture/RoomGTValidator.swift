import CoreGraphics
import Foundation

struct RoomPolygonCandidate {
    let label: String
    let vertices: [CGPoint]
}

struct RoomTrajectorySample {
    let xy: CGPoint
    let z: Double
}

struct RoomValidationResult {
    let warnings: [String]
    let trajectoryFrameCounts: [Int]

    var hasWarnings: Bool {
        !warnings.isEmpty
    }
}

enum RoomGTValidator {
    static let minimumAreaSquareMeters = 0.25
    static let overlapToleranceSquareMeters = 0.25

    static func validate(
        rooms: [RoomPolygonCandidate],
        trajectoryXY: [CGPoint],
        allowedLabels: Set<String> = Set(RoomLabelStore.load()),
        overlapTolerance: Double = overlapToleranceSquareMeters
    ) -> RoomValidationResult {
        validate(
            rooms: rooms,
            trajectorySamples: trajectoryXY.map { RoomTrajectorySample(xy: $0, z: 0.0) },
            zRange: nil,
            allowedLabels: allowedLabels,
            overlapTolerance: overlapTolerance
        )
    }

    static func validate(
        rooms: [RoomPolygonCandidate],
        trajectorySamples: [RoomTrajectorySample],
        zRange: ClosedRange<Double>?,
        allowedLabels: Set<String> = Set(RoomLabelStore.load()),
        overlapTolerance: Double = overlapToleranceSquareMeters
    ) -> RoomValidationResult {
        var warnings: [String] = []
        var trajectoryCounts: [Int] = []
        let normalizedAllowedLabels = Set(allowedLabels.map(RoomLabelStore.normalize))

        for (index, room) in rooms.enumerated() {
            let roomName = "room \(index)"
            if !normalizedAllowedLabels.contains(RoomLabelStore.normalize(room.label)) {
                warnings.append("\(roomName): label '\(room.label)' is not in the active room type list.")
            }
            if room.vertices.count < 3 {
                warnings.append("\(roomName): polygon needs at least 3 vertices.")
                trajectoryCounts.append(0)
                continue
            }

            let area = polygonArea(room.vertices)
            if area < minimumAreaSquareMeters {
                warnings.append(String(format: "\(roomName): polygon area %.2f m^2 is below %.2f m^2.", area, minimumAreaSquareMeters))
            }
            if isSelfIntersecting(room.vertices) {
                warnings.append("\(roomName): polygon is self-intersecting.")
            }

            let count = trajectorySamples.filter { sample in
                let zMatches = zRange.map { $0.contains(sample.z) } ?? true
                return zMatches && pointInPolygon(sample.xy, polygon: room.vertices)
            }.count
            trajectoryCounts.append(count)
        }

        if rooms.count > 1 {
            for leftIndex in 0..<(rooms.count - 1) {
                for rightIndex in (leftIndex + 1)..<rooms.count {
                    let overlap = approximateOverlapArea(
                        rooms[leftIndex].vertices,
                        rooms[rightIndex].vertices
                    )
                    if overlap > overlapTolerance {
                        warnings.append(String(format: "rooms %d and %d overlap by %.2f m^2.", leftIndex, rightIndex, overlap))
                    }
                }
            }
        }

        return RoomValidationResult(warnings: warnings, trajectoryFrameCounts: trajectoryCounts)
    }

    static func polygonArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0.0 }
        var sum = 0.0
        for index in points.indices {
            let next = points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)
            sum += Double(points[index].x * points[next].y - points[next].x * points[index].y)
        }
        return abs(sum) * 0.5
    }

    static func isSelfIntersecting(_ points: [CGPoint]) -> Bool {
        guard points.count >= 4 else { return false }
        for firstIndex in 0..<points.count {
            let firstNext = (firstIndex + 1) % points.count
            for secondIndex in (firstIndex + 1)..<points.count {
                let secondNext = (secondIndex + 1) % points.count
                if firstIndex == secondIndex || firstNext == secondIndex || secondNext == firstIndex {
                    continue
                }
                if firstIndex == 0 && secondNext == 0 {
                    continue
                }
                if segmentsIntersect(
                    points[firstIndex],
                    points[firstNext],
                    points[secondIndex],
                    points[secondNext]
                ) {
                    return true
                }
            }
        }
        return false
    }

    static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let denominator = previous.y - current.y
                if abs(denominator) > .ulpOfOne {
                    let xIntersection = (previous.x - current.x) * (point.y - current.y) / denominator + current.x
                    if point.x < xIntersection {
                        inside.toggle()
                    }
                }
            }
            previous = current
        }
        return inside
    }

    static func approximateOverlapArea(
        _ first: [CGPoint],
        _ second: [CGPoint],
        sampleStep: Double = 0.10
    ) -> Double {
        guard first.count >= 3, second.count >= 3 else { return 0.0 }
        let boundsA = polygonBounds(first)
        let boundsB = polygonBounds(second)
        let minX = max(boundsA.minX, boundsB.minX)
        let maxX = min(boundsA.maxX, boundsB.maxX)
        let minY = max(boundsA.minY, boundsB.minY)
        let maxY = min(boundsA.maxY, boundsB.maxY)
        guard maxX > minX, maxY > minY else { return 0.0 }

        var overlapSamples = 0
        var y = minY + sampleStep * 0.5
        while y < maxY {
            var x = minX + sampleStep * 0.5
            while x < maxX {
                let sample = CGPoint(x: x, y: y)
                if pointInPolygon(sample, polygon: first) && pointInPolygon(sample, polygon: second) {
                    overlapSamples += 1
                }
                x += sampleStep
            }
            y += sampleStep
        }
        return Double(overlapSamples) * sampleStep * sampleStep
    }

    private static func polygonBounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return .null
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)

        if o1 == 0 && point(c, liesOnSegmentFrom: a, to: b) { return true }
        if o2 == 0 && point(d, liesOnSegmentFrom: a, to: b) { return true }
        if o3 == 0 && point(a, liesOnSegmentFrom: c, to: d) { return true }
        if o4 == 0 && point(b, liesOnSegmentFrom: c, to: d) { return true }
        return o1 != o2 && o3 != o4
    }

    private static func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Int {
        let value = Double((b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y))
        if abs(value) < 1e-9 {
            return 0
        }
        return value > 0 ? 1 : 2
    }

    private static func point(_ point: CGPoint, liesOnSegmentFrom a: CGPoint, to b: CGPoint) -> Bool {
        point.x <= max(a.x, b.x) + 1e-9 &&
            point.x + 1e-9 >= min(a.x, b.x) &&
            point.y <= max(a.y, b.y) + 1e-9 &&
            point.y + 1e-9 >= min(a.y, b.y)
    }
}
