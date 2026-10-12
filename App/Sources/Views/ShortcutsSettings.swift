import AppKit
import SwiftUI

/// Settings, Shortcuts: every menu command's shortcut, which can be recorded again, removed or reset.
struct ShortcutsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var message: (action: ShortcutAction, text: String)?

    var body: some View {
        let store = model.shortcuts
        Form {
            ForEach(ShortcutAction.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        row(action, store: store)
                    }
                }
            }
            Section {
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels, Delete removes the shortcut. Space plays and pauses outside text fields.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        store.recording = nil
                        store.resetAll()
                        message = nil
                    }
                    .disabled(ShortcutAction.allCases.allSatisfy { !store.isCustomized($0) })
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { store.recording = nil }
    }

    private func row(_ action: ShortcutAction, store: ShortcutStore) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if store.isCustomized(action) {
                    Button {
                        store.reset(action)
                        message = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(action.defaultShortcut.map(ShortcutStore.display) ?? "none")")
                }
                ShortcutRecorder(action: action) { text in
                    message = text.map { (action, $0) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let message, message.action == action {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

/// Shows an action's shortcut; click it to record a new one from the next key press.
private struct ShortcutRecorder: View {
    var action: ShortcutAction
    /// Why the pressed keys were refused, or nil once a shortcut was set.
    var onResult: (String?) -> Void
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?

    var body: some View {
        let store = model.shortcuts
        let isRecording = store.recording == action
        Button {
            store.recording = isRecording ? nil : action
        } label: {
            Text(isRecording ? "Type Shortcut…" : store.shortcut(for: action).map(ShortcutStore.display) ?? "None")
                .monospacedDigit()
                .foregroundStyle(isRecording ? Color.brand : store.shortcut(for: action) == nil ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .onChange(of: isRecording, initial: true) { _, recording in
            recording ? startMonitor() : stopMonitor()
        }
        .onDisappear { stopMonitor() }
    }

    /// Takes the next key press for this action (before the menus see it, so the old shortcut does not run).
    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let store = model.shortcuts
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 53 where plain:  // Esc
                store.recording = nil
            case 51 where plain, 117 where plain:  // Delete, Forward Delete
                onResult(store.set(.none, for: action))
                store.recording = nil
            default:
                guard let stored = ShortcutStore.stored(from: event) else {
                    onResult("Use Command, Option or Control with a key (or a function key).")
                    return nil
                }
                let problem = store.set(stored, for: action)
                onResult(problem)
                if problem == nil { store.recording = nil }
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
