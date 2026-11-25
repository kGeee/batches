import SwiftUI
import UIKit

/// How a post carries the Batches name. Designed on the "Batches watermark options" canvas at
/// 360 points wide; everything here is measured in those points and scaled by `k`, the post's
/// width over 360 (3 for a 1080-wide post, 1 for the sheet's one-third preview).
enum SocialBranding: String, CaseIterable, Identifiable {
    /// A: the app icon and "Batches" in the bottom-left corner, over any fill.
    case corner
    /// B: the photo as a paper print on the linen desk, its name and the lockup underneath.
    case print
    /// C: the photo on film black, with rebate markings above and below in amber.
    case film
    /// Nothing added.
    case none

    var id: Self { self }

    var title: String {
        switch self {
        case .corner: "Corner"
        case .print: "Print"
        case .film: "Film"
        case .none: "None"
        }
    }

    var note: String {
        switch self {
        case .corner: "A small Batches mark in the corner."
        case .print: "The photo as a print on the desk, named, with Batches underneath."
        case .film: "The photo on film, with Batches and the date along its edges."
        case .none: "No Batches mark."
        }
    }

    /// Print and Film lay out the whole post themselves, so the fill choice doesn't apply.
    var usesFill: Bool { self == .corner || self == .none }
}

/// What a branded post can say about where it came from.
struct SocialCaption: Equatable {
    var title: String
    var date: Date?
    /// 1-based position among the photos being posted.
    var index = 1
    var total = 1
}

/// The colours and type of batches.space, for drawing posts.
enum Brand {
    static let desk = UIColor(red: 0xdd / 255, green: 0xd4 / 255, blue: 0xc1 / 255, alpha: 1)
    static let thread = UIColor(red: 70 / 255, green: 56 / 255, blue: 34 / 255, alpha: 0.038)
    static let paper = UIColor(red: 0xfa / 255, green: 0xf8 / 255, blue: 0xf2 / 255, alpha: 1)
    static let ink = UIColor(red: 0x1d / 255, green: 0x1b / 255, blue: 0x17 / 255, alpha: 1)
    static let muted = UIColor(red: 0x5a / 255, green: 0x53 / 255, blue: 0x47 / 255, alpha: 1)
    static let accent = UIColor(red: 0x8a / 255, green: 0x52 / 255, blue: 0x10 / 255, alpha: 1)
    static let accentOnDark = UIColor(red: 0xe7 / 255, green: 0xa4 / 255, blue: 0x52 / 255, alpha: 1)
    static let film = UIColor(red: 0x16 / 255, green: 0x14 / 255, blue: 0x12 / 255, alpha: 1)
    static let shadow = UIColor(red: 40 / 255, green: 28 / 255, blue: 12 / 255, alpha: 1)

    /// The app icon, as the site's header shows it.
    static let mark: UIImage? = UIImage(named: "BrandMark")

