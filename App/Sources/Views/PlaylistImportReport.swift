import SwiftUI

/// After importing playlist files: how many songs each playlist found in the library, and which were not there.
struct PlaylistImportReport: View {
    var report: PlaylistTransfer.Report
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.playlists.count == 1 ? "Playlist Imported" : "\(report.playlists.count) Playlists Imported")
                .font(.title2.bold())
            List {
                ForEach(report.playlists) { playlist in
                    Section {
                        ForEach(Array(playlist.missing.enumerated()), id: \.offset) { _, label in
                            Label(label, systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } header: {
                        HStack {
                            Text(playlist.name).font(.headline)
                            Spacer()
                            Text(playlist.found == playlist.total ? "All \(playlist.total) songs"
                                 : "\(playlist.found) of \(playlist.total) songs found")
                                .foregroundStyle(playlist.found == playlist.total ? Color.secondary : Color.orange)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
            Text("Songs are matched by their file, then by title and artist. Songs that are not in your library are left out: import them first (File, Import) and import the playlist again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}
