//
//  AudioHealth.swift
//  OpenBeam
//
//  What "the audio broke" means, counted where it can be seen.
//
//  Audio that arrives robotic says nothing about where it went wrong: the same
//  sound comes out of a capture thread that missed its deadline, a stream that
//  stalled on the wire, and a cushion that ran dry. The ear cannot separate
//  them and neither can a meter. Each of the three, though, is an exact event
//  at the place it happens — so each is counted there, and the naming of the
//  culprit is done once, here, rather than guessed at afterwards.
//

import Foundation
import os

/// Where in the path a fault was seen. The order is the order audio travels,
/// which is also the order of blame: a capture that is already broken explains
/// everything downstream of it, so there is no point reporting the rest.
enum AudioStage: Int, Comparable, Sendable {
    case capture, network, playback

    static func < (a: AudioStage, b: AudioStage) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .capture:  return "capture"
        case .network:  return "network"
        case .playback: return "playback"
        }
    }
}

/// A rolling minute of what went wrong, written from three audio threads and
/// read on main.
///
/// Counting rather than sampling: these faults last a few milliseconds and
/// happen minutes apart, so anything that looks at the pipeline once a second
/// sees a healthy one. The whole reason this exists is that the thing to be
/// caught is never happening while you are looking at it.
final class AudioHealth: @unchecked Sendable {

    /// How far back the report reaches. A minute is long enough that a burst
    /// is still there when you open the menu after hearing it, and short
    /// enough that yesterday's bad patch is not still being reported.
    private static let window = 60

    /// One second's worth. Counts are summed across the window and durations
    /// are maxed, because what matters about the worst block in a minute is
    /// that it happened, not how many others were fine.
    private struct Bucket {
        var captureLate = 0
        var networkGaps = 0
        var underruns = 0
        var driftDrops = 0
        var rebuilds = 0
        var worstWork: Double = 0
        var worstSend: Double = 0
        var worstGap: Double = 0
    }

    private struct State {
        var buckets = [Bucket](repeating: Bucket(), count: AudioHealth.window)
        /// Which second the newest bucket holds, so the ones skipped while
        /// nothing was recorded can be cleared rather than counted again a
        /// minute later.
        var second = 0
        /// When the last block arrived, for the gap between it and the next.
        var lastArrival: UInt64 = 0
        var format: (sampleRate: Double, channels: Int)?
        var formatChanges = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Recording

    /// Called on the capture thread once per block. `work` is how long that
    /// thread spent, and the budget is the audio it carried: a block that took
    /// longer to handle than it lasts is one the device had to wait for, which
    /// is the definition of a capture-side dropout.
    func captured(frames: Int, sampleRate: Double, work: Double) {
        guard frames > 0, sampleRate > 0 else { return }
        let budget = Double(frames) / sampleRate
        write { bucket in
            bucket.worstWork = max(bucket.worstWork, work)
            if work > budget { bucket.captureLate += 1 }
        }
    }

    /// Called on the capture thread, with the time spent inside libndi. Split
    /// from the rest of the block's work because it is the one part of it that
    /// waits on something else — see BACKLOG.md, where an audio send and a
    /// 5-9 ms video send can be inside the same instance at once.
    func sent(in duration: Double) {
        write { $0.worstSend = max($0.worstSend, duration) }
    }

    /// Called on the receive thread once per block. The gap since the previous
    /// one is measured here rather than passed in: only this object sees every
    /// block, and a caller keeping its own timestamp would be a second answer
    /// to the same question.
    func received(frames: Int, sampleRate: Double, channels: Int) {
        guard frames > 0, sampleRate > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds

        state.withLock { state in
            rotate(&state, now: now)

            if let last = state.lastArrival.nonZero {
                let gap = Double(now - last) / 1_000_000_000
                state.buckets[index(state.second)].worstGap = max(state.buckets[index(state.second)].worstGap, gap)

                // Measured against how much audio a block carries, not
                // against a fixed figure. Blocks arrive about one block-time
                // apart, so the interval that counts as normal is whatever
                // the source happens to send — 85 ms for a 4096-frame block
                // at 48 kHz, which a fixed 80 ms threshold read as a stall
                // fourteen times a minute on a pair that was working
                // perfectly. Three block-times leaves room for jitter and
                // still catches a block that never came.
                let expected = Double(frames) / sampleRate
                if gap > 3 * expected { state.buckets[index(state.second)].networkGaps += 1 }
            }
            state.lastArrival = now

            let format = (sampleRate: sampleRate, channels: channels)
            if let previous = state.format, previous != format { state.formatChanges += 1 }
            state.format = format
        }
    }

