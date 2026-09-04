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

    init() {
        // Task 15C: once-per-process launch + daily fallback scheduling.
        // Async so app construction / initial UI presentation is not delayed;
        // startLifecycle() itself is idempotent for the process lifetime.
        Task { @MainActor in
            AutomaticBackupScheduler.shared.startLifecycle()
        }
    }

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
