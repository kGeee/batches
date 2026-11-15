import SwiftUI

/// How much room the window has, and what the screens do with it. Decided once at the root from
/// the size class, never from the device or its orientation, so the same code covers a folded
/// iPhone Duo (compact, like any iPhone), an unfolded one (regular), and whatever comes next.
///
/// Screens read this instead of `horizontalSizeClass`: a navigation stack can hand its content a
/// size class of its own, and this stays whatever the root decided.
struct WindowLayout: Equatable {
    /// Regular width: the inside of an iPhone Duo.
    var isWide = false

    /// Batches across a grid: the desk, a group, a profile.
    var gridColumns: Int { isWide ? 3 : 2 }
    /// Cards across the Friends feed.
    var feedColumns: Int { isWide ? 2 : 1 }
    /// Photos across a two-column batch.
    var masonryColumns: Int { isWide ? 3 : 2 }
    /// The floating bar stands down the leading edge, leaving the full height to the photos.
    var usesSideRail: Bool { isWide }
    /// Text and rows stop growing here and sit centered, so a line stays readable.
    var readableWidth: CGFloat { 620 }

    func grid(spacing: CGFloat = 14, alignment: Alignment = .top) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: alignment), count: gridColumns)
    }

    func feedGrid(spacing: CGFloat = 14) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: feedColumns)
    }
}

extension EnvironmentValues {
    @Entry var windowLayout = WindowLayout()
}

extension View {
    /// Works out the window's layout from its size class and hands it to everything inside.
    func readsWindowLayout() -> some View { modifier(WindowLayoutReader()) }
}

private struct WindowLayoutReader: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontal

    func body(content: Content) -> some View {
        let layout = WindowLayout(isWide: horizontal == .regular)
        content
            .environment(\.windowLayout, layout)
            // Opening or closing the phone resizes the window; the grids settle rather than jump.
            .animation(.snappy(duration: 0.3), value: layout)
    }
}
