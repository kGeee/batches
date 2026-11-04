import SwiftUI

/// How a pile's photos are framed in the gallery. Chosen by the owner and stored with the
/// collection, so every viewer sees the pile the same way.
struct FrameStyle: Hashable, Codable {
    var kind: Kind = .whiteBorder
    /// Base border thickness in points. Each kind scales it (polaroid uses a deeper bottom).
    var borderWidth: CGFloat = 14
    var wall: Wall = .light
    var layout: Layout = .single
    /// Film strip only: which way the roll runs when opened. Optional so older saved
    /// frames decode; nil means down.
    var rollDirection: RollDirection?

    var roll: RollDirection { rollDirection ?? .down }

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case none, whiteBorder, thinBlack, polaroid, filmStrip, galleryMat
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .whiteBorder: "White"
            case .thinBlack: "Thin black"
            case .polaroid: "Polaroid"
            case .filmStrip: "Film strip"
            case .galleryMat: "Gallery mat"
            }
        }
    }

    enum Wall: String, Codable, CaseIterable { case light, dark, desk }
    enum Layout: String, Codable, CaseIterable { case single, twoColumn }
    enum RollDirection: String, Codable, CaseIterable { case down, sideways }

    /// Total padding the frame adds around the photo, used to size the photo so the whole
    /// framed print fits on screen.
    var insets: EdgeInsets {
        let w = borderWidth
        switch kind {
        case .none: return EdgeInsets()
        case .whiteBorder: return EdgeInsets(top: w, leading: w, bottom: w, trailing: w)
        case .thinBlack: return EdgeInsets(top: w * 0.25, leading: w * 0.25, bottom: w * 0.25, trailing: w * 0.25)
        case .polaroid: return EdgeInsets(top: w, leading: w, bottom: w * 3.6 + 6, trailing: w)
        case .filmStrip: return EdgeInsets(top: w * 1.5 + 12, leading: 8, bottom: w * 1.5 + 12, trailing: 8)
        case .galleryMat: return EdgeInsets(top: w * 1.8, leading: w * 1.8, bottom: w * 1.8, trailing: w * 1.8)
        }
    }
}
