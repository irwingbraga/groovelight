import LibraryKit
import SwiftUI

/// Naming template and options, shared by Organize, Import and Settings.
struct NamingOptionsEditor: View {
    @Binding var options: OrganizeOptions

    private let tokens = ["{albumartist}", "{artist}", "{album}", "{year}", "{genre}", "{disc}", "{track:02}", "{title}"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Template", text: $options.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Menu("Presets") {
                    ForEach(OrganizeOptions.presets, id: \.template) { preset in
                        Button(preset.name) { options.template = preset.template }
                    }
                }
                .fixedSize()
                Menu("Insert") {
                    ForEach(tokens, id: \.self) { token in
                        Button(token) { options.template += token }
                    }
                    Divider()
                    Button("Folder separator /") { options.template += "/" }
                    Button("Optional part [ ]") { options.template += "[ ]" }
                }
                .fixedSize()
            }
            Text("Tokens in { } are replaced by tags; a part in [ ] only appears when its tags have values (\"[{disc}-]\" for multi-disc albums); \"/\" makes folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Toggle("Organize into folders", isOn: $options.organizeFolders)
                Toggle("Portable names", isOn: $options.portableNames)
                    .help("Also replace characters Windows and many network drives reject: \\ ? * \" < > |")
                Toggle("Consistent \"feat.\"", isOn: $options.normalizeFeaturing)
                Toggle("Title Case", isOn: $options.titleCase)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
        }
    }
}

/// Organize Files: preview of the new names (current, new, conflicts), then apply; undo from the Library menu.
struct OrganizeSheet: View {
    var tracks: [Track]?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var plan: [RenamePlanItem] = []
    @State private var isPlanning = true

