import SwiftUI

@main
struct StrewnApp: App {
    @State private var model = AppModel(backend: AppModel.makeBackend())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.load() }
        }
    }
}
