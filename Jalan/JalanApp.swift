import SwiftUI

@main
struct JalanApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
        }
    }
}
