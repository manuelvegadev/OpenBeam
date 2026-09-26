//
//  AudioOutputPlayer.swift
//  OpenBeam
//
//  Plays the audio arriving from the network on an output device of the
//  user's choosing — the half of Receive that makes the other machine
//  audible in the room rather than only inside a video call app.
//

import AVFoundation
import Accelerate
import CoreAudio
import os

final class AudioOutputPlayer: @unchecked Sendable {

    /// The cushion the received stream is playing with right now, for the
    /// statistics. Zero when nothing is playing.
    var cushion: Double { ringLock.withLock { $0 }?.cushion ?? 0 }

    private let peakLock = OSAllocatedUnfairLock(initialState: Float(0))
    var currentPeak: Float { peakLock.withLock { $0 } }

    /// Where a cushion that ran dry is counted. Set only on the player that
    /// carries the received stream: the monitor has one of these too, and its
    /// own underruns are the monitor's business, not the pipeline's.
    var health: AudioHealth?

    private let deviceLock = OSAllocatedUnfairLock<AudioDevices.Device?>(initialState: nil)
    /// The device audio is going to, or nil when nothing is playing.
    var currentDevice: AudioDevices.Device? { deviceLock.withLock { $0 } }
    var isPlaying: Bool { currentDevice != nil }

    /// What the engine is built for, consulted on the receive thread for every
    /// block that arrives. `rebuilding` is what keeps a source the engine
    /// cannot be built for — a device that has been unplugged — from queueing
    /// one rebuild per block for as long as it stays gone.
    private struct EngineFormat {
        var sampleRate: Double = 0
        var channels: Int = 0
        var isReady = false
        var rebuilding = false
    }
    private let formatLock = OSAllocatedUnfairLock(initialState: EngineFormat())

    /// Written on `queue`, read on the receive thread for every block.
    private let ringLock = OSAllocatedUnfairLock<RingBuffer?>(initialState: nil)

    private let queue = DispatchQueue(label: "com.openbeam.audio-output")
    private var target: AudioOutputTarget?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Nothing is built here: the engine's format is the source's, and that is
    /// only known once the first block has arrived.
    func start(target: AudioOutputTarget) {
        queue.async {
            guard self.target != target else { return }
            self.target = target
            self.teardown()
        }
    }

    func stop() {
        queue.async {
            self.target = nil
            self.teardown()
        }
    }

    // MARK: - Receiving audio

    /// What a block arriving from the network can do with the engine as it
    /// stands. "Ask for one" and "wait for the one being built" have to be
    /// different answers: blocks arrive every 10 ms, and treating the second
    /// as the first queued a rebuild per block and rebuilt for ever — the
    /// engine was torn down again before its cushion had filled, so nothing
    /// was ever played.
    private enum Readiness { case ready, waiting, needsRebuild }

    /// Called on the NDI receive thread. Copies the block into the ring, and
    /// asks for an engine when there is none for this format yet.
    func play(_ audio: PlanarAudio) {
        guard audio.frameCount > 0, audio.channelCount > 0 else { return }

        let readiness = formatLock.withLock { format -> Readiness in
            if format.isReady, format.sampleRate == audio.sampleRate, format.channels == audio.channelCount {
                return .ready
            }
            guard !format.rebuilding else { return .waiting }
            format.rebuilding = true
            return .needsRebuild
        }

        switch readiness {
        case .waiting:
            return
        case .needsRebuild:
            let sampleRate = audio.sampleRate
            let channels = audio.channelCount
            queue.async { self.rebuild(sampleRate: sampleRate, channels: channels) }
            return
        case .ready:
            break
        }

        peakLock.withLock {
            $0 = AudioLevel.peak(planar: audio.data,
                                 frames: audio.frameCount,
                                 channels: audio.channelCount,
                                 channelStride: audio.channelStride)
        }
        ringLock.withLock { $0 }?.write(audio)
    }

    // MARK: - Engine

    private func rebuild(sampleRate: Double, channels: Int) {
        let wasRunning = engine != nil
        teardown()
        guard let target else {
            formatLock.withLock { $0.rebuilding = false }
            return
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)) else {
            retryLater()
            return
        }

        let engine = AVAudioEngine()

        // Touching `audioUnit` instantiates the output unit, so the device has
        // to be chosen before anything else asks the engine about its format.
        // `.systemDefault` sets nothing: an untouched engine already follows
        // the system default, and says so through a configuration change when
        // the user switches it mid-stream.
        let device = target.resolvedDevice
        if case .device = target {
            guard let device, let unit = engine.outputNode.audioUnit else {
                print("[OpenBeam] playback: the chosen output is not present")
                retryLater()
                return
            }
            AudioDevices.setDevice(device.id, on: unit)
        }

        // A rebuild mid-stream is a gap of its own, however short. The
        // first build of a session is not: there was nothing playing to
        // interrupt.
        if wasRunning { health?.rebuilt() }

        let ring = RingBuffer(sampleRate: sampleRate, channels: channels, health: health)

