import SwiftUI

// Synthetic samples never reach the widget bridge or notification controller.
enum ReminderExampleScenario: String, CaseIterable, Identifiable {
    case fiveHour, weekly, both
    var id: Self { self }
    var title: String {
        switch self { case .fiveHour: return L("5 小时"); case .weekly: return L("每周"); case .both: return L("两者同时") }
    }
}
enum SettingsReminderExample {
    static func showsWidget(_ kind: Reminder.Kind) -> Bool { [.low, .weeklySurplus].contains(kind) }
    static func reading(for kind: Reminder.Kind, preferences: Preferences, weeklyOnly: Bool, now: Date) -> Reading {
        var short = 73.0, week = 54.0
        let shortReset = now.addingTimeInterval(2 * 3600).timeIntervalSince1970
        var weekReset = now.addingTimeInterval(5 * 86400).timeIntervalSince1970
        if kind == .low {
            if weeklyOnly { week = max(0, preferences.weeklyLowQuotaThreshold - 5) }
            else { short = max(0, preferences.lowQuotaThreshold - 5) }
        } else if kind == .weeklySurplus {
            week = max(75, min(100, preferences.weeklyReminderThreshold + 10))
            weekReset = now.addingTimeInterval(preferences.weeklyReminderLead.seconds).timeIntervalSince1970
        }
        let five = QuotaWindow(usedPercent: 100 - short, windowDurationMins: 300, resetsAt: shortReset)
        let weekly = QuotaWindow(usedPercent: 100 - week, windowDurationMins: 10080, resetsAt: weekReset)
        var reading = Reading(bucket: Bucket(primary: weeklyOnly ? weekly : five, secondary: weeklyOnly ? nil : weekly),
            cards: ResetCredits(availableCount: 2, credits: [ResetCard(status: "available", expiresAt: now.addingTimeInterval(3 * 86400).timeIntervalSince1970),
                ResetCard(status: "available", expiresAt: now.addingTimeInterval(7 * 86400).timeIntervalSince1970)]),
            updated: now, message: "已连接", lowQuotaThreshold: preferences.lowQuotaThreshold,
            weeklyLowQuotaThreshold: preferences.weeklyLowQuotaThreshold)
        if kind == .weeklySurplus {
            let rate = max(0, min(0.25, (week - preferences.weeklyReminderThreshold - 1) / Double(preferences.weeklyReminderLead.rawValue)))
            reading.weeklyUsageEstimate = WeeklyUsageEstimate(resetsAt: weekReset, sampledAt: now, percentPerHour: rate, observedMinutes: 120)
            reading.weeklyUsageReminder = WeeklyUsageReminder(resetsAt: weekReset, leadHours: preferences.weeklyReminderLead.rawValue,
                minimumRemainingPercent: preferences.weeklyReminderThreshold)
        }
        return reading
    }
    static func notification(for kind: Reminder.Kind, preferences: Preferences, weeklyOnly: Bool, now: Date,
                             scenario: ReminderExampleScenario = .fiveHour) -> (title: String, body: String) {
        let quota = weeklyOnly || scenario == .weekly ? L("每周") : L("5 小时")
        let sample = reading(for: kind, preferences: preferences, weeklyOnly: weeklyOnly, now: now)
        switch kind {
        case .low:
            return (quota + L("额度预警"), L("示例账号的%@额度还剩 %@%%。", String(quota), String(Int(sample.quotaWindows.first?.remaining ?? 0))))
        case .recovery:
            return (quota + L("额度已恢复"), L("示例账号的%@额度已可用，当前剩余 80%%。", String(quota)))
        case .accountChange:
            return (L("Codex 同步账号已切换"), L("当前额度属于示例账号。点击核对账号与额度。"))
        case .weeklySurplus:
            guard let remaining = sample.weeklySurplusEstimate(at: now, lead: preferences.weeklyReminderLead,
                minimumRemainingPercent: preferences.weeklyReminderThreshold) else {
                return (L("每周余量使用提醒"), L("当前阈值不会触发提醒。"))
            }
            return (L("每周额度即将重置"), L("约 %@ 小时后重置，预计还会剩 %@%%。趁重置前安排想完成的任务吧。", String(preferences.weeklyReminderLead.rawValue), String(Int(remaining.rounded()))))
        case .card:
            return (L("重置卡即将到期"), L("示例账号的 2 张重置卡将于 %@ 到期。", String(shortDate(now.addingTimeInterval(preferences.cardReminderLead.seconds).timeIntervalSince1970))))
        case .legacyForecastRisk: return ("", "")
        }
    }
    static func notifications(for kind: Reminder.Kind, preferences: Preferences, weeklyOnly: Bool, now: Date,
                              scenario: ReminderExampleScenario) -> [(title: String, body: String)] {
        if !weeklyOnly, scenario == .both, kind == .recovery {
            return [ReminderExampleScenario.fiveHour, .weekly].map {
                notification(for: kind, preferences: preferences, weeklyOnly: false, now: now, scenario: $0)
            }
        }
        return [notification(for: kind, preferences: preferences, weeklyOnly: weeklyOnly, now: now, scenario: scenario)]
    }
}
private enum ReminderExampleDisplay: String, CaseIterable, Identifiable {
    case small, medium, notification
    var id: Self { self }
    var title: String {
        switch self { case .small: return L("小尺寸"); case .medium: return L("中尺寸"); case .notification: return L("通知") }
    }
}
struct ReminderExampleView: View {
    let kind: Reminder.Kind
    @ObservedObject var preferences: Preferences
    let template: Reading
    private let now = Date()
    @State private var display = ReminderExampleDisplay.medium
    @State private var scenario = ReminderExampleScenario.fiveHour
    var weeklyOnly: Bool { template.weeklyQuota != nil && template.fiveHourQuota == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if kind == .recovery && !weeklyOnly {
                Picker(L("提醒情形示例"), selection: $scenario) {
                    ForEach(ReminderExampleScenario.allCases) { choice in Text(choice.title).tag(choice) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if SettingsReminderExample.showsWidget(kind) {
                Picker(L("提醒效果示例"), selection: $display) {
                    ForEach(ReminderExampleDisplay.allCases) { style in Text(style.title).tag(style) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if SettingsReminderExample.showsWidget(kind) && display != .notification {
                T3SizePreview(reading: SettingsReminderExample.reading(for: kind, preferences: preferences, weeklyOnly: weeklyOnly, now: now),
                    size: display == .small ? .small : .medium, maxHeight: 148, demonstration: true, now: now)
            } else {
                let contents = SettingsReminderExample.notifications(for: kind, preferences: preferences, weeklyOnly: weeklyOnly, now: now, scenario: scenario)
                ForEach(contents.indices, id: \.self) { index in notificationBanner(contents[index]) }
            }
            Text(explanation).font(.system(size: 10)).foregroundStyle(ink.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    func notificationBanner(_ content: (title: String, body: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: MenuBarSymbol.make()).frame(width: 22, height: 18)
                Text(appDisplayName).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.9)
                Spacer()
                Text(L("现在 · 示例")).font(.system(size: 10)).foregroundStyle(ink.opacity(0.55))
            }
            Text(content.title).font(.system(size: 12, weight: .semibold))
            Text(content.body).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.10), lineWidth: 0.5))
            .accessibilityElement(children: .combine).accessibilityLabel(L("系统通知示例：%@。%@", content.title, content.body))
    }
    var explanation: String {
        guard SettingsReminderExample.showsWidget(kind), display != .notification else { return L("此处展示通知样式，实际通知会在满足条件后出现。") }
        return kind == .low ? L("百分比颜色由预警阈值控制，此开关控制系统通知。")
            : L("真实提示需每周采样至少 1 小时，并连续 3 次判断一致；关闭此开关即停止余量判断。")
    }
}
