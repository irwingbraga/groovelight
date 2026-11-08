import Charts
import LibraryKit
import SwiftUI
import WirelessSyncClient

/// Home, as on the Mac: a greeting, Song, Album and Artist of the Day, and Your Listening (tiles, charts and top lists),
/// all worked out by the Mac from its listening log and kept here for when it is away.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.playerBarInset) private var playerBarInset
    @AppStorage("home.range") private var range: ListeningStats.Range = .month

    var body: some View {
        let home = model.home
        Group {
            if !model.sync.isPaired, home.home == nil {
                ContentUnavailableView {
                    Label("Home", systemImage: "house")
                } description: {
                    Text("Pair with your \(Host.word) to see your song, album and artist of the day, and charts of your listening.")
                } actions: {
                    Button("Pair") { window.isPairing = true }.buttonStyle(.glassProminent)
                }
            } else if home.home == nil {
                if home.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Home", systemImage: "house")
                    } description: {
                        Text(home.error ?? "Your \(Host.word) could not be reached. Home shows once it is.")
                    } actions: {
                        Button("Try Again") { Task { await home.refresh() } }.buttonStyle(.glassProminent)
                    }
                }
            } else {
                content
            }
        }
        .navigationTitle("Home")
        // The greeting is the page's title.
        .toolbarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .regular ? .automatic : .hidden, for: .navigationBar)
        .task(id: model.sync.mac?.id) { await home.refresh() }
    }

    private var content: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                picks
                dashboard.id("dashboard")
            }
            .padding(.horizontal, sizeClass == .regular ? 28 : 16)
            .padding(.top, 8)
            .padding(.bottom, 24 + playerBarInset)
        }
        .refreshable { await model.home.refresh() }
        #if DEBUG
        // `-GLDebugHomeScroll <0 to 1>` scrolls the dashboard that far into view, for layout checks.
        .task {
            let anchor = UserDefaults.standard.double(forKey: "GLDebugHomeScroll")
            guard anchor > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            reader.scrollTo("dashboard", anchor: UnitPoint(x: 0.5, y: anchor))
        }
        #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Self.greeting).font(.title.bold())
            if model.home.isFromAnotherDay, let fetched = model.home.fetchedAt {
                Label("From \(fetched.formatted(.relative(presentation: .named))): your \(Host.word) was not reachable since.",
                      systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private static var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good Morning"
        case 12..<18: "Good Afternoon"
        default: "Good Evening"
        }
    }

    // MARK: Picks

    @ViewBuilder private var picks: some View {
        let cards = Discovery.Kind.allCases.compactMap { model.home.card($0) }
        if sizeClass == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(cards) { PickCard(card: $0) }
            }
        } else {
            // One card at a time, the next peeking in.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cards) { PickCard(card: $0).containerRelativeFrame(.horizontal) { width, _ in min(width * 0.72, 340) } }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Listening").font(.title2.bold())
            Picker("Range", selection: $range) {
                Text("Week").tag(ListeningStats.Range.week)
                Text("Month").tag(ListeningStats.Range.month)
                Text("Year").tag(ListeningStats.Range.year)
                Text("All Time").tag(ListeningStats.Range.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let stats = model.home.home?.stats(range) {
                if stats.plays == 0 && stats.minutes == 0 {
                    ContentUnavailableView("Nothing played yet", systemImage: "chart.bar",
                                           description: Text("Play some music, or import your Last.fm history on your \(Host.word), and your listening shows here."))
                } else {
                    PhoneStatsDashboard(stats: stats)
                }
            }
        }
    }
}

/// One of the day's picks: the cover (tap opens it), what it is and why, Play, Shuffle, Something Else, and Bring Here
/// when its songs are not on this device.
private struct PickCard: View {
    var card: HomeSnapshot.Card
    @Environment(AppModel.self) private var model

