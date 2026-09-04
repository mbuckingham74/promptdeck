import AppKit
import Combine
import SwiftData
import SwiftUI

enum LibrarySelection: String, CaseIterable, Identifiable {
    case prompts
    case commands

    var id: Self { self }
}

struct ContentView: View {
    @State private var selection: LibrarySelection? = .prompts
    @State private var showingShortcuts = false
    @State private var resetNonce = 0

    private func switchTo(_ target: LibrarySelection) {
        selection = target
        resetNonce += 1
    }

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
                PromptLibraryView(
                    librarySelection: $selection,
                    resetNonce: $resetNonce,
                    showingShortcuts: $showingShortcuts
                )
            case .commands:
                CommandLibraryView(
                    librarySelection: $selection,
                    resetNonce: $resetNonce,
                    showingShortcuts: $showingShortcuts
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Show Prompts") { switchTo(.prompts) }
                    .keyboardShortcut("1", modifiers: .command)
                    .hidden()
                Button("Show Commands") { switchTo(.commands) }
                    .keyboardShortcut("2", modifiers: .command)
                    .hidden()
                Button("Show Shortcuts") { showingShortcuts = true }
                    .keyboardShortcut("?", modifiers: .command)
                    .hidden()
            }
        }
        .sheet(isPresented: $showingShortcuts) {
            ShortcutsHelpView()
        }
    }
}

