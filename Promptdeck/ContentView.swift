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
    @State private var showingEditPrompt = false

    private var selectedPrompt: PromptEntry? {
        prompts.first(where: { $0.id == selection })
    }

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
            ToolbarItem {
                Button {
                    showingEditPrompt = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .disabled(selection == nil)
            }
            ToolbarItem {
                Button {
                    showingNewPrompt = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewPrompt) {
            PromptEditorView()
        }
        .sheet(isPresented: $showingEditPrompt) {
            if let selectedPrompt {
                PromptEditorView(entry: selectedPrompt)
            }
        }
    }
}

struct PromptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    private var entry: PromptEntry?
    @State private var title: String
    @State private var promptBody: String
    @State private var tagsString: String

    init(entry: PromptEntry? = nil) {
        self.entry = entry
        _title = State(initialValue: entry?.title ?? "")
        _promptBody = State(initialValue: entry?.body ?? "")
        _tagsString = State(initialValue: entry?.tags.joined(separator: ", ") ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEditing: Bool {
        entry != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $promptBody)
                    .frame(minHeight: 120)
                TextField("Tags (e.g. vps, sysadmin)", text: $tagsString, prompt: Text("vps, sysadmin"))
            }
            .navigationTitle(isEditing ? "Edit Prompt" : "New Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let entry {
                            entry.title = title
                            entry.body = promptBody
                            entry.tags = parseTags(tagsString)
                            entry.updatedAt = Date()
                        } else {
                            let newEntry = PromptEntry(title: title, body: promptBody, tags: parseTags(tagsString))
                            modelContext.insert(newEntry)
                        }
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
    @State private var showingEditCommand = false

    private var selectedCommand: CommandEntry? {
        commands.first(where: { $0.id == selection })
    }

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
            ToolbarItem {
                Button {
                    showingEditCommand = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .disabled(selection == nil)
            }
            ToolbarItem {
                Button {
                    showingNewCommand = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewCommand) {
            CommandEditorView()
        }
        .sheet(isPresented: $showingEditCommand) {
            if let selectedCommand {
                CommandEditorView(entry: selectedCommand)
            }
        }
    }
}

struct CommandEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    private var entry: CommandEntry?
    @State private var title: String
    @State private var command: String
    @State private var explanation: String
    @State private var tagsString: String
    @State private var platform: CommandPlatform
    @State private var isDangerous: Bool

    init(entry: CommandEntry? = nil) {
        self.entry = entry
        _title = State(initialValue: entry?.title ?? "")
        _command = State(initialValue: entry?.command ?? "")
        _explanation = State(initialValue: entry?.explanation ?? "")
        _tagsString = State(initialValue: entry?.tags.joined(separator: ", ") ?? "")
        _platform = State(initialValue: entry?.platform ?? .macOS)
        _isDangerous = State(initialValue: entry?.isDangerous ?? false)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEditing: Bool {
        entry != nil
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
            .navigationTitle(isEditing ? "Edit Command" : "New Command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let entry {
                            entry.title = title
                            entry.command = command
                            entry.explanation = explanation
                            entry.tags = parseTags(tagsString)
                            entry.platform = platform
                            entry.isDangerous = isDangerous
                            entry.updatedAt = Date()
                        } else {
                            let newEntry = CommandEntry(
                                title: title,
                                command: command,
                                explanation: explanation,
                                tags: parseTags(tagsString),
                                platform: platform,
                                isDangerous: isDangerous
                            )
                            modelContext.insert(newEntry)
                        }
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
