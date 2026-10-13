import AVFAudio
import Foundation
import GRDB
import SFBAudioEngine

/// Integrated loudness of a song (EBU R128 / ITU-R BS.1770, in LUFS), for volume normalization of songs without
/// ReplayGain tags: K-weighting, 400 ms blocks every 100 ms, then the absolute (-70 LUFS) and relative (-10 LU) gates.
public enum LoudnessMeter {
    /// ReplayGain 2 reference level: a song measured at -18 LUFS needs no gain.
    public static let referenceLUFS = -18.0

    /// The gain (dB) that brings a song of `loudness` LUFS to the reference.
    public static func gain(forLoudness loudness: Double) -> Double { referenceLUFS - loudness }

    /// Measures a file, or the region of it a cue track covers (`start` and `end` in seconds). Nil for silence.
    public static func measure(url: URL, start: Double? = nil, end: Double? = nil) throws -> Double? {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }
        let format = decoder.processingFormat
        let rate = format.sampleRate
        if let start, start > 0 { try decoder.seek(to: AVAudioFramePosition(start * rate)) }
        var remaining = end.map { AVAudioFramePosition((($0 - (start ?? 0)) * rate).rounded()) } ?? .max

        var meter = Meter(sampleRate: rate, channels: Int(format.channelCount))
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // Some decoders hand out integer samples (FLAC, ALAC, WAV): those are converted to floats first.
        let floatFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: format.channelCount)
        let converter = format.commonFormat == .pcmFormatFloat32 ? nil : floatFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        let converted = floatFormat.flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: capacity) }
        if format.commonFormat != .pcmFormatFloat32, converter == nil || converted == nil { return nil }

        while remaining > 0 {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(Int64(capacity), remaining)))
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            if let converter, let converted {
                try converter.convert(to: converted, from: buffer)
                guard let data = converted.floatChannelData else { break }
                meter.add(data, frames: Int(converted.frameLength))
            } else if let data = buffer.floatChannelData {
                // Decoders usually hand out interleaved samples (one buffer, channels alternating).
                if format.isInterleaved {
                    meter.add(interleaved: data[0], frames: frames)
                } else {
                    meter.add(data, frames: frames)
                }
            } else {
                break
            }
            remaining -= AVAudioFramePosition(frames)
        }
        return meter.integratedLoudness()
    }

    /// The meter itself, fed with deinterleaved float samples.
    struct Meter {
        private var filters: [[Biquad]]
        private let blockSize: Int
        private let step: Int
        /// Mean square energy of each 100 ms step, per channel summed.
        private var stepEnergies: [Double] = []
        private var current = 0.0
        private var inStep = 0

        init(sampleRate: Double, channels: Int) {
            filters = (0..<max(channels, 1)).map { _ in Biquad.kWeighting(sampleRate: sampleRate) }
            step = max(Int(sampleRate / 10), 1)
            blockSize = step * 4
        }

        /// Deinterleaved samples: one buffer per channel.
        mutating func add(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
            add(frames: frames) { channel, frame in data[channel][frame] }
        }

        /// Interleaved samples: one buffer, channels alternating.
        mutating func add(interleaved data: UnsafePointer<Float>, frames: Int) {
            let channels = filters.count
            add(frames: frames) { channel, frame in data[frame * channels + channel] }
        }

        private mutating func add(frames: Int, sample read: (Int, Int) -> Float) {
            let channels = filters.count
            for frame in 0..<frames {
                var energy = 0.0
                for channel in 0..<channels {
                    var sample = Double(read(channel, frame))
                    for stage in 0..<filters[channel].count { sample = filters[channel][stage].process(sample) }
                    // Channel weights are 1 for left, right and center (surround channels are rare in music libraries).
                    energy += sample * sample
                }
                current += energy
                inStep += 1
                if inStep == step {
                    stepEnergies.append(current / Double(step))
                    current = 0
                    inStep = 0
                }
            }
        }

        func integratedLoudness() -> Double? {
            // 400 ms blocks, overlapping by 75%: four consecutive 100 ms steps.
            guard stepEnergies.count >= 4 else { return nil }
            let blocks = (0...(stepEnergies.count - 4)).map { index in
                stepEnergies[index..<(index + 4)].reduce(0, +) / 4
            }
            func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
            let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
            guard !absolute.isEmpty else { return nil }
            let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
            let gated = absolute.filter { loudness($0) > relativeGate }
            guard !gated.isEmpty else { return nil }
            return loudness(gated.reduce(0, +) / Double(gated.count))
        }
    }

    /// A second order filter (direct form I).
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }

        /// BS.1770 K-weighting at any sample rate (the formulas of libebur128, the reference implementation): a high
        /// shelf (head effects) then a high pass (RLB weighting).
        static func kWeighting(sampleRate fs: Double) -> [Biquad] {
            // High shelf: about +4 dB above 1.7 kHz.
            let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
            var k = tan(.pi * f0 / fs)
            let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
            var a0 = 1 + k / q + k * k
            let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                               a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
            // High pass at about 38 Hz.
            let hf = 38.13547087602444, hq = 0.5003270373238773
            k = tan(.pi * hf / fs)
            a0 = 1 + k / hq + k * k
            let pass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / hq + k * k) / a0)
            return [shelf, pass]
        }
    }
}

extension LibraryDatabase {
    /// Songs whose loudness is unknown: no ReplayGain tag and never measured, most recently added first.
    public static func trackIdsNeedingLoudness(_ db: Database, limit: Int) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM track WHERE replayGainTrackGain IS NULL AND loudnessCheckedAt IS NULL
            ORDER BY dateAdded DESC LIMIT ?
            """, arguments: [limit])
    }

    /// Which of `ids` still need measuring.
    public static func trackIdsNeedingLoudness(_ db: Database, among ids: [Int64]) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        let found = Set(try Int64.fetchAll(db, sql: """
            SELECT id FROM track WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            AND replayGainTrackGain IS NULL AND loudnessCheckedAt IS NULL
            """, arguments: StatementArguments(ids)))
        return ids.filter(found.contains)
    }

    public static func loudnessProgress(_ db: Database) throws -> (measured: Int, total: Int) {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE replayGainTrackGain IS NULL") ?? 0
        let measured = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE replayGainTrackGain IS NULL AND loudnessCheckedAt IS NOT NULL") ?? 0
        return (measured, total)
    }

    /// Saves a song's measured loudness (nil: could not be measured; it is not tried again).
    public func setLoudness(_ loudness: Double?, trackId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET loudness = ?, loudnessCheckedAt = ? WHERE id = ?", arguments: [loudness, Date.now, trackId])
        }
    }
}
