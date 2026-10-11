import LibraryKit
import MetadataKit
import SwiftUI

extension AlbumInfo {
    /// Main producers (not assistants or executives), for the header's "Produced by" line.
    var producers: [String] {
        let production = sections.first { $0.kind == .production }?.credits ?? []
        return production.filter { $0.roles.contains("producer") || $0.roles.contains("co-producer") }.prefix(3).map(\.name)
    }
}

/// The Wikipedia background as part of a page's title block (like Apple Music's editorial notes): a short excerpt at a
/// readable width, with MORE opening the full text.
struct AboutExcerpt: View {
    var about: AlbumAbout
    @State private var isShowingAll = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(about.summary)
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(3)
                .foregroundStyle(.primary.opacity(0.75))
            Button("MORE") { isShowingAll = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brand)
                .fixedSize()
                .help("Read the full text")
        }
        .frame(maxWidth: 560, alignment: .leading)
        .popover(isPresented: $isShowingAll, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(about.title).font(.headline)
                ScrollView {
                    Text(about.summary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                HStack {
                    Link("Read on Wikipedia", destination: about.url)
                    Spacer()
                    Text("Text from Wikipedia, CC BY-SA").foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            .padding(18)
            .frame(width: 460)
        }
    }
}

/// Credit sections side by side when there is room: section title, then each name (opening their page) over its roles.
struct CreditsGrid: View {
    var sections: [CreditSection]
    var onSelectPerson: (CreditPerson) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 28, alignment: .top)], alignment: .leading, spacing: 24) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.kind.rawValue.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    ForEach(section.credits, id: \.name) { credit in
                        VStack(alignment: .leading, spacing: 1) {
                            LinkText(text: credit.name, help: "Albums and songs with \(credit.name) in your library") {
                                onSelectPerson(CreditPerson(name: credit.name, artistId: credit.artistId))
                            }
                            .font(.system(size: 13, weight: .medium))
                            #if DEBUG
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.creditNames[credit.name] = $0 }
                            #endif
                            Text(credit.roles.joined(separator: ", "))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Credits in a sheet: the album's (from the album page) or one song's.
struct CreditsSheet: View {
    var title: String
    var subtitle: String
    var artworkHash: String?
    var sections: [CreditSection]
    var releaseId: String?
    var isLoading: Bool
    var artistNames: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ArtworkImage(hash: artworkHash, size: .small, cornerRadius: 6)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer()
                Text("Credits").font(.title3.weight(.bold)).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                Group {
                    if !sections.isEmpty {
                        CreditsGrid(sections: sections) { person in
                            // Close the sheet, then open the person's page.
                            dismiss()
                            model.showPerson(person)
                        }
                    } else if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking up credits…").foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView("No Credits Found", systemImage: "person.2",
                                               description: Text("MusicBrainz has no credits for this, or the album could not be matched."))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240, maxHeight: 520)
            HStack {
                if let releaseId, let url = URL(string: "https://musicbrainz.org/release/\(releaseId)") {
                    Link("Credits from MusicBrainz", destination: url).font(.caption)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
    }
}

/// Credits of one song (from its album's MusicBrainz release), loading them if needed.
struct TrackCreditsSheet: View {
    var track: Track
    @Environment(AppModel.self) private var model
    @State private var info: AlbumInfo?
    @State private var didLoad = false
    @State private var artistNames: Set<String> = []

    var body: some View {
        CreditsSheet(title: track.title, subtitle: "\(track.displayArtist) · \(track.displayAlbum)", artworkHash: track.artworkHash,
                     sections: info?.sections(forTrack: track) ?? [], releaseId: info?.releaseId,
                     isLoading: model.metadata.albumInfoInFlight.contains(track.albumKey) || !didLoad, artistNames: artistNames)
            .task {
                await model.metadata.loadAlbumInfo(albumKey: track.albumKey)
                didLoad = true
            }
            .observing(model.database, id: track.albumKey, { [key = track.albumKey] db in
                (try LibraryDatabase.albumInfo(db, albumKey: key)?.data, try LibraryDatabase.artists(db).map(\.name))
            }) { value in
                info = value.0.flatMap { try? JSONDecoder().decode(AlbumInfo.self, from: $0) }
                artistNames = Set(value.1.map { $0.lowercased() })
            }
    }
}
