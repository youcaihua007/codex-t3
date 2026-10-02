import Foundation

@main enum WeeklySurplusChecks {
    static func main() throws {
        let suite = "local.codext3.weekly-surplus-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 2000000000)
        let account = AccountInfo(type: "chatgpt", email: "demo@example.com", id: "synthetic-a")
        let second = AccountInfo(type: "chatgpt", email: "demo@example.com", id: "synthetic-b")
        let reset = start.addingTimeInterval(7 * 86400).timeIntervalSince1970
        func reading(_ minutes: Double, _ remaining: Double, duration: Int = 10080,
                     resetAt: Double = reset, identity: AccountInfo = account) -> Reading {
            Reading(bucket: Bucket(primary: QuotaWindow(usedPercent: 100 - remaining,
                windowDurationMins: duration, resetsAt: resetAt)),
                updated: start.addingTimeInterval(minutes * 60), message: "已连接", account: identity)
        }
        defaults.set(Data("obsolete history".utf8), forKey: "usageHistory.v1")
        defaults.set(true, forKey: "recordUsageHistory")
        defaults.set(true, forKey: "notifyWeeklySurplus")
        defaults.set(true, forKey: "showUsageForecast")
        defaults.set(true, forKey: "notifyForecastRisk")
        let prefs = Preferences(defaults: defaults)
        precondition(prefs.notifyWeeklySurplus && prefs.weeklyReminderThreshold == 5)
        for key in ["recordUsageHistory", "usageHistory.v1", "showUsageForecast", "notifyForecastRisk"] {
            precondition(defaults.object(forKey: key) == nil, "Removed feature retained a preference or history archive")
        }
        precondition(SettingsPage.allCases.map(\.rawValue) == ["account", "display", "alerts", "about"])
        let originalDefaults = defaults.dictionaryRepresentation() as NSDictionary
        let monitor = WeeklySurplusMonitor()
        for minute in stride(from: 0.0, through: 60.0, by: 5) { monitor.receive(reading(minute, 100 - minute / 10)) }
        precondition(monitor.estimate == nil && !monitor.enabled, "Disabled reminder collected or calculated data")
        monitor.configure(enabled: true)
        for minute in stride(from: 0.0, through: 60.0, by: 5) { monitor.receive(reading(minute, 100 - minute / 10, duration: 300)) }
        precondition(monitor.estimate == nil, "Five-hour quota was used for weekly reminder calculation")
        for minute in stride(from: 0.0, through: 55.0, by: 5) { monitor.receive(reading(minute, 100 - minute / 10)) }
        precondition(monitor.estimate == nil, "Less than one hour enabled a weekly reminder")
        monitor.receive(reading(60, 94))
        precondition(monitor.estimate?.percentPerHour == 6 && monitor.estimate?.observedMinutes == 60)
        let first = monitor.estimate
        monitor.receive(reading(60, 50)); monitor.receive(reading(59, 50))
        precondition(monitor.estimate == first, "A duplicate or out-of-order reading altered the estimate")
        for minute in stride(from: 65.0, through: 180.0, by: 5) { monitor.receive(reading(minute, 94 - (minute - 60) / 20)) }
        precondition(monitor.estimate?.percentPerHour == 3 && monitor.estimate?.observedMinutes == 60,
                     "Baseline failed to advance to recent consumption")
        monitor.receive(reading(185, 100))
        precondition(monitor.estimate == nil, "A refill reused old consumption")
        for minute in stride(from: 190.0, through: 245.0, by: 5) { monitor.receive(reading(minute, 100)) }
        precondition(monitor.estimate?.percentPerHour == 0, "Idle usage must still support a surplus reminder")
        monitor.receive(reading(250, 99, resetAt: reset + 86400))
        precondition(monitor.estimate == nil, "A new cycle reused old consumption")
        for minute in stride(from: 255.0, through: 310.0, by: 5) { monitor.receive(reading(minute, 99, resetAt: reset + 86400)) }
        precondition(monitor.estimate != nil)
        monitor.receive(reading(330, 99, resetAt: reset + 86400))
        precondition(monitor.estimate == nil, "Offline gaps reused old consumption")
        for minute in stride(from: 335.0, through: 390.0, by: 5) { monitor.receive(reading(minute, 99, resetAt: reset + 86400)) }
        precondition(monitor.estimate != nil)
        monitor.receive(reading(395, 99, resetAt: reset + 86400, identity: second))
        precondition(monitor.estimate == nil, "Accounts sharing an email reused the same measurements")
        monitor.select(account: nil)
        precondition(monitor.estimate == nil)
        monitor.configure(enabled: false)
        monitor.configure(enabled: true)
        for minute in stride(from: 0.0, through: 1440.0, by: 5) { monitor.receive(reading(minute, 100 - minute / 600)) }
        precondition((60...120).contains(monitor.estimate!.observedMinutes), "Long-running calculation retained an old baseline")
        var failed = reading(1445, 95); failed.markSyncUnavailable("离线")
        monitor.receive(failed)
        precondition(monitor.estimate == nil, "A failed refresh kept a usable estimate")
        monitor.receive(reading(1450, 95)); precondition(monitor.estimate == nil)
        monitor.configure(enabled: false)
        precondition(monitor.estimate == nil)
        precondition(originalDefaults.isEqual(to: defaults.dictionaryRepresentation()), "Weekly calculation wrote persistent history")
        let reopened = WeeklySurplusMonitor(enabled: true)
        reopened.receive(reading(1455, 95)); precondition(reopened.estimate == nil, "Process restart restored deleted history")
        let old = try JSONDecoder().decode(Reading.self, from: Data(#"{"message":"已连接","detailsCached":false,"showUsageForecast":true,"quotaForecasts":[]}"#.utf8))
        precondition(old.weeklyUsageEstimate == nil && old.weeklyUsageReminder == nil)
        var payload = reading(60, 94); payload.weeklyUsageEstimate = first
        let wire = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(payload.widgetSummary))
        precondition(wire.account == nil && wire.weeklyUsageEstimate == first)
        print("Passed: four settings tabs; deleted history/preferences migration; opt-in weekly-only constant-space calculations without persistence; one-hour warmup and recent rolling baseline; reset/refill/offline/account/restart safety; widget wire compatibility/privacy.")
    }
}
