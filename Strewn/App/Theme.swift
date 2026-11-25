import SwiftUI

extension Color {
    /// Print paper: stays light in dark mode because prints are physical objects.
    static let paper = Color(red: 0.965, green: 0.969, blue: 0.957)
    static let film = Color(white: 0.08)
    static let filmEdge = Color(red: 0.89, green: 0.60, blue: 0.23)
    /// The one accent, a sea-glass green kept for the few things that are yours to act on:
    /// deep on the fog, pale at night and on the camera and editor, which are always dark.
    static let strewnAccent = Color(light: Color(red: 0.271, green: 0.412, blue: 0.373),
                                    dark: Color(red: 0.616, green: 0.749, blue: 0.706))
    /// Fog: a soft grey-green that holds everything, so the photos are the only colour.
    static let mat = Color(light: Color(red: 0.890, green: 0.898, blue: 0.878), dark: Color(red: 0.106, green: 0.114, blue: 0.110))
    /// Behind a photo opened full screen: a shade deeper than the desk, so the photo lifts off it.
    static let viewerFog = Color(light: Color(red: 0.831, green: 0.843, blue: 0.816), dark: Color(red: 0.071, green: 0.078, blue: 0.075))
    /// The paper edges that peek out behind a cover, nearest first.
    static let fogEdge = Color(light: Color(red: 0.745, green: 0.761, blue: 0.729), dark: Color(red: 0.200, green: 0.212, blue: 0.204))
    static let fogEdgeFar = Color(light: Color(red: 0.808, green: 0.820, blue: 0.792), dark: Color(red: 0.165, green: 0.176, blue: 0.169))

    /// Text and icons on the accent. The accent is bright amber at night, where white washes out.
    static let onAccent = Color(light: .white, dark: Color(white: 0.1))
    /// A panel on the mat, such as the account rows. Paper by day; at night paper would sit
    /// white text on a near-white panel, so it's a lift of the mat instead.
    static let card = Color(light: Color(red: 0.843, green: 0.855, blue: 0.827), dark: Color.white.opacity(0.07))

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
    /// Titles are set in a light reading serif, like a caption on a print; metadata is plain
    /// small text underneath.
    func titleStyle(_ style: Font.TextStyle = .title3, weight: Font.Weight = .regular) -> some View {
        font(.system(style, design: .serif, weight: weight))
    }

    /// A small text link that's easier to hit than its text is tall, without taking more room.
    func roomyTapTarget() -> some View {
        padding(.vertical, 12).contentShape(Rectangle()).padding(.vertical, -12)
    }

    func metaStyle(_ style: Font.TextStyle = .caption2) -> some View {
        font(.system(style)).foregroundStyle(.secondary)
    }
}

/// The fog everything sits on: one flat, quiet grey, so nothing competes with the photos.
struct DeskMatBackground: View {
    var body: some View {
        Color.mat.ignoresSafeArea()
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
