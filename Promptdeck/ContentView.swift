import SwiftData
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
    @Query(sort: \PromptEntry.title) private var prompts: [PromptEntry]
    @State private var selection: UUID?

    var body: some View {
        if prompts.isEmpty {
            VStack(spacing: 8) {
                Text("Prompts")
                    .font(.title)
                Text("Saved prompts will appear here.")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Prompts")
        } else {
            List(prompts, selection: $selection) { prompt in
                VStack(alignment: .leading) {
                    Text(prompt.title)
                    Text(verbatim: prompt.body)
                        .lineLimit(2)
                    if !prompt.tags.isEmpty {
                        Text(verbatim: prompt.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(prompt.id)
            }
            .navigationTitle("Prompts")
        }
    }
}

struct CommandLibraryView: View {
    @Query(sort: \CommandEntry.title) private var commands: [CommandEntry]
    @State private var selection: UUID?

    var body: some View {
        if commands.isEmpty {
            VStack(spacing: 8) {
                Text("Commands")
                    .font(.title)
                Text("Saved commands will appear here.")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Commands")
        } else {
            List(commands, selection: $selection) { command in
                VStack(alignment: .leading) {
                    Text(command.title)
                    Text(verbatim: command.command)
                        .monospaced()
                        .lineLimit(1)
                    if !command.explanation.isEmpty {
                        Text(verbatim: command.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !command.tags.isEmpty {
                        Text(verbatim: command.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(command.id)
            }
            .navigationTitle("Commands")
        }
    }
}

#Preview {
    ContentView()
}
