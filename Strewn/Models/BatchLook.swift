import SwiftUI

/// The typeface a batch's owner picked. Stored with the batch, so everyone who opens it sees the
/// same one. Every face ships with iOS, so nothing is downloaded. Adding a case means widening the
/// check on collections.font too.
enum BatchFont: String, Codable, CaseIterable, Identifiable {
    case classic, modern, rounded, typewriter, didot, futura, handwritten
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .modern: "Modern"
        case .rounded: "Rounded"
        case .typewriter: "Typewriter"
        case .didot: "Didot"
        case .futura: "Futura"
        case .handwritten: "Handwritten"
        }
    }

    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .classic: .system(style, design: .serif, weight: weight)
        case .modern: .system(style, design: .default, weight: weight)
        case .rounded: .system(style, design: .rounded, weight: weight)
        case .typewriter: .custom("American Typewriter", size: Self.size(of: style), relativeTo: style).weight(weight)
        case .didot: .custom("Didot", size: Self.size(of: style), relativeTo: style).weight(weight)
        case .futura: .custom("Futura", size: Self.size(of: style), relativeTo: style).weight(weight)
        case .handwritten: .custom("Noteworthy", size: Self.size(of: style), relativeTo: style).weight(weight)
        }
    }

    /// Default sizes of the text styles, so named fonts scale with Dynamic Type as the system ones do.
    private static func size(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

extension View {
    /// A title set in its batch's font. A batch with none chosen looks like every other title.
    func batchTitle(_ font: BatchFont?, _ style: Font.TextStyle = .title3, weight: Font.Weight = .semibold) -> some View {
        self.font((font ?? .classic).font(style, weight: weight))
    }
}

/// The owner's freehand arrangement of a batch. It sits in its own column rather than in
/// FrameStyle, because older builds can't decode a frame with a layout they don't know.
///
/// Positions and widths are fractions of the board's width, so the arrangement looks the same on
/// every phone. The board grows as tall as its prints need. Prints stay inside its width, so a
/// photo is never pushed partly off screen and shown cut off.
struct BatchBoard: Hashable, Codable {
    /// Whether the batch opens as a board. Turning it off keeps the arrangement for later.
    var isOn = true
    /// By photo id. Photos with none yet (a friend just added them) are placed below the rest.
    var placements: [String: Placement] = [:]

    struct Placement: Hashable, Codable {
        /// Center of the print, as fractions of the board's width.
        var x: CGFloat
        var y: CGFloat
        /// Print width, frame included, as a fraction of the board's width.
        var width: CGFloat
        var rotation: Double = 0
        /// Higher sits on top.
        var z: Int = 0

        var angle: Angle { .degrees(rotation) }

        /// Within what the editor can produce. A board comes from another person's phone, so a
        /// hand-made one mustn't be able to make a viewer lay out an enormous canvas.
        var sane: Placement {
            Placement(x: min(1, max(0, x)), y: min(200, max(0, y)),
                      width: min(BatchBoard.widths.upperBound, max(BatchBoard.widths.lowerBound, width)),
                      rotation: min(BatchBoard.rotations.upperBound, max(BatchBoard.rotations.lowerBound, rotation)),
                      z: z)
        }
    }

    static let widths: ClosedRange<CGFloat> = 0.22...1
    static let rotations: ClosedRange<Double> = -30...30
    /// Space kept along the board's edges, as a fraction of its width.
    private static let margin: CGFloat = 0.03

    func placement(of photo: Photo) -> Placement? { placements[Self.key(photo.id)] }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// Every photo's place: its saved one, or the next free spot below the rest.
    static func resolved(_ board: BatchBoard?, photos: [Photo], insets: EdgeInsets, width: CGFloat) -> [UUID: Placement] {
        var result: [UUID: Placement] = [:]
        var unplaced: [Photo] = []
        for photo in photos {
            if let saved = board?.placement(of: photo) { result[photo.id] = saved.sane } else { unplaced.append(photo) }
        }
        guard !unplaced.isEmpty else { return result }
        let placed = photos.filter { result[$0.id] != nil }
        let bottom = placed.map { photo -> CGFloat in
            let place = result[photo.id]!
            return place.y + bounds(of: photo, at: place, insets: insets, boardWidth: width).height / 2
        }.max() ?? margin
        let topZ = (result.values.map(\.z).max() ?? 0) + 1
        for (photo, place) in tidy(unplaced, insets: insets, width: width, from: bottom + (placed.isEmpty ? 0 : margin), z: topZ) {
            result[photo] = place
        }
        return result
    }

    /// A loose two-column layout, used when a board starts and for "Tidy up". A slight tilt per
    /// photo, the same every time, so it reads as prints on a board rather than a grid.
    static func tidy(_ photos: [Photo], insets: EdgeInsets, width: CGFloat, from top: CGFloat = margin, z: Int = 0) -> [UUID: Placement] {
        let printWidth: CGFloat = 0.46
        var bottoms: [CGFloat] = [top, top]
        var result: [UUID: Placement] = [:]
        for (index, photo) in photos.enumerated() {
            var rng = SeededRandom(seed: photo.id)
            let column = bottoms[0] <= bottoms[1] ? 0 : 1
            var place = Placement(x: column == 0 ? 0.26 : 0.74, y: 0, width: printWidth,
                                  rotation: rng.next(in: -2.5...2.5), z: z + index)
            let box = bounds(of: photo, at: place, insets: insets, boardWidth: width)
            place.y = bottoms[column] + box.height / 2
            bottoms[column] += box.height + margin
            result[photo.id] = place
        }
        return result
    }

    /// The width of the photo itself in points: the print's width less its frame.
    static func imageWidth(_ place: Placement, insets: EdgeInsets, boardWidth: CGFloat) -> CGFloat {
        max(20, place.width * boardWidth - insets.leading - insets.trailing)
    }

    /// The print's size in points, frame included, before it's turned.
    static func printSize(of photo: Photo, at place: Placement, insets: EdgeInsets, boardWidth: CGFloat) -> CGSize {
        let image = imageWidth(place, insets: insets, boardWidth: boardWidth)
        return CGSize(width: image + insets.leading + insets.trailing,
                      height: image / photo.aspectRatio + insets.top + insets.bottom)
    }

    /// How much room the turned print takes, as fractions of the board's width.
    static func bounds(of photo: Photo, at place: Placement, insets: EdgeInsets, boardWidth: CGFloat) -> CGSize {
        let size = printSize(of: photo, at: place, insets: insets, boardWidth: boardWidth)
        let c = abs(cos(place.angle.radians)), s = abs(sin(place.angle.radians))
        return CGSize(width: (size.width * c + size.height * s) / boardWidth,
                      height: (size.width * s + size.height * c) / boardWidth)
    }

    /// Keeps a print whole: no wider than the board once turned, and inside its left, right and
    /// top edges. The bottom is open because the board grows.
    static func clamped(_ place: Placement, photo: Photo, insets: EdgeInsets, boardWidth: CGFloat) -> Placement {
        var place = place
        place.rotation = min(rotations.upperBound, max(rotations.lowerBound, place.rotation))
        place.width = min(widths.upperBound, max(widths.lowerBound, place.width))
        var box = bounds(of: photo, at: place, insets: insets, boardWidth: boardWidth)
        // Shrink a little at a time: the frame doesn't scale, so the size can't be solved directly.
        while box.width > 1, place.width > widths.lowerBound {
            place.width = max(widths.lowerBound, place.width - 0.01)
            box = bounds(of: photo, at: place, insets: insets, boardWidth: boardWidth)
        }
        let half = min(0.5, box.width / 2)
        place.x = min(1 - half, max(half, place.x))
        place.y = max(box.height / 2, place.y)
        return place
    }

    /// How tall the board is, in points.
    static func height(of photos: [Photo], placements: [UUID: Placement], insets: EdgeInsets, width: CGFloat) -> CGFloat {
        let bottom = photos.compactMap { photo -> CGFloat? in
            guard let place = placements[photo.id] else { return nil }
            return place.y + bounds(of: photo, at: place, insets: insets, boardWidth: width).height / 2
        }.max() ?? 0
        return (bottom + margin) * width
    }
}

/// Decodes to nil rather than failing when a value is one this build can't read, so a newer
/// build's arrangement can't take a whole feed down with it.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    init(_ value: Value?) { self.value = value }
}
