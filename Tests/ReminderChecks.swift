import Foundation

final class ReminderTransportFixture: NotificationTransport {
    var allowed = true, fail = false, hold = false
    var requests = 0
    var submitted: [Reminder] = []
    var pending: [String: Reminder] = [:]
    var callbacks: [(Error?) -> Void] = []
    func authorization(_ completion: @escaping (Bool, String) -> Void) { completion(allowed, "fixture") }
    func requestAuthorization(_ completion: @escaping (Bool, String) -> Void) { requests += 1; authorization(completion) }
    func add(_ reminder: Reminder, completion: @escaping (Error?) -> Void) {
        submitted.append(reminder); pending[reminder.identifier] = reminder
        if hold { callbacks.append(completion) }
        else { completion(fail ? NSError(domain: "fixture", code: 1) : nil) }
    }
    func cancel(_ identifiers: [String]) { for id in identifiers { pending.removeValue(forKey: id) } }
    func clearAll() { pending.removeAll() }
}

@main enum ReminderChecks {
    static func main() throws {
        var suites: [String] = []
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        func defaults() -> UserDefaults {
            let suite = "local.codext3.reminder-tests." + UUID().uuidString; suites.append(suite)
            return UserDefaults(suiteName: suite)!
        }
        let base = Date(timeIntervalSince1970: 2100000000)
        var now = base
        func snapshot(short: Double? = 80, week: Double = 60, reset: Double? = nil,
                      weekRate: Double = 0, observed: Int = 120,
                      id: String = "fixture-account-a", weeklyOnly: Bool = false) -> Reading {
            let shortReset = base.addingTimeInterval(3 * 3600).timeIntervalSince1970
            let weekReset = reset ?? base.addingTimeInterval(5 * 3600).timeIntervalSince1970
            let five = QuotaWindow(usedPercent: short.map { 100 - $0 }, windowDurationMins: 300, resetsAt: shortReset)
            let weekly = QuotaWindow(usedPercent: 100 - week, windowDurationMins: 10080, resetsAt: weekReset)
            return Reading(bucket: Bucket(primary: weeklyOnly ? weekly : five, secondary: weeklyOnly ? nil : weekly),
                updated: now, message: "已连接", account: AccountInfo(type: "chatgpt", email: "demo@example.com", id: id, name: "Fixture"),
                sync: SyncInfo(networkAvailable: true), weeklyUsageEstimate:
                    WeeklyUsageEstimate(resetsAt: weekReset, sampledAt: now, percentPerHour: weekRate, observedMinutes: observed))
        }
        func candidates(_ policy: ReminderPolicy, _ reading: Reading, _ options: ReminderOptions) -> [Reminder] {
            policy.usageCandidates(reading: reading, account: ReminderPolicy.accountKey(reading.account)!, options: options, now: now)
        }
        func advance(_ seconds: Double = 60) { now = now.addingTimeInterval(seconds) }
        func stable(_ policy: ReminderPolicy, _ options: ReminderOptions, reading: () -> Reading) -> [Reminder] {
            var result: [Reminder] = []
            for _ in 0..<3 { result = candidates(policy, reading(), options); advance() }
            return result
        }
        let storage = defaults(); let prefs = Preferences(defaults: storage)
        precondition(!prefs.compactMenuBar && !prefs.notifyQuotaRecovery && !prefs.notifyAccountChange && !prefs.notifyWeeklySurplus)
        precondition(prefs.weeklyReminderLead == .twelveHours && ReminderOptions().weeklyLead == .twelveHours)
        precondition(WeeklyReminderLead.allCases.map(\.rawValue) == [6, 12, 24, 48, 72])
        precondition(prefs.weeklyReminderThreshold == 5 && ReminderOptions().weeklySurplusThreshold == 5)
        precondition(WeeklySurplusAlert.threshold(.nan) == 5 && WeeklySurplusAlert.threshold(-2) == 0 && WeeklySurplusAlert.threshold(101) == 100)
        let oldLead = defaults(); oldLead.set(1, forKey: "weeklyReminderLeadHours")
        precondition(Preferences(defaults: oldLead).weeklyReminderLead == .twelveHours, "Removed one-hour choice did not migrate to the new default")
        oldLead.set(6, forKey: "weeklyReminderLeadHours")
        precondition(Preferences(defaults: oldLead).weeklyReminderLead == .sixHours, "An explicit supported preference was overwritten")
        let extended = defaults(); let extendedPrefs = Preferences(defaults: extended)
        extendedPrefs.weeklyReminderLead = .threeDays; extendedPrefs.weeklyReminderThreshold = 37
        let restoredExtended = Preferences(defaults: extended)
        precondition(restoredExtended.weeklyReminderLead == .threeDays && restoredExtended.weeklyReminderThreshold == 37 && restoredExtended.reminderOptions.weeklySurplusThreshold == 37)
        prefs.compactMenuBar = true; prefs.notifyQuotaRecovery = true
        prefs.notifyAccountChange = true; prefs.notifyWeeklySurplus = true; prefs.weeklyReminderLead = .oneDay
        let restored = Preferences(defaults: storage)
        precondition(restored.compactMenuBar && restored.reminderOptions.enabledKinds.count == 3 && restored.weeklyReminderLead == .oneDay)
        precondition(restored.reminderOptions.weeklySurplus, "Weekly reminder incorrectly depends on a removed prediction preference")
        let legacy = Data(#"{"low":{"fixture":{"remaining":10,"sent":true}},"cards":{}}"#.utf8)
        let legacyLedger = try JSONDecoder().decode(ReminderLedger.self, from: legacy)
        precondition(legacyLedger.low["fixture"]?.sent == true && legacyLedger.events.isEmpty, "Old reminder ledger was not migrated")
        let migrationStorage = defaults(), migrationTransport = ReminderTransportFixture()
        var migrationLedger = legacyLedger
        migrationLedger.events["removed-forecast"] = ReminderLedger.Event(kind: .legacyForecastRisk, account: "synthetic", eligible: true, validUntil: base.addingTimeInterval(3600))
        migrationLedger.events["keep-recovery"] = ReminderLedger.Event(kind: .recovery, account: "synthetic", eligible: true, sent: true, validUntil: base.addingTimeInterval(3600))
        migrationStorage.set(try JSONEncoder().encode(migrationLedger), forKey: "reminderLedger.v1")
        migrationTransport.pending["removed-forecast"] = Reminder(identifier: "removed-forecast", accountKey: "synthetic", kind: .legacyForecastRisk, title: "", body: "", fireAt: base)
        let migratedController = ReminderController(transport: migrationTransport, defaults: migrationStorage)
        migratedController.configure(ReminderOptions())
        let migratedLedger = try JSONDecoder().decode(ReminderLedger.self, from: migrationStorage.data(forKey: "reminderLedger.v1")!)
        precondition(migrationTransport.pending.isEmpty && migratedLedger.events["removed-forecast"] == nil)
        precondition(migratedLedger.events["keep-recovery"]?.sent == true && migratedLedger.low["fixture"]?.sent == true, "Removing forecasts erased other notification deduplication")

        let recovery = ReminderOptions(quotaRecovery: true)
        let recoveryPolicy = ReminderPolicy()
        precondition(candidates(recoveryPolicy, snapshot(), recovery).isEmpty, "First positive reading falsely meant quota recovery")
        advance(); precondition(candidates(recoveryPolicy, snapshot(short: 0), recovery).isEmpty)
        advance(); let recovered = candidates(recoveryPolicy, snapshot(short: 90), recovery)
        precondition(recovered.count == 1 && recovered[0].period == 300 && recovered[0].settingsPage == "alerts")
        recoveryPolicy.acknowledge(recovered[0])
        advance(); _ = candidates(recoveryPolicy, snapshot(short: 0), recovery)
        advance(); precondition(candidates(recoveryPolicy, snapshot(short: 50), recovery).isEmpty, "Recovery repeated in the same cycle")
        let restartStorage = defaults(), recoveryTransport = ReminderTransportFixture()
        let recoveryController = ReminderController(transport: recoveryTransport, defaults: restartStorage, options: recovery, clock: { now })
        recoveryController.refreshAuthorization(); recoveryController.receive(snapshot(week: 0, weeklyOnly: true))
        advance()
        let restartedTransport = ReminderTransportFixture()
        let restartedRecovery = ReminderController(transport: restartedTransport, defaults: restartStorage, options: recovery, clock: { now })
        restartedRecovery.refreshAuthorization(); restartedRecovery.receive(snapshot(week: 70, weeklyOnly: true))
        precondition(restartedTransport.submitted.count == 1 && restartedTransport.submitted[0].period == 10080, "Observed weekly recovery was lost on restart")
        restartedRecovery.receive(snapshot(week: 70, weeklyOnly: true))
        precondition(restartedTransport.submitted.count == 1)
        advance(); restartedRecovery.receive(snapshot(week: 0, reset: base.addingTimeInterval(7 * 86400).timeIntervalSince1970, weeklyOnly: true))
        advance(); restartedRecovery.receive(snapshot(week: 100, reset: base.addingTimeInterval(7 * 86400).timeIntervalSince1970, weeklyOnly: true))
        precondition(restartedTransport.submitted.count == 2, "New quota cycle failed to rearm recovery")

        now = base
        let bothRecoveryPolicy = ReminderPolicy()
        _ = candidates(bothRecoveryPolicy, snapshot(short: 0, week: 0), recovery)
        advance()
        let bothRecovered = candidates(bothRecoveryPolicy, snapshot(short: 90, week: 70), recovery)
        precondition(bothRecovered.count == 2 && Set(bothRecovered.compactMap(\.period)) == [300, 10080], "Simultaneous five-hour and weekly recovery suppressed one window")
        for reminder in bothRecovered { bothRecoveryPolicy.acknowledge(reminder) }
        advance(); precondition(candidates(bothRecoveryPolicy, snapshot(short: 90, week: 70), recovery).isEmpty)

        now = base
        let surplus = ReminderOptions(weeklySurplus: true), surplusPolicy = ReminderPolicy()
        let streakPolicy = ReminderPolicy()
        let repeated = snapshot()
        for _ in 0..<5 { precondition(candidates(streakPolicy, repeated, surplus).isEmpty) }
        advance(); precondition(candidates(streakPolicy, snapshot(), surplus).isEmpty)
        advance(); precondition(candidates(streakPolicy, snapshot(), surplus).count == 1)
        let pauseTransport = ReminderTransportFixture(); pauseTransport.hold = true
        let pauseController = ReminderController(transport: pauseTransport, defaults: defaults(), options: surplus, clock: { now })
        pauseController.refreshAuthorization()
        for _ in 0..<3 { pauseController.receive(snapshot()); advance() }
        precondition(pauseTransport.pending.count == 1)
        pauseController.configure(ReminderOptions())
        precondition(pauseTransport.pending.isEmpty && pauseController.weeklyWidgetReminder(for: snapshot()) == nil)
        now = base
        let farReset = base.addingTimeInterval(13 * 3600).timeIntervalSince1970
        precondition(stable(surplusPolicy, surplus, reading: { snapshot(reset: farReset) }).isEmpty, "Reminder was outside its lead time")
        let surplusAlert = stable(surplusPolicy, surplus, reading: { snapshot(weekRate: 2, weeklyOnly: true) })
        precondition(surplusAlert.count == 1 && surplusAlert[0].kind == .weeklySurplus && surplusAlert[0].body.contains("预计还会剩"))
        surplusPolicy.acknowledge(surplusAlert[0])
        var annotated = snapshot(weekRate: 2, weeklyOnly: true)
        annotated.weeklyUsageReminder = surplusPolicy.weeklyWidgetReminder(reading: annotated, options: surplus, now: now)
        precondition(annotated.weeklyUsageReminder != nil, "Delivered notification incorrectly dismissed the widget caption")
        precondition(annotated.weeklyUsageReminderLabel(at: now, compact: true)!.contains("先用余量"))
        precondition(annotated.weeklyUsageReminderLabel(at: now)!.contains("预计剩"))
        var refreshing = annotated; refreshing.sync?.refreshing = true
        precondition(refreshing.weeklyUsageReminderLabel(at: now) == annotated.weeklyUsageReminderLabel(at: now))
        precondition(surplusPolicy.weeklyWidgetReminder(reading: refreshing, options: surplus, now: now) != nil)
        precondition(candidates(surplusPolicy, refreshing, surplus).isEmpty, "In-progress refresh triggered a notification")
        precondition(WidgetReloadCoordinator.signature(for: refreshing) == WidgetReloadCoordinator.signature(for: annotated), "Routine refresh caused redundant caption reloads")
        let wire = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(annotated.widgetSummary))
        precondition(wire.account == nil && wire.weeklyUsageReminder == annotated.weeklyUsageReminder && wire.weeklyUsageReminderLabel(at: now) != nil, "Widget wire stripped the caption or exposed identity")
        precondition(surplusPolicy.weeklyWidgetReminder(reading: annotated, options: ReminderOptions(), now: now) == nil)
        for mode in 0..<7 {
            var invalid = annotated
            switch mode {
            case 0: invalid.markSyncUnavailable("离线")
            case 1: invalid.updated = now.addingTimeInterval(-500)
            case 2: invalid.weeklyUsageEstimate = nil
            case 3: invalid.weeklyUsageEstimate?.sampledAt = now.addingTimeInterval(-500)
            case 4: invalid.weeklyUsageReminder?.resetsAt += 86400
            case 5: invalid.weeklyUsageReminder?.leadHours = 1
            default: invalid.bucket?.primary?.usedPercent = 100
            }
            precondition(invalid.weeklyUsageReminderLabel(at: now) == nil, "Widget encouraged usage with stale, disabled, mismatched or depleted data")
        }
        var oneDay = surplus; oneDay.weeklyLead = .oneDay
        precondition(candidates(surplusPolicy, snapshot(), oneDay).isEmpty, "Changing reminder lead repeated this cycle's reminder")
        for mode in 0..<5 {
            let invalidPolicy = ReminderPolicy()
            precondition(stable(invalidPolicy, surplus, reading: {
                switch mode {
                case 0: return snapshot(week: 8, weekRate: 1)
                case 1: return snapshot(weekRate: 100)
                case 2: return snapshot(observed: 45)
                case 3: return snapshot(short: 0)
                default: var invalid = snapshot(); invalid.weeklyUsageEstimate = nil; return invalid
                }
            }).isEmpty, "Weekly surplus was inferred from insufficient/blocked/at-risk data")
        }
        var sixHours = surplus; sixHours.weeklyLead = .sixHours
        precondition(candidates(ReminderPolicy(), snapshot(reset: now.addingTimeInterval(9 * 3600).timeIntervalSince1970), sixHours).isEmpty)
        now = base
        let oneDayPolicy = ReminderPolicy()
        precondition(stable(oneDayPolicy, oneDay, reading: { snapshot(reset: base.addingTimeInterval(12 * 3600).timeIntervalSince1970) }).count == 1)
        now = base
        var twoDays = surplus; twoDays.weeklyLead = .twoDays
        let twoDayPolicy = ReminderPolicy()
        precondition(stable(twoDayPolicy, twoDays, reading: { snapshot(reset: base.addingTimeInterval(36 * 3600).timeIntervalSince1970) }).count == 1)
        precondition(twoDayPolicy.weeklyWidgetReminder(reading: snapshot(reset: base.addingTimeInterval(36 * 3600).timeIntervalSince1970), options: oneDay, now: now) == nil)

        now = base
        var threeDays = surplus; threeDays.weeklyLead = .threeDays
        let threeDayPolicy = ReminderPolicy(), threeDayReset = base.addingTimeInterval(60 * 3600).timeIntervalSince1970
        precondition(stable(threeDayPolicy, threeDays, reading: { snapshot(reset: threeDayReset) }).count == 1)
        precondition(threeDayPolicy.weeklyWidgetReminder(reading: snapshot(reset: threeDayReset), options: twoDays, now: now) == nil)
        precondition(stable(ReminderPolicy(), threeDays, reading: { snapshot(reset: base.addingTimeInterval(73 * 3600).timeIntervalSince1970) }).isEmpty)
        now = base
        var customThreshold = surplus; customThreshold.weeklySurplusThreshold = 20
        precondition(stable(ReminderPolicy(), customThreshold, reading: { snapshot(week: 20) }).isEmpty,
                     "Projected surplus equal to the threshold must not trigger a greater-than reminder")
        precondition(stable(ReminderPolicy(), customThreshold, reading: { snapshot(week: 24, weekRate: 1) }).isEmpty,
                     "Threshold compared current quota instead of the projected leftover")
        let customPolicy = ReminderPolicy()
        precondition(stable(customPolicy, customThreshold, reading: { snapshot(week: 21) }).count == 1)
        var customCaption = snapshot(week: 21)
        customCaption.weeklyUsageReminder = customPolicy.weeklyWidgetReminder(reading: customCaption, options: customThreshold, now: now)
        precondition(customCaption.weeklyUsageReminder?.minimumRemainingPercent == 20 && customCaption.weeklyUsageReminderLabel(at: now) != nil)
        let customWire = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(customCaption.widgetSummary))
        precondition(customWire.weeklyUsageReminder?.minimumRemainingPercent == 20 && customWire.weeklyUsageReminderLabel(at: now) != nil)
        customCaption.weeklyUsageReminder?.minimumRemainingPercent = 21
        precondition(customCaption.weeklyUsageReminderLabel(at: now) == nil, "Widget ignored the configured threshold")
        let oldMarker = try JSONDecoder().decode(WeeklyUsageReminder.self, from: Data("{\"resetsAt\":\(customCaption.weeklyQuota!.resetsAt!),\"leadHours\":12}".utf8))
        customCaption.weeklyUsageReminder = oldMarker
        precondition(customCaption.weeklyUsageReminderLabel(at: now) != nil, "Old cached reminder did not retain the 5% default")
        let thresholdTransport = ReminderTransportFixture(); thresholdTransport.hold = true
        let thresholdController = ReminderController(transport: thresholdTransport, defaults: defaults(), options: customThreshold, clock: { now })
        thresholdController.refreshAuthorization()
        for _ in 0..<3 { thresholdController.receive(snapshot(week: 21)); advance() }
        precondition(thresholdTransport.pending.count == 1 && thresholdController.weeklyWidgetReminder(for: snapshot(week: 21)) != nil)
        customThreshold.weeklySurplusThreshold = 21
        thresholdController.configure(customThreshold)
        precondition(thresholdTransport.pending.isEmpty && thresholdController.weeklyWidgetReminder(for: snapshot(week: 21)) == nil,
                     "Changing the threshold left an invalid pending notification or widget caption")
        thresholdTransport.callbacks[0](nil)
        precondition(thresholdTransport.pending.isEmpty)
        var allRemaining = surplus; allRemaining.weeklySurplusThreshold = 100
        precondition(stable(ReminderPolicy(), allRemaining, reading: { snapshot(week: 100) }).isEmpty)