    var body: some View {
        @Bindable var files = model.files
        let changes = plan.filter { $0.status != .unchanged }
        VStack(alignment: .leading, spacing: 14) {
            Text(tracks == nil ? "Organize Library Files" : "Organize Files").font(.headline)
            NamingOptionsEditor(options: $files.options)
            Divider()
            HStack {
                if isPlanning {
                    ProgressView().controlSize(.small)
                    Text("Planning…").foregroundStyle(.secondary)
                } else {
                    let conflicts = Text(plan.contains { $0.status == .renamedForConflict } ? ", some numbered to avoid name conflicts" : "")
                        .foregroundStyle(.orange)
                    Text("\(changes.count) of \(plan.count) files will be renamed or moved\(conflicts)")
                }
                Spacer()
            }
            .font(.callout)
            List(changes.prefix(500)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(relative(item.destination))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.status == .renamedForConflict ? Color.orange : .primary)
                    Text("was " + relative(item.source))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(minHeight: 260)
            .overlay {
                if !isPlanning, changes.isEmpty {
                    ContentUnavailableView("Already Organized", systemImage: "checkmark.circle", description: Text("Every file already matches the template."))
                }
            }
            HStack {
                Text("Files are moved inside your library folder; Library, \(model.files.undoTitle) puts them back.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(changes.isEmpty ? "Done" : "Rename \(changes.count) Files") {
                    Task {
                        if !changes.isEmpty { await model.files.apply(plan) }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPlanning || model.files.isWorking)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .task(id: files.options) {
            isPlanning = true
            try? await Task.sleep(for: .milliseconds(200))
            plan = await model.files.plan(for: tracks)
            isPlanning = false
        }
    }

    /// Path relative to the library folder it is in.
    private func relative(_ url: URL) -> String {
        let roots = (try? model.database.writer.read { try LibraryDatabase.roots($0) }) ?? []
        for root in roots where url.path.hasPrefix(root.path + "/") {
            return String(url.path.dropFirst(root.path.count + 1))
        }
        return url.path
    }
}

/// Import: what was found for the chosen songs and where they will go; then move (or copy), tag and name them.
struct ImportSheet: View {
    @Bindable var session: ImportSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Music").font(.headline)
            switch session.phase {
            case .reading(let done, let total):
                progress("Reading \(done) of \(total) files…", done, total)
            case .identifying(let done, let total):
                progress("Identifying albums on MusicBrainz (\(done + 1) of \(total))…", done, total)
            case .importing(let done, let total):
                progress("Importing \(done) of \(total) songs…", done, total)
            case .review:
                review
            case .finished(let imported, let skipped, let failed):
                finished(imported: imported, skipped: skipped, failed: failed)
            }
        }
        .padding(20)
        .frame(width: 820, height: 640)
    }

    private func progress(_ text: String, _ done: Int, _ total: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var review: some View {
        let destinations = session.destinations()
        HStack(spacing: 16) {
            Picker("", selection: $session.moveFiles) {
                Text("Move into library").tag(true)
                Text("Copy into library").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if session.roots.count > 1 {
                Picker("Library folder", selection: $session.rootId) {
                    ForEach(session.roots, id: \.id) { Text(URL(fileURLWithPath: $0.path).lastPathComponent).tag(Optional($0.id)) }
                }
                .fixedSize()
            }
            Spacer()
        }
        HStack(spacing: 18) {
            Toggle("Use metadata found online", isOn: $session.useOnlineMetadata)
            Toggle("Write tags and cover into the files", isOn: $session.writeTags)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        List {
            ForEach($session.groups) { $group in
                Section {
                    ForEach($group.items) { $item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $item.include)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destinations[item.id].map(relative) ?? (item.isDuplicate ? "Already in your library" : "Skipped"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(item.include ? .primary : .secondary)
                                Text(item.cue.map { cue in
                                    "\(item.source.lastPathComponent) + \(cue.sheet?.lastPathComponent ?? "embedded cue sheet") · \(cue.songs) songs"
                                } ?? item.source.lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        Group {
                            if let cover = group.cover, let image = NSImage(data: cover) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "music.note").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(.quaternary)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(.rect(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title).font(.system(size: 13, weight: .semibold))
                            Text(group.artist).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let release = group.matchedRelease, session.useOnlineMetadata {
                            Label("Matched: \(release)", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("File tags", systemImage: "tag")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        HStack {
            Text(session.duplicateCount == 1 ? "1 song already in your library is left out."
                 : session.duplicateCount > 1 ? "\(session.duplicateCount) songs already in your library are left out." : "Undo with Library, Undo Import.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                model.files.importSession = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Import \(session.includedCount) Songs") { Task { await session.run() } }
                .keyboardShortcut(.defaultAction)
                .disabled(session.includedCount == 0)
        }
    }

    private func finished(imported: Int, skipped: Int, failed: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(failed == 0 ? .green : .orange)
            Text("\(imported) songs imported").font(.title3.weight(.semibold))
            if skipped > 0 { Text("\(skipped) left out").foregroundStyle(.secondary) }
            if failed > 0 { Text("\(failed) could not be imported").foregroundStyle(.orange) }
            Button("Done") {
                model.files.importSession = nil
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func relative(_ url: URL) -> String {
        guard let root = session.roots.first(where: { $0.id == session.rootId }), url.path.hasPrefix(root.path + "/") else { return url.path }
        return String(url.path.dropFirst(root.path.count + 1))
    }
}

/// Settings tab: the naming template used by Organize and Import.
struct FilesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var files = model.files
        Form {
            Section {
                NamingOptionsEditor(options: $files.options)
                    .padding(.vertical, 4)
                LabeledContent("Example") {
                    Text(FileNaming.relativePath(for: NamingFields(title: "Karma Police", artist: "Radiohead", album: "OK Computer",
                                                                   albumArtist: "Radiohead", genre: "Alternative Rock", year: 1997, trackNumber: 6),
                                                 fileExtension: "flac", options: files.options))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("File Names")
            } footer: {
                Text("Used by Library, Organize Library Files and by imports. Files are never renamed without a preview.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Organize Library Files…") { model.files.organize() }
                    Spacer()
                    Button(model.files.undoTitle) { Task { await model.files.undoLast() } }
                        .disabled(model.files.undoable == nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}
