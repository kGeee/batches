import SwiftUI

extension Color {
    /// Print paper: stays light in dark mode because prints are physical objects.
    static let paper = Color(red: 0.984, green: 0.980, blue: 0.965)
    static let film = Color(white: 0.08)
    static let filmEdge = Color(red: 0.89, green: 0.60, blue: 0.23)
    /// The one accent, a darkroom amber: deep on light surfaces, bright on the camera and
    /// editor, which are always dark.
    static let strewnAccent = Color(light: Color(red: 0.70, green: 0.42, blue: 0.08),
                                    dark: Color(red: 0.95, green: 0.71, blue: 0.30))
    /// Undyed linen: warm oatmeal by day, a deep brown-grey at night.
    static let mat = Color(light: Color(red: 0.89, green: 0.86, blue: 0.80), dark: Color(red: 0.15, green: 0.14, blue: 0.12))

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

extension Int {
    /// "1 frame", "3 frames": the count with its noun, plural only when it should be. Pass
    /// `plural` for words that don't just take an s ("batch", "batches").
    func counted(_ noun: String, plural: String? = nil) -> String { "\(self) \(self == 1 ? noun : plural ?? noun + "s")" }
}

extension View {
    /// Titles are set in the serif, like a caption on a print; metadata stays monospaced,
    /// like the edge printing on film.
    func titleStyle(_ style: Font.TextStyle = .title3, weight: Font.Weight = .semibold) -> some View {
        font(.system(style, design: .serif, weight: weight))
    }

    func metaStyle(_ style: Font.TextStyle = .caption2) -> some View {
        font(.system(style, design: .monospaced)).foregroundStyle(.secondary)
    }
}

/// The linen the piles sit on: a warm cloth a shade darker than the prints, so white
/// borders still read. The weave is a small tile drawn once and repeated by the GPU, so
/// animations over it cost nothing extra.
struct DeskMatBackground: View {
    var body: some View {
        Color.mat
            .overlay(Image(uiImage: LinenTile.image).resizable(resizingMode: .tile))
            .ignoresSafeArea()
    }
}

/// One seamless square of weave, transparent apart from the threads, so the same tile works
/// over the light and dark linen.
enum LinenTile {
    static let image: UIImage = {
        let side: CGFloat = 240
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            // A fixed xorshift, kept local because the photo editing extension shares this file.
            var state: UInt64 = 0x9E3779B97F4A7C15
            func random() -> CGFloat {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return CGFloat(Double(state >> 11) / Double(1 << 53))
            }
            // Warp and weft: fine threads of slightly uneven weight. 240 / 1.5 is whole, so the
            // threads line up across tile edges.
            cg.setLineWidth(0.6)
            for vertical in [false, true] {
                for offset in stride(from: 0, to: side, by: 1.5) {
                    let dark = random() < 0.5
                    cg.setStrokeColor((dark ? UIColor.black : .white).withAlphaComponent(0.015 + random() * 0.035).cgColor)
                    cg.beginPath()
                    if vertical {
                        cg.move(to: CGPoint(x: offset, y: 0)); cg.addLine(to: CGPoint(x: offset, y: side))
                    } else {
                        cg.move(to: CGPoint(x: 0, y: offset)); cg.addLine(to: CGPoint(x: side, y: offset))
                    }
                    cg.strokePath()
                }
            }
            // Slubs: the short thick bits that make linen look like linen. Each is drawn again one
            // tile over, so any that cross an edge continue on the next tile.
            for _ in 0..<Int(side * side / 900) {
                let x = random() * side, y = random() * side
                let rect = random() < 0.5
                    ? CGRect(x: x, y: y, width: 4 + random() * 10, height: 0.8)
                    : CGRect(x: x, y: y, width: 0.8, height: 4 + random() * 10)
                cg.setFillColor(UIColor.black.withAlphaComponent(0.03 + random() * 0.04).cgColor)
                for dx in [0, -side] { for dy in [0, -side] { cg.fill(rect.offsetBy(dx: dx, dy: dy)) } }
            }
        }
    }()
}
