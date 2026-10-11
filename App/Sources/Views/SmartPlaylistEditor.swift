import LibraryKit
import SwiftUI

/// Creates or edits a smart playlist: name, rules (match all or any), optional limit, with a live count of matches.
struct SmartPlaylistEditor: View {
    /// The playlist being edited, nil for a new one.
    var playlist: Playlist?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Untitled Smart Playlist"
    @State private var rules = SmartPlaylistRules()
    @State private var hasLimit = false
    @State private var limit = SmartLimit()
    @State private var preview: (count: Int, duration: Double)?
    @State private var didLoad = false

    private var effectiveRules: SmartPlaylistRules {
        var result = rules
        result.limit = hasLimit ? limit : nil
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(playlist == nil ? "New Smart Playlist" : "Edit Smart Playlist").font(.headline)
                Spacer()
                if playlist == nil {
                    Menu("Templates") {
                        ForEach(SmartPlaylistTemplate.all) { template in
                            Button(template.name) { apply(template) }
                        }
                    }
                    .fixedSize()
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            HStack(spacing: 6) {
                Text("Match")
                Picker("Match", selection: $rules.match) {
                    Text("all").tag(SmartPlaylistRules.Match.all)
                    Text("any").tag(SmartPlaylistRules.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following rules:")
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rules.rules) { $rule in
                        SmartRuleRow(rule: $rule, canRemove: rules.rules.count > 1,
                                     onAdd: { addRule(after: rule.id) },
                                     onRemove: { rules.rules.removeAll { $0.id == rule.id } })
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 260)

            Divider()

            HStack(spacing: 6) {
                Toggle("Limit to", isOn: $hasLimit)
                Group {
                    TextField("Count", value: $limit.count, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Picker("Unit", selection: $limit.unit) {
                        ForEach(SmartLimit.Unit.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("selected by")
                    Picker("Selected by", selection: $limit.selectedBy) {
                        ForEach(SmartLimit.Selection.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!hasLimit)
            }

            Divider()

            HStack {
                Group {
                    if let preview {
                        Text("\(preview.count) \(preview.count == 1 ? "song" : "songs") match, \(formatLongDuration(preview.duration))")
                    } else {
                        Text("Counting…")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(playlist == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear(perform: load)
        .task(id: effectiveRules) {
            // Debounced live preview of what the rules match.
            try? await Task.sleep(for: .milliseconds(250))
            let rules = effectiveRules
            if let tracks = try? await model.database.writer.read({ try LibraryDatabase.tracks($0, rules: rules) }) {
                preview = (tracks.count, tracks.reduce(0) { $0 + $1.duration })
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let playlist, let saved = playlist.rules else { return }
        name = playlist.name
        rules = saved
        if let savedLimit = saved.limit {
            hasLimit = true
            limit = savedLimit
        }
        if rules.rules.isEmpty { rules.rules = [SmartRule()] }
    }

    private func addRule(after id: UUID) {
        let index = rules.rules.firstIndex { $0.id == id }.map { $0 + 1 } ?? rules.rules.endIndex
        rules.rules.insert(SmartRule(), at: index)
    }

    private func apply(_ template: SmartPlaylistTemplate) {
        name = template.name
        rules = template.rules
        hasLimit = template.rules.limit != nil
        limit = template.rules.limit ?? SmartLimit()
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let id = playlist?.id {
                try model.database.updateSmartPlaylist(id, name: trimmed, rules: effectiveRules)
            } else {
                let created = try model.database.createSmartPlaylist(named: trimmed, rules: effectiveRules, cover: .randomGenerated())
                if let id = created.id { model.selection = .playlist(id) }
            }
            dismiss()
        } catch {
            model.errorMessage = "Could not save the smart playlist: \(error.localizedDescription)"
        }
    }
}

/// One rule: field, operator, value editor, and add / remove buttons.
private struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    var canRemove: Bool
    var onAdd: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: Binding(get: { rule.field }, set: { rule.setField($0) })) {
                Section("Text") { options([.title, .artist, .album, .albumArtist, .composer, .genre, .comment, .kind]) }
                Section("Numbers") { options([.year, .rating, .plays, .skips, .time, .bpm]) }
                Section("Audio") { options([.quality, .sampleRate, .bitDepth, .bitrate]) }
                Section("Dates") { options([.dateAdded, .lastPlayed]) }
                Section("Other") { options([.loved, .compilation, .hasArtwork, .hasLyrics]) }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("Operator", selection: $rule.op) {
                ForEach(SmartOperator.operators(for: rule.field.kind)) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

            value
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                Button(action: onRemove) { Image(systemName: "minus") }
                    .disabled(!canRemove)
                    .help("Remove rule")
                Button(action: onAdd) { Image(systemName: "plus") }
                    .help("Add rule")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func options(_ fields: [SmartField]) -> some View {
        ForEach(fields) { Text($0.displayName).tag($0) }
    }

    @ViewBuilder
    private var value: some View {
        switch rule.field.kind {
        case .text:
            TextField("Value", text: $rule.text)
        case .number:
            HStack(spacing: 6) {
                TextField("Value", value: $rule.number, format: .number).frame(width: 80)
                if rule.op == .inRange {
                    Text("to")
                    TextField("Value", value: $rule.number2, format: .number).frame(width: 80)
                }
                if let unit = rule.field.unit { Text(unit).foregroundStyle(.secondary) }
            }
        case .date:
            if rule.op == .inTheLast || rule.op == .notInTheLast {
                HStack(spacing: 6) {
                    TextField("Count", value: $rule.period, format: .number).frame(width: 60)
                    Picker("Unit", selection: $rule.periodUnit) {
                        ForEach(PeriodUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                DatePicker("Date", selection: $rule.date, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
        case .bool:
            EmptyView()
        case .quality:
            Picker("Quality", selection: $rule.quality) {
                ForEach(QualityTier.allCases.reversed(), id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Ready-made rules offered when creating a smart playlist.
struct SmartPlaylistTemplate: Identifiable {
    var name: String
    var rules: SmartPlaylistRules
    var id: String { name }

    static let all: [SmartPlaylistTemplate] = [
        .init(name: "Recently Added", rules: .init(rules: [SmartRule(field: .dateAdded, op: .inTheLast, period: 2, periodUnit: .weeks)])),
        .init(name: "Recently Played", rules: .init(rules: [SmartRule(field: .lastPlayed, op: .inTheLast, period: 2, periodUnit: .weeks)],
                                                    limit: SmartLimit(count: 50, selectedBy: .mostRecentlyPlayed))),
        .init(name: "Top 25 Most Played", rules: .init(rules: [SmartRule(field: .plays, op: .greaterThan, number: 0)],
                                                       limit: SmartLimit(count: 25, selectedBy: .mostPlayed))),
        .init(name: "Hi-Res Lossless", rules: .init(rules: [SmartRule(field: .quality, op: .isAtLeast, quality: .hiResLossless)])),
        .init(name: "Lossless", rules: .init(rules: [SmartRule(field: .quality, op: .isAtLeast, quality: .lossless)])),
        .init(name: "Never Played", rules: .init(rules: [SmartRule(field: .plays, op: .is, number: 0)])),
        .init(name: "Missing Artwork", rules: .init(rules: [SmartRule(field: .hasArtwork, op: .isFalse)])),
        .init(name: "Missing Lyrics", rules: .init(rules: [SmartRule(field: .hasLyrics, op: .isFalse)])),
        .init(name: "90s Music", rules: .init(rules: [SmartRule(field: .year, op: .inRange, number: 1990, number2: 1999)])),
    ]
}

extension SmartPlaylistRules {
    /// One line description: "Artist contains "Radio" and Plays is greater than 10 · 25 songs by most played".
    var summary: String {
        let joiner = match == .all ? " and " : " or "
        var text = rules.map(\.summary).joined(separator: joiner)
        if text.isEmpty { text = "All songs" }
        if let limit {
            text += " · limited to \(limit.count) \(limit.unit.displayName) by \(limit.selectedBy.displayName)"
        }
        return text
    }
}

extension SmartRule {
    var summary: String {
        let head = "\(field.displayName) \(op.displayName)"
        switch field.kind {
        case .text: return "\(head) \"\(text)\""
        case .number:
            let unit = field.unit.map { " \($0)" } ?? ""
            let value = number.formatted()
            return op == .inRange ? "\(head) \(value) to \(number2.formatted())\(unit)" : "\(head) \(value)\(unit)"
        case .date:
            if op == .inTheLast || op == .notInTheLast { return "\(head) \(period) \(periodUnit.rawValue)" }
            return "\(head) \(date.formatted(date: .abbreviated, time: .omitted))"
        case .bool: return head
        case .quality: return "\(head) \(quality.displayName)"
        }
    }
}
