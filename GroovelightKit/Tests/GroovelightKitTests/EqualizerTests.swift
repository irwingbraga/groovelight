import Foundation
import Testing
@testable import PlayerCore

struct EqualizerTests {
    @Test func qAndBandwidthRoundTrip() {
        for q in [0.3, 0.707, 1.41, 4.0, 10.0] {
            let bandwidth = EQMath.bandwidth(fromQ: q)
            #expect(abs(EQMath.qFromBandwidth(bandwidth) - q) < 1e-9)
        }
        // One octave is Q ~ 1.414.
        #expect(abs(EQMath.qFromBandwidth(1) - 1.4142) < 0.001)
    }

    @Test func peakBandHitsItsGainAtCenter() {
        let band = EQBand(frequency: 1_000, gain: 6, q: 1.4)
        #expect(abs(EQMath.response(of: band, at: 1_000) - 6) < 0.01)
        #expect(abs(EQMath.response(of: band, at: 20)) < 0.1)
    }

    @Test func disabledAndFlatBandsAreNeutral() {
        #expect(EQMath.response(of: EQBand(isEnabled: false, frequency: 100, gain: 12), at: 100) == 0)
        for f in EQMath.logSpacedFrequencies(count: 20) {
            #expect(abs(EQMath.response(of: .flat, at: f)) < 1e-6)
        }
    }

    @Test func autoPreampCancelsMaxBoost() {
        let bands = [EQBand(frequency: 100, gain: 9, q: 1)]
        #expect(abs(EQMath.autoPreamp(for: bands) + 9) < 0.2)
        #expect(EQMath.autoPreamp(for: [EQBand(frequency: 100, gain: -6)]) == 0)
    }

    @Test func builtInPresetsHaveFifteenBands() {
        for preset in EQPreset.builtIns {
            #expect(preset.bands.count == EQMath.bandCount)
            #expect(preset.preamp <= 0)
        }
    }

    @Test func parsesAutoEqFile() throws {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
        Filter 2: ON PK Fc 160 Hz Gain -2.1 dB Q 0.83
        Filter 3: OFF HSC Fc 10000 Hz Gain 3.0 dB Q 0.70
        """
        let preset = try #require(ParametricEQFile.parse(text, name: "HD 600"))
        #expect(preset.preamp == -6.2)
        #expect(preset.bands.count == 15)
        #expect(preset.bands[0] == EQBand(type: .lowShelf, frequency: 105, gain: 5.5, q: 0.70))
        #expect(preset.bands[1].type == .peak)
        #expect(preset.bands[2].isEnabled == false)
        #expect(preset.bands[3].isEnabled == false)

        let reparsed = try #require(ParametricEQFile.parse(ParametricEQFile.export(preset), name: "HD 600"))
        #expect(reparsed.bands[0].frequency == 105)
        #expect(reparsed.bands[1].gain == -2.1)
    }
}
