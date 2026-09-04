import SwiftData
import SwiftUI

@main
struct PromptdeckApp: App {
    static let sharedContainer: ModelContainer = {
        do {
            return try ModelContainer(for: PromptEntry.self, CommandEntry.self)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(PromptdeckApp.sharedContainer)
        Settings {
            BackupSettingsView()
        }
        .modelContainer(PromptdeckApp.sharedContainer)
    }
}
