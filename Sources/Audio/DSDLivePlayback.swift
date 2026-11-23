import AudioToolbox
import AVFoundation
import Foundation
import os

// MARK: - Playback backend

/// What `AudioPlayer` needs from something that plays one track. `AVAudioPlayer`
/// (via an extension in AudioPlayer.swift) and `DSDLivePlayback` both provide it.
protocol PlaybackBackend: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var volume: Float { get set }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    /// Stops reporting that the track finished (used when the backend is discarded).
    func detach()
}

// MARK: - Live DSD rendering
//
// Instead of converting a DSD file into a big temporary WAV first, DSD is turned into
// audio *while it plays*: a background thread reads and (for PCM) filters the DSD
// into a ring buffer, and the audio engine's render callback drains it.
//
// For DoP the ring holds only the 16 DSD bits of each sample; the callback adds the
// 0x05 / 0xFA marker byte itself from a single running frame counter. That makes the
// marker sequence continuous through pauses, buffer under-runs and seeks — the
// callback keeps emitting DSD silence (0x69 bytes) instead of stopping, so the DAC
// stays locked on DSD and there is no click when pausing.

final class DSDLiveRenderer {
    let isDoP: Bool
    let sampleRate: Double

    /// A stable address is required for `os_unfair_lock`, so it's heap-allocated.
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()
    private var ring: [Float]
    private let capacityFrames: Int
    private var readFrame = 0
    private var buffered = 0
    private var frameCounter: UInt64 = 0          // every frame rendered, for the marker phase
    private var musicFrames: Double = 0           // frames of actual music rendered
    private var paused = true
    private var endOfStream = false
    private var leadRemaining: Int
    private var tailRemaining: Int
    private var finishedSent = false
    private let silenceFrames: Int
    // Gapless: frames pushed / rendered in total, and where the next track starts.
    private var produced: UInt64 = 0
    private var consumed: UInt64 = 0
    private var boundaries: [UInt64] = []
    private var completed = 0

    /// Called (once, from the render thread) when the music and tail silence are done.
    var onFinished: (() -> Void)?

    /// `silenceSeconds` of DSD silence is played before the music and after it.
    init(isDoP: Bool, sampleRate: Double, capacitySeconds: Double = 1.5, silenceSeconds: Double) {
        self.isDoP = isDoP
        self.sampleRate = sampleRate
        capacityFrames = max(4096, Int(sampleRate * capacitySeconds))
        ring = [Float](repeating: 0, count: capacityFrames * 2)
        silenceFrames = Int((sampleRate * silenceSeconds).rounded())
        leadRemaining = silenceFrames
        tailRemaining = silenceFrames
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: Producer side

    var freeFrames: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return capacityFrames - buffered
    }

