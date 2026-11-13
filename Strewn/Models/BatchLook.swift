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

    /// A loose two-column layout, used when a board starts and for "Tidy up". Prints start
    /// straight; the owner can tilt any of them in the editor.
    static func tidy(_ photos: [Photo], insets: EdgeInsets, width: CGFloat, from top: CGFloat = margin, z: Int = 0) -> [UUID: Placement] {
        let printWidth: CGFloat = 0.46
        var bottoms: [CGFloat] = [top, top]
        var result: [UUID: Placement] = [:]
        for (index, photo) in photos.enumerated() {
            let column = bottoms[0] <= bottoms[1] ? 0 : 1
            var place = Placement(x: column == 0 ? 0.26 : 0.74, y: 0, width: printWidth,
                                  rotation: 0, z: z + index)
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

/// What a batch's photos sit on. Stored in its own column (collections.background) because older
/// builds can't decode a FrameStyle.wall they don't know; `legacyWall` is what those builds get.
enum BatchBackground: Hashable, Codable {
    case light, dark, desk, kraft
    /// The owner's own colour, as 0...1 RGB.
    case custom(red: Double, green: Double, blue: Double)

    static let presets: [BatchBackground] = [.light, .dark, .desk, .kraft]

    init?(raw: String) {
        switch raw {
        case "light": self = .light
        case "dark": self = .dark
        case "desk": self = .desk
        case "kraft": self = .kraft
        default:
            guard raw.wholeMatch(of: #/#[0-9a-f]{6}/#) != nil, let value = UInt32(raw.dropFirst(), radix: 16) else { return nil }
            self = .custom(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255)
        }
    }

    init(_ wall: FrameStyle.Wall) {
        switch wall {
        case .light: self = .light
        case .dark: self = .dark
        case .desk: self = .desk
        }
    }

    /// A colour from the picker, rounded to what's stored.
    init(_ color: Color) {
        let resolved = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in (min(1, max(0, Double(v))) * 255).rounded() / 255 }
        self = .custom(red: clamp(r), green: clamp(g), blue: clamp(b))
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = BatchBackground(raw: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown background \(raw)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var raw: String {
        switch self {
        case .light: "light"
        case .dark: "dark"
        case .desk: "desk"
        case .kraft: "kraft"
        case .custom(let r, let g, let b):
            String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
    }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .desk: "Linen"
        case .kraft: "Kraft"
        case .custom: "Custom"
        }
    }

    var isCustom: Bool { if case .custom = self { true } else { false } }

    /// Amber controls disappear into kraft and into colours near it, so on those the controls are
    /// plain black or white instead.
    var neutralControls: Bool {
        switch self {
        case .kraft, .custom: true
        default: false
        }
    }

    /// Kraft paper: a warm, light brown card.
    static let kraftColor = Color(red: 0.80, green: 0.69, blue: 0.53)

    var color: Color? {
        switch self {
        case .light: Color(white: 0.953)
        case .dark: Color(white: 0.07)
        case .desk: nil
        case .kraft: Self.kraftColor
        case .custom(let r, let g, let b): Color(red: r, green: g, blue: b)
        }
    }

    /// Text and controls follow the background, not the system: dark on light backgrounds, light on
    /// dark ones. Linen follows the system, as the desk does.
    var scheme: ColorScheme? {
        switch self {
        case .light, .kraft: .light
        case .dark: .dark
        case .desk: nil
        case .custom(let r, let g, let b):
            // Relative luminance, so mid greys and saturated colours pick sensibly.
            0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5 ? .light : .dark
        }
    }

    /// The nearest wall builds 7 and 8 know, kept in the frame for them.
    var legacyWall: FrameStyle.Wall {
        switch self {
        case .light, .kraft: .light
        case .dark: .dark
        case .desk: .desk
        case .custom: scheme == .dark ? .dark : .light
        }
    }

    @ViewBuilder var view: some View {
        if let color { color } else { DeskMatBackground() }
    }
}

extension PhotoCollection {
    /// What the batch is shown on. A roll of film is always on a dark wall, like a light table
    /// with the lights down.
    var backdrop: BatchBackground {
        if frame.kind == .filmStrip { return .dark }
        return background ?? BatchBackground(frame.wall)
    }
}

/// Likes and comments on one photo, as the signed-in person sees them: people on the other side of
/// a block aren't counted.
struct PhotoReactions: Hashable {
    var likeCount = 0
    var likedByMe = false
    var commentCount = 0
}

/// Something someone else did to one of your photos: a like or a comment. Shown on the desk and
/// under Friends › Activity.
struct ActivityItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case like, comment(String) }
    let id: String
    let kind: Kind
    let actor: User?
    let actorID: UUID
    let photoID: UUID
    let at: Date

    var isLike: Bool { kind == .like }
}

/// A comment on a photo. Comments can't be edited; their author and the batch's owner can remove
/// them, and anyone who sees them can report them.
struct PhotoComment: Identifiable, Hashable {
    let id: UUID
    let photoID: UUID
    let author: User?
    let authorID: UUID
    let body: String
    let createdAt: Date

    static let maxLength = 500
}
