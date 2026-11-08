import Charts
import LibraryKit
import SwiftUI

/// Home: today's picks, then a dashboard of the listening log (time, plays, when, what) for a range of days.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("home.range") private var range: ListeningStats.Range = .month
    @State private var stats: ListeningStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                picks
                dashboard
            }
            .padding(28)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .task { await model.home.refresh() }
        .observing(model.database, id: range, { [range] db in try LibraryDatabase.listeningStats(db, range: range) }) { stats = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Self.greeting)
                .font(.system(size: 30, weight: .bold))
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
        if cards.isEmpty {
            if model.home.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 18, alignment: .top)], alignment: .leading,
                      spacing: 18) {
                ForEach(cards) { PickCardView(card: $0) }
            }
        }
    }

    // MARK: Dashboard

    @ViewBuilder private var dashboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your Listening")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("Range", selection: $range) {
                    Text("Week").tag(ListeningStats.Range.week)
                    Text("Month").tag(ListeningStats.Range.month)
                    Text("Year").tag(ListeningStats.Range.year)
                    Text("All Time").tag(ListeningStats.Range.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let stats {
                if stats.plays == 0 && stats.minutes == 0 {
                    ContentUnavailableView("Nothing played yet", systemImage: "chart.bar",
                                           description: Text("Play some music, or import your Last.fm history in Settings, Last.fm, and your listening shows here."))
                        .frame(minHeight: 220)
                } else {
                    StatsDashboard(stats: stats)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }
}

/// One of the day's picks: the cover, what it is and why, Play, Shuffle and Something Else.
private struct PickCardView: View {
    var card: HomeStore.Card
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.pick.kind.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(action: open) {
                ArtworkImage(hash: card.artworkHash, size: .large, cornerRadius: card.pick.kind == .artist ? 0 : 12)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(card.pick.kind == .artist ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 12)))
                    .shadow(color: .black.opacity(0.25), radius: isHovering ? 14 : 6, y: isHovering ? 8 : 3)
                    .scaleEffect(isHovering ? 1.015 : 1)
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(card.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(card.pick.reason.text(for: card.pick.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button { model.play(card.tracks) } label: { Label("Play", systemImage: "play.fill") }
                    .glassProminentButtonStyle()
                if card.tracks.count > 1 {
                    Button { model.play(card.tracks, shuffle: true) } label: { Image(systemName: "shuffle") }
                        .glassButtonStyle()
                        .help("Shuffle")
                }
                Spacer()
                if model.home.hasAlternatives(card.pick.kind) {
                    Button { withAnimation(.smooth) { model.home.somethingElse(card.pick.kind) } } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                    }
                    .glassButtonStyle()
                    .help("Something Else (the day's pick comes back after the last)")
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 18))
        .contextMenu {
            Button("Play") { model.play(card.tracks) }
            Button("Shuffle") { model.play(card.tracks, shuffle: true) }
            Button(card.pick.kind == .song ? "Show Album" : "Show") { open() }
        }
    }

    private func open() {
        switch card.pick.kind {
        case .song, .album:
            guard let albumKey = card.tracks.first?.albumKey else { return }
            Task {
                if let album = try? await model.database.writer.read({ db in
                    try LibraryDatabase.albums(db).first { $0.albumKey == albumKey }
                }) {
                    model.path.append(.album(album))
                }
            }
        case .artist:
            model.showArtist(card.pick.key)
        }
    }
}

/// The charts and lists of the listening log.
private struct StatsDashboard: View {
    var stats: ListeningStats
    @Environment(AppModel.self) private var model