    var bufferedFrames: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return buffered
    }

    /// Appends interleaved L/R samples; returns how many frames were accepted.
    /// DoP: each value is the 16 DSD bits of a channel (0…65535). PCM: a float sample.
    @discardableResult
    func push(_ samples: [Float]) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let frames = min(samples.count / 2, capacityFrames - buffered)
        var write = (readFrame + buffered) % capacityFrames
        for f in 0..<frames {
            ring[2 * write] = samples[2 * f]
            ring[2 * write + 1] = samples[2 * f + 1]
            write += 1
            if write == capacityFrames { write = 0 }
        }
        buffered += frames
        produced &+= UInt64(frames)
        return frames
    }

    /// Marks that the samples pushed from now on belong to the next track.
    func addBoundary() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        boundaries.append(produced)
    }

    /// Next-track boundaries still ahead of the playhead.
    var pendingBoundaries: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return boundaries.count
    }

    /// How many track boundaries the playhead has crossed so far.
    var completedBoundaries: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return completed
    }

    func markEnd() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        endOfStream = true
    }

    /// Drops everything buffered (the reader is about to move) and places the music
    /// clock at `seconds`; the marker phase carries on unbroken.
    func flush(musicSeconds seconds: Double) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        readFrame = 0
        buffered = 0
        endOfStream = false
        finishedSent = false
        tailRemaining = silenceFrames
        musicFrames = seconds * sampleRate
        consumed = produced                     // what was buffered is dropped
        boundaries.removeAll()
    }

    // MARK: Control / state

    func setPaused(_ value: Bool) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        paused = value
    }

    var isPaused: Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return paused
    }

    /// Seconds of music rendered so far (the playback position).
    var musicSeconds: Double {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return musicFrames / sampleRate
    }

    // MARK: Render side

    /// 24-bit DoP word → float, exactly (|value| ≤ 2^23, so the float holds it exactly).
    @inline(__always)
    private func dopSample(marker: UInt32, bits: UInt32) -> Float {
        var word = Int32(bitPattern: (marker << 16) | (bits & 0xFFFF))
        if word & 0x80_0000 != 0 { word -= 0x100_0000 }
        return Float(word) / 8_388_608
    }

    /// Fills `frames` frames of both channels. Never blocks; plays silence (DSD silence
    /// for DoP) when paused or when the buffer runs dry.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var notifyFinished = false
        os_unfair_lock_lock(lock)
        for i in 0..<frames {
            let marker: UInt32 = frameCounter & 1 == 0 ? 0x05 : 0xFA
            var l: Float = 0, r: Float = 0
            var silent = true
            if !paused {
                if leadRemaining > 0 {
                    leadRemaining -= 1
                } else if buffered > 0 {
                    if let boundary = boundaries.first, consumed >= boundary {
                        boundaries.removeFirst()
                        completed += 1
                        musicFrames = 0         // a new track starts here
                    }
                    consumed &+= 1
                    let a = ring[2 * readFrame], b = ring[2 * readFrame + 1]
                    readFrame += 1
                    if readFrame == capacityFrames { readFrame = 0 }
                    buffered -= 1
                    musicFrames += 1
                    if isDoP {
                        l = dopSample(marker: marker, bits: UInt32(max(0, a)))
                        r = dopSample(marker: marker, bits: UInt32(max(0, b)))
                    } else {
                        l = a
                        r = b
                    }
                    silent = false
                } else if endOfStream {
                    if tailRemaining > 0 {
                        tailRemaining -= 1
                    } else if !finishedSent {
                        finishedSent = true
                        notifyFinished = true
                    }
                }
            }
            if silent, isDoP {
                l = dopSample(marker: marker, bits: 0x6969)
                r = l
            }
            left[i] = l
            right[i] = r
            frameCounter &+= 1
        }
        os_unfair_lock_unlock(lock)
        if notifyFinished { onFinished?() }
    }
}

// MARK: - Live playback (AVAudioEngine)

/// A source of interleaved stereo float PCM for the live engine.
struct PCMSource {
    let sampleRate: Double
    let durationSeconds: Double
    let label: String
    /// The next run of interleaved L,R samples, or nil at the end.
    let next: () throws -> [Float]?
    let seek: (Double) throws -> Void
}

enum DSDLiveError: LocalizedError {
    case rateMismatch(Double, Double)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .rateMismatch(let hardware, let wanted):
            return "The output runs at \(Int(hardware)) Hz, not the \(Int(wanted)) Hz DoP needs."
        case .engine(let reason): return "Audio engine: \(reason)"
        }
    }
}

/// Plays a DSD stream live: no temporary file, playback starts at once.
final class DSDLivePlayback: PlaybackBackend {
    let plan: DSDDoPDecoder.Plan
    private let reader: DSDStreamReader?
    /// Set instead of `reader` when this plays plain PCM (e.g. FLAC streamed from a share).
    private let pcm: PCMSource?
    let renderer: DSDLiveRenderer
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    private let producerLock = NSLock()
    private var stopRequested = false
    private var pendingSeek: Double?
    private var producer: Thread?
    private var nextSource: PCMSource?          // gapless: the track to continue with (producerLock)
    private var pendingRewind = false           // a seek landed while still in the previous track
    private var rewinds = 0
    private var started = false
    private var detached = false

    /// Called on the main queue when the track has played to the end.
    var onFinished: (() -> Void)?

    /// Called on the main queue when reading the source failed for good (e.g. the network
    /// share went away), so the user is told why playback stopped.
    var onFailed: ((String) -> Void)?

    /// A failed read is retried this many times, half a second apart, before giving up.
    /// (Variables so tests can shorten them.)
    static var maxReadRetries = 20
    static var readRetryInterval: TimeInterval = 0.5

    init(reader: DSDStreamReader, plan: DSDDoPDecoder.Plan) {
        self.reader = reader
        self.pcm = nil
        self.plan = plan
        renderer = DSDLiveRenderer(isDoP: plan.useDoP, sampleRate: Double(plan.outputRate),
                                   silenceSeconds: DSDDoPDecoder.silenceSeconds)
    }

    /// Seconds of audio read ahead for PCM from a share (rides out network hiccups).
    static let pcmBufferSeconds = 10.0

