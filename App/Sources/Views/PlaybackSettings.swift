import PlayerCore
import Skins
import SwiftUI

/// Settings, Playback: crossfade, volume normalization (Sound Check) and playback speed.
struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PlaybackPrefs.crossfade) private var crossfade = 0.0
    @AppStorage(PlaybackPrefs.crossfadeSkipsAlbum) private var skipsAlbum = true
    @AppStorage(PlaybackPrefs.normalization) private var normalization = VolumeNormalization.off
    @AppStorage(PlaybackPrefs.rate) private var rate = 1.0
    @AppStorage(PlaybackPrefs.bitPerfect) private var bitPerfect = false
    @AppStorage(PlaybackPrefs.exclusive) private var exclusive = false
    @AppStorage(NowPlayingSkin.tapeCueStorageKey) private var tapeCue = true

    var body: some View {
        Form {
            Section {
                Toggle("Bit-perfect playback", isOn: $bitPerfect)
                if bitPerfect {
                    Toggle("Exclusive access to the output device", isOn: $exclusive)
                    OutputStatusRow()
                }
            } header: {
                Text("Bit-Perfect")
            } footer: {
                Text(bitPerfect
                     ? "The output device switches to each song's sample rate and the samples reach it untouched: the equalizer, crossfade, Sound Check and speed are paused, and the volume slider sets the device's own volume. Exclusive access keeps other apps' sounds from mixing in or changing the rate."
                     : "Plays songs exactly as they are in the files: the output device follows each song's sample rate and nothing in Groovelight changes the sound. Best with a USB DAC.")
                    .foregroundStyle(.secondary)
            }

            Group {
            Section {
                Toggle("Crossfade songs", isOn: Binding(get: { crossfade > 0 }, set: { crossfade = $0 ? 6 : 0 }))
                if crossfade > 0 {
                    LabeledContent("Fade length") {
                        HStack {
                            Slider(value: $crossfade, in: 1...12, step: 1)
                                .frame(width: 220)
                            Text("\(Int(crossfade)) s")
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    Toggle("Keep albums gapless", isOn: $skipsAlbum)
                }
            } header: {
                Text("Crossfade")
            } footer: {
                Text(crossfade > 0
                     ? "Each song fades into the next over the last seconds. With \"Keep albums gapless\", songs that follow each other on the same album play without a fade, as live albums and mixes are meant to be heard."
                     : "Songs follow each other gaplessly.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Volume normalization", selection: $normalization) {
                    Text("Off").tag(VolumeNormalization.off)
                    Text("Songs").tag(VolumeNormalization.track)
                    Text("Albums").tag(VolumeNormalization.album)
                }
                .pickerStyle(.segmented)
                if normalization != .off {
                    let loudness = model.loudness
                    LabeledContent("Songs without ReplayGain") {
                        HStack(spacing: 8) {
                            if loudness?.isRunning == true, (loudness?.measured ?? 0) < (loudness?.total ?? 0) {
                                ProgressView().controlSize(.small)
                            }
                            Text("\(loudness?.measured ?? 0) of \(loudness?.total ?? 0) measured")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sound Check")
            } footer: {
                Text("Plays songs at the same perceived loudness, like Sound Check, from their ReplayGain tags. Songs without tags are measured in the background (EBU R128). \"Albums\" keeps the differences between the songs of an album.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Playback speed") {
                    Picker("Playback speed", selection: $rate) {
                        ForEach(PlaybackPrefs.speeds, id: \.self) { speed in
                            Text(PlaybackPrefs.speedLabel(speed)).tag(Double(speed))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("Changes the speed without changing the pitch. Also in Controls, Playback Speed.")
                    .foregroundStyle(.secondary)
            }
            }
            // Bypassed while bit-perfect playback is on.
            .disabled(bitPerfect)
            Section {
                Toggle("Tape sound when cueing", isOn: $tapeCue)
            } header: {
                Text("Cassette Deck")
            } footer: {
                Text("In Now Playing's cassette deck, holding Rewind or Fast Forward plays the tape racing past the heads, as a real deck does.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: crossfade) { model.player.crossfadeDuration = crossfade }
        .onChange(of: skipsAlbum) { model.player.crossfadeSkipsSameAlbum = skipsAlbum }
        .onChange(of: normalization) {
            model.player.normalization = normalization
            model.loudness.setEnabled(normalization != .off)
        }
        .onChange(of: rate) { model.player.rate = Float(rate) }
        .onChange(of: bitPerfect) { model.player.bitPerfect = bitPerfect }
        .onChange(of: exclusive) { model.player.exclusiveAccess = exclusive }
    }
}

/// The output device and whether the current song reaches it bit-perfect.
struct OutputStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let output = model.player.output
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: output.isBitPerfect ? "checkmark.seal.fill" : "hifispeaker")
                    .foregroundStyle(output.isBitPerfect ? Color.green : .secondary)
                Text(output.deviceName ?? "Output device")
                Spacer()
                Text(OutputStatusRow.format(rate: output.deviceRate, bits: output.deviceBitDepth))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if model.player.current != nil {
                Text(output.isBitPerfect ? "Bit-perfect: the song reaches the device untouched." : output.notes.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(output.isBitPerfect ? Color.green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func format(rate: Double, bits: Int?) -> String {
        guard rate > 0 else { return "" }
        let khz = (rate / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        return bits.map { "\(khz) kHz, \($0)-bit" } ?? "\(khz) kHz"
    }
}
