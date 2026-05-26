import Foundation
import simd

enum MatrixJSON {
    static func rows(_ matrix: simd_float3x3) -> [[Float]] {
        return [
            [matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x],
            [matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y],
            [matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z],
        ]
    }

    static func rows(_ matrix: simd_float4x4) -> [[Float]] {
        return [
            [matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x, matrix.columns.3.x],
            [matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y, matrix.columns.3.y],
            [matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z, matrix.columns.3.z],
            [matrix.columns.0.w, matrix.columns.1.w, matrix.columns.2.w, matrix.columns.3.w],
        ]
    }
}
