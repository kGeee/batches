import SwiftUI

@main
struct StrewnApp: App {
    @UIApplicationDelegateAdaptor(PushNotifications.self) private var push
    // The Duo preview (debug builds, see DuoPreview) always runs on sample data.
    @State private var model = AppModel(backend: DuoPreview.asked == nil ? AppModel.makeBackend() : MockBackend())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    model.push = push
                    push.attach(to: model)
                    await model.load()
                }
                .duoPreviewIfAsked()
        }
    }
}