        now = base
        let change = ReminderOptions(accountChange: true), changeTransport = ReminderTransportFixture(), changeStorage = defaults()
        let changes = ReminderController(transport: changeTransport, defaults: changeStorage, options: change, clock: { now })
        changes.refreshAuthorization(); changes.receive(snapshot())
        precondition(changeTransport.submitted.isEmpty, "Initial account binding sent a switch notification")
        advance(); changes.receive(snapshot(id: "fixture-account-b")); changes.receive(snapshot(id: "fixture-account-b"))
        precondition(changeTransport.submitted.count == 1 && changeTransport.submitted[0].settingsPage == "account", "Same email with different workspace ID was not distinguished")
        let restartChanges = ReminderTransportFixture()
        let sameAccount = ReminderController(transport: restartChanges, defaults: changeStorage, options: change, clock: { now })
        sameAccount.refreshAuthorization(); sameAccount.receive(snapshot(id: "fixture-account-b"))
        precondition(restartChanges.submitted.isEmpty)
        sameAccount.receive(Reading(message: "请先登录", account: .signedOut))
        advance(); sameAccount.receive(snapshot())
        precondition(restartChanges.submitted.count == 1, "Verified account change after sign-out was missed")
        let asyncTransport = ReminderTransportFixture(); asyncTransport.hold = true
        let asyncController = ReminderController(transport: asyncTransport, defaults: defaults(), options: change, clock: { now })
        asyncController.refreshAuthorization(); asyncController.receive(snapshot())
        advance(); asyncController.receive(snapshot(id: "fixture-account-b"))
        advance(); asyncController.receive(snapshot(id: "fixture-account-c"))
        asyncTransport.callbacks[0](nil)
        precondition(asyncTransport.pending.count == 1 && asyncTransport.pending.values.first?.accountKey == ReminderPolicy.accountKey(snapshot(id: "fixture-account-c").account), "Old callback canceled the new account's notification")
        asyncTransport.callbacks[1](nil); asyncController.receive(snapshot(id: "fixture-account-c"))
        precondition(asyncTransport.submitted.count == 2)