    /// Live PCM playback (no DSD): the same engine, ring buffer and seek handling.
    init(pcm: PCMSource) {
        self.reader = nil
        self.pcm = pcm
        let rate = Int(pcm.sampleRate)
        self.plan = DSDDoPDecoder.Plan(dsdRate: 0, multiple: 0, useDoP: false, outputRate: rate, label: pcm.label)
        renderer = DSDLiveRenderer(isDoP: false, sampleRate: pcm.sampleRate,
                                   capacitySeconds: Self.pcmBufferSeconds + 1, silenceSeconds: 0)
        segmentDuration = pcm.durationSeconds
    }

    // MARK: Gapless (PCM only)

    var isPCM: Bool { pcm != nil }

    /// The duration shown for the track now playing (follows gapless track changes).
    var segmentDuration: TimeInterval = 0

    /// Tracks the playhead has moved into since playback began.
    var completedSegments: Int { renderer.completedBoundaries }

    /// Increments when a seek pulled playback back into a track whose successor had
    /// already been taken (the successor must be queued again).
    var rewindEpoch: Int {
        producerLock.lock(); defer { producerLock.unlock() }
        return rewinds
    }

    /// True while no successor is queued.
    var wantsNext: Bool {
        producerLock.lock(); defer { producerLock.unlock() }
        return nextSource == nil
    }

    /// Queues the track to continue with once this one ends, without a gap. Only a
    /// source at the same sample rate can join the running stream.
    @discardableResult
    func queueNext(_ source: PCMSource) -> Bool {
        guard pcm != nil, Int(source.sampleRate) == plan.outputRate else { return false }
        producerLock.lock(); defer { producerLock.unlock() }
        nextSource = source
        return true
    }

    func clearNext() {
        producerLock.lock(); defer { producerLock.unlock() }
        nextSource = nil
    }

    deinit { shutDown() }

    // MARK: PlaybackBackend

    var isPlaying: Bool { started && !renderer.isPaused }

    var currentTime: TimeInterval {
        get { renderer.musicSeconds }
        set { seek(to: newValue) }
    }

