import Foundation

/// Opt-in weekly reminder calculation using existing quota refreshes only.
/// Three measurements stay in memory; no history, disk writes, requests or timers.
final class WeeklySurplusMonitor {
    private struct Measurement {
        var date: Date
        var remaining: Double
        var reset: Double
        func continues(_ previous: Measurement) -> Bool {
            reset == previous.reset && date > previous.date &&
            date.timeIntervalSince(previous.date) <= 900 && remaining <= previous.remaining + 0.5
        }
    }
    private var activeAccount: String?
    private var baseline: Measurement?
    private var nextBaseline: Measurement?
    private var previous: Measurement?
    private(set) var enabled: Bool
    private(set) var estimate: WeeklyUsageEstimate?
    init(enabled: Bool = false) { self.enabled = enabled }
    func configure(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        clearMeasurements()
    }
    func select(account: AccountInfo?) {
        let key = ReminderPolicy.accountKey(account)
        guard activeAccount != key else { return }
        activeAccount = key
        clearMeasurements()
    }
    private func clearMeasurements() {
        baseline = nil; nextBaseline = nil; previous = nil; estimate = nil
    }
    func receive(_ reading: Reading) {
        guard enabled else { return }
        select(account: reading.account)
        guard activeAccount != nil, reading.message == "已连接", reading.sync?.lastError == nil,
              reading.sync?.networkAvailable != false, reading.sync?.sleeping != true,
              let date = reading.updated, date.timeIntervalSince1970.isFinite,
              let weekly = reading.weeklyQuota, let remaining = weekly.remaining,
              let reset = weekly.resetsAt, reset.isFinite, reset > date.timeIntervalSince1970 else {
            clearMeasurements(); return
        }
        let current = Measurement(date: date, remaining: remaining, reset: reset)
        if let previous, date <= previous.date { return }
        if previous == nil || !current.continues(previous!) {
            baseline = current; nextBaseline = nil; estimate = nil
        }
        previous = current
        // Advance the baseline hourly to measure the most recent one to two hours
        // without retaining an ever-growing series of samples.
        if let nextBaseline, date.timeIntervalSince(nextBaseline.date) >= 3600 {
            baseline = nextBaseline; self.nextBaseline = current
        }
        guard let baseline else { return }
        let span = date.timeIntervalSince(baseline.date)
        guard span >= 3600 else { estimate = nil; return }
        if nextBaseline == nil { nextBaseline = current }
        estimate = WeeklyUsageEstimate(resetsAt: reset, sampledAt: date,
            percentPerHour: max(0, baseline.remaining - remaining) / span * 3600,
            observedMinutes: Int(span / 60))
    }
}
