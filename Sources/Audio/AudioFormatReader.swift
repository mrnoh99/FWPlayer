import AVFoundation
import CoreMedia
import Foundation

enum AudioFormatReader {
    static func sampleRate(for url: URL) async -> Double? {
        await SampleRateCache.shared.sampleRate(for: url)
    }

    static func readSampleRate(from url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks) else { return nil }
        for track in tracks {
            guard let descriptions = try? await track.load(.formatDescriptions) else { continue }
            for description in descriptions {
                guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
                      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      basic.mSampleRate > 0 else { continue }
                return basic.mSampleRate
            }
        }
        return nil
    }

    static func duration(for url: URL) async -> Double? {
        await DurationCache.shared.duration(for: url)
    }

    static func readDuration(from url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// "m:ss" duration string (e.g. 3:23).
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func formatSampleRate(_ hz: Double) -> String {
        if hz >= 1000 {
            let khz = hz / 1000
            if khz.rounded() == khz {
                return String(format: "%.0f kHz", khz)
            }
            return String(format: "%.1f kHz", khz)
        }
        return String(format: "%.0f Hz", hz)
    }
}

actor SampleRateCache {
    static let shared = SampleRateCache()

    private var values: [String: Double] = [:]

    func sampleRate(for url: URL) async -> Double? {
        let key = url.path
        if let cached = values[key] { return cached }
        let rate = await AudioFormatReader.readSampleRate(from: url)
        if let rate { values[key] = rate }
        return rate
    }
}

actor DurationCache {
    static let shared = DurationCache()

    private var values: [String: Double] = [:]

    func duration(for url: URL) async -> Double? {
        let key = url.path
        if let cached = values[key] { return cached }
        let seconds = await AudioFormatReader.readDuration(from: url)
        if let seconds { values[key] = seconds }
        return seconds
    }
}
