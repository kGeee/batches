import SwiftUI

enum PullToDismiss {
    /// How far you pull down before letting go puts the pile back.
    static let threshold: CGFloat = 110
    /// Pull distance at which the shrink and fade are at their strongest.
    static let fullPull: CGFloat = 320
    /// A quick flick down closes too, even if it didn't travel far.
    static let flickVelocity: CGFloat = 900
}

extension View {
    /// Pull down while scrolled to the top of this scroll view to close it. Only a drag that
    /// starts at the top and heads down counts, so it never fights normal scrolling.
    /// `distance` follows the finger so the caller can shrink and fade as you pull; letting go
    /// early springs back.
    ///
    /// The pull is read from the finger, not the scroll view's overscroll: the overscroll
    /// reading drops back to 0 on alternate frames while the view is being transformed, so
    /// it reported no pull at the moment you let go. Needs iOS 18 to know the scroll is at
    /// the top; on iOS 17 the gallery header's own drag still closes the pile.
    func pullDownToDismiss(distance: Binding<CGFloat>, onDismiss: @escaping () -> Void) -> some View {
        modifier(PullDownToDismiss(distance: distance, onDismiss: onDismiss))
    }
}

private struct PullDownToDismiss: ViewModifier {
    @Binding var distance: CGFloat
    let onDismiss: () -> Void

    /// Scrolled to the very top. A Bool rather than the offset, so scrolling only updates this
    /// view when it crosses the top instead of on every frame.
    @State private var atTop = true
    @State private var pulling: Bool?          // nil until the drag picks a direction
    @State private var fired = false
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 1 } action: { _, top in
                    atTop = top
                }
                // Global space: the caller shrinks this view as you pull, which would
                // otherwise change the translation under a still finger.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged(changed)
                        .onEnded(ended)
                )
                // A drag the scroll view takes over ends without onEnded; don't leave the
                // photos shrunk.
                .onChange(of: dragging) { _, isDragging in
                    if !isDragging, pulling == true, !fired { settle(commit: distance > PullToDismiss.threshold) }
                    if !isDragging { pulling = nil }
                }
        } else {
            content
        }
    }

    private func changed(_ value: DragGesture.Value) {
        guard !fired else { return }
        let dy = value.translation.height
        if pulling == nil {
            pulling = atTop && dy > 0 && dy > abs(value.translation.width)
        }
        guard pulling == true else { return }
        // Scrolled into the content after all (pulled down, then pushed back up past the top).
        if !atTop {
            pulling = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { distance = 0 }
            return
        }
        distance = max(0, dy)
    }

    private func ended(_ value: DragGesture.Value) {
        defer { pulling = nil }
        guard pulling == true, !fired else { return }
        let velocity = value.velocity.height
        settle(commit: distance > PullToDismiss.threshold || (velocity > PullToDismiss.flickVelocity && distance > 24))
    }

    private func settle(commit: Bool) {
        if commit {
            fired = true
            onDismiss()
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { distance = 0 }
        }
    }
}