        now = base
        let denied = ReminderTransportFixture(); denied.allowed = false
        let deniedController = ReminderController(transport: denied, defaults: defaults(), options: surplus, clock: { now })
        deniedController.refreshAuthorization()
        for _ in 0..<3 { deniedController.receive(snapshot()); advance() }
        precondition(denied.submitted.isEmpty)
        precondition(deniedController.weeklyWidgetReminder(for: snapshot()) != nil, "Widget caption incorrectly required system-notification permission")
        precondition(deniedController.weeklyWidgetReminder(for: snapshot(id: "fixture-account-other")) == nil, "Widget reminder crossed accounts")
        deniedController.refreshAuthorization(); denied.allowed = true; deniedController.refreshAuthorization()
        precondition(denied.submitted.count == 1, "Denied notification was marked sent or lost eligibility")
        precondition(deniedController.weeklyWidgetReminder(for: snapshot()) != nil)
        deniedController.configure(ReminderOptions(quotaRecovery: true, weeklySurplus: true), requestPermission: true)
        precondition(denied.requests == 0, "Already authorized notifications asked for permission again")
        let failedTransport = ReminderTransportFixture(); failedTransport.fail = true
        let failedController = ReminderController(transport: failedTransport, defaults: defaults(), options: recovery, clock: { now })
        failedController.refreshAuthorization(); failedController.receive(snapshot(short: 0))
        advance(); failedController.receive(snapshot(short: 90)); precondition(failedController.deliveryError != nil)
        failedTransport.fail = false; advance(); failedController.receive(snapshot(short: 90))
        precondition(failedTransport.submitted.count == 2 && failedController.deliveryError == nil)

