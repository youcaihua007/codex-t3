import Foundation

extension ReminderPolicy {
    private func usageID(_ kind: Reminder.Kind, account: String, period: Int, reset: Double?) -> String {
        "codext3." + kind.rawValue + "." + account + "." + String(period) + "." + Self.hash(reset.map(String.init(describing:)) ?? "unknown")
    }
    func weeklySurplusEstimate(reading: Reading, options: ReminderOptions, now: Date) -> Double? {
        guard options.weeklySurplus, reading.sync?.refreshing != true else { return nil }
        return reading.weeklySurplusEstimate(at: now, lead: options.weeklyLead,
            minimumRemainingPercent: options.weeklySurplusThreshold)
    }
    func weeklyWidgetReminder(reading: Reading, options: ReminderOptions, now: Date) -> WeeklyUsageReminder? {
        guard options.weeklySurplus, let account = Self.accountKey(reading.account), let reset = reading.weeklyQuota?.resetsAt,
              reading.weeklySurplusEstimate(at: now, lead: options.weeklyLead,
                minimumRemainingPercent: options.weeklySurplusThreshold) != nil else { return nil }
        let id = usageID(.weeklySurplus, account: account, period: 10080, reset: reset)
        // A delivered notification does not dismiss the widget caption. It stays
        // visible while the same cycle still meets the verified reminder condition,
        // including a routine refresh of a healthy cached reading.
        guard let event = ledger.events[id], event.eligible, event.validUntil > now else { return nil }
        return WeeklyUsageReminder(resetsAt: reset, leadHours: options.weeklyLead.rawValue,
            minimumRemainingPercent: WeeklySurplusAlert.threshold(options.weeklySurplusThreshold))
    }
    private func updateWeeklySurplusEvent(window: QuotaWindow, account: String,
                                       condition: Bool, reading: Reading, now: Date) {
        let kind = Reminder.Kind.weeklySurplus
        guard let period = window.windowDurationMins, let reset = window.resetsAt, reset.isFinite,
              reset > now.timeIntervalSince1970, let sampleDate = reading.updated else { return }
        let id = usageID(kind, account: account, period: period, reset: reset)
        guard condition || ledger.events[id] != nil else { return }
        var event = ledger.events[id] ?? ReminderLedger.Event(kind: kind, account: account, period: period,
            reset: reset, validUntil: Date(timeIntervalSince1970: reset))
        if !condition { event.streak = 0; event.eligible = false }
        else if event.lastObserved == nil || sampleDate.timeIntervalSince(event.lastObserved!) >= 30 {
            let maximumGap = max(reading.refreshInterval.staleAfter, reading.refreshInterval.seconds * 2)
            if let last = event.lastObserved, sampleDate.timeIntervalSince(last) > maximumGap { event.streak = 0 }
            event.streak = min(3, event.streak + 1)
            event.eligible = event.streak >= 3
            event.lastObserved = sampleDate
        }
        if !condition { event.lastObserved = sampleDate }
        ledger.events[id] = event
    }
    func usageCandidates(reading: Reading, account: String, options: ReminderOptions, now: Date) -> [Reminder] {
        guard reading.message == "已连接", !reading.isStale(at: now), reading.sync?.refreshing != true,
              let sampleDate = reading.updated else { return [] }
        ledger.events = ledger.events.filter { $0.value.validUntil > now }
        ledger.observations = ledger.observations.filter { now.timeIntervalSince($0.value.observedAt) <= 7 * 86400 }
        if ledger.confirmedAccount != account {
            if let previous = ledger.accountChangeID { ledger.events[previous]?.eligible = false }
            ledger.accountChangeID = nil
            if ledger.confirmedAccount != nil, options.accountChange {
                let id = "codext3.accountChange." + account + "." + UUID().uuidString
                ledger.events[id] = ReminderLedger.Event(kind: .accountChange, account: account,
                    lastObserved: sampleDate, eligible: true, validUntil: now.addingTimeInterval(3600))
                ledger.accountChangeID = id
            }
            ledger.confirmedAccount = account
        }
        if !options.accountChange, let id = ledger.accountChangeID { ledger.events[id]?.eligible = false }
        for window in [reading.fiveHourQuota, reading.weeklyQuota].compactMap({ $0 }) {
            guard let period = window.windowDurationMins, let remaining = window.remaining else { continue }
            let observationID = account + "." + String(period)
            let reset = window.resetsAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let recoveryID = usageID(.recovery, account: account, period: period, reset: reset)
            if options.quotaRecovery {
                if let previous = ledger.observations[observationID], previous.remaining == 0, remaining > 0,
                   sampleDate > previous.observedAt,
                   sampleDate.timeIntervalSince(previous.observedAt) <= Double(period * 60) + 60,
                   ledger.events[recoveryID]?.sent != true {
                    let until = reset.map { Date(timeIntervalSince1970: $0) }.flatMap { $0 > now ? $0 : nil }
                        ?? now.addingTimeInterval(Double(period * 60))
                    ledger.events[recoveryID] = ReminderLedger.Event(kind: .recovery, account: account, period: period,
                        reset: reset, lastObserved: sampleDate, eligible: true, validUntil: until)
                }
                if ledger.observations[observationID]?.observedAt != sampleDate {
                    ledger.observations[observationID] = ReminderLedger.Observation(remaining: remaining, observedAt: sampleDate)
                }
            } else { ledger.observations.removeValue(forKey: observationID) }
            if !options.quotaRecovery || remaining == 0 { ledger.events[recoveryID]?.eligible = false }
            if period == 10080 {
                updateWeeklySurplusEvent(window: window, account: account,
                    condition: weeklySurplusEstimate(reading: reading, options: options, now: now) != nil, reading: reading, now: now)
            }
        }
        // A small bounded ledger keeps once-per-window delivery across restarts.
        if ledger.events.count > 128 {
            let ids = Set(ledger.events.sorted { $0.value.validUntil > $1.value.validUntil }.prefix(128).map(\.key))
            ledger.events = ledger.events.filter { ids.contains($0.key) }
        }
        if ledger.observations.count > 32 {
            let ids = Set(ledger.observations.sorted { $0.value.observedAt > $1.value.observedAt }.prefix(32).map(\.key))
            ledger.observations = ledger.observations.filter { ids.contains($0.key) }
        }
        return ledger.events.sorted { $0.key < $1.key }.compactMap { id, event in
            guard event.account == account, event.eligible, !event.sent, event.validUntil > now else { return nil }
            let reminder: Reminder
            switch event.kind {
            case .recovery:
                guard let window = reading.quotaWindows.first(where: { $0.windowDurationMins == event.period }) else { return nil }
                reminder = Reminder(identifier: id, accountKey: account, kind: .recovery, title: window.title + L("额度已恢复"),
                    body: String(format: L("%@的%@额度已可用，当前剩余 %.0f%%。"), reading.account?.displayName ?? L("当前账号"), window.title, window.remaining ?? 0),
                    fireAt: now.addingTimeInterval(1), period: event.period, reset: event.reset)
            case .accountChange:
                reminder = Reminder(identifier: id, accountKey: account, kind: .accountChange, title: L("Codex 同步账号已切换"),
                    body: L("当前额度属于 %@（%@）。点击核对账号与额度。", String(reading.account?.displayName ?? L("当前账号")), String(reading.account?.detail ?? "")),
                    fireAt: now.addingTimeInterval(1))
            case .weeklySurplus:
                guard let projected = weeklySurplusEstimate(reading: reading, options: options, now: now), let reset = event.reset else { return nil }
                let hours = max(1, Int(ceil((reset - now.timeIntervalSince1970) / 3600)))
                reminder = Reminder(identifier: id, accountKey: account, kind: .weeklySurplus, title: L("每周额度即将重置"),
                    body: L("约 %@ 小时后重置，按近期消耗预计还会剩 %@%%。趁重置前安排想完成的任务吧。", String(hours), String(Int(projected.rounded()))),
                    fireAt: now.addingTimeInterval(1), period: 10080, reset: reset)
            case .low, .card, .legacyForecastRisk: return nil
            }
            return usageStillValid(reminder, reading: reading, options: options, now: now) ? reminder : nil
        }
    }
    func usageStillValid(_ reminder: Reminder, reading: Reading, options: ReminderOptions, now: Date) -> Bool {
        guard reading.message == "已连接", !reading.isStale(at: now), reading.sync?.refreshing != true,
              let event = ledger.events[reminder.identifier], event.eligible, !event.sent, event.validUntil > now,
              ReminderPolicy.accountKey(reading.account) == event.account else { return false }
        if reminder.kind == .accountChange {
            return options.accountChange && ledger.accountChangeID == reminder.identifier
        }
        guard let window = reading.quotaWindows.first(where: { $0.windowDurationMins == event.period }),
              window.resetsAt.flatMap({ $0.isFinite && $0 > 0 ? $0 : nil }) == event.reset else { return false }
        switch reminder.kind {
        case .recovery: return options.quotaRecovery && (window.remaining ?? 0) > 0
        case .weeklySurplus: return weeklySurplusEstimate(reading: reading, options: options, now: now) != nil
        case .accountChange, .low, .card, .legacyForecastRisk: return false
        }
    }
}
