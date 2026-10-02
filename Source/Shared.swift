import Foundation
import SwiftUI
import AppIntents
import WidgetKit

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    static let preferenceKey = "appLanguage"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}

// Resolve each widget's language from its snapshot, independently of host globals.
enum Localization {
    private static let lock = NSLock()
    private static var selected = AppLanguage.system
    private static var languages: [AppLanguage: Bundle] = [:]
    #if QUOTA_TEST_BUILD
    private static var systemBundle = Bundle.main
    #else
    private static let systemBundle = Bundle.main
    #endif
    static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }; return selected
    }
    static func setLanguage(_ language: AppLanguage) {
        lock.lock(); defer { lock.unlock() }; selected = language
    }
    #if QUOTA_TEST_BUILD
    static var bundle: Bundle {
        get { resolve(nil) }
        set {
            lock.lock(); defer { lock.unlock() }
            systemBundle = newValue; selected = .system; languages.removeAll()
        }
    }
    #else
    static var bundle: Bundle { resolve(nil) }
    #endif
    private static func resolve(_ language: AppLanguage?) -> Bundle {
        lock.lock(); defer { lock.unlock() }
        let choice = language ?? selected
        if choice == .system { return systemBundle }
        if let cached = languages[choice] { return cached }
        let root = systemBundle.bundleURL.pathExtension == "lproj"
            ? systemBundle.bundleURL.deletingLastPathComponent()
            : systemBundle.resourceURL ?? systemBundle.bundleURL
        let resolved = Bundle(url: root.appendingPathComponent(choice.rawValue + ".lproj")) ?? systemBundle
        languages[choice] = resolved
        return resolved
    }
    static func text(_ key: String, language: AppLanguage? = nil, arguments: [CVarArg] = []) -> String {
        let value = resolve(language).localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? value : String(format: value, locale: Locale.current, arguments: arguments)
    }
}
func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}

var appDisplayName: String { L("Codex T3 · 额度小组件") }
let widgetKind = "CodexT3Quota"
let ivory = Color(red: 0.91, green: 0.90, blue: 0.86)
let ink = Color(red: 0.19, green: 0.20, blue: 0.18)

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case everyMinute = 1, everyTwoMinutes = 2, everyFiveMinutes = 5
    var id: Int { rawValue }
    var seconds: TimeInterval { Double(rawValue * 60) }
    var title: String { L("每%@分钟", String(rawValue)) }
    var staleAfter: TimeInterval { seconds + 120 }
}

enum QuotaAlert {
    static let defaultThreshold: Double = 20
    static func threshold(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultThreshold }
        return max(0, min(100, value.rounded()))
    }
}

struct AccountInfo: Codable, Equatable {
    var type: String
    var email: String?
    var planType: String?
    var id: String?
    var name: String?
    static let signedOut = AccountInfo(type: "signedOut")
    var displayName: String {
        if type == "signedOut" { return L("未登录") }
        if type == "apiKey" { return L("API Key 登录") }
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        if let id, !id.isEmpty { return L("账号 · ") + String(id.suffix(8)) }
        return type == "chatgpt" ? L("ChatGPT 账号（未提供邮箱）") : L("其他登录方式")
    }
    var detail: String {
        if type == "signedOut" { return L("请先在本机 Codex 登录 ChatGPT 账号。") }
        if type != "chatgpt" { return L("当前登录方式不提供 ChatGPT 订阅额度。") }
        let plans = ["plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu", "free": "Free"]
        let plan = planType.map { plans[$0] ?? $0.capitalized } ?? ""
        let identifier = id.map { L(" · 账号 ") + String($0.suffix(8)) } ?? ""
        return "ChatGPT" + (plan.isEmpty ? "" : " " + plan) + identifier
    }
    func matchesIdentity(_ other: AccountInfo) -> Bool {
        guard type == other.type, email == other.email else { return false }
        if let id, let otherID = other.id { return id == otherID }
        return true
    }
}
struct AccountResponse: Decodable { var account: AccountInfo? }

struct RefreshQuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "立即刷新 Codex 额度"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        do {
            let reading = try await Task.detached(priority: .utility) { try LocalClient.read(.refresh) }.value
            WidgetCache.save(reading)
        } catch {
            var cached = WidgetCache.read()
            cached.markSyncUnavailable("刷新失败 · 请打开 Codex T3")
            WidgetCache.save(cached)
        }
        // WidgetKit reloads the timeline when this interactive intent finishes.
        // Cache the returned reading first; the host also updates other instances.
        return .result()
    }
}

