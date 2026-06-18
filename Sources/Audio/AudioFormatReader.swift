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
