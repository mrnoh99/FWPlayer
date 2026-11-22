import Foundation
#if targetEnvironment(macCatalyst)
import CoreAudio

/// Reads and switches the sample rate of the Mac's default output device (e.g. a
/// USB DAC) so playback runs at each track's native rate with no resampling.
///
/// `AVAudioSession.setPreferredSampleRate` is iOS-only; on Mac Catalyst the
/// device's nominal rate must be set through Core Audio's HAL instead.
enum MacOutputDevice {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (status == noErr && id != kAudioObjectUnknown) ? id : nil
    }

    /// Whether the default output device is attached over USB. Nil if it can't
    /// be determined.
    static func isUSBOutput() -> Bool? {
        guard let device = defaultDeviceID() else { return nil }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyTransportType)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport == UInt32(kAudioDeviceTransportTypeUSB)
    }

    /// The default output device's current nominal sample rate.
    static func currentRate() -> Double? {
        guard let device = defaultDeviceID() else { return nil }
        return nominalRate(of: device)
    }

    private static func nominalRate(of device: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    private static func availableRates(of device: AudioDeviceID) -> [AudioValueRange] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges
    }

    /// The rate to run the device at for a track of `trackRate`: the exact rate
    /// when supported, else the lowest supported integer multiple (44.1 kHz →
    /// 88.2 kHz), which upsamples losslessly in ratio; nil if neither exists.
    static func bestRate(for trackRate: Double, in ranges: [AudioValueRange]) -> Double? {
        func supports(_ r: Double) -> Bool {
            ranges.contains { r >= $0.mMinimum - 0.5 && r <= $0.mMaximum + 0.5 }
        }
        if supports(trackRate) { return trackRate }
        for multiple in 2...8 where supports(trackRate * Double(multiple)) {
            return trackRate * Double(multiple)
        }
        // The device can't reach the track's rate (e.g. a 192 kHz file on a DAC that stops
        // at 96 kHz): run at the highest rate it does support up to the track's, so the
        // system's conversion is as gentle as possible (192 → 96, not 192 → 48). An exact
        // integer divisor is preferred, since that conversion is the simplest.
        for divisor in [2.0, 4.0, 8.0] where supports(trackRate / divisor) {
            return trackRate / divisor
        }
        let highest = ranges.map { $0.mMaximum }.filter { $0 <= trackRate + 0.5 }.max()
        return highest.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The default output device's name and the highest rate it offers, for the status
    /// line ("Prodigy CUBE 2 (up to 96 kHz)"). Nil if it can't be read.
    static func deviceSummary() -> String? {
        guard let device = defaultDeviceID() else { return nil }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = address(kAudioObjectPropertyName)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        let title = status == noErr ? (name as String) : "Output device"
        guard let top = availableRates(of: device).map({ $0.mMaximum }).max(), top > 0 else { return title }
        return "\(title) (up to \(AudioFormatReader.formatSampleRate(top)))"
    }

    /// Switches the default output device to the best rate for `trackRate`.
    /// Returns the device's rate afterwards (nil if there is no output device).
    @discardableResult
    static func match(trackRate: Double) -> Double? {
        guard trackRate > 0, let device = defaultDeviceID() else { return nil }
        let before = nominalRate(of: device)
        guard let target = bestRate(for: trackRate, in: availableRates(of: device)) else { return before }
        if let before, abs(before - target) < 0.5 { return before }

        var value = Float64(target)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { return before }

        // The change is applied asynchronously by the driver; wait briefly so
        // playback starts at the new rate.
        for _ in 0..<30 {
            if let now = nominalRate(of: device), abs(now - target) < 0.5 { return now }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nominalRate(of: device)
    }
}
#endif
