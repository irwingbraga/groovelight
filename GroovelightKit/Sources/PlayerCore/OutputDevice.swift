import AudioToolbox
import CoreAudio
import Foundation

/// An output device through Core Audio: its sample rates, stream format, volume and exclusive (hog) access. Used for
/// bit-perfect playback, where the device follows each song's sample rate so nothing is resampled.
public struct OutputDevice: Sendable, Equatable {
    public let id: AudioObjectID

    public init(id: AudioObjectID) {
        self.id = id
    }

    /// The device macOS plays sounds through by default.
    public static var systemDefault: OutputDevice? {
        var id = AudioObjectID(kAudioObjectUnknown)
        guard getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id),
              id != kAudioObjectUnknown else { return nil }
        return OutputDevice(id: id)
    }

    public var name: String? {
        var name: Unmanaged<CFString>?
        guard Self.getProperty(id, kAudioObjectPropertyName, &name), let name else { return nil }
        return name.takeRetainedValue() as String
    }

    // MARK: - Sample rate

    public var sampleRate: Double {
        var rate: Float64 = 0
        _ = Self.getProperty(id, kAudioDevicePropertyNominalSampleRate, &rate)
        return rate
    }

    /// Rates the device can run at (ranges; most devices list single values).
    public var availableSampleRates: [ClosedRange<Double>] {
        var address = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum...$0.mMaximum }
    }

    public func supports(sampleRate rate: Double) -> Bool {
        availableSampleRates.contains { $0.contains(rate) || abs($0.lowerBound - rate) < 1 }
    }

    /// Switches the device to `rate`, with the deepest integer stream format it offers at that rate, and waits (up to
    /// about a second) for it to settle. Returns whether the device now runs at that rate.
    @discardableResult
    public func switchTo(sampleRate rate: Double) -> Bool {
        if abs(sampleRate - rate) < 1 { selectBestPhysicalFormat(at: rate); return true }
        guard supports(sampleRate: rate) else { return false }
        if !selectBestPhysicalFormat(at: rate) {
            var value = Float64(rate)
            _ = Self.setProperty(id, kAudioDevicePropertyNominalSampleRate, &value)
        }
        for _ in 0..<40 where abs(sampleRate - rate) >= 1 {
            usleep(25_000)
        }
        return abs(sampleRate - rate) < 1
    }

    // MARK: - Stream format

    /// The first output stream of the device.
    private var outputStream: AudioStreamID? {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    /// Bits per sample the device's converter receives (its physical format), e.g. 24 or 32.
    public var bitDepth: Int? {
        guard let stream = outputStream else { return nil }
        var format = AudioStreamBasicDescription()
        guard Self.getProperty(stream, kAudioStreamPropertyPhysicalFormat, &format), format.mBitsPerChannel > 0 else { return nil }
        return Int(format.mBitsPerChannel)
    }

    /// Picks the physical format with the most bits (integer PCM) at `rate`, so 24-bit files reach the converter whole.
    @discardableResult
    private func selectBestPhysicalFormat(at rate: Double) -> Bool {
        guard let stream = outputStream else { return false }
        var address = Self.address(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                     count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &formats) == noErr else { return false }
        let candidates = formats.map(\.mFormat).filter { format in
            format.mFormatID == kAudioFormatLinearPCM && abs(format.mSampleRate - rate) < 1
        }
        // Integer formats first (what DACs take natively), then the most bits.
        let best = candidates.max { lhs, rhs in
            let lhsInt = lhs.mFormatFlags & kAudioFormatFlagIsFloat == 0, rhsInt = rhs.mFormatFlags & kAudioFormatFlagIsFloat == 0
            if lhsInt != rhsInt { return !lhsInt }
            return lhs.mBitsPerChannel < rhs.mBitsPerChannel
        }
        guard var format = best else { return false }
        return Self.setProperty(stream, kAudioStreamPropertyPhysicalFormat, &format)
    }

    // MARK: - Volume

    /// The device's own volume (0 to 1), nil when it has none (many DACs have a fixed output).
    public var volume: Float? {
        var value: Float32 = 0
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public func setVolume(_ volume: Float) {
        var value = Float32(min(max(volume, 0), 1))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return }
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    // MARK: - Exclusive access

    /// The process holding the device exclusively (-1: nobody).
    public var hogOwner: pid_t {
        var owner: pid_t = -1
        _ = Self.getProperty(id, kAudioDevicePropertyHogMode, &owner)
        return owner
    }

    /// Takes the device for this app only (other apps cannot play through it meanwhile), or gives it back.
    @discardableResult
    public func setExclusive(_ exclusive: Bool) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let owned = hogOwner == me
        guard exclusive != owned else { return true }
        // Setting the property toggles ownership: it takes a free device, or releases one this process holds.
        if exclusive, hogOwner != -1 { return false }
        var value = exclusive ? me : -1
        _ = Self.setProperty(id, kAudioDevicePropertyHogMode, &value)
        return (hogOwner == me) == exclusive
    }

    // MARK: - Core Audio plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Values are plain C data (numbers, structs, an unmanaged CFString): passed through a typed pointer to Core Audio.
    private static func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)) == noErr
        }
    }

    private static func setProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        return withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), UnsafeRawPointer(pointer)) == noErr
        }
    }
}
