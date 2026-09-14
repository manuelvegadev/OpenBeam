//
//  NetTrafficMonitor.swift
//  Open Beam
//
//  Per-process wire-bandwidth measurement. macOS exposes no public per-process
//  network byte counter (`rusage_info_v6` has disk + memory but no network;
//  `proc_pidfdinfo` returns socket state, not cumulative TCP `tcpi_txbytes`),
//  so we read nettop's cumulative `bytes_out` and difference it ourselves.
//
//  Sampled as a one-shot per tick rather than a long-lived `nettop -L 0` child,
//  because that mode burns ~1.45 s of CPU for every second it samples
//  (measured identical at -s 1, -s 5 and -s 10, so the interval is not the
//  lever), never exits on its own — a crash or force quit stranded it spinning
//  under launchd until reboot — and line-buffers only to a terminal, so a Pipe
//  reader starves for seconds at a time. A `-L 1` one-shot has none of those
//  properties and costs nothing measurable.
//

import Foundation
import os

final class NetTrafficMonitor: @unchecked Sendable {

    /// A kept baseline older than this spans too much idle time to difference
    /// against, so the next sample re-seeds instead.
    private static let staleBaselineSeconds: CFAbsoluteTime = 10

    private let queue = DispatchQueue(label: "com.openbeam.nettop", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        /// Previous reading, nil until the first sample seeds it.
        var last: (bytes: Int64, at: CFAbsoluteTime)?
        var bytesPerSecondOut: Double = 0
    }

    var bytesPerSecondOut: Double { lock.withLock { $0.bytesPerSecondOut } }

    /// Only worth sampling while something can display the figure, so the
    /// caller ties this to menu visibility.
    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t
        t.resume()
    }

    /// Keeps the baseline so a reopen inside `staleBaselineSeconds` reports a
    /// real figure on its first tick rather than zero.
    func stop() {
        timer?.cancel()
        timer = nil
        lock.withLock { $0.bytesPerSecondOut = 0 }
    }

    // MARK: - Sampling

    private func sample() {
        guard let bytes = Self.readCumulativeBytesOut() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock { st in
            let prev = st.last
            st.last = (bytes, now)
            guard let prev, now > prev.at, now - prev.at <= Self.staleBaselineSeconds else { return }
            st.bytesPerSecondOut = Double(max(bytes - prev.bytes, 0)) / (now - prev.at)
        }
    }

    // The pid cannot change within a process lifetime, so the invocation is
    // fixed for the life of the app.
    private static let nettopURL = URL(fileURLWithPath: "/usr/bin/nettop")
    private static let nettopArguments = [
        "-P",                                          // per-process summary only
        "-p", "\(ProcessInfo.processInfo.processIdentifier)",
        "-L", "1",                                     // a single sample, then exit
        "-J", "bytes_out",                             // emit only what we need
        "-x"                                           // raw numbers, no MiB suffixes
    ]

    /// One `nettop` sample: a CSV header (`,bytes_out,`) then one data line per
    /// matched process, `OpenBeam.<pid>,<cumulative bytes_out>,`.
    private static func readCumulativeBytesOut() -> Int64? {
        let p = Process()
        p.executableURL = nettopURL
        p.arguments = nettopArguments
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            print("[Open Beam] NetTrafficMonitor: nettop failed to start: \(error)")
            return nil
        }
        // Read to EOF before waiting: a child blocked on a full pipe would
        // otherwise deadlock against waitUntilExit.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: true)
            if cols.count >= 2, let bytesOut = Int64(cols[1]) { return bytesOut }
        }
        return nil
    }

    deinit { stop() }
}