    var body: some View {
        let local = localTracks
        let isArtist = card.kind == .artist
        VStack(alignment: .leading, spacing: 10) {
            Text(card.kind.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            NavigationLink(value: route) {
                CatalogCover(hash: card.artworkHash, corner: isArtist ? 0 : 12)
                    .clipShape(isArtist ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 12)))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(route == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline).lineLimit(1)
                Text(card.subtitle).foregroundStyle(.secondary).lineLimit(1)
                Text(card.reasonText).font(.caption).foregroundStyle(.tertiary).lineLimit(2, reservesSpace: true)
            }
            HStack(spacing: 8) {
                if model.playsOnMac {
                    Button { model.playOnMac(card.trackIds) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                    if card.trackIds.count > 1 {
                        Button { model.playOnMac(card.trackIds, shuffle: true) } label: { Image(systemName: "shuffle") }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Shuffle")
                    }
                } else if !local.isEmpty {
                    Button { model.play(local) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                    if local.count > 1 {
                        Button { model.play(local, shuffle: true) } label: { Image(systemName: "shuffle") }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Shuffle")
                    }
                }
                if local.count < card.trackIds.count {
                    Button(action: bringHere) {
                        Label(local.isEmpty && !model.playsOnMac ? "Bring Here" : "Bring the Rest", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glass)
                    .disabled(isRequested)
                }
                Spacer(minLength: 0)
                if model.home.hasAlternatives(card.kind) {
                    Button { withAnimation(.smooth) { model.home.somethingElse(card.kind) } } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Something Else")
                }
            }
            .controlSize(.regular)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 20))
    }

    /// The pick's songs that are on this device, in its order.
    private var localTracks: [Track] {
        let here = card.trackIds.filter { model.catalog.isHere(song: $0) }
        guard !here.isEmpty else { return [] }
        return model.library.read { try LibraryDatabase.tracks($0, ids: here) } ?? []
    }

    private var isRequested: Bool {
        let catalog = model.catalog
        return card.trackIds.allSatisfy { id in
            guard let song = catalog.song(id) else { return catalog.isHere(song: id) }
            return [.onDevice, .arriving, .waiting].contains(catalog.availability(song: song))
        }
    }

    /// Its album or artist page, here when it is here, else the Mac's.
    private var route: LibraryRoute? {
        switch card.kind {
        case .artist:
            return model.catalog.isHere(artist: card.key) ? .artist(card.key) : .macArtist(card.key)
        case .album:
            return model.catalog.isHere(album: card.key) ? .album(card.key) : .macAlbum(card.key)
        case .song:
            guard let id = Int64(card.key) else { return nil }
            let albumKey = model.catalog.song(id)?.albumKey ?? localTracks.first?.albumKey
            guard let albumKey else { return nil }
            return model.catalog.isHere(album: albumKey) ? .album(albumKey) : .macAlbum(albumKey)
        }
    }

    /// Asks the Mac for the pick's songs: the whole album for an album, each song for a song or an artist's essentials.
    private func bringHere() {
        if card.kind == .album {
            model.catalog.request(.add, .album, key: card.key)
        } else {
            for id in card.trackIds where !model.catalog.isHere(song: id) {
                model.catalog.request(.add, .song, key: String(id))
            }
        }
    }
}

/// The dashboard for a phone: tiles two by two, then each chart and list full width (side by side on an iPad).
private struct PhoneStatsDashboard: View {
    var stats: ListeningStats
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var placeNames: [ListeningStats.Place: String] { [.here: Host.word, .devices: "Phones", .lastfm: "Last.fm"] }
    private var placeColors: KeyValuePairs<String, Color> {
        [Host.word: Color.accentColor, "Phones": Color.teal, "Last.fm": Color.red.opacity(0.75)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                tile("Listening", Self.hours(stats.minutes), "clock")
                tile("Plays", stats.plays.formatted(), "play.circle")
                tile("Songs", stats.songs.formatted(), "music.note")
                tile(stats.range == .all ? "Songs Heard" : "New to You", stats.newSongs.formatted(), "sparkles")
                tile("Streak", stats.streak == 1 ? "1 day" : "\(stats.streak) days", "flame")
                tile("Loved", stats.loved.formatted(), "heart")
            }
            panel("Listening Time") { overTime }
            columns {
                panel("When You Listen") { heatMap }
                panel("Where") { places }
            }
            columns {
                panel("Top Songs") { RankedRows(items: stats.topSongs, kind: .song) }
                panel("Top Albums") { RankedRows(items: stats.topAlbums, kind: .album) }
            }
            columns {
                panel("Top Artists") { RankedRows(items: stats.topArtists, kind: .artist) }
                panel("Genres") { bars(stats.genres) }
            }
            panel("Decades") { decades }
            Text("\(stats.librarySongs.formatted()) songs on your \(Host.word), \(stats.neverPlayed.formatted()) never played.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func columns(@ViewBuilder _ content: () -> some View) -> some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 16, content: content)
        } else {
            VStack(alignment: .leading, spacing: 16, content: content)
        }
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 18))
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 18))
    }

    static func hours(_ minutes: Double) -> String {
        minutes >= 120 ? "\((minutes / 60).formatted(.number.precision(.fractionLength(0)))) hr" : "\(Int(minutes.rounded())) min"
    }

    private struct Segment: Identifiable {
        var label: String
        var place: String
        var minutes: Double
        var id: String { label + place }
    }

    private var overTime: some View {
        let segments = stats.buckets.flatMap { bucket in
            ListeningStats.Place.allCases.map { Segment(label: bucket.label, place: placeNames[$0]!, minutes: bucket.minutes[$0] ?? 0) }
        }
        return Chart(segments) { segment in
            BarMark(x: .value("When", Self.shortLabel(segment.label, range: stats.range)), y: .value("Minutes", segment.minutes))
                .foregroundStyle(by: .value("Where", segment.place))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(placeColors)
        .chartLegend(position: .bottom)
        .chartXAxis {
            // Every few bars only (a category axis labels them all).
            let labels = stats.buckets.map { Self.shortLabel($0.label, range: stats.range) }
            let step = max(1, Int((Double(labels.count) / 7).rounded(.up)))
            let shown = Set(labels.enumerated().filter { $0.offset % step == 0 }.map(\.element))
            AxisMarks { value in
                if let label = value.as(String.self), shown.contains(label) { AxisValueLabel() }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let minutes = value.as(Double.self) { Text(Self.hours(minutes)) } }
            }
        }
        .frame(height: 190)
    }

    /// "Mon" for a day of the week, "8" for a day of the month, "Nov" for a month, the year as is.
    static func shortLabel(_ label: String, range: ListeningStats.Range) -> String {
        let parts = label.split(separator: "-")
        switch range {
        case .week:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard parts.count == 3, let date = formatter.date(from: label) else { return label }
            return date.formatted(.dateTime.weekday(.abbreviated))
        case .month:
            return parts.count == 3 ? String(Int(parts[2]) ?? 0) : label
        case .year:
            guard parts.count == 2, let month = Int(parts[1]), (1...12).contains(month) else { return label }
            return Calendar.current.shortMonthSymbols[month - 1]
        case .all:
            return label
        }
    }

    /// Plays by weekday and hour, the busiest hour darkest.
    private var heatMap: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let most = max(stats.hours.flatMap { $0 }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 2) {
                    Text(symbols[day])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let plays = stats.hours[day][hour]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(plays == 0 ? 0.08 : 0.2 + 0.8 * Double(plays) / Double(most)))
                            .frame(height: 14)
                    }
                }
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 14)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plays by weekday and hour")
    }

    private struct Share: Identifiable {
        var name: String
        var plays: Int
        var id: String { name }
    }

    private var places: some View {
        let shares = ListeningStats.Place.allCases.compactMap { place in
            (stats.places[place] ?? 0) > 0 ? Share(name: placeNames[place]!, plays: stats.places[place]!) : nil
        }
        return Chart(shares) { share in
            SectorMark(angle: .value("Plays", share.plays), innerRadius: .ratio(0.6), angularInset: 2)
                .foregroundStyle(by: .value("Where", share.name))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale(placeColors)
        .chartLegend(position: .bottom, spacing: 10)
        .frame(height: 180)
    }

    private func bars(_ items: [ListeningStats.Ranked]) -> some View {
        Chart(items, id: \.key) { item in
            BarMark(x: .value("Plays", item.plays), y: .value("Genre", item.name))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text(item.plays.formatted()).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: max(CGFloat(items.count) * 28, 60))
    }

    private var decades: some View {
        Chart(stats.decades, id: \.key) { item in
            BarMark(x: .value("Decade", item.name), y: .value("Plays", item.plays))
                .foregroundStyle(Color.purple.gradient)
                .cornerRadius(4)
        }
        .frame(height: 170)
    }
}

/// A top list: rank, cover, name and a bar for the plays; albums and artists open their page.
private struct RankedRows: View {
    enum Kind { case song, album, artist }

    var items: [ListeningStats.Ranked]
    var kind: Kind
    @Environment(AppModel.self) private var model

    var body: some View {
        let most = max(items.first?.plays ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.prefix(8).enumerated()), id: \.element.key) { index, item in
                let row = HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    if kind != .artist {
                        CatalogCover(hash: item.artworkHash, size: 36, corner: 5)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.5))
                                .frame(width: max(proxy.size.width * CGFloat(item.plays) / CGFloat(most), 4), height: 4)
                        }
                        .frame(height: 4)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(item.plays.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
                if let route = route(item) {
                    NavigationLink(value: route) { row }.buttonStyle(.plain)
                } else {
                    row
                }
            }
            if items.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
        }
    }

    private func route(_ item: ListeningStats.Ranked) -> LibraryRoute? {
        switch kind {
        case .song: nil
        case .album: model.catalog.isHere(album: item.key) ? .album(item.key) : .macAlbum(item.key)
        case .artist: model.catalog.isHere(artist: item.key) ? .artist(item.key) : .macArtist(item.key)
        }
    }
}
