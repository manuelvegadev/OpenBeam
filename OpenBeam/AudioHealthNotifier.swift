//
//  AudioHealthNotifier.swift
//  OpenBeam
//
//  Saying it while it is happening.
//
//  A count in a menu is only read by someone who already suspects something,
//  and the difficulty with this fault is that it happens while nobody is
//  looking — in the middle of the call, with the menu closed. So the app says
//  so at the time, which is also the only way the moment ever gets written
//  down: "it broke at 09:14" is the fact that turns an intermittent fault into
//  a reproducible one.
//

import Foundation
import UserNotifications

/// Only ever touched from the main thread, by the timer that reads the report.
final class AudioHealthNotifier {

    /// How many faults in the window are worth interrupting someone for. One
    /// underrun in a minute is a click nobody noticed; five is audible damage.
    private static let threshold = 5

    /// And how long before saying it again. Audio that is badly broken stays
    /// broken for minutes, and a notification per second would be worse than
    /// the fault.
    private static let cooldown: TimeInterval = 120

    private var lastPosted: Date?
    /// Nil until asked for, false when refused. Asked for on the first burst
    /// rather than at launch: most installs never glitch, and a permission
    /// prompt is a poor way to say hello.
    private var authorized: Bool?
    private var asking = false

    /// Called on a timer that runs whether or not the menu is open.
    func consider(_ report: AudioHealth.Report) {
        guard report.faults >= Self.threshold, let stage = report.stage else { return }
        if let lastPosted, Date().timeIntervalSince(lastPosted) < Self.cooldown { return }

        // Not posted once permission comes back: the next tick does that, if
        // the burst is still going on.
        whenAuthorized(postAfterAsking: false) { [weak self] in self?.post(report, stage: stage) }
    }

    /// A one-off, for a fault the counters cannot see — one past the end of
    /// the pipeline, in a driver that is not ours. Not subject to the
    /// threshold or the cooldown: the caller only says it once. Posted as soon
    /// as permission comes back when this is what asked for it, since there is
    /// no next tick to post it on.
    func notify(title: String, body: String) {
        whenAuthorized(postAfterAsking: true) { [weak self] in self?.deliver(title: title, body: body) }
    }

    /// Runs `post` now if notifications are allowed, and asks when nobody has
    /// yet — running it once granted only if `postAfterAsking`.
    private func whenAuthorized(postAfterAsking: Bool, _ post: @escaping () -> Void) {
        switch authorized {
        case .some(false):
            return
        case .some(true):
            post()
        case nil:
            requestAuthorization { granted in if granted && postAfterAsking { post() } }
        }
    }

    private func requestAuthorization(then completion: @escaping (Bool) -> Void) {
        guard !asking else { return }
        asking = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                self.authorized = granted
                completion(granted)
            }
        }
    }

    private func post(_ report: AudioHealth.Report, stage: AudioStage) {
        lastPosted = Date()
        deliver(title: "Audio is breaking up", body: AudioHealthNotifier.summary(report, stage: stage))
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The one sentence. Says the count and the stage and nothing else: the
    /// numbers behind it are in the menu, and a notification that needs
    /// reading twice has failed at the one thing it is for.
    static func summary(_ report: AudioHealth.Report, stage: AudioStage) -> String {
        let count = report.faults
        let noun = count == 1 ? "dropout" : "dropouts"
        return "\(count) \(noun) in the last minute — \(stage.name)"
    }
}