        let source = AVAudioSourceNode(format: format) { silence, _, frameCount, audioBufferList in
            let filled = ring.read(into: UnsafeMutableAudioBufferListPointer(audioBufferList),
                                   frames: Int(frameCount))
            if filled == 0 { silence.pointee = true }
            return noErr
        }

        engine.attach(source)
        // Straight into the main mixer, which is what resamples the source's
        // rate to the device's and folds its channels into the device's.
        engine.connect(source, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            print("[OpenBeam] playback engine failed to start: \(error)")
            retryLater()
            return
        }

        self.engine = engine
        ringLock.withLock { $0 = ring }
        deviceLock.withLock { $0 = device }
        formatLock.withLock { $0 = EngineFormat(sampleRate: sampleRate, channels: channels, isReady: true, rebuilding: false) }

        // The engine stops itself when its device disappears or changes shape,
        // and this is the only notice we get that it has to be built again.
        //
        // Not every notice means that, though — starting an engine on a device
        // of our choosing posts one by itself, so rebuilding on each of them
        // rebuilt six times a second for ever, and the cushion never had time
        // to fill. The question worth asking is not whether something changed
        // but whether this engine is still playing where it was told to.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.engine === engine, self.target != nil else { return }

                guard !engine.isRunning || Self.currentDevice(of: engine) != target.resolvedDevice?.id
                else { return }

                self.formatLock.withLock { $0.rebuilding = true }
                self.rebuild(sampleRate: sampleRate, channels: channels)
            }
        }

        print("[OpenBeam] Playing NDI audio on \(device?.name ?? "the system output") — \(Int(sampleRate)) Hz, \(channels) ch")
    }

    /// Which device the engine's output unit ended up on, which is not always
    /// the one it was asked for — an engine following the system default moves
    /// under itself, and a device that goes away takes the engine with it.
    private static func currentDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
        engine.outputNode.audioUnit.flatMap(AudioDevices.device(of:))
    }

    /// Leaves the player idle and lets the next block try again in a moment.
    /// A device can be missing because it is being unplugged and replugged,
    /// which resolves itself; a rebuild per block would not.
    private func retryLater() {
        queue.asyncAfter(deadline: .now() + 1) {
            self.formatLock.withLock { $0 = EngineFormat() }
        }
    }

    private func teardown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        engine = nil
        ringLock.withLock { $0 = nil }
        deviceLock.withLock { $0 = nil }
        peakLock.withLock { $0 = 0 }
        formatLock.withLock { $0 = EngineFormat(rebuilding: $0.rebuilding) }
    }

    deinit {
        queue.sync { teardown() }
    }
}

// MARK: - Ring buffer

/// One writer (the receive thread) and one reader (the render thread), holding
/// interleaved frames so that a single pair of indices describes the whole
/// buffer. Each index has exactly one owner — the writer only ever moves
/// `written`, the reader only ever moves `read` — so neither can undo what the
/// other just did, and the lock is held for two integer reads at a time and
/// never across a copy.
///
/// The two machines' clocks are independent: the sending card decides how much
/// audio arrives, this one decides how fast it leaves, so the buffer drifts in
/// one direction or the other however good the network is. The reader handles
/// both ends of that — it throws away the excess when the stream falls more
/// than `maximum` behind, and goes quiet to fill the cushion again when it
/// runs dry — because moving the read index is the one correction that costs
/// nothing to get wrong twice.
///
/// The cushion itself is the reader's to size: it grows by half each time it
/// runs dry on a stream that was still flowing, up to `ceiling`, and never
/// shrinks while the ring lives. A link that jittered once will again.
final class RingBuffer: @unchecked Sendable {

    /// How much audio is held back before playback starts. The network
    /// delivers in bursts and the output device consumes at a perfectly even
    /// rate; the cushion is the difference between continuous audio and a
    /// click on every jitter.
    ///
    /// It starts small and grows only when it proves too small. Both capture
    /// paths send ~10 ms blocks, and over a Thunderbolt Bridge or a quiet LAN
    /// 30 ms rides them out with room to spare — it was a fixed 80 ms while
    /// the microphone sent 85 ms blocks, and every listener paid for that on
    /// every link. A link that jitters more (Wi-Fi, an older sender still
    /// sending big blocks) costs a few dropouts at the start, each of which
    /// grows the cushion, up to the 80 ms that used to be the only size.
    private static let initialLatency = 0.03
    private static let ceilingLatency = 0.08

    /// How soon the stream has to come back after running dry for the dropout
    /// to count against the cushion. Jitter is a block or two late; a source
    /// that stopped — a tapped output between sentences runs no I/O at all —
    /// stays gone far longer, and growing on that would grow on every pause.
    private static let jitterWindow = 0.25

    let channels: Int
    let sampleRate: Double
    private let capacity: Int
    private let ceiling: Int
    private let storage: UnsafeMutablePointer<Float>
    private let health: AudioHealth?

