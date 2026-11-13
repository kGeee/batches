import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.auth {
            case .loading:
                ZStack { DeskMatBackground(); ProgressView() }
            case .signedOut:
                SignInView()
            case .needsProfile:
                CreateProfileView()
            case .signedIn:
                SignedInTabs()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.auth)
        .onOpenURL { url in Task { await model.open(url) } }
        .fullScreenCover(item: $model.linkedPile) { LinkedPileView(pile: $0) }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// What the two main screens share with the bar under them: which one is showing, and whether
/// something (an open batch, say) has taken the whole screen.
@MainActor
@Observable
final class AppChrome {
    enum Tab: Hashable { case desk, shoot, friends }
    var tab = Tab.desk
    /// Set to open Friends on its Activity list; Friends clears it.
    var showsActivity = false
    private var covers: Set<String> = []

    var barHidden: Bool { !covers.isEmpty }

    func setCovered(_ covered: Bool, by key: String) {
        if covered { covers.insert(key) } else { covers.remove(key) }
    }
}

extension View {
    /// Hides the floating bar while `covered` is true, such as while a batch is open full screen.
    func coversTabBar(_ covered: Bool, key: String) -> some View { modifier(CoversTabBar(covered: covered, key: key)) }
}

private struct CoversTabBar: ViewModifier {
    let covered: Bool
    let key: String
    @Environment(AppChrome.self) private var chrome: AppChrome?

    func body(content: Content) -> some View {
        content
            .onChange(of: covered, initial: true) { _, now in chrome?.setCovered(now, by: key) }
            .onDisappear { chrome?.setCovered(false, by: key) }
    }
}

private struct SignedInTabs: View {
    /// Shoot is switched off for now. The camera code is all still here; set this back to
    /// true to bring the tab back.
    static let showsShoot = false
    @Environment(AppModel.self) private var model
    @State private var chrome = AppChrome()
    /// Made the first time you open Shoot, then kept, so the color pipeline isn't rebuilt
    /// and your look and dials survive switching tabs. The session itself stops off-tab.
    @State private var camera: CameraModel?
    @State private var showNewPile = false
    @State private var keyboardUp = false

    var body: some View {
        // Both screens stay alive, so each keeps its scroll position and anything it has open.
        ZStack {
            page(.desk) { DeskView() }
            // The camera and its color pipeline start only when you open Shoot, so launch stays
            // fast and the desk still opens if the camera can't start.
            if Self.showsShoot {
                page(.shoot) {
                    if chrome.tab == .shoot, let camera { CameraScreen(camera: camera) } else { Color.black.ignoresSafeArea() }
                }
            }
            page(.friends) { FriendsFeedView() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !chrome.barHidden && !keyboardUp {
                FloatingTabBar(tab: $chrome.tab, showsShoot: Self.showsShoot, unseen: model.unseenActivity.count) {
                    chrome.tab = .desk
                    showNewPile = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: chrome.barHidden)
        .animation(.snappy(duration: 0.2), value: keyboardUp)
        .environment(chrome)
        .tint(.strewnAccent)
        .sheet(isPresented: $showNewPile) { NewPileSheet() }
        .sensoryFeedback(.selection, trigger: chrome.tab)
        .onChange(of: chrome.tab) { _, tab in
            if tab == .shoot, camera == nil { camera = CameraModel() }
        }
        // The bar would otherwise ride up on top of the keyboard.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }

    private func page<Content: View>(_ tab: AppChrome.Tab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(chrome.tab == tab ? 1 : 0)
            .allowsHitTesting(chrome.tab == tab)
            .accessibilityHidden(chrome.tab != tab)
    }
}

/// The bar that floats over the desk and the feed: the two screens, with New batch between them
/// where a thumb reaches it.
private struct FloatingTabBar: View {
    @Binding var tab: AppChrome.Tab
    let showsShoot: Bool
    let unseen: Int
    let onNewBatch: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            item(.desk, "Desk", "rectangle.stack.fill")
            if showsShoot { item(.shoot, "Shoot", "camera.aperture") }
            Button(action: onNewBatch) {
                Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(Color.onAccent)
                    .frame(width: 52, height: 52)
                    .background(Color.strewnAccent, in: Circle())
                    .shadow(color: Color.strewnAccent.opacity(0.45), radius: 7, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New batch")
            item(.friends, "Friends", "person.2.fill", badge: unseen)
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func item(_ value: AppChrome.Tab, _ title: String, _ symbol: String, badge: Int = 0) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Circle().fill(Color.strewnAccent).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.paper, lineWidth: 1.5))
                                .offset(x: 6, y: -2)
                        }
                    }
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? Color.strewnAccent : Color.secondary)
            .frame(width: 84, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) new" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A pile opened from a strewn://pile link.
private struct LinkedPileView: View {
    let pile: PhotoCollection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Namespace private var space

    var body: some View {
        GalleryView(collection: pile, namespace: space, isOwner: pile.ownerID == model.me?.id,
                    startPhotoID: model.linkedPhotoID) { dismiss() }
    }
}