        now = base
        var menu = snapshot(short: 80, week: 20)
        precondition(menu.menuBarTitle(at: now) == "5h 80% · 周 20%" && menu.menuBarTitle(at: now, compact: true) == "周 20%")
        menu = snapshot(short: 80, week: 0)
        precondition(menu.menuBarTitle(at: now, compact: true) == "周 0%")
        menu = snapshot(short: nil)
        precondition(menu.menuBarTitle(at: now, compact: true) == "周 60%")
        menu = snapshot(weeklyOnly: true)
        precondition(menu.menuBarTitle(at: now, compact: true) == "周 60%")
        menu.sync?.networkAvailable = false
        precondition(menu.menuBarTitle(at: now, compact: true) == "周 60% · 待同步")
        precondition(Reading(message: "已连接").menuBarTitle(at: now, compact: true).contains("额度未提供"))
        let examplePrefs = Preferences(defaults: defaults())
        var exampleChanges = 0; examplePrefs.onChange = { exampleChanges += 1 }
        for kind: Reminder.Kind in [.low, .recovery, .accountChange, .weeklySurplus, .card] {
            let sample = SettingsReminderExample.reading(for: kind, preferences: examplePrefs, weeklyOnly: false, now: now)
            precondition(sample.account == nil && ReminderPolicy.accountKey(sample.account) == nil, "Example data can bind a real account or trigger account notifications")
        }
        let lowExample = SettingsReminderExample.reading(for: .low, preferences: examplePrefs, weeklyOnly: true, now: now)
        precondition(lowExample.weeklyQuotaIsLow && lowExample.fiveHourQuota == nil)
        let surplusExample = SettingsReminderExample.reading(for: .weeklySurplus, preferences: examplePrefs, weeklyOnly: false, now: now)
        precondition(surplusExample.weeklyUsageReminderLabel(at: now) != nil && surplusExample.weeklyUsageReminder?.leadHours == 12)
        precondition(SettingsReminderExample.notifications(for: .recovery, preferences: examplePrefs, weeklyOnly: false, now: now, scenario: .both).count == 2)
        var disabledExample = surplusExample; disabledExample.weeklyUsageEstimate = nil
        precondition(disabledExample.weeklyUsageReminderLabel(at: now) == nil, "Removed or disabled weekly computation retained a widget caption")
        precondition(exampleChanges == 0, "Constructing an example changed live preferences")
        examplePrefs.weeklyReminderLead = .threeDays; examplePrefs.weeklyReminderThreshold = 99
        let configuredExample = SettingsReminderExample.reading(for: .weeklySurplus, preferences: examplePrefs, weeklyOnly: true, now: now)
        precondition(configuredExample.weeklyUsageReminder?.leadHours == 72 && configuredExample.weeklyUsageReminder?.minimumRemainingPercent == 99 && configuredExample.weeklyUsageReminderLabel(at: now) != nil)
        examplePrefs.weeklyReminderThreshold = 100
        let disabledThresholdExample = SettingsReminderExample.reading(for: .weeklySurplus, preferences: examplePrefs, weeklyOnly: true, now: now)
        precondition(disabledThresholdExample.weeklyUsageReminderLabel(at: now) == nil)
        precondition(SettingsReminderExample.notification(for: .weeklySurplus, preferences: examplePrefs, weeklyOnly: true, now: now).body == "当前阈值不会触发提醒。")
        let ledgerText = String(data: try JSONEncoder().encode(surplusPolicy.ledger), encoding: .utf8)!
        precondition(!ledgerText.contains("demo@example.com") && !ledgerText.contains("fixture-account") && !ledgerText.contains("Fixture"), "Reminder ledger retained raw account identity")
        print("Passed: recovery observations/restart/new-cycle deduplication; weekly-only estimates and spaced sample safety; weekly surplus 6/12/24/48/72-hour choices/default/migration; configurable strict surplus thresholds/persistence/projected boundary/pending cancellation/examples/wire; widget caption/privacy/permission/delivered/stale/blocked safety; verified account change and async ownership; permission/failure retry; compact menu priority and full details.")
    }
}
