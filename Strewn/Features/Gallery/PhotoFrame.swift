import SwiftUI

/// Wraps a photo in the pile's chosen frame. The frame only ever adds space around the
/// photo; it never changes the photo's shape.
struct PhotoFrameModifier: ViewModifier {
    let style: FrameStyle
    var caption: String?
    var frameNumber: Int = 1

    func body(content: Content) -> some View {
        let inset = style.insets
        switch style.kind {
        case .none:
            content.clipShape(RoundedRectangle(cornerRadius: 3))
        case .whiteBorder:
            content.padding(inset).background { PrintBacking() }
        case .thinBlack:
            content.padding(inset).background(Color.black)
        case .polaroid:
            content
                .padding(inset)
                .background { PrintBacking() }
                .overlay(alignment: .bottomLeading) {
                    if let caption {
                        Text(caption)
                            .font(.custom("Bradley Hand", size: max(15, min(26, style.borderWidth * 1.5))))
                            .foregroundStyle(Color(white: 0.17))
                            .lineLimit(1)
                            .frame(height: inset.bottom)
                            .padding(.horizontal, inset.leading)
                    }
                }
        case .filmStrip:
            content
                .padding(inset)
                .background(Color.film)
                .overlay { SprocketHoles(borderWidth: style.borderWidth) }
                .overlay(alignment: .bottom) {
                    HStack {
                        Text("BATCHES 400")
                        Spacer()
                        Text("▸ \(String(format: "%02d", frameNumber))A")
                    }
                    .font(.system(size: 8.5, design: .monospaced))
                    .kerning(1)
                    .foregroundStyle(Color.filmEdge)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 1)
                }
        case .galleryMat:
            content
                .overlay(Rectangle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                .padding(4)
                .overlay(Rectangle().stroke(Color.black.opacity(0.14), lineWidth: 1))
                .padding(max(0, inset.top - 4))
                .background { PrintBacking() }
        }
    }
}

extension View {
    func photoFrame(_ style: FrameStyle, caption: String? = nil, frameNumber: Int = 1) -> some View {
        modifier(PhotoFrameModifier(style: style, caption: caption, frameNumber: frameNumber))
    }
}

/// The paper behind a framed print, with its shadow. The shadow sits on this plain rectangle
/// rather than on the photo: a shape's shadow is cheap to draw, while one cast by an image
/// is redrawn on every frame of a scroll or animation.
private struct PrintBacking: View {
    var body: some View {
        Rectangle()
            .fill(Color.paper)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }
}

/// 35mm perforations along the top and bottom of a strip of film.
struct SprocketHoles: View {
    var holeHeight: CGFloat
    /// Distance from the edges to the holes.
    var inset: CGFloat
    /// .horizontal: rows along top and bottom. .vertical: columns down both sides.
    var axis: Axis = .horizontal

    init(holeHeight: CGFloat, inset: CGFloat, axis: Axis = .horizontal) {
        self.holeHeight = holeHeight
        self.inset = inset
        self.axis = axis
    }

    init(borderWidth: CGFloat) {
        self.init(holeHeight: max(7, borderWidth * 0.55), inset: borderWidth * 0.45 + 2)
    }

    var body: some View {
        Canvas { ctx, size in
            let h = holeHeight, w = h * 0.8, gap = w * 0.75
            let corner = h * 0.2
            let length = axis == .horizontal ? size.width : size.height
            let across = axis == .horizontal ? size.height : size.width
            var t = w * 0.5
            while t + w < length {
                for c in [inset, across - inset - h] {
                    let rect = axis == .horizontal
                        ? CGRect(x: t, y: c, width: w, height: h)
                        : CGRect(x: c, y: t, width: h, height: w)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: corner), with: .color(Color(white: 0.86).opacity(0.9)))
                }
                t += w + gap
            }
        }
        .allowsHitTesting(false)
    }
}