    private static let placeNames: [ListeningStats.Place: String] = [.here: "This Mac", .devices: "Phones", .lastfm: "Last.fm"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            tiles
            panel("Listening Time") { overTime }
            HStack(alignment: .top, spacing: 18) {
                panel("When You Listen") { heatMap }
                panel("Where") { places }
                    .frame(maxWidth: 320)
            }
            HStack(alignment: .top, spacing: 18) {
                panel("Top Songs") { RankedList(items: stats.topSongs, showsArtwork: true) }
                panel("Top Albums") { RankedList(items: stats.topAlbums, showsArtwork: true) }
                panel("Top Artists") { RankedList(items: stats.topArtists, showsArtwork: false) }
            }
            HStack(alignment: .top, spacing: 18) {
                panel("Genres") { bars(stats.genres) }
                panel("Decades") { decades }
            }
            library
        }
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
    }

    private var tiles: some View {
        HStack(spacing: 18) {
            tile("Listening", Self.hours(stats.minutes), "clock")
            tile("Plays", stats.plays.formatted(), "play.circle")
            tile("Songs", stats.songs.formatted(), "music.note")
            tile(stats.range == .all ? "Songs Heard" : "New to You", stats.newSongs.formatted(), "sparkles")
            tile("Streak", stats.streak == 1 ? "1 day" : "\(stats.streak) days", "flame")
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
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
            ListeningStats.Place.allCases.map { Segment(label: bucket.label, place: Self.placeNames[$0]!, minutes: bucket.minutes[$0] ?? 0) }
        }
        return Chart(segments) { segment in
            BarMark(x: .value("When", Self.shortLabel(segment.label, range: stats.range)), y: .value("Minutes", segment.minutes))
                .foregroundStyle(by: .value("Where", segment.place))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale([Self.placeNames[.here]!: Color.accentColor, Self.placeNames[.devices]!: Color.teal,
                                    Self.placeNames[.lastfm]!: Color.red.opacity(0.75)])
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisValueLabel() }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let minutes = value.as(Double.self) { Text(Self.hours(minutes)) } }
            }
        }
        .frame(height: 200)
    }

    /// "8" for a day, "Nov" for a month, the year as is.
    static func shortLabel(_ label: String, range: ListeningStats.Range) -> String {
        let parts = label.split(separator: "-")
        switch range {
        case .week:
            guard parts.count == 3, let date = Self.parse(label) else { return label }
            return date.formatted(.dateTime.weekday(.abbreviated))
        case .month:
            return parts.count == 3 ? String(Int(parts[2]) ?? 0) : label
        case .year:
            guard parts.count == 2, let month = Int(parts[1]) else { return label }
            return Calendar.current.shortMonthSymbols[month - 1]
        case .all:
            return label
        }
    }

    private static func parse(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private var heatMap: some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let most = max(stats.hours.flatMap { $0 }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 3) {
                    Text(symbols[day])
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let plays = stats.hours[day][hour]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(plays == 0 ? 0.07 : 0.2 + 0.8 * Double(plays) / Double(most)))
                            .frame(height: 20)
                            .help("\(symbols[day]) \(hour):00, \(plays == 1 ? "1 play" : "\(plays) plays")")
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 30)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour):00" : "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct Share: Identifiable {
        var name: String
        var plays: Int
        var id: String { name }
    }

    private var places: some View {
        let shares = ListeningStats.Place.allCases.compactMap { place in
            (stats.places[place] ?? 0) > 0 ? Share(name: Self.placeNames[place]!, plays: stats.places[place]!) : nil
        }
        return Chart(shares) { share in
            SectorMark(angle: .value("Plays", share.plays), innerRadius: .ratio(0.6), angularInset: 2)
                .foregroundStyle(by: .value("Where", share.name))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale([Self.placeNames[.here]!: Color.accentColor, Self.placeNames[.devices]!: Color.teal,
                                    Self.placeNames[.lastfm]!: Color.red.opacity(0.75)])
        .chartLegend(position: .bottom, spacing: 12)
        .frame(height: 190)
    }

    private func bars(_ items: [ListeningStats.Ranked]) -> some View {
        Chart(items, id: \.key) { item in
            BarMark(x: .value("Plays", item.plays), y: .value("Genre", item.name))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text(item.plays.formatted()).font(.system(size: 10)).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: max(CGFloat(items.count) * 26, 60))
    }

    private var decades: some View {
        Chart(stats.decades, id: \.key) { item in
            BarMark(x: .value("Decade", item.name), y: .value("Plays", item.plays))
                .foregroundStyle(Color.purple.gradient)
                .cornerRadius(4)
        }
        .frame(height: 180)
    }

    private var library: some View {
        HStack(spacing: 18) {
            tile("In Your Library", stats.librarySongs.formatted(), "music.note.list")
            tile("Never Played", stats.neverPlayed.formatted(), "moon.zzz")
            tile("Loved", stats.loved.formatted(), "heart")
        }
    }
}

/// A top list: rank, cover, name and a bar for the plays.
private struct RankedList: View {
    var items: [ListeningStats.Ranked]
    var showsArtwork: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let most = max(items.first?.plays ?? 1, 1)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.prefix(8).enumerated()), id: \.element.key) { index, item in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    if showsArtwork {
                        ArtworkImage(hash: item.artworkHash, size: .small, cornerRadius: 4)
                            .frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.5))
                                .frame(width: max(proxy.size.width * CGFloat(item.plays) / CGFloat(most), 4), height: 4)
                        }
                        .frame(height: 4)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(item.plays.formatted())
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
                .onTapGesture(count: 2) { open(item) }
            }
            if items.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ item: ListeningStats.Ranked) {
        if !showsArtwork {
            model.showArtist(item.key)
        } else if let id = Int64(item.key) {
            Task {
                if let tracks = try? await model.database.writer.read({ db in try LibraryDatabase.tracks(db, ids: [id]) }) {
                    model.play(tracks)
                }
            }
        } else {
            Task {
                if let album = try? await model.database.writer.read({ db in
                    try LibraryDatabase.albums(db).first { $0.albumKey == item.key }
                }) {
                    model.path.append(.album(album))
                }
            }
        }
    }
}
