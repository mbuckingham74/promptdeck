import SwiftUI

enum LibrarySelection: String, CaseIterable, Identifiable {
    case prompts
    case commands

    var id: Self { self }
}

struct ContentView: View {
    @State private var selection: LibrarySelection? = .prompts

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Prompts", systemImage: "text.quote")
                    .tag(LibrarySelection.prompts)
                Label("Commands", systemImage: "terminal")
                    .tag(LibrarySelection.commands)
            }
        } detail: {
            switch selection ?? .prompts {
            case .prompts:
                PromptLibraryView()
            case .commands:
                CommandLibraryView()
            }
        }
    }
}

struct PromptLibraryView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Prompts")
                .font(.title)
            Text("Saved prompts will appear here.")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Prompts")
    }
}

struct CommandLibraryView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Commands")
                .font(.title)
            Text("Saved commands will appear here.")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Commands")
    }
}

#Preview {
    ContentView()
}
