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

private struct SignedInTabs: View {
    enum Tab { case desk, shoot, friends }
    /// Shoot is switched off for now. The camera code is all still here; set this back to
    /// true to bring the tab back.
    static let showsShoot = false
    @State private var tab = Tab.desk
    /// Made the first time you open Shoot, then kept, so the color pipeline isn't rebuilt
    /// and your look and dials survive switching tabs. The session itself stops off-tab.
    @State private var camera: CameraModel?

    var body: some View {
        TabView(selection: $tab) {
            DeskView()
                .tabItem { Label("Desk", systemImage: "rectangle.stack") }
                .tag(Tab.desk)
            // The camera and its color pipeline start only when you open Shoot, so launch stays
            // fast and the desk still opens if the camera can't start.
            if Self.showsShoot {
                Group {
                    if tab == .shoot, let camera { CameraScreen(camera: camera) } else { Color.black.ignoresSafeArea() }
                }
                .tabItem { Label("Shoot", systemImage: "camera.aperture") }
                .tag(Tab.shoot)
            }
            FriendsFeedView()
                .tabItem { Label("Friends", systemImage: "person.2") }
                .tag(Tab.friends)
        }
        .tint(.strewnAccent)
        .onChange(of: tab) { _, tab in
            if tab == .shoot, camera == nil { camera = CameraModel() }
        }
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
