import SwiftUI

/// A stand-in for the iPhone Duo simulator, which needs Xcode 27.1. Debug builds only.
///
/// Launch on an iPad simulator (built with TARGETED_DEVICE_FAMILY=1,2 so there is room) with
/// `-duoPreview outer`, `inner` or `innerLandscape`, and the app is drawn in a window the size
/// of that screen with that screen's size classes, on sample data.
///
/// The sizes are the published pixel sizes divided by 3; Apple hasn't published point sizes, and
/// the safe areas here are guesses. It shows how the layouts respond, not the exact pixels:
/// sheets and covers still use the whole iPad. Delete this once the real simulator is installed.
enum DuoPreview: String {
    case outer, inner, innerLandscape

    #if DEBUG
    static let asked = UserDefaults.standard.string(forKey: "duoPreview").flatMap(DuoPreview.init)
    #else
    static let asked: DuoPreview? = nil
    #endif

    var size: CGSize {
        switch self {
        case .outer: CGSize(width: 466, height: 678)            // 1398 × 2034 px
        case .inner: CGSize(width: 626, height: 890)            // 1878 × 2670 px
        case .innerLandscape: CGSize(width: 890, height: 626)
        }
    }
    /// The outside behaves like any iPhone; the inside is regular both ways.
    var horizontal: UserInterfaceSizeClass { self == .outer ? .compact : .regular }
    var title: String {
        switch self {
        case .outer: "iPhone Duo, closed · compact width · about 466 × 678 pt"
        case .inner: "iPhone Duo, open · regular width · about 626 × 890 pt"
        case .innerLandscape: "iPhone Duo, open, turned · regular width · about 890 × 626 pt"
        }
    }
}

extension View {
    /// Draws the app inside a Duo-sized window when launched with `-duoPreview`.
    @ViewBuilder
    func duoPreviewIfAsked() -> some View {
        #if DEBUG
        if let pose = DuoPreview.asked {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 14) {
                    self
                        .safeAreaPadding(EdgeInsets(top: 44, leading: 0, bottom: 20, trailing: 0))
                        .frame(width: pose.size.width, height: pose.size.height)
                        .environment(\.horizontalSizeClass, pose.horizontal)
                        .environment(\.verticalSizeClass, .regular)
                        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                    Text(pose.title).font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.7))
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
