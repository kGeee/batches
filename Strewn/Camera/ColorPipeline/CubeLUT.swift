import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Minimal Adobe .cube parser that produces data for CIColorCube.
/// .cube stores red varying fastest, which is the order Core Image expects.
struct CubeLUT {
    let dimension: Int
    let data: Data   // Float32 RGBA

    init?(named name: String, bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: name, withExtension: "cube"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    init?(text: String) {
        var size = 0
        var values: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") || trimmed.hasPrefix("DOMAIN") { continue }
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                size = Int(trimmed.split(separator: " ").last ?? "") ?? 0
                values.reserveCapacity(size * size * size * 4)
                continue
            }
            let rgb = trimmed.split(separator: " ").compactMap { Float($0) }
            guard rgb.count == 3 else { continue }
            values.append(contentsOf: rgb + [1])
        }
        guard size > 1, values.count == size * size * size * 4 else { return nil }
        dimension = size
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func filter() -> CIFilter & CIColorCube {
        let f = CIFilter.colorCube()
        f.cubeDimension = Float(dimension)
        f.cubeData = data
        return f
    }
}
