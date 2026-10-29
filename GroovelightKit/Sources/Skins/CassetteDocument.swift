import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A cassette design to share: a package (a folder shown as one file) holding `cassette.json` and its pictures.
    public static let cassette = UTType(exportedAs: "dev.irwingbraga.groovelight.cassette", conformingTo: .package)
}

/// A cassette design as a file to save (`fileExporter`): its `.cassette` package.
public struct CassetteDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [.cassette]
    public static let writableContentTypes: [UTType] = [.cassette]

    /// The file's name, and its contents (data, so the document can go between threads): a package's files by name,
    /// or a single file's (the template).
    var name: String
    var files: [String: Data]
    var contents: Data?

    public init(name: String, files: [String: Data]) {
        self.name = name
        self.files = files
    }

    /// A single file (the template's PNG).
    public init(name: String, contents: Data) {
        self.name = name
        files = [:]
        self.contents = contents
    }

    public init(configuration: ReadConfiguration) throws {
        name = configuration.file.preferredFilename ?? configuration.file.filename ?? "Cassette.cassette"
        files = (configuration.file.fileWrappers ?? [:]).compactMapValues(\.regularFileContents)
        contents = configuration.file.isRegularFile ? configuration.file.regularFileContents : nil
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = contents.map { FileWrapper(regularFileWithContents: $0) }
            ?? FileWrapper(directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) })
        wrapper.preferredFilename = name
        return wrapper
    }
}

extension CassetteStore {
    /// The design as a `.cassette` package: its file and its pictures.
    public func document(for design: CassetteDesign) throws -> CassetteDocument {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files = [Self.fileName: try encoder.encode(design)]
        for picture in [Picture.shell, .label] {
            if let url = url(of: picture, in: design) {
                files[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return CassetteDocument(name: "\(design.name).cassette", files: files)
    }
}

/// The template to draw a shell or a label on: the cassette's outline at 1000 x 635 pixels, the places of the reels,
/// the window and the label marked. A shell drawn on it needs no numbers in its design.
public enum CassetteTemplate {
    public static let pixelWidth = 1000

    @MainActor public static func png() -> Data? {
        let layout = CassetteGeometry.standard
        let width = CGFloat(pixelWidth), height = (width / layout.aspectRatio).rounded()
        let renderer = ImageRenderer(content: TemplateDrawing(layout: layout).frame(width: width, height: height))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The template as a file to save (`fileExporter`).
    @MainActor public static func document() -> CassetteDocument? {
        guard let data = png() else { return nil }
        return CassetteDocument(name: "Cassette Template.png", contents: data)
    }
}

private struct TemplateDrawing: View {
    var layout: CassetteGeometry

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let guide = Color(red: 0.1, green: 0.5, blue: 0.95)
            let dash = StrokeStyle(lineWidth: 2, dash: [10, 6])
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: size.width * 0.035).fill(Color(white: 0.85))
                RoundedRectangle(cornerRadius: size.width * 0.035).stroke(.black, lineWidth: 2)
                // The label.
                Rectangle().stroke(guide, style: dash)
                    .frame(width: layout.label.width * size.width, height: layout.label.height * size.height)
                    .offset(x: layout.label.x * size.width, y: layout.label.y * size.height)
                Text("LABEL").font(.system(size: 22, weight: .bold)).foregroundStyle(guide)
                    .offset(x: layout.label.x * size.width + 12, y: layout.label.y * size.height + 10)
                // The window and the reels: leave them transparent in a shell picture.
                RoundedRectangle(cornerRadius: layout.window.height * size.height * 0.18)
                    .fill(Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: layout.window.height * size.height * 0.18).stroke(.red, lineWidth: 2))
                    .frame(width: layout.window.width * size.width, height: layout.window.height * size.height)
                    .offset(x: layout.window.x * size.width, y: layout.window.y * size.height)
                ForEach([layout.leftReel, layout.rightReel], id: \.x) { reel in
                    let full = layout.reelRadius * size.width, hole = layout.hubRadius * size.width * 1.25
                    Circle().stroke(.red, style: dash).frame(width: full * 2, height: full * 2)
                        .position(x: reel.x * size.width, y: reel.y * size.height)
                    Circle().stroke(.red, lineWidth: 2).frame(width: hole * 2, height: hole * 2)
                        .position(x: reel.x * size.width, y: reel.y * size.height)
                }
                Text("Red: transparent in a shell picture (the window and the hubs' holes). Dashed red: the full reels. Blue: the label.")
                    .font(.system(size: 16)).foregroundStyle(.black.opacity(0.7))
                    .frame(width: size.width * 0.8)
                    .position(x: size.width / 2, y: size.height * 0.88)
            }
        }
    }
}
