import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The cassettes to choose from, with a preview of each: the built-in ones and the user's, which can be made (from a
/// copy), edited, imported, shared and deleted.
public struct CassetteLibrary: View {
    @Bindable var store: CassetteStore
    @Binding var selection: String
    @State private var editing: CassetteDesign?
    @State private var importing = false
    @State private var exporting: CassetteDocument?
    @State private var savingTemplate: CassetteDocument?
    @State private var problem: String?

    /// `selection` is the chosen design's id (as kept in `@AppStorage`).
    public init(store: CassetteStore, selection: Binding<String>) {
        self.store = store
        _selection = selection
    }

    private var chosen: UUID { store.design(id: UUID(uuidString: selection)).id }

    public var body: some View {
        List {
            Section {
                ForEach(CassetteDesign.builtIn) { row($0) }
            } header: {
                Text("Built In")
            }
            Section {
                ForEach(store.custom) { row($0) }
                Button("New Cassette", systemImage: "plus") { make(from: store.design(id: chosen)) }
                Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                Button("Save Template…", systemImage: "square.dashed") { savingTemplate = CassetteTemplate.document() }
            } header: {
                Text("Yours")
            } footer: {
                Text("Make your own from a copy of any cassette: its colors, its label and its text, or your own pictures of the shell and the label, drawn on the template. Share one as a .cassette file; it opens on the Mac, iPhone, iPad and Android.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.cassette, .folder, .json]) { result in
            do {
                let design = try store.importDesign(from: result.get())
                selection = design.id.uuidString
            } catch {
                problem = error.localizedDescription
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
                      contentType: .cassette, defaultFilename: exporting?.name) { _ in exporting = nil }
        .fileExporter(isPresented: Binding(get: { savingTemplate != nil }, set: { if !$0 { savingTemplate = nil } }), document: savingTemplate,
                      contentType: .png, defaultFilename: "Cassette Template.png") { _ in savingTemplate = nil }
        .sheet(item: $editing) { design in
            CassetteEditor(store: store, design: design) { saved in
                if let saved { selection = saved.id.uuidString }
                editing = nil
            }
        }
        .alert("Cassette", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func row(_ design: CassetteDesign) -> some View {
        Button {
            selection = design.id.uuidString
        } label: {
            HStack(spacing: 12) {
                CassettePreview(design: design, pictures: store.pictures(of: design), playing: false)
                    .frame(width: 76, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(design.name).foregroundStyle(.primary)
                    if let author = design.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if design.id == chosen {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Chosen")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !design.isBuiltIn {
                Button("Edit…", systemImage: "pencil") { editing = design }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { make(from: design) }
            if !design.isBuiltIn {
                Button("Share…", systemImage: "square.and.arrow.up") { share(design) }
                Button("Delete", systemImage: "trash", role: .destructive) { delete(design) }
            }
        }
        .swipeActions {
            if !design.isBuiltIn {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(design) }
                Button("Edit", systemImage: "pencil") { editing = design }
            }
        }
    }

    private func make(from design: CassetteDesign) {
        do {
            let copy = try store.duplicate(design, name: design.isBuiltIn ? "My \(design.name)" : nil)
            editing = copy
        } catch {
            problem = error.localizedDescription
        }
    }

    private func share(_ design: CassetteDesign) {
        do { exporting = try store.document(for: design) } catch { problem = error.localizedDescription }
    }

    private func delete(_ design: CassetteDesign) {
        do {
            try store.delete(design)
            if design.id.uuidString == selection { selection = CassetteDesign.builtIn[0].id.uuidString }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A cassette with a sample song on its label, still or with the reels turning.
public struct CassettePreview: View {
    var design: CassetteDesign
    var pictures: CassettePictures
    var playing: Bool

    public init(design: CassetteDesign, pictures: CassettePictures, playing: Bool) {
        self.design = design
        self.pictures = pictures
        self.playing = playing
    }

    public var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            let start = Self.start
            let playback = SkinPlayback(title: "Side A", artist: "Groovelight", isPlaying: playing, duration: 60) { date in
                date.timeIntervalSince(start).truncatingRemainder(dividingBy: 60)
            }
            CassetteFace(design: design, pictures: pictures, playback: playback, date: context.date) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.63), Color(red: 0.56, green: 0.35, blue: 0.54)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .aspectRatio(design.resolvedGeometry.aspectRatio, contentMode: .fit)
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
    }

    private static let start = Date()
}

/// Edits a design of the user's: the preview at the top, then the shell, the label, the text, the reels and the
/// pictures. Pictures are kept at once; the rest when saved.
public struct CassetteEditor: View {
    var store: CassetteStore
    @State private var design: CassetteDesign
    @State private var choosingPicture: CassetteStore.Picture?
    @State private var problem: String?
    var done: (CassetteDesign?) -> Void

    public init(store: CassetteStore, design: CassetteDesign, done: @escaping (CassetteDesign?) -> Void) {
        self.store = store
        _design = State(initialValue: design)
        self.done = done
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    CassettePreview(design: design, pictures: store.pictures(of: design), playing: true)
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                }
                Section("Name") {
                    TextField("Name", text: $design.name)
                    TextField("Made By", text: Binding(get: { design.author ?? "" }, set: { design.author = $0.isEmpty ? nil : $0 }))
                }
                Section("Shell") {
                    ColorPicker("Plastic", selection: color(\.shellColor), supportsOpacity: false)
                    LabeledContent("Clear") {
                        Slider(value: $design.shellClarity, in: 0...0.8)
                    }
                    ColorPicker("Screws and Edges", selection: color(\.detailColor), supportsOpacity: false)
                }
                Section("Label") {
                    ColorPicker("Paper", selection: color(\.label.background), supportsOpacity: false)
                    ColorPicker("Writing", selection: color(\.label.textColor), supportsOpacity: false)
                    ForEach(design.label.stripes.indices, id: \.self) { index in
                        HStack {
                            ColorPicker("Band \(index + 1)", selection: Binding(
                                get: { Color(design.label.stripes[index]) },
                                set: { design.label.stripes[index] = HexColor($0) }), supportsOpacity: false)
                            Button("Remove Band", systemImage: "minus.circle.fill") { design.label.stripes.remove(at: index) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                        }
                    }
                    if design.label.stripes.count < 5 {
                        Button("Add Band", systemImage: "plus.circle") {
                            design.label.stripes.append(design.label.stripes.last ?? design.label.textColor)
                        }
                    }
                    Toggle("Song Written on It", isOn: $design.label.showsText)
                    Toggle("Handwriting", isOn: $design.label.handwritten).disabled(!design.label.showsText)
                    Toggle("Cover on It", isOn: $design.label.showsArtwork)
                }
                Section("Printed") {
                    TextField("Brand", text: $design.brand)
                    TextField("Tape Type", text: $design.tapeType)
                    TextField("Side", text: $design.side)
                }
                Section("Reels") {
                    ColorPicker("Hubs", selection: color(\.reels.hubColor), supportsOpacity: false)
                    ColorPicker("Tape", selection: color(\.reels.tapeColor), supportsOpacity: false)
                }
                Section {
                    pictureRow("Shell Picture", picture: .shell)
                    pictureRow("Label Picture", picture: .label)
                } header: {
                    Text("Your Pictures")
                } footer: {
                    Text("A shell picture is drawn over the reels: make the window and the hubs' holes transparent (a PNG). Draw it on the template (Save Template in the list) and it fits; the song is still written on the label.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(design.name.isEmpty ? "Cassette" : design.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.save(design)
                            done(design)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
            }
            .fileImporter(isPresented: Binding(get: { choosingPicture != nil }, set: { if !$0 { choosingPicture = nil } }),
                          allowedContentTypes: [.png, .jpeg, .heic]) { result in
                guard let picture = choosingPicture else { return }
                do { design = try store.setPicture(picture, from: result.get(), in: design) } catch { problem = error.localizedDescription }
                choosingPicture = nil
            }
            .alert("Cassette", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") { problem = nil }
            } message: {
                Text(problem ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    private func pictureRow(_ title: String, picture: CassetteStore.Picture) -> some View {
        let has = store.url(of: picture, in: design) != nil
        return HStack {
            Text(title)
            Spacer()
            if has {
                Button("Remove", role: .destructive) {
                    do { design = try store.setPicture(picture, from: nil, in: design) } catch { problem = error.localizedDescription }
                }
                .buttonStyle(.borderless)
            }
            Button(has ? "Change…" : "Choose…") { choosingPicture = picture }
                .buttonStyle(.borderless)
        }
    }

    private func color(_ path: WritableKeyPath<CassetteDesign, HexColor>) -> Binding<Color> {
        Binding(get: { Color(design[keyPath: path]) }, set: { design[keyPath: path] = HexColor($0) })
    }
}

extension HexColor {
    /// The color in sRGB, as the design file keeps it.
    public init(_ color: Color) {
        #if os(macOS)
        let platform = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: platform.redComponent, green: platform.greenComponent, blue: platform.blueComponent, alpha: platform.alphaComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: red.clamped(to: 0...1), green: green.clamped(to: 0...1), blue: blue.clamped(to: 0...1), alpha: alpha)
        #endif
    }
}
