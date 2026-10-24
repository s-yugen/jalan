import SwiftUI

@main
struct JalanApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
        }
    }
}