private func parseTags(_ raw: String) -> [String] {
    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private func copyToPasteboard(_ text: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
}

// Tiny AppKit bridge: `.searchable` puts the search field in the toolbar,
// outside the library view hierarchy, so SwiftUI `.onKeyPress` never sees
// keys pressed while search is focused. A local keyDown monitor fires first
// regardless of focus, so arrows/Return/Escape work from both search and list.
// All other keys (typing, Cmd shortcuts) pass through untouched.
private struct LibraryKeyMonitor: NSViewRepresentable {
    var onEvent: (NSEvent) -> Bool

    final class Coordinator {
        var onEvent: (NSEvent) -> Bool = { _ in false }
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.onEvent = onEvent
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            if coordinator?.onEvent(event) == true {
                return nil
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
        coordinator.monitor = nil
    }
}

struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            List {
                LabeledContent("⌘1", value: "Prompts")
                LabeledContent("⌘2", value: "Commands")
                LabeledContent("↓", value: "Move into results / next result")
                LabeledContent("↑", value: "Previous result / return to clean search from first result")
                LabeledContent("Return", value: "Copy selected prompt or command, then hide Promptdeck")
                LabeledContent("Esc", value: "Cancel, reset, and hide Promptdeck")
                LabeledContent("⌘?", value: "Show keyboard shortcuts")
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }
}

struct PromptRowView: View {
    var prompt: PromptEntry
    var onCopy: () -> Void

    var body: some View {
        HStack {
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
            Spacer()
            Button {
                prompt.isFavorite.toggle()
            } label: {
                Image(systemName: prompt.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(prompt.isFavorite ? "Unfavorite prompt" : "Favorite prompt")
            .help(prompt.isFavorite ? "Unfavorite prompt" : "Favorite prompt")
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy prompt")
            .help("Copy prompt")
        }
        .tag(prompt.id)
    }
}

struct PromptLibraryView: View {
    @Binding var librarySelection: LibrarySelection?
    @Binding var resetNonce: Int
    @Binding var showingShortcuts: Bool
    @Query(sort: \PromptEntry.title) private var prompts: [PromptEntry]
    @State private var selection: UUID?
    @State private var showingNewPrompt = false
    @State private var showingEditPrompt = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    init(
        librarySelection: Binding<LibrarySelection?> = .constant(.prompts),
        resetNonce: Binding<Int> = .constant(0),
        showingShortcuts: Binding<Bool> = .constant(false)
    ) {
        _librarySelection = librarySelection
        _resetNonce = resetNonce
        _showingShortcuts = showingShortcuts
    }

    private var filteredPrompts: [PromptEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [PromptEntry]
        if query.isEmpty {
            base = prompts
        } else {
            base = prompts.filter { prompt in
                prompt.title.localizedCaseInsensitiveContains(query)
                    || prompt.body.localizedCaseInsensitiveContains(query)
                    || prompt.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
        }
        return base.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var selectedPrompt: PromptEntry? {
        filteredPrompts.first(where: { $0.id == selection })
    }

    @discardableResult
    private func copyPrompt(_ prompt: PromptEntry) -> Bool {
        if copyToPasteboard(prompt.body) {
            prompt.lastCopiedAt = Date()
            return true
        }
        return false
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            focusSearchNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusSearchNow()
        }
    }

    private func focusSearchNow() {
        searchFocused = true
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let searchItem = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first else {
            return
        }
        searchItem.beginSearchInteraction()
        window.makeFirstResponder(searchItem.searchField)
    }

    private func resetQueryAndSelection() {
        searchText = ""
        selection = nil
    }

    private func switchLibrary(to target: LibrarySelection) {
        librarySelection = target
        resetNonce += 1
        resetQueryAndSelection()
        focusSearch()
    }

    private func cancelAndHide() {
        resetQueryAndSelection()
        NSApp.hide(nil)
    }

    private func handleDown() {
        let ids = filteredPrompts.map(\.id)
        if let current = selection, let index = ids.firstIndex(of: current) {
            if index + 1 < ids.count {
                selection = ids[index + 1]
            }
        } else if let first = ids.first {
            selection = first
        }
    }

    private func handleUp() {
        let ids = filteredPrompts.map(\.id)
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            return
        }
        if index == 0 {
            resetQueryAndSelection()
            focusSearch()
        } else {
            selection = ids[index - 1]
        }
    }

    private func handleReturnCopy() {
        guard let target = selectedPrompt else {
            return
        }
        if copyPrompt(target) {
            resetQueryAndSelection()
            NSApp.hide(nil)
        }
    }

    // Local-monitor entry point. Returns true when the key was handled
    // (swallow it) or false to let it pass through untouched (typing,
    // Cmd shortcuts, keys while an editor/help sheet is open).
    private func handleMonitorEvent(_ event: NSEvent) -> Bool {
        if showingNewPrompt || showingEditPrompt || showingShortcuts {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if flags == [.command, .shift], event.keyCode == 44 {
                showingShortcuts = true
                return true
            }
            if flags == .command {
                switch event.keyCode {
                case 18:
                    switchLibrary(to: .prompts)
                    return true
                case 19:
                    switchLibrary(to: .commands)
                    return true
                default:
                    return false
                }
            }
            return false
        }
        if !flags.subtracting([.numericPad, .function]).isEmpty {
            return false
        }
        switch event.keyCode {
        case 125: // Down
            handleDown()
            return true
        case 126: // Up
            handleUp()
            return true
        case 36: // Return
            guard selectedPrompt != nil else {
                return false
            }
            handleReturnCopy()
            return true
        case 53: // Escape
            cancelAndHide()
            return true
        default:
            return false
        }
    }

    // Arrows/Return/Escape are owned by the AppKit local monitor
    // (handleMonitorEvent), which also fires while toolbar search is focused.
    // This stays as a backup path for Cmd combos only.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers == .command {
            if press.characters == "1" {
                switchLibrary(to: .prompts)
                return .handled
            }
            if press.characters == "2" {
                switchLibrary(to: .commands)
                return .handled
            }
            return .ignored
        }
        if press.modifiers == [.command, .shift] {
            if press.characters == "/" || press.characters == "?" {
                showingShortcuts = true
                return .handled
            }
        }
        return .ignored
    }

    @ViewBuilder
    private var content: some View {
        if prompts.isEmpty {
            VStack(spacing: 8) {
                Text("Prompts")
                    .font(.title)
                Text("Saved prompts will appear here.")
                    .foregroundStyle(.secondary)
            }
        } else if filteredPrompts.isEmpty {
            VStack(spacing: 8) {
                Text("No matching prompts.")
                    .foregroundStyle(.secondary)
            }
        } else {
            List(filteredPrompts, selection: $selection) { prompt in
                PromptRowView(prompt: prompt) {
                    copyPrompt(prompt)
                }
            }
        }
    }

    var body: some View {
        content
            .background(LibraryKeyMonitor(onEvent: handleMonitorEvent))
            .navigationTitle("Prompts")
            .searchable(text: $searchText)
            .searchFocused($searchFocused)
            .onAppear {
                focusSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                focusSearch()
            }
            .onChange(of: resetNonce) { _, _ in
                resetQueryAndSelection()
                focusSearch()
            }
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .onExitCommand {
                cancelAndHide()
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        showingEditPrompt = true
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .disabled(selectedPrompt == nil)
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

struct CommandRowView: View {
    var command: CommandEntry
    var onCopy: () -> Void

    var body: some View {
        HStack {
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
            Spacer()
            Button {
                command.isFavorite.toggle()
            } label: {
                Image(systemName: command.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(command.isFavorite ? "Unfavorite command" : "Favorite command")
            .help(command.isFavorite ? "Unfavorite command" : "Favorite command")
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy command")
            .help("Copy command")
        }
        .tag(command.id)
    }
}

struct CommandLibraryView: View {
    @Binding var librarySelection: LibrarySelection?
    @Binding var resetNonce: Int
    @Binding var showingShortcuts: Bool
    @Query(sort: \CommandEntry.title) private var commands: [CommandEntry]
    @State private var selection: UUID?
    @State private var showingNewCommand = false
    @State private var showingEditCommand = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    init(
        librarySelection: Binding<LibrarySelection?> = .constant(.commands),
        resetNonce: Binding<Int> = .constant(0),
        showingShortcuts: Binding<Bool> = .constant(false)
    ) {
        _librarySelection = librarySelection
        _resetNonce = resetNonce
        _showingShortcuts = showingShortcuts
    }

    private var filteredCommands: [CommandEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [CommandEntry]
        if query.isEmpty {
            base = commands
        } else {
            base = commands.filter { command in
                command.title.localizedCaseInsensitiveContains(query)
                    || command.command.localizedCaseInsensitiveContains(query)
                    || command.explanation.localizedCaseInsensitiveContains(query)
                    || command.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
        }
        return base.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var selectedCommand: CommandEntry? {
        filteredCommands.first(where: { $0.id == selection })
    }

    @discardableResult
    private func copyCommand(_ command: CommandEntry) -> Bool {
        if copyToPasteboard(command.command) {
            command.lastCopiedAt = Date()
            return true
        }
        return false
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            focusSearchNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusSearchNow()
        }
    }

    private func focusSearchNow() {
        searchFocused = true
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let searchItem = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first else {
            return
        }
        searchItem.beginSearchInteraction()
        window.makeFirstResponder(searchItem.searchField)
    }

    private func resetQueryAndSelection() {
        searchText = ""
        selection = nil
    }

    private func switchLibrary(to target: LibrarySelection) {
        librarySelection = target
        resetNonce += 1
        resetQueryAndSelection()
        focusSearch()
    }

    private func cancelAndHide() {
        resetQueryAndSelection()
        NSApp.hide(nil)
    }

    private func handleDown() {
        let ids = filteredCommands.map(\.id)
        if let current = selection, let index = ids.firstIndex(of: current) {
            if index + 1 < ids.count {
                selection = ids[index + 1]
            }
        } else if let first = ids.first {
            selection = first
        }
    }

    private func handleUp() {
        let ids = filteredCommands.map(\.id)
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            return
        }
        if index == 0 {
            resetQueryAndSelection()
            focusSearch()
        } else {
            selection = ids[index - 1]
        }
    }

    private func handleReturnCopy() {
        guard let target = selectedCommand else {
            return
        }
        if copyCommand(target) {
            resetQueryAndSelection()
            NSApp.hide(nil)
        }
    }

    // Local-monitor entry point. Returns true when the key was handled
    // (swallow it) or false to let it pass through untouched (typing,
    // Cmd shortcuts, keys while an editor/help sheet is open).
    private func handleMonitorEvent(_ event: NSEvent) -> Bool {
        if showingNewCommand || showingEditCommand || showingShortcuts {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if flags == [.command, .shift], event.keyCode == 44 {
                showingShortcuts = true
                return true
            }
            if flags == .command {
                switch event.keyCode {
                case 18:
                    switchLibrary(to: .prompts)
                    return true
                case 19:
                    switchLibrary(to: .commands)
                    return true
                default:
                    return false
                }
            }
            return false
        }
        if !flags.subtracting([.numericPad, .function]).isEmpty {
            return false
        }
        switch event.keyCode {
        case 125: // Down
            handleDown()
            return true
        case 126: // Up
            handleUp()
            return true
        case 36: // Return
            guard selectedCommand != nil else {
                return false
            }
            handleReturnCopy()
            return true
        case 53: // Escape
            cancelAndHide()
            return true
        default:
            return false
        }
    }

    // Arrows/Return/Escape are owned by the AppKit local monitor
    // (handleMonitorEvent), which also fires while toolbar search is focused.
    // This stays as a backup path for Cmd combos only.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers == .command {
            if press.characters == "1" {
                switchLibrary(to: .prompts)
                return .handled
            }
            if press.characters == "2" {
                switchLibrary(to: .commands)
                return .handled
            }
            return .ignored
        }
        if press.modifiers == [.command, .shift] {
            if press.characters == "/" || press.characters == "?" {
                showingShortcuts = true
                return .handled
            }
        }
        return .ignored
    }

    @ViewBuilder
    private var content: some View {
        if commands.isEmpty {
            VStack(spacing: 8) {
                Text("Commands")
                    .font(.title)
                Text("Saved commands will appear here.")
                    .foregroundStyle(.secondary)
            }
        } else if filteredCommands.isEmpty {
            VStack(spacing: 8) {
                Text("No matching commands.")
                    .foregroundStyle(.secondary)
            }
        } else {
            List(filteredCommands, selection: $selection) { command in
                CommandRowView(command: command) {
                    copyCommand(command)
                }
            }
        }
    }

    var body: some View {
        content
            .background(LibraryKeyMonitor(onEvent: handleMonitorEvent))
            .navigationTitle("Commands")
            .searchable(text: $searchText)
            .searchFocused($searchFocused)
            .onAppear {
                focusSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                focusSearch()
            }
            .onChange(of: resetNonce) { _, _ in
                resetQueryAndSelection()
                focusSearch()
            }
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .onExitCommand {
                cancelAndHide()
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        showingEditCommand = true
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .disabled(selectedCommand == nil)
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