    var duration: TimeInterval { reader?.durationSeconds ?? segmentDuration }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = plan.useDoP ? 1 : newValue }   // DoP must stay at unity
    }

    @discardableResult
    func play() -> Bool {
        do {
            try startEngineIfNeeded()
        } catch {
            return false
        }
        renderer.setPaused(false)
        return true
    }

    func pause() {
        // The engine keeps running (silence / DSD silence), so the DAC stays locked.
        renderer.setPaused(true)
    }

    func stop() {
        shutDown()
    }

    func detach() {
        detached = true
        renderer.onFinished = nil
    }

    // MARK: Setup

    /// Builds the audio graph and starts the producer thread. Throws if the output
    /// can't carry the stream bit-exactly.
    func prepare() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(plan.outputRate),
                                   channels: 2, interleaved: false)
        guard let format else { throw DSDLiveError.engine("no stream format") }
        let renderer = self.renderer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            // Non-interleaved stereo: two buffers, one per channel. (Read directly instead of
            // through UnsafeMutableAudioBufferListPointer, which Mac Catalyst doesn't expose.)
            guard audioBufferList.pointee.mNumberBuffers >= 2,
                  let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else { return noErr }
            let buffers = UnsafeMutableRawPointer(audioBufferList).advanced(by: offset)
                .assumingMemoryBound(to: AudioBuffer.self)
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            renderer.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        sourceNode = node

        renderer.onFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.detached else { return }
                self.onFinished?()
            }
        }
        try startEngineIfNeeded()
        let hardware = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if plan.useDoP, abs(hardware - Double(plan.outputRate)) > 1 {
            shutDown()
            throw DSDLiveError.rateMismatch(hardware, Double(plan.outputRate))
        }
        startProducer()
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { started = true; return }
        engine.prepare()
        do { try engine.start() } catch { throw DSDLiveError.engine(error.localizedDescription) }
        started = true
    }

    private func shutDown() {
        producerLock.lock()
        stopRequested = true
        producerLock.unlock()
        renderer.setPaused(true)
        if engine.isRunning { engine.stop() }
        started = false
    }

    // MARK: Seeking

    private func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        let rewound = renderer.pendingBoundaries > 0     // still in the track before a gapless join
        producerLock.lock()
        pendingSeek = clamped
        if rewound { pendingRewind = true }
        producerLock.unlock()
        // Silence until the producer has repositioned; the position follows at once.
        renderer.flush(musicSeconds: clamped)
    }

    // MARK: Producer

    func startProducer() {
        let thread = Thread { [weak self] in self?.produceLoop() }
        thread.name = "FWPlayer.DSDLive"
        thread.qualityOfService = .userInitiated
        producer = thread
        thread.start()
    }

    private func produceLoop() {
        let bufferTarget = pcm != nil ? Int(renderer.sampleRate * Self.pcmBufferSeconds)
                                      : Int(renderer.sampleRate)   // DSD: keep ~1 s buffered
        var source = pcm
        var previous: PCMSource?                                  // kept until the playhead leaves it
        var converter = plan.useDoP || reader == nil ? nil : DSDToPCMConverter(dsdRate: plan.dsdRate, multiple: plan.multiple)
        var pendingSamples = [Float]()
        var readFailures = 0

        func waitForSeekOrStop() {
            while true {
                producerLock.lock()
                let done = stopRequested || pendingSeek != nil
                producerLock.unlock()
                if done { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        func reportFailure(_ error: Error) {
            DiagnosticsLog.log("read", "giving up: \(error.localizedDescription)")
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.detached else { return }
                self.onFailed?("Playback stopped: the file could no longer be read (\(text)).")
            }
        }

        while true {
            producerLock.lock()
            let stop = stopRequested
            let seekTo = pendingSeek
            pendingSeek = nil
            let rewind = pendingRewind
            pendingRewind = false
            if rewind { nextSource = nil; rewinds += 1 }
            producerLock.unlock()
            if stop { return }

            if let seekTo {
                // A seek made while still in the previous track of a gapless join: the main thread
                // has already dropped the boundary, so go back to that track before it is forgotten.
                if rewind, let old = previous { source = old; previous = nil }
                try? reader?.seek(toSeconds: seekTo)
                try? source?.seek(seekTo)
                converter = plan.useDoP || reader == nil ? nil : DSDToPCMConverter(dsdRate: plan.dsdRate, multiple: plan.multiple)
                pendingSamples.removeAll()
                renderer.flush(musicSeconds: seekTo)             // drop anything produced before the move
            }
            if previous != nil, renderer.pendingBoundaries == 0 { previous = nil }   // the playhead has left it

            if !pendingSamples.isEmpty {
                let accepted = renderer.push(pendingSamples)
                pendingSamples.removeFirst(min(accepted * 2, pendingSamples.count))
                if !pendingSamples.isEmpty { Thread.sleep(forTimeInterval: 0.01); continue }
            }
            if renderer.bufferedFrames >= bufferTarget {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            if let current = source {
                do {
                    if let samples = try current.next(), !samples.isEmpty {
                        readFailures = 0
                        pendingSamples = samples
                        continue
                    }
                    readFailures = 0
                } catch {
                    // A dropped read (Wi-Fi blip, NAS busy) isn't the end of the track: retry.
                    readFailures += 1
                    DiagnosticsLog.log("read", "failed (\(readFailures)/\(Self.maxReadRetries)): \(error.localizedDescription)")
                    if readFailures <= Self.maxReadRetries {
                        Thread.sleep(forTimeInterval: Self.readRetryInterval)
                        continue
                    }
                    reportFailure(error)
                    renderer.markEnd()
                    waitForSeekOrStop()
                    readFailures = 0
                    continue
                }
                producerLock.lock()
                let following = nextSource
                nextSource = nil
                producerLock.unlock()
                if let following {                                // gapless: carry straight on
                    previous = current
                    source = following
                    renderer.addBoundary()
                    continue
                }
                renderer.markEnd()
                waitForSeekOrStop()
                continue
            }
            let nextChunk: DSDChunk?
            do {
                nextChunk = try reader?.next()
                readFailures = 0
            } catch {
                readFailures += 1
                DiagnosticsLog.log("read", "failed (\(readFailures)/\(Self.maxReadRetries)): \(error.localizedDescription)")
                if readFailures <= Self.maxReadRetries {
                    Thread.sleep(forTimeInterval: Self.readRetryInterval)
                    continue
                }
                reportFailure(error)
                nextChunk = nil
            }
            guard let chunk = nextChunk else {
                renderer.markEnd()
                // Wait for a seek (or stop) once the stream is exhausted.
                waitForSeekOrStop()
                readFailures = 0
                continue
            }
            pendingSamples = plan.useDoP
                ? DSDLivePlayback.dopUnits(left: chunk.left, right: chunk.right)
                : (converter?.convertToFloats(left: chunk.left, right: chunk.right) ?? [])
        }
    }

    /// Pairs of DSD bytes → one 16-bit unit per channel, interleaved, as floats.
    static func dopUnits(left: [UInt8], right: [UInt8]) -> [Float] {
        let frames = min(left.count, right.count) / 2
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            out[2 * f] = Float(UInt32(left[2 * f]) << 8 | UInt32(left[2 * f + 1]))
            out[2 * f + 1] = Float(UInt32(right[2 * f]) << 8 | UInt32(right[2 * f + 1]))
        }
        return out
    }
}
