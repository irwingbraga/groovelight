import Foundation
import Observation

/// The user's cassettes, beside the built-in ones: a folder for each (named by its id) holding `cassette.json` and its
/// pictures. A design is shared as that folder, and imported from one (or from its `cassette.json`).
@MainActor @Observable
public final class CassetteStore {
    public nonisolated static let fileName = "cassette.json"

    public let folder: URL
    public private(set) var custom: [CassetteDesign] = []
    /// Bumped when a design's pictures change, so views showing them load them again.
    public private(set) var revision = 0

    public enum Picture: String, Sendable { case shell, label }

    public enum StoreError: LocalizedError {
        case notADesign(URL)
        case builtIn

        public var errorDescription: String? {
            switch self {
            case .notADesign(let url): "\(url.lastPathComponent) is not a cassette: it has no \(CassetteStore.fileName)."
            case .builtIn: "The built-in cassettes cannot be changed. Duplicate one to make your own."
            }
        }
    }

    /// `folder` is where the designs live (Application Support's "Cassettes" in the apps).
    public init(folder: URL) {
        self.folder = folder
        reload()
    }

    /// Application Support/Groovelight/Cassettes.
    public static func defaultFolder() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Groovelight/Cassettes", directoryHint: .isDirectory)
    }

    public var all: [CassetteDesign] { CassetteDesign.builtIn + custom }

    /// The design with that id, or the first built-in one (a deleted design's choice falls back to it).
    public func design(id: UUID?) -> CassetteDesign {
        all.first { $0.id == id } ?? CassetteDesign.builtIn[0]
    }

    public func reload() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        custom = folders.compactMap { try? Self.read(from: $0.appending(path: Self.fileName)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func folder(of design: CassetteDesign) -> URL {
        folder.appending(path: design.id.uuidString, directoryHint: .isDirectory)
    }

    /// Where a design's picture is (nil for none, or for a built-in design, which has none).
    public func url(of picture: Picture, in design: CassetteDesign) -> URL? {
        guard let name = picture == .shell ? design.shellImage : design.labelImage, !design.isBuiltIn else { return nil }
        // Only a file in the design's own folder, whatever a hand-written file says.
        let url = folder(of: design).appending(path: (name as NSString).lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func save(_ design: CassetteDesign) throws {
        guard !design.isBuiltIn else { throw StoreError.builtIn }
        let directory = folder(of: design)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(design, to: directory.appending(path: Self.fileName))
        reload()
    }

    /// A copy to change: built-in designs are changed this way.
    @discardableResult
    public func duplicate(_ design: CassetteDesign, name: String? = nil) throws -> CassetteDesign {
        var copy = design
        copy.id = UUID()
        copy.name = name ?? "\(design.name) Copy"
        let directory = folder(of: copy)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for picture in [Picture.shell, .label] {
            if let source = url(of: picture, in: design) {
                try FileManager.default.copyItem(at: source, to: directory.appending(path: source.lastPathComponent))
            }
        }
        try Self.write(copy, to: directory.appending(path: Self.fileName))
        reload()
        return copy
    }

    public func delete(_ design: CassetteDesign) throws {
        guard !design.isBuiltIn else { throw StoreError.builtIn }
        try FileManager.default.removeItem(at: folder(of: design))
        reload()
    }

    /// Sets (or with nil, removes) the shell's or the label's picture, copied into the design's folder.
    @discardableResult
    public func setPicture(_ picture: Picture, from source: URL?, in design: CassetteDesign) throws -> CassetteDesign {
        guard !design.isBuiltIn else { throw StoreError.builtIn }
        var design = design
        let directory = folder(of: design)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old = url(of: picture, in: design) { try? FileManager.default.removeItem(at: old) }
        var name: String?
        if let source {
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
            // A new name each time, so nothing holds on to the old picture.
            name = "\(picture.rawValue)-\(UUID().uuidString.prefix(8)).\(ext)"
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: directory.appending(path: name!))
        }
        switch picture {
        case .shell: design.shellImage = name
        case .label: design.labelImage = name
        }
        try save(design)
        revision += 1
        return design
    }

    /// Adds a design from a folder holding `cassette.json` and its pictures, or from the file itself (its pictures
    /// beside it). It keeps its id unless one here has it already, then it is added as a copy.
    @discardableResult
    public func importDesign(from url: URL) throws -> CassetteDesign {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let file = isFolder ? url.appending(path: Self.fileName) : url
        guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.notADesign(url) }
        var design = try Self.read(from: file)
        let source = file.deletingLastPathComponent()
        if all.contains(where: { $0.id == design.id }) { design.id = UUID() }
        let directory = folder(of: design)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in [design.shellImage, design.labelImage].compactMap({ $0 }) {
            let base = (name as NSString).lastPathComponent
            let from = source.appending(path: base)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: directory.appending(path: base))
            }
        }
        // A picture the file names but that did not come with it: drawn without it.
        let present = { (name: String?) in
            name.map { (($0 as NSString).lastPathComponent) }.flatMap {
                FileManager.default.fileExists(atPath: directory.appending(path: $0).path) ? $0 : nil
            }
        }
        design.shellImage = present(design.shellImage)
        design.labelImage = present(design.labelImage)
        try Self.write(design, to: directory.appending(path: Self.fileName))
        reload()
        return design
    }

    /// Writes the design as a folder (its `cassette.json` and pictures) into `destination`, and returns it.
    @discardableResult
    public func export(_ design: CassetteDesign, to destination: URL) throws -> URL {
        let safeName = design.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        var target = destination.appending(path: "\(safeName).cassette", directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = destination.appending(path: "\(safeName) \(counter).cassette", directoryHint: .isDirectory)
            counter += 1
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for picture in [Picture.shell, .label] {
            if let source = url(of: picture, in: design) {
                try FileManager.default.copyItem(at: source, to: target.appending(path: source.lastPathComponent))
            }
        }
        try Self.write(design, to: target.appending(path: Self.fileName))
        return target
    }

    public nonisolated static func read(from file: URL) throws -> CassetteDesign {
        try JSONDecoder().decode(CassetteDesign.self, from: Data(contentsOf: file))
    }

    public nonisolated static func write(_ design: CassetteDesign, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(design).write(to: file, options: .atomic)
    }
}
