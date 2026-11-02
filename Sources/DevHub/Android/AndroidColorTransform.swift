import CoreImage
import simd

/// SurfaceFlinger's linear-RGB/LMS simulation, also applied to scrcpy's unfiltered capture.
/// See docs/android-runtime-settings.md for the AOSP source and capture behavior.
struct AndroidColorTransform {
    let matrix: simd_float3x3

    init?(mode: Int?) {
        guard let mode, (0...3).contains(mode) else { return nil }
        if mode == 0 {
            matrix = simd_float3x3(columns: (SIMD3(repeating: 0.2126), SIMD3(repeating: 0.7152), SIMD3(repeating: 0.0722)))
            return
        }
        let rgbToXYZ = simd_float3x3(columns: (SIMD3(0.4124, 0.2126, 0.0193), SIMD3(0.3576, 0.7152, 0.1192), SIMD3(0.1805, 0.0722, 0.9505)))
        let xyzToLMS = simd_float3x3(columns: (SIMD3(0.7328, -0.7036, 0.0030), SIMD3(0.4296, 1.6975, 0.0136), SIMD3(-0.1624, 0.0061, 0.9834)))
        let rgbToLMS = xyzToLMS * rgbToXYZ
        let white = rgbToLMS * SIMD3<Float>(repeating: 1)
        let plane = simd_cross(white, mode == 3 ? rgbToLMS.columns.0 : rgbToLMS.columns.2)
        let projection: simd_float3x3
        switch mode {
        case 1: projection = simd_float3x3(columns: (SIMD3(0, 0, 0), SIMD3(-plane.y / plane.x, 1, 0), SIMD3(-plane.z / plane.x, 0, 1)))
        case 2: projection = simd_float3x3(columns: (SIMD3(1, -plane.x / plane.y, 0), SIMD3(0, 0, 0), SIMD3(0, -plane.z / plane.y, 1)))
        default: projection = simd_float3x3(columns: (SIMD3(1, 0, -plane.x / plane.z), SIMD3(0, 1, -plane.y / plane.z), SIMD3(0, 0, 0)))
        }
        matrix = rgbToLMS.inverse * projection * rgbToLMS
    }

    var parameters: [String: CIVector] {
        func row(_ index: Int) -> CIVector {
            CIVector(x: CGFloat(matrix[0][index]), y: CGFloat(matrix[1][index]), z: CGFloat(matrix[2][index]), w: 0)
        }
        return ["inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]
    }
}