    /// Called on the render thread when the ring had less than was asked for.
    /// Exact rather than inferred: this is the moment the speaker is handed
    /// silence, which is what a listener hears as a click or a stutter.
    ///
    /// Unless nothing was arriving anyway. A cushion that empties because the
    /// source stopped is not a dropout — the silence it produces is the right
    /// answer. A tapped output runs no I/O cycle at all while its device is
    /// idle, so a machine whose meeting is between sentences sends nothing,
    /// and counting that would be counting the quiet.
    func ranDry() {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock { state in
            rotate(&state, now: now)
            guard let last = state.lastArrival.nonZero,
                  Double(now - last) / 1_000_000_000 < 0.5
            else { return }
            state.buckets[index(state.second)].underruns += 1
        }
    }

    /// Called on the render thread when the stream fell far enough behind that
    /// the excess was thrown away.
    func droppedForDrift() {
        write { $0.driftDrops += 1 }
    }

    /// Called when the playback engine was torn down and built again, which is
    /// a gap of its own however briefly it lasts.
    func rebuilt() {
        write { $0.rebuilds += 1 }
    }

    /// The receive side has stopped, so the next block is not late — it is the
    /// first of a new stream.
    /// The rate of the stream being received, once a block has said.
    var receivedSampleRate: Double? { state.withLock { $0.format?.sampleRate } }

    func streamEnded() {
        state.withLock { $0.lastArrival = 0; $0.format = nil }
    }

    // MARK: - Reporting

    struct Report: Equatable {
        var captureLate = 0
        var networkGaps = 0
        var underruns = 0
        var driftDrops = 0
        var rebuilds = 0
        var formatChanges = 0
        var worstWork: Double = 0
        var worstSend: Double = 0
        var worstGap: Double = 0

        /// Everything a listener would have heard.
        ///
        /// Gaps in the stream are not in it, and that is the whole lesson of
        /// the first version: a gap the cushion absorbed cost nobody anything,
        /// and counting it reported fourteen faults a minute on a pair that
        /// sounded perfect. The cushion exists precisely to make gaps
        /// inaudible; a diagnosis that fires when it succeeds is noise.
        ///
        /// `worstWork` and `worstSend` are out for the same reason: a block
        /// that took 4 ms of its 21 ms is worth showing and is not a fault.
        var faults: Int { captureLate + underruns + driftDrops + rebuilds }

        /// Who to blame, which is the earliest stage that fired. Reporting all
        /// three when the first one is broken is how a diagnosis turns back
        /// into the shrug it was meant to replace.
        ///
        /// A gap is not a fault but it is an explanation: when the cushion did
        /// run dry and the stream had stalled, the stall is the reason, and
        /// saying "playback" would send someone to look at the wrong end.
        var stage: AudioStage? {
            if captureLate > 0 { return .capture }
            guard underruns + driftDrops + rebuilds > 0 else { return nil }
            return (networkGaps > 0 || formatChanges > 0) ? .network : .playback
        }
    }

    /// Read on main. Ages the window first, so a pipeline that stopped an hour
    /// ago reports nothing rather than whatever it was doing when it stopped.
    var report: Report {
        state.withLock { state in
            rotate(&state, now: DispatchTime.now().uptimeNanoseconds)

            var report = Report(formatChanges: state.formatChanges)
            for bucket in state.buckets {
                report.captureLate += bucket.captureLate
                report.networkGaps += bucket.networkGaps
                report.underruns += bucket.underruns
                report.driftDrops += bucket.driftDrops
                report.rebuilds += bucket.rebuilds
                report.worstWork = max(report.worstWork, bucket.worstWork)
                report.worstSend = max(report.worstSend, bucket.worstSend)
                report.worstGap = max(report.worstGap, bucket.worstGap)
            }
            return report
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    // MARK: - The window

    private func index(_ second: Int) -> Int {
        ((second % Self.window) + Self.window) % Self.window
    }

    /// Moves to the current second, clearing every bucket passed over on the
    /// way. Clearing on the way forward rather than on read is what lets a
    /// gap of silence expire the window instead of preserving it.
    private func rotate(_ state: inout State, now: UInt64) {
        let second = Int(now / 1_000_000_000)
        guard second != state.second else { return }

        let elapsed = second - state.second
        if elapsed >= Self.window || elapsed < 0 {
            state.buckets = [Bucket](repeating: Bucket(), count: Self.window)
            state.formatChanges = 0
        } else {
            for step in 1...elapsed { state.buckets[index(state.second + step)] = Bucket() }
        }
        state.second = second
    }

    private func write(_ body: (inout Bucket) -> Void) {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock { state in
            rotate(&state, now: now)
            body(&state.buckets[index(state.second)])
        }
    }
}

private extension UInt64 {
    var nonZero: UInt64? { self == 0 ? nil : self }
}
