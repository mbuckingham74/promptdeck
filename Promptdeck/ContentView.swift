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

private func parseTags(_ raw: String) -> [String] {
    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

struct PromptLibraryView: View {
    @Query(sort: \PromptEntry.title) private var prompts: [PromptEntry]
    @State private var selection: UUID?
    @State private var showingNewPrompt = false

    var body: some View {
        Group {
            if prompts.isEmpty {
                VStack(spacing: 8) {
                    Text("Prompts")
                        .font(.title)
                    Text("Saved prompts will appear here.")
                        .foregroundStyle(.secondary)
                }
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
            }
        }
        .navigationTitle("Prompts")
        .toolbar {
            Button {
                showingNewPrompt = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingNewPrompt) {
            NewPromptView()
        }
    }
}

struct NewPromptView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var promptBody = ""
    @State private var tagsString = ""

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $promptBody)
                    .frame(minHeight: 120)
                TextField("Tags (e.g. vps, sysadmin)", text: $tagsString, prompt: Text("vps, sysadmin"))
            }
            .navigationTitle("New Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = PromptEntry(title: title, body: promptBody, tags: parseTags(tagsString))
                        modelContext.insert(entry)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

struct CommandLibraryView: View {
    @Query(sort: \CommandEntry.title) private var commands: [CommandEntry]
    @State private var selection: UUID?
    @State private var showingNewCommand = false

    var body: some View {
        Group {
            if commands.isEmpty {
                VStack(spacing: 8) {
                    Text("Commands")
                        .font(.title)
                    Text("Saved commands will appear here.")
                        .foregroundStyle(.secondary)
                }
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
            }
        }
        .navigationTitle("Commands")
        .toolbar {
            Button {
                showingNewCommand = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingNewCommand) {
            NewCommandView()
        }
    }
}

struct NewCommandView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var command = ""
    @State private var explanation = ""
    @State private var tagsString = ""
    @State private var platform: CommandPlatform = .macOS
    @State private var isDangerous = false

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $command)
                    .monospaced()
                    .frame(minHeight: 80)
                TextEditor(text: $explanation)
                    .frame(minHeight: 80)
                TextField("Tags (e.g. vps, sysadmin)", text: $tagsString, prompt: Text("vps, sysadmin"))
                Picker("Platform", selection: $platform) {
                    Text("macOS").tag(CommandPlatform.macOS)
                    Text("Linux").tag(CommandPlatform.Linux)
                    Text("Both").tag(CommandPlatform.Both)
                }
                Toggle("Dangerous command", isOn: $isDangerous)
            }
            .navigationTitle("New Command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = CommandEntry(
                            title: title,
                            command: command,
                            explanation: explanation,
                            tags: parseTags(tagsString),
                            platform: platform,
                            isDangerous: isDangerous
                        )
                        modelContext.insert(entry)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
