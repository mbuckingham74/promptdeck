import SwiftData
import SwiftUI

@main
struct PromptdeckApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [PromptEntry.self, CommandEntry.self])
    }
}
