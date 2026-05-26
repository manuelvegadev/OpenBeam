//
//  NetTrafficMonitor.swift
//  Open Beam
//
//  Per-process wire-bandwidth measurement by piping `nettop -P -p <pid>` and
//  parsing its CSV stream. macOS exposes no public per-process network byte
//  counter (`rusage_info_v6` has disk + memory but no network; `proc_pidfdinfo`
//  returns socket state, not cumulative TCP `tcpi_txbytes`), so we delegate
//  to nettop the same way the user's terminal command does.
//

import Foundation
import os

final class NetTrafficMonitor: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.openbeam.nettop", qos: .utility)
    private var process: Process?
    private var pipe: Pipe?
    private var readBuffer = Data()

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var lastBytesOut: Int64 = -1
        var bytesPerSecondOut: Double = 0
    }

    var bytesPerSecondOut: Double { lock.withLock { $0.bytesPerSecondOut } }

    func start() {
        stop()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = [
            "-P",                                          // parseable CSV mode
            "-p", "\(ProcessInfo.processInfo.processIdentifier)",
            "-L", "0",                                     // run continuously
            "-s", "1",                                     // 1s sample interval
            "-J", "bytes_out",                             // emit only what we need
            "-x"                                           // line-buffered output
        ]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.ingest(data) }
        }

        do {
            try p.run()
            self.process = p
            self.pipe = outPipe
        } catch {
            print("[Open Beam] NetTrafficMonitor: nettop failed to start: \(error)")
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        pipe = nil
        queue.async { [weak self] in
            self?.readBuffer.removeAll()
            self?.lock.withLock {
                $0.lastBytesOut = -1
                $0.bytesPerSecondOut = 0
            }
        }
    }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            guard let s = String(data: line, encoding: .utf8) else { continue }
            handle(line: s)
        }
    }

    /// nettop emits a CSV header (`,bytes_out,`) then one data line per sample
    /// looking like `OpenBeam.<pid>,<cumulative bytes_out>,`. We compute the
    /// delta between consecutive samples; each sample is ~1s.
    private func handle(line: String) {
        let cols = line.split(separator: ",", omittingEmptySubsequences: true)
        guard cols.count >= 2, let bytesOut = Int64(cols[1]) else { return }

        lock.withLock { st in
            if st.lastBytesOut < 0 {
                st.lastBytesOut = bytesOut
                return
            }
            let delta = bytesOut - st.lastBytesOut
            st.lastBytesOut = bytesOut
            st.bytesPerSecondOut = Double(max(delta, 0))
        }
    }

    deinit { stop() }
}
