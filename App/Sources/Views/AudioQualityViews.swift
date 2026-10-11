import LibraryKit
import PlayerCore
import SwiftUI

extension QualityTier {
    /// Badge color: gold for Hi-Res, teal for Lossless, purple for DSD, neutral for high quality lossy.
    var tint: Color {
        switch self {
        case .hiResLossless: Color(red: 0.88, green: 0.70, blue: 0.30)
        case .lossless: Color(red: 0.35, green: 0.75, blue: 0.80)
        case .dsd: Color(red: 0.70, green: 0.50, blue: 0.95)
        case .highQuality, .standard: .secondary
        }
    }

    var badgeText: String {
        switch self {
        case .hiResLossless: "Hi-Res"
        case .lossless: "Lossless"
        case .dsd: "DSD"
        case .highQuality: "HQ"
        case .standard: ""
        }
    }

    var symbol: String? {
        switch self {
        case .hiResLossless, .lossless: "waveform"
        case .dsd: "waveform.path"
        case .highQuality, .standard: nil
        }
    }

    /// Standard lossy files get no badge, only their specs.
    var hasBadge: Bool { self != .standard }
}

/// Small capsule badge showing the quality tier, like Apple Music's Lossless mark.
struct QualityBadge: View {
    var tier: QualityTier
    var isMini = false

    var body: some View {
        if tier.hasBadge {
            HStack(spacing: 3) {
                if let symbol = tier.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: isMini ? 7 : 8, weight: .bold))
                }
                Text(tier.badgeText.uppercased())
                    .font(.system(size: isMini ? 8 : 9, weight: .bold))
                    .tracking(0.4)
            }
            .foregroundStyle(tier.tint)
            .padding(.horizontal, isMini ? 4 : 6)
            .padding(.vertical, isMini ? 1 : 2)
            .background(tier.tint.opacity(0.14), in: .capsule)
            .overlay(Capsule().strokeBorder(tier.tint.opacity(0.55), lineWidth: 0.8))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tier.displayName)
        }
    }
}

/// Badge plus spec text ("FLAC · 24-bit / 96 kHz"); click for the full details popover.
struct AudioQualityButton: View {
    var track: Track
    var showsText = true
    var isMini = false
    /// Short text for list rows ("FLAC 24/96", "MP3 320") instead of the resolution line.
    var isCompactText = false
    @State private var isShowingDetails = false

    var body: some View {
        let spec = track.audioSpec
        Button {
            isShowingDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                QualityBadge(tier: spec.tier, isMini: isMini)
                if showsText {
                    Text(isCompactText ? spec.compactText : spec.summary)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(spec.tier == .standard ? spec.summary : "\(spec.tier.displayName) · \(spec.summary)")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            AudioDetailsView(track: track)
        }
    }
}

/// Full technical details of a track plus where it is being played.
struct AudioDetailsView: View {
    var track: Track
    @Environment(AppModel.self) private var model

    var body: some View {
        let spec = track.audioSpec
        let player = model.player
        let isCurrent = player.current?.id == track.id
        let outputRate = player.outputSampleRate
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                QualityBadge(tier: spec.tier)
                Text(spec.tier == .standard ? "Compressed" : spec.tier.displayName)
                    .font(.headline)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Format", spec.formatName.map { $0 == spec.codec.shortName ? $0 : "\(spec.codec.shortName) (\($0))" } ?? spec.codec.shortName)
                row("Encoding", spec.codec.isLossless ? "Lossless" : "Lossy")
                row("Sample rate", spec.sampleRateText)
                row("Bit depth", spec.codec.isDSD ? "1-bit" : spec.bitDepth.map { "\($0)-bit" })
                row("Bitrate", spec.bitrateText)
                row("Channels", spec.channelsText)
                row("File size", ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
            }
            .font(.callout)

            if isCurrent, outputRate > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label(player.outputDeviceName ?? "Output", systemImage: "hifispeaker")
                        .font(.callout.weight(.medium))
                    Text(outputDescription(fileRate: spec.sampleRate, outputRate: outputRate, isDSD: spec.codec.isDSD))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).monospacedDigit()
            }
        }
    }

    private func outputDescription(fileRate: Double?, outputRate: Double, isDSD: Bool) -> String {
        let output = String(format: "%g kHz", outputRate / 1_000)
        if isDSD { return "Converted from DSD to PCM, playing at \(output)." }
        guard let fileRate else { return "Playing at \(output)." }
        if abs(fileRate - outputRate) < 1 { return "Playing at the file's native rate (\(output))." }
        return String(format: "Resampled from %g kHz to %@. Set the device to %g kHz in Audio MIDI Setup for native playback.",
                      fileRate / 1_000, output, fileRate / 1_000)
    }
}

extension Track {
    /// Sort key for quality columns (tier first, then sample rate).
    var qualityRank: Double {
        let spec = audioSpec
        return Double(spec.tier.rawValue) * 10_000_000 + (spec.sampleRate ?? 0)
    }
}
