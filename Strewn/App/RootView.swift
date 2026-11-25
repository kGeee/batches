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
            case .needsFirstBatch:
                FirstBatchOnboardingView()
            case .signedIn:
                SignedInTabs()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.auth)
        .fullScreenCover(isPresented: $model.showsTour) {
            WelcomeTourView(finishTitle: model.auth == .needsFirstBatch ? "Start your first batch" : "Get started") {
                model.finishTour()
            }
        }
        .readsWindowLayout()
        .onOpenURL { url in Task { await model.open(url) } }
        .fullScreenCover(item: $model.linkedPile) { LinkedPileView(pile: $0) }
        .sheet(item: $model.linkedUser) { LinkedUserSheet(user: $0) }
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
    @Environment(\.windowLayout) private var layout
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
            if !layout.usesSideRail && !chrome.barHidden && !keyboardUp {
                bar(.horizontal).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // With room to spare (an open iPhone Duo) the bar stands down the side instead, and the
        // keyboard doesn't reach it there. Padding, not a safe area inset: a navigation stack
        // doesn't pass a leading inset on to its content.
        .padding(.leading, showsRail ? 84 : 0)
        .background(DeskMatBackground())
        .overlay(alignment: .leading) {
            if showsRail { bar(.vertical).transition(.move(edge: .leading).combined(with: .opacity)) }
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
        .onChange(of: model.wantsActivityTab) { _, wanted in
            guard wanted else { return }
            model.wantsActivityTab = false
            chrome.showsActivity = true
            chrome.tab = .friends
        }
        // The bar would otherwise ride up on top of the keyboard.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }

    private var showsRail: Bool { layout.usesSideRail && !chrome.barHidden }

    private func bar(_ axis: Axis) -> some View {
        FloatingTabBar(tab: $chrome.tab, axis: axis, showsShoot: Self.showsShoot, unseen: model.unseenActivity.count) {
            chrome.tab = .desk
            showNewPile = true
        }
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
    var axis = Axis.horizontal
    let showsShoot: Bool
    let unseen: Int
    let onNewBatch: () -> Void

    private var vertical: Bool { axis == .vertical }

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 22))
        stack {
            item(.desk, "Desk")
            if showsShoot { item(.shoot, "Shoot") }
            Button(action: onNewBatch) {
                Image(systemName: "plus").font(.title3.weight(.light)).foregroundStyle(Color.primary)
                    .frame(width: 46, height: 46)
                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1.2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New batch")
            item(.friends, "Friends", badge: unseen)
        }
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .frame(width: vertical ? 72 : nil, height: vertical ? nil : 64)
        .padding(.bottom, vertical ? 0 : 4)
        // The fog thickens towards the edge, so photos fade out under the bar instead of meeting a pill.
        .background {
            LinearGradient(stops: [.init(color: Color.mat.opacity(0), location: 0), .init(color: Color.mat.opacity(0.92), location: 0.45),
                                   .init(color: Color.mat, location: 1)],
                           startPoint: vertical ? .trailing : .top, endPoint: vertical ? .leading : .bottom)
                .padding(vertical ? .trailing : .top, -28)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private func item(_ value: AppChrome.Tab, _ title: String, badge: Int = 0) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Circle().fill(Color.strewnAccent).frame(width: 7, height: 7).offset(x: 9, y: -1)
                    }
                }
                .frame(width: vertical ? 72 : 76, height: 48)
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

private struct LinkedUserSheet: View {
    let user: User
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProfileView(user: user)
                .navigationDestination(for: User.self) { ProfileView(user: $0) }
                .navigationDestination(for: FollowListRoute.self) { FollowListView(route: $0) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
        }
        .tint(.strewnAccent)
    }
}