    /// Reader-owned. `maximum` follows `target` at three times it, the ratio
    /// the fixed 80/240 ms pair had: room for a burst after a stall without
    /// throwing it away.
    private var target: Int
    private var maximum: Int { target * 3 }
    /// When the reader last ran dry, while it waits to know whether that was
    /// jitter or the source stopping.
    private var dryAt: UInt64?
    /// The cushion in seconds, for the statistics.
    var cushion: Double { Double(state.withLock { $0.target }) / sampleRate }

    /// Frame counters rather than offsets: the difference between them is how
    /// much audio is in the buffer, with no empty-or-full ambiguity to resolve.
    /// `target` rides along as main may read it, published when it changes.
    private let state: OSAllocatedUnfairLock<(written: Int, read: Int, target: Int)>
    /// Touched only by the reader, so it needs no protection.
    private var isPrimed = false

    /// A second of storage, and the cushion starting at `initialLatency`.
    init(sampleRate: Double, channels: Int, health: AudioHealth?) {
        self.health = health
        self.channels = max(channels, 1)
        self.sampleRate = sampleRate
        target = Int(sampleRate * Self.initialLatency)
        ceiling = max(Int(sampleRate * Self.ceilingLatency), target)
        state = OSAllocatedUnfairLock(initialState: (written: 0, read: 0, target: target))
        capacity = max(Int(sampleRate), ceiling * 3 * 2)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity * self.channels)
        storage.initialize(repeating: 0, count: self.capacity * self.channels)
    }

    deinit {
        storage.deallocate()
    }

    func write(_ audio: PlanarAudio) {
        guard audio.channelCount == channels else { return }

        let (written, read) = state.withLock { ($0.written, $0.read) }

        // `read` only ever grows, so the free space computed from a stale one
        // is an underestimate — never an overrun.
        let free = capacity - (written - read)
        let count = min(audio.frameCount, free)
        guard count > 0 else { return }

        // Where the buffer wraps is known before the copy starts, so this is
        // two contiguous runs rather than a modulo per sample.
        let start = written % capacity
        let firstRun = min(count, capacity - start)

        for channel in 0..<channels {
            let source = audio.data + channel * audio.channelStride
            copy(from: source, stride: 1,
                 to: storage + start * channels + channel, stride: channels,
                 count: firstRun)
            copy(from: source + firstRun, stride: 1,
                 to: storage + channel, stride: channels,
                 count: count - firstRun)
        }

        state.withLock { $0.written = written + count }
    }

    /// Fills the render buffers and returns how many frames were real audio.
    func read(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        let written = state.withLock { $0.written }
        var read = state.withLock { $0.read }

        var available = written - read
        if available > maximum {
            read += available - target
            available = target
            health?.droppedForDrift()
        }

        if !isPrimed {
            // The stream came back soon after running dry, so it was the
            // cushion that was short, not the source that stopped: wait for a
            // bigger one before playing again.
            if let dryAt, available > 0 {
                self.dryAt = nil
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - dryAt) / 1_000_000_000
                if elapsed < Self.jitterWindow, target < ceiling {
                    target = min(ceiling, target * 3 / 2)
                    let published = target
                    state.withLock { $0.target = published }
                }
            }
            guard available >= target else {
                silence(buffers, frames: frames, from: 0)
                publish(read: read)
                return 0
            }
            isPrimed = true
        }

        let count = min(frames, available)
        let start = read % capacity
        let firstRun = min(count, capacity - start)

        for (channel, buffer) in buffers.enumerated() {
            guard let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            // A device with more channels than the source repeats the last one
            // rather than going silent on the extras.
            let sourceChannel = min(channel, channels - 1)
            copy(from: storage + start * channels + sourceChannel, stride: channels,
                 to: destination, stride: 1,
                 count: firstRun)
            copy(from: storage + sourceChannel, stride: channels,
                 to: destination + firstRun, stride: 1,
                 count: count - firstRun)
        }
        if count < frames { silence(buffers, frames: frames, from: count) }

        read += count
        // Running dry means the cushion is gone; filling it again costs one
        // quiet moment now instead of a click on every block from here on.
        //
        // Counted here rather than at the `isPrimed` check above, because this
        // is the branch where the speaker is handed silence it was not
        // expecting — which is the thing a listener hears.
        if count < frames {
            isPrimed = false
            dryAt = DispatchTime.now().uptimeNanoseconds
            health?.ranDry()
        }

        publish(read: read)
        return count
    }

    private func publish(read: Int) {
        state.withLock { $0.read = read }
    }

    /// One strided copy, which Accelerate vectorises. Interleaving and
    /// de-interleaving are the same operation with the strides swapped, and a
    /// run of zero frames is the wrap that did not happen.
    private func copy(from source: UnsafePointer<Float>, stride sourceStride: Int,
                      to destination: UnsafeMutablePointer<Float>, stride destinationStride: Int,
                      count: Int) {
        guard count > 0 else { return }
        cblas_scopy(Int32(count), source, Int32(sourceStride), destination, Int32(destinationStride))
    }

    private func silence(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, from start: Int) {
        for buffer in buffers {
            guard let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            destination.advanced(by: start).update(repeating: 0, count: frames - start)
        }
    }
}