struct QuotaWindow: Codable {
    var usedPercent: Double?
    var windowDurationMins: Int?
    var resetsAt: Double?
    var remaining: Double? { usedPercent.flatMap { $0.isFinite ? max(0, min(100, 100 - $0)) : nil } }
    var title: String {
        title(language: nil)
    }
    func title(language: AppLanguage?) -> String {
        guard let m = windowDurationMins, m > 0 else { return Localization.text("额度", language: language) }
        if m == 10080 { return Localization.text("每周", language: language) }
        if m % 60 == 0 {
            return m == 60 ? Localization.text("1 小时", language: language)
                : Localization.text("%@ 小时", language: language, arguments: [String(m / 60)])
        }
        return m == 1 ? Localization.text("1 分钟", language: language)
            : Localization.text("%@ 分钟", language: language, arguments: [String(m)])
    }
    var menuLabel: String {
        menuLabel(language: nil)
    }
    func menuLabel(language: AppLanguage?) -> String {
        guard let m = windowDurationMins, m > 0 else { return Localization.text("额度", language: language) }
        return m == 10080 ? Localization.text("周", language: language) : m % 60 == 0 ? "\(m / 60)h" : "\(m)m"
    }
}
struct Bucket: Codable {
    var limitId: String?
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
}
struct ResetCard: Codable {
    var status: String?
    var expiresAt: Double?
}
struct ResetCredits: Codable {
    var availableCount: Int?
    var credits: [ResetCard]?
}
struct Limits: Decodable {
    var accountId: String?
    var rateLimits: Bucket?
    var rateLimitsByLimitId: [String: Bucket]?
    var rateLimitResetCredits: ResetCredits?
    var codex: Bucket? {
        if let map = rateLimitsByLimitId { return map["codex"] }
        return rateLimits?.limitId == "codex" ? rateLimits : nil
    }
}
struct SyncInfo: Codable {
    var lastAttempt: Date?
    var nextAttempt: Date?
    var lastError: String?
    var refreshing = false
    var networkAvailable: Bool?
    var sleeping = false
    var failureCount = 0
}
struct WeeklyUsageEstimate: Codable, Equatable {
    var resetsAt: Double
    var sampledAt: Date
    var percentPerHour: Double
    var observedMinutes: Int
}
enum WeeklyReminderLead: Int, CaseIterable, Identifiable {
    case sixHours = 6, twelveHours = 12, oneDay = 24, twoDays = 48, threeDays = 72
    var id: Int { rawValue }
    var seconds: TimeInterval { Double(rawValue * 3600) }
    var title: String { L("%@小时", String(rawValue)) }
}
enum WeeklySurplusAlert {
    static let defaultThreshold: Double = 5
    static func threshold(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultThreshold }
        return max(0, min(100, value.rounded()))
    }
}
struct WeeklyUsageReminder: Codable, Equatable {
    var resetsAt: Double
    var leadHours: Int
    var minimumRemainingPercent: Double?
}
struct Reading: Codable {
    var bucket: Bucket?
    var cards: ResetCredits?
    var updated: Date?
    var message: String
    var detailsCached: Bool = false
    var account: AccountInfo?
    var refreshIntervalMinutes: Int?
    var lowQuotaThreshold: Double?
    var weeklyLowQuotaThreshold: Double?
    var sync: SyncInfo?
    var weeklyUsageEstimate: WeeklyUsageEstimate?
    var weeklyUsageReminder: WeeklyUsageReminder?
    var appLanguage: String?
    var displayLanguage: AppLanguage? { appLanguage.flatMap(AppLanguage.init(rawValue:)) }
    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        Localization.text(key, language: displayLanguage, arguments: arguments)
    }
    var widgetSummary: Reading { var summary = self; summary.account = nil; return summary }
    static let empty = Reading(message: "请打开 Codex T3")
    mutating func markSyncUnavailable(_ message: String) {
        self.message = message
        var status = sync ?? SyncInfo()
        status.refreshing = false; status.nextAttempt = nil; status.lastError = message
        sync = status
    }
    var refreshInterval: RefreshInterval { RefreshInterval(rawValue: refreshIntervalMinutes ?? 1) ?? .everyMinute }
    var quotaWindows: [QuotaWindow] {
        [bucket?.primary, bucket?.secondary].compactMap { $0 }.sorted {
            ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max)
        }
    }
    var fiveHourQuota: QuotaWindow? { quotaWindows.first { $0.windowDurationMins == 300 } }
    var weeklyQuota: QuotaWindow? { quotaWindows.first { $0.windowDurationMins == 10080 } }
    var fiveHourQuotaIsLow: Bool { fiveHourQuota.map(quotaIsLow) ?? false }
    var weeklyQuotaIsLow: Bool { weeklyQuota.map(quotaIsLow) ?? false }
    func weeklySurplusEstimate(at now: Date, lead: WeeklyReminderLead,
                               minimumRemainingPercent: Double = WeeklySurplusAlert.defaultThreshold) -> Double? {
        guard !isStale(at: now), message == "已连接",
              let week = weeklyQuota, let remaining = week.remaining,
              let reset = week.resetsAt, reset.isFinite,
              reset > now.timeIntervalSince1970, reset - now.timeIntervalSince1970 <= lead.seconds,
              fiveHourQuota == nil || (fiveHourQuota?.remaining ?? 0) > 0,
              let estimate = weeklyUsageEstimate, abs(estimate.resetsAt - reset) <= 1,
              estimate.percentPerHour.isFinite, estimate.percentPerHour >= 0,
              estimate.sampledAt <= now.addingTimeInterval(5),
              now.timeIntervalSince(estimate.sampledAt) <= refreshInterval.staleAfter,
              estimate.observedMinutes >= 60 else { return nil }
        let projected = max(0, min(100, remaining - estimate.percentPerHour * (reset - estimate.sampledAt.timeIntervalSince1970) / 3600))
        return projected.isFinite && projected > WeeklySurplusAlert.threshold(minimumRemainingPercent) ? projected : nil
    }
    func weeklyUsageReminderLabel(at now: Date, compact: Bool = false) -> String? {
        guard let reminder = weeklyUsageReminder, weeklyQuota?.resetsAt == reminder.resetsAt,
              let lead = WeeklyReminderLead(rawValue: reminder.leadHours),
              let projected = weeklySurplusEstimate(at: now, lead: lead,
                  minimumRemainingPercent: WeeklySurplusAlert.threshold(reminder.minimumRemainingPercent)) else { return nil }
        let hours = max(1, Int(ceil((reminder.resetsAt - now.timeIntervalSince1970) / 3600)))
        if compact { return localized("周%@h后重置 · 先用余量", String(hours)) }
        return localized("每周约 %@ 小时后重置，预计剩 %@%% · 先用余量", String(hours), String(Int(projected.rounded())))
    }
    func quotaIsLow(_ window: QuotaWindow) -> Bool {
        guard let remaining = window.remaining else { return false }
        switch window.windowDurationMins {
        case 300: return remaining <= QuotaAlert.threshold(lowQuotaThreshold)
        case 10080: return remaining <= QuotaAlert.threshold(weeklyLowQuotaThreshold)
        default: return false
        }
    }
    func isStale(at now: Date) -> Bool {
        if sync?.lastError != nil || sync?.networkAvailable == false || sync?.sleeping == true { return true }
        return updated.map { now.timeIntervalSince($0) > refreshInterval.staleAfter } ?? true
    }
    func statusLabel(at now: Date) -> String {
        if sync?.sleeping == true || sync?.networkAvailable == false { return localized("待同步") }
        if sync?.refreshing == true {
            return sync?.lastAttempt.map { now.timeIntervalSince($0) < 35 } == true ? localized("同步中") : localized("待同步")
        }
        if sync?.lastError != nil { return localized("刷新失败") }
        if message.contains("失败") || message.contains("超时") { return localized("刷新失败") }
        guard !isStale(at: now) && message == "已连接" else { return localized("待同步") }
        return quotaWindows.isEmpty ? localized("额度未提供") : localized("剩余额度")
    }
    func mostRelevantQuota() -> QuotaWindow? {
        let known = quotaWindows.filter { $0.remaining != nil }
        if let empty = known.filter({ $0.remaining == 0 }).max(by: { ($0.resetsAt ?? 0) < ($1.resetsAt ?? 0) }) { return empty }
        return known.min { ($0.remaining ?? 100) < ($1.remaining ?? 100) } ?? quotaWindows.first
    }
    func menuBarTitle(at now: Date, compact: Bool = false) -> String {
        let windows = compact ? mostRelevantQuota().map { [$0] } ?? [] : quotaWindows
        let values = windows.map { window in
            window.menuLabel(language: displayLanguage) + " " + (window.remaining.map { String(format: "%.0f%%", $0) } ?? "—")
        }
        let value = values.isEmpty ? localized("额度未提供") : values.joined(separator: " · ")
        return value + (isStale(at: now) ? localized(" · 待同步") : "")
    }
    var nextCardExpiry: Double? {
        guard let count = cards?.availableCount, count > 0 else { return nil }
        return cards?.credits?
            .filter { $0.status == "available" }
            .compactMap { $0.expiresAt }
            .filter { $0.isFinite && $0 > 0 }
            .min()
    }
    var expiryLines: [String] {
        guard let count = cards?.availableCount else { return [localized("到期时间暂不可用")] }
        guard count > 0 else { return [localized("暂无可用重置卡")] }
        guard let entries = cards?.credits, !entries.isEmpty else { return [localized("明细暂不可用")] }
        let available = entries.filter { $0.status == "available" }
        let grouped = Dictionary(grouping: available, by: { $0.expiresAt ?? -1 })
        var lines = grouped.keys.sorted().map { timestamp -> String in
            let suffix = (grouped[timestamp]?.count ?? 0) > 1 ? " ×\(grouped[timestamp]!.count)" : ""
            return (timestamp < 0 ? localized("到期时间未提供") : shortDate(timestamp)) + suffix
        }
        if count > available.count { lines.append(localized("另 %@ 张无明细", String(count - available.count))) }
        return lines.isEmpty ? [localized("明细暂不可用")] : lines
    }

}
private enum TimestampFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
    static let lock = NSLock()
}
func shortDate(_ timestamp: Double) -> String {
    TimestampFormat.lock.lock()
    defer { TimestampFormat.lock.unlock() }
    return TimestampFormat.formatter.string(from: Date(timeIntervalSince1970: timestamp))
}
enum T3WidgetSize: String, CaseIterable, Identifiable {
    case small, medium
    var id: String { rawValue }
    var title: String {
        switch self { case .small: return L("小"); case .medium: return L("中") }
    }
    var referenceSize: CGSize {
        switch self {
        case .small: return CGSize(width: 164, height: 170)
        case .medium: return CGSize(width: 344, height: 170)
        }
    }
    var family: WidgetFamily {
        switch self { case .small: return .systemSmall; case .medium: return .systemMedium }
    }
    init(family: WidgetFamily) {
        self = family == .systemSmall ? .small : .medium
    }
}
struct T3WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let reading: Reading
    let now: Date
    var body: some View { T3View(reading: reading, now: now, size: T3WidgetSize(family: family)) }
}
struct T3SizePreview: View {
    let reading: Reading
    let size: T3WidgetSize
    var maxHeight: CGFloat = 170
    var demonstration = false
    var now = Date()
    var body: some View {
        let dimensions = size.referenceSize
        let scale = min(344 / dimensions.width, maxHeight / dimensions.height)
        T3View(reading: reading, now: now, preview: demonstration, size: size)
            .frame(width: dimensions.width, height: dimensions.height)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .scaleEffect(scale)
            .frame(width: 344, height: maxHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(size.title + L("尺寸小组件预览"))
    }
}
struct T3View: View {
    let reading: Reading
    var now = Date()
    var preview = false
    var size: T3WidgetSize = .medium
    private func L(_ key: String, _ arguments: CVarArg...) -> String {
        Localization.text(key, language: reading.displayLanguage, arguments: arguments)
    }
    var divider: some View { Rectangle().fill(ink.opacity(0.18)).frame(height: 0.5) }
    var freshnessDot: some View {
        let stale = reading.isStale(at: now)
        return Circle().fill(stale ? ink.opacity(0.25) : Color(red: 0.25, green: 0.55, blue: 0.12))
            .overlay {
                Circle().strokeBorder(stale ? ink.opacity(0.14) : Color(red: 0.16, green: 0.37, blue: 0.07), lineWidth: 0.5)
            }
            .frame(width: 4, height: 4).accessibilityHidden(true)
    }
    var refreshGlyph: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(ink.opacity(0.06), in: Capsule())
    }
    @ViewBuilder var refreshButton: some View {
        if preview { refreshGlyph.accessibilityHidden(true) }
        else { Button(intent: RefreshQuotaIntent()) { refreshGlyph }.buttonStyle(.plain).accessibilityLabel(L("立即刷新 Codex 额度")) }
    }
    func progress(_ w: QuotaWindow?, label: String, compact: Bool = false) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Capsule().fill(ink.opacity(0.12)).frame(height: compact ? 3 : 3.5)
                if let remaining = w?.remaining {
                    Capsule().fill(ink.opacity(0.8))
                        .frame(width: geometry.size.width * remaining / 100, height: compact ? 3 : 3.5)
                }
                Canvas { context, size in
                    for index in 0...10 {
                        let x = 0.5 + (size.width - 1) * Double(index) / 10
                        let major = index % 5 == 0
                        let mark = CGRect(x: x - 0.3, y: compact ? (major ? 4 : 4.5) : (major ? 5.5 : 6.5), width: 0.6, height: compact ? (major ? 2 : 1.5) : (major ? 2.5 : 1.5))
                        context.fill(Path(mark), with: .color(ink.opacity(major ? 0.36 : 0.21)))
                    }
                }.accessibilityHidden(true)
            }
        }
        .frame(height: compact ? 6 : 8)
        .accessibilityLabel(L("%@剩余额度", w?.title(language: reading.displayLanguage) ?? label))
        .accessibilityValue(w?.remaining.map { L("剩余 %@%%", String(format: "%.0f", $0)) } ?? L("暂无数据"))
    }
    func percentage(_ w: QuotaWindow, expanded: Bool = false, fontSize: CGFloat? = nil) -> some View {
        let remainingText = w.remaining.map { L("剩余 %@%%", String(format: "%.0f", $0)) } ?? L("暂无数据")
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(w.remaining.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: fontSize ?? (expanded ? 52 : 42), weight: .light)).monospacedDigit()
            Text("%").font(.system(size: fontSize.map { min(18, max(11, $0 / 3.5)) } ?? (expanded ? 16 : 14), weight: .medium))
        }.foregroundStyle(reading.quotaIsLow(w) ? Color(red: 0.78, green: 0.17, blue: 0.13) : ink)
            .lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("%@剩余额度", w.title(language: reading.displayLanguage))).accessibilityValue(remainingText)
            .help(remainingText)
    }
    func quota(_ w: QuotaWindow, expanded: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(w.title(language: reading.displayLanguage)).font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.7))
            if expanded {
                HStack(alignment: .firstTextBaseline) {
                    percentage(w, expanded: true)
                    Spacer(minLength: 8)
                    Text(w.resetsAt.map { "↻ " + shortDate($0) } ?? L("重置时间未知"))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(ink.opacity(0.7))
                }
                progress(w, label: w.title(language: reading.displayLanguage))
            } else {
                percentage(w, expanded: false)
                progress(w, label: w.title(language: reading.displayLanguage))
                Text(w.resetsAt.map { "↻ " + shortDate($0) } ?? L("重置时间未知"))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(ink.opacity(0.7))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var speakerDots: some View {
        Canvas { context, _ in
            for row in 0..<4 { for col in 0..<8 {
                let hole = CGRect(x: Double(col * 4), y: Double(row * 4), width: 1.5, height: 1.5)
                context.fill(Path(ellipseIn: hole.offsetBy(dx: 0, dy: 0.5)), with: .color(.white.opacity(0.5)))
                context.fill(Path(ellipseIn: hole), with: .color(ink.opacity(0.42)))
            }}
        }.frame(width: 30, height: 14).accessibilityHidden(true)
    }
    var header: some View {
        HStack(alignment: .center) {
            Text("Codex").font(.system(size: 18, weight: .bold)).tracking(-0.6)
            speakerDots
            Spacer()
            let status = reading.statusLabel(at: now)
            if preview {
                Text(L("设计预览")).font(.system(size: 10)).foregroundStyle(ink.opacity(0.5))
            } else if status != L("剩余额度") {
                Text(status).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ink.opacity(0.6)).lineLimit(1)
            }
            freshnessDot
            refreshButton
        }
    }
    var emptyMessage: String { reading.bucket == nil ? L(reading.message) : L("服务未提供额度窗口") }
    var smallPanel: some View {
        VStack(alignment: .leading, spacing: hasWeeklyCaption ? 1 : 3) {
            HStack(spacing: 5) {
                Text("Codex").font(.system(size: 16, weight: .bold)).tracking(-0.5)
                speakerDots
                Spacer(minLength: 4)
                freshnessDot
                refreshButton
            }
            if reading.quotaWindows.isEmpty {
                Text(emptyMessage).font(.system(size: 12)).foregroundStyle(ink.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                VStack(spacing: hasWeeklyCaption ? 2 : 4) {
                    ForEach(reading.quotaWindows.indices, id: \.self) { index in
                        let window = reading.quotaWindows[index]
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(window.title(language: reading.displayLanguage)).font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.7))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                                percentage(window, fontSize: reading.quotaWindows.count == 1 ? 40 : 24)
                            }
                            progress(window, label: window.title(language: reading.displayLanguage), compact: true)
                            Text(window.resetsAt.map { "↻ " + shortDate($0) } ?? L("重置时间未知"))
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(ink.opacity(0.65))
                                .lineLimit(1).minimumScaleFactor(0.9).padding(.top, 1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if let surplus = reading.weeklyUsageReminderLabel(at: now, compact: true) {
                Text(surplus).font(.system(size: 9)).foregroundStyle(surplusColor)
                    .lineLimit(1).minimumScaleFactor(0.9)
                    .accessibilityLabel(reading.weeklyUsageReminderLabel(at: now) ?? surplus)
            }
            VStack(alignment: .leading, spacing: 3) {
                divider
                HStack(spacing: 4) {
                    Text(L("重置卡 ") + (reading.cards?.availableCount.map(String.init) ?? "—"))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    let expiry = reading.nextCardExpiry
                    Text(expiry.map(shortDate) ?? (reading.cards?.availableCount == 0 ? "—" : L("到期未知")))
                        .font(.system(size: 11)).monospacedDigit()
                        .accessibilityLabel(expiry.map { L("重置卡最近到期 ") + shortDate($0) }
                            ?? (reading.cards?.availableCount == 0 ? L("暂无可用重置卡") : L("重置卡到期时间未知")))
                        .help(reading.detailsCached || reading.isStale(at: now)
                            ? L("上次同步的最近一张重置卡到期时间") : L("最近一张可用重置卡的到期时间"))
                }.lineLimit(1).minimumScaleFactor(0.9)
            }
        }.padding(.horizontal, 14).padding(.vertical, hasWeeklyCaption ? 10 : 11)
    }
    var mediumPanel: some View {
        VStack(alignment: .leading, spacing: hasWeeklyCaption ? 2 : 4) {
            header
            if reading.quotaWindows.isEmpty {
                Text(reading.bucket == nil ? L(reading.message) : L("服务未提供额度窗口"))
                    .font(.system(size: 13)).foregroundStyle(ink.opacity(0.65))
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .center)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(reading.quotaWindows.indices, id: \.self) { index in
                        quota(reading.quotaWindows[index], expanded: reading.quotaWindows.count == 1)
                    }
                }
            }
            if let surplus = reading.weeklyUsageReminderLabel(at: now) {
                Text(surplus).font(.system(size: 10)).foregroundStyle(surplusColor)
                    .lineLimit(1).minimumScaleFactor(0.9)
            }
            Rectangle().fill(ink.opacity(0.18)).frame(height: 0.5)
                .overlay(Rectangle().fill(.white.opacity(0.4)).frame(height: 0.5).offset(y: 0.5))
            HStack(alignment: .top, spacing: 10) {
                Text(L("重置卡 ") + (reading.cards?.availableCount.map(String.init) ?? "—"))
                    .font(.system(size: 11, weight: .semibold)).fixedSize()
                let lines = reading.expiryLines
                if reading.detailsCached {
                    Text(L("上次")).font(.system(size: 8)).foregroundStyle(ink.opacity(0.65)).fixedSize()
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    if lines.count == 1 {
                        GridRow {
                            Text(lines[0]).frame(maxWidth: .infinity, alignment: .leading).gridCellColumns(2)
                        }
                    } else {
                        ForEach(0..<min(2, (lines.count + 1) / 2), id: \.self) { row in
                            GridRow {
                                Text(lines[row * 2]).frame(maxWidth: .infinity, alignment: .leading)
                                Text(row * 2 + 1 < lines.count ? lines[row * 2 + 1] + (row == 1 && lines.count > 4 ? " …" : "") : "")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(ink.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.9)
                    .help(reading.detailsCached ? L("上次同步的重置卡到期时间") : L("可用重置卡的到期时间"))
            }
        }.padding(.horizontal, 18).padding(.vertical, hasWeeklyCaption ? 10 : 12)
    }
    var hasWeeklyCaption: Bool { reading.weeklyUsageReminderLabel(at: now) != nil }
    var surplusColor: Color { Color(red: 0.70, green: 0.32, blue: 0.16) }
    var body: some View {
        Group {
            switch size {
            case .small: smallPanel
            case .medium: mediumPanel
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(ink).background(ivory)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.7).padding(5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}