    static func serif(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    static func mono(_ size: CGFloat) -> UIFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

/// Draws the branded parts of a post into the current UIKit context (origin top-left).
enum BrandDrawing {
    /// The linen desk: the site's thread texture, 1-point threads every 3 points across and
    /// every 4 points down.
    static func linen(in rect: CGRect, k: CGFloat) {
        Brand.desk.setFill()
        UIRectFill(rect)
        Brand.thread.setFill()
        let line = max(1, k)
        var y = rect.minY
        while y < rect.maxY { UIRectFillUsingBlendMode(CGRect(x: rect.minX, y: y, width: rect.width, height: line), .normal); y += 3 * k }
        var x = rect.minX
        while x < rect.maxX { UIRectFillUsingBlendMode(CGRect(x: x, y: rect.minY, width: line, height: rect.height), .normal); x += 4 * k }
    }

    /// The icon tile with rounded corners.
    static func icon(at rect: CGRect, radius: CGFloat, shadow: (blur: CGFloat, alpha: CGFloat)? = nil) {
        guard let mark = Brand.mark, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        if let shadow {
            context.setShadow(offset: CGSize(width: 0, height: rect.height * 0.05), blur: shadow.blur,
                              color: UIColor.black.withAlphaComponent(shadow.alpha).cgColor)
            UIColor.black.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            context.setShadow(offset: .zero, blur: 0)
        }
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        mark.draw(in: rect)
        context.restoreGState()
    }

    /// A paper print: the photo with a paper border and the site's two-layer shadow.
    static func paperPrint(_ photo: UIImage, in photoRect: CGRect, border: CGFloat, k: CGFloat, lift: CGFloat = 1) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let paper = photoRect.insetBy(dx: -border, dy: -border)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 6 * k * lift), blur: 14 * k * lift, color: Brand.shadow.withAlphaComponent(0.22).cgColor)
        Brand.paper.setFill()
        UIRectFill(paper)
        context.setShadow(offset: CGSize(width: 0, height: 1 * k), blur: 2 * k, color: Brand.shadow.withAlphaComponent(0.28).cgColor)
        UIRectFill(paper)
        context.restoreGState()
        photo.draw(in: photoRect)
    }

    @discardableResult
    static func text(_ string: String, font: UIFont, color: UIColor, kern: CGFloat = 0,
                     at point: CGPoint, anchor: UnitPoint = .topLeading, shadow: NSShadow? = nil) -> CGRect {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        if let shadow { attributes[.shadow] = shadow }
        let text = NSAttributedString(string: string, attributes: attributes)
        let size = text.size()
        let origin = CGPoint(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y)
        text.draw(at: origin)
        return CGRect(origin: origin, size: size)
    }

    // MARK: A · Corner lockup

    /// Icon and "Batches", 16 points in from the bottom-left corner.
    static func corner(canvas: CGSize, k: CGFloat, opacity: CGFloat = 0.92) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let side = 20 * k
        let iconRect = CGRect(x: 16 * k, y: canvas.height - 16 * k - side, width: side, height: side)
        icon(at: iconRect, radius: 5 * k, shadow: (3 * k, 0.35))
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3 * k
        shadow.shadowOffset = CGSize(width: 0, height: k)
        text("Batches", font: Brand.serif(14 * k, weight: .semibold), color: Brand.paper,
             at: CGPoint(x: iconRect.maxX + 7 * k, y: iconRect.midY), anchor: UnitPoint(x: 0, y: 0.5), shadow: shadow)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: B · Print on the desk

    static func printPost(_ photo: UIImage, caption: SocialCaption, canvas: CGSize, k: CGFloat) {
        linen(in: CGRect(origin: .zero, size: canvas), k: k)
        let border = 9 * k, side = 32 * k, gap = 18 * k, captionHeight = 34 * k
        let maxWidth = canvas.width - 2 * side - 2 * border
        let maxHeight = canvas.height - 2 * 40 * k - gap - captionHeight - 2 * border
        let aspect = photo.size.width / max(photo.size.height, 1)
        var size = CGSize(width: maxWidth, height: maxWidth / aspect)
        if size.height > maxHeight { size = CGSize(width: maxHeight * aspect, height: maxHeight) }
        let blockHeight = size.height + 2 * border + gap + captionHeight
        let paperX = (canvas.width - size.width - 2 * border) / 2
        let top = (canvas.height - blockHeight) / 2
        let photoRect = CGRect(x: paperX + border, y: top + border, width: size.width, height: size.height)
        paperPrint(photo, in: photoRect, border: border, k: k)

        // The caption runs under the print, edge to edge with it.
        let left = paperX + 1 * k, right = paperX + size.width + 2 * border - 1 * k
        let captionTop = photoRect.maxY + border + gap
        let titleRect = text(caption.title, font: Brand.serif(15 * k, weight: .semibold), color: Brand.ink,
                             at: CGPoint(x: left, y: captionTop))
        text(dateLine(caption, total: true), font: Brand.mono(10 * k), color: Brand.muted,
             at: CGPoint(x: left, y: titleRect.maxY + 2 * k))
        let mid = captionTop + 16 * k
        let label = NSAttributedString(string: "Batches", attributes: [.font: Brand.serif(13 * k, weight: .semibold)])
        let iconSide = 18 * k
        let iconX = right - label.size().width - 6 * k - iconSide
        icon(at: CGRect(x: iconX, y: mid - iconSide / 2, width: iconSide, height: iconSide), radius: 4 * k)
        text("Batches", font: Brand.serif(13 * k, weight: .semibold), color: Brand.ink,
             at: CGPoint(x: right, y: mid), anchor: UnitPoint(x: 1, y: 0.5))
    }

    // MARK: C · Film rebate

    static func filmPost(_ photo: UIImage, caption: SocialCaption, canvas: CGSize, k: CGFloat) {
        Brand.film.setFill()
        UIRectFill(CGRect(origin: .zero, size: canvas))
        let side = 10 * k, gap = 10 * k, rowHeight = 12 * k
        let maxWidth = canvas.width - 2 * side
        let maxHeight = canvas.height - 2 * (24 * k + rowHeight + gap)
        let aspect = photo.size.width / max(photo.size.height, 1)
        var size = CGSize(width: maxWidth, height: maxWidth / aspect)
        if size.height > maxHeight { size = CGSize(width: maxHeight * aspect, height: maxHeight) }
        let photoRect = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                               width: size.width, height: size.height)
        photo.draw(in: photoRect)

        let ink = Brand.accentOnDark.withAlphaComponent(0.8)
        let font = Brand.mono(9 * k)
        let left = photoRect.minX + 4 * k, right = photoRect.maxX - 4 * k
        let topRow = photoRect.minY - gap, bottomRow = photoRect.maxY + gap
        text("BATCHES", font: font, color: ink, kern: 1.44 * k, at: CGPoint(x: left, y: topRow), anchor: UnitPoint(x: 0, y: 1))
        text(String(format: "%02d", caption.index), font: font, color: ink, kern: 1.44 * k,
             at: CGPoint(x: right, y: topRow), anchor: UnitPoint(x: 1, y: 1))
        if let date = caption.date {
            text(date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased().replacingOccurrences(of: ",", with: ""),
                 font: font, color: ink, kern: 1.44 * k, at: CGPoint(x: left, y: bottomRow))
        }
        text("batches.space", font: font, color: ink, kern: 0.54 * k, at: CGPoint(x: right, y: bottomRow), anchor: UnitPoint(x: 1, y: 0))
    }

    // MARK: E · Video end card

    /// The closing card of a video: the batch's pile, its name, and the Batches lockup. Drawn in
    /// the 360 × 640 design scaled to fit the post, on linen that fills it.
    static func endCard(prints: [UIImage], caption: SocialCaption, canvas: CGSize) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let u = min(canvas.width / 360, canvas.height / 640)
        linen(in: CGRect(origin: .zero, size: canvas), k: canvas.width / 360)
        context.saveGState()
        context.translateBy(x: (canvas.width - 360 * u) / 2, y: (canvas.height - 640 * u) / 2)
        context.scaleBy(x: u, y: u)

        // The pile: back left, back right, front, each a whole photo on paper.
        let spots: [(x: CGFloat, y: CGFloat, angle: CGFloat)] = [(-36, -12, -8), (36, -22, 6), (0, 10, -1)]
        let pileCenter = CGPoint(x: 180, y: 96 + 98)
        for (index, image) in prints.prefix(3).enumerated() {
            let spot = spots[index + max(0, 3 - prints.count)]
            let aspect = image.size.width / max(image.size.height, 1)
            var size = CGSize(width: 146, height: 146 / aspect)
            if size.height > 110 { size = CGSize(width: 110 * aspect, height: 110) }
            context.saveGState()
            context.translateBy(x: pileCenter.x + spot.x, y: pileCenter.y + spot.y)
            context.rotate(by: spot.angle * .pi / 180)
            paperPrint(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                  border: 5, k: 1, lift: index == prints.prefix(3).count - 1 ? 1.3 : 0.9)
            context.restoreGState()
        }

        let titleRect = text(caption.title, font: Brand.serif(28, weight: .bold), color: Brand.ink, kern: -0.56,
                             at: CGPoint(x: 180, y: 292), anchor: UnitPoint(x: 0.5, y: 0))
        text(dateLine(caption, total: false), font: Brand.mono(11), color: Brand.muted,
             at: CGPoint(x: 180, y: titleRect.maxY + 6), anchor: UnitPoint(x: 0.5, y: 0))

        // The lockup, centred near the bottom, with the address under it.
        let label = NSAttributedString(string: "Batches", attributes: [.font: Brand.serif(19, weight: .semibold)])
        let width = 30 + 9 + label.size().width
        let lockupY: CGFloat = 640 - 48 - 22 - 30
        icon(at: CGRect(x: 180 - width / 2, y: lockupY, width: 30, height: 30), radius: 7, shadow: (3, 0.25))
        text("Batches", font: Brand.serif(19, weight: .semibold), color: Brand.ink,
             at: CGPoint(x: 180 - width / 2 + 39, y: lockupY + 15), anchor: UnitPoint(x: 0, y: 0.5))
        text("batches.space", font: Brand.mono(11), color: Brand.accent,
             at: CGPoint(x: 180, y: lockupY + 38), anchor: UnitPoint(x: 0.5, y: 0))
        context.restoreGState()
    }

    /// "Oct 10 · 3 of 12" under a print, or "Oct 10 · 12 photos" on the end card.
    static func dateLine(_ caption: SocialCaption, total: Bool) -> String {
        var parts: [String] = []
        if let date = caption.date { parts.append(date.formatted(.dateTime.month(.abbreviated).day())) }
        if total {
            if caption.total > 1 { parts.append("\(caption.index) of \(caption.total)") }
        } else {
            parts.append(caption.total.counted("photo"))
        }
        return parts.joined(separator: " · ")
    }
}
