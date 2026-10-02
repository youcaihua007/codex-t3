import Foundation

private final class LanguageNotifications: NotificationTransport {
    var submitted: [Reminder] = []
    var pending: [String: Reminder] = [:]
    func authorization(_ completion: @escaping (Bool, String) -> Void) { completion(true, L("系统通知已允许")) }
    func requestAuthorization(_ completion: @escaping (Bool, String) -> Void) { authorization(completion) }
    func add(_ reminder: Reminder, completion: @escaping (Error?) -> Void) {
        submitted.append(reminder); pending[reminder.identifier] = reminder; completion(nil)
    }
    func cancel(_ identifiers: [String]) { for id in identifiers { pending.removeValue(forKey: id) } }
    func clearAll() { pending.removeAll() }
}

@main enum LocalizationChecks {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Source")
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: source.appendingPathComponent(language + ".lproj/Localizable.strings"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        }
        let english = try table("en"), chinese = try table("zh-Hans")
        precondition(Set(english.keys) == Set(chinese.keys))
        let placeholders = try NSRegularExpression(pattern: "%(@|[0-9.]*[df])")
        func formats(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }
        }
        for (key, value) in english {
            precondition(formats(key) == formats(value), "Format mismatch: " + key)
            precondition(value.range(of: "[\\p{Han}]", options: .regularExpression) == nil, "Untranslated English: " + key)
            precondition(value.range(of: "\\bquota\\b|\\breset[ -]credits?\\b", options: [.regularExpression, .caseInsensitive]) == nil,
                         "Inconsistent public usage-limit terminology: " + key)
        }
        precondition(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: ["en-GB"]).first == "en")
        precondition(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: ["zh-CN"]).first == "zh-Hans")
        Localization.bundle = Bundle(url: source.appendingPathComponent("en.lproj"))!
        precondition(L("已连接") == "Connected" && appDisplayName == "Codex T3 · Usage Limits Widget")
        let infoData = try Data(contentsOf: source.appendingPathComponent("en.lproj/InfoPlist.strings"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: String]
        precondition(info["CFBundleDisplayName"] == appDisplayName)
        precondition(RefreshInterval.everyMinute.title == "Every 1 min")
        precondition(QuotaWindow(windowDurationMins: 60).title == "1 hour")
        precondition(QuotaWindow(windowDurationMins: 1).title == "1 minute")
        precondition(L("剩余 %@%%", "73") == "73% remaining")
        let now = Date()
        let window = QuotaWindow(usedPercent: 88, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970)
        let reading = Reading(bucket: Bucket(primary: window), updated: now, message: "已连接",
            account: AccountInfo(type: "chatgpt", email: "demo@example.com", id: "demo", name: "Demo"))
        precondition(window.title == "5 hours" && reading.menuBarTitle(at: now) == "5h 12%")
        var countdown = reading; countdown.sync = SyncInfo(nextAttempt: now.addingTimeInterval(30))
        precondition(SyncStatusView.status(countdown, at: now) == "Auto-refresh in 30s")
        countdown.sync?.lastError = "offline"
        precondition(SyncStatusView.status(countdown, at: now) == "Retry in 30s")
        let policy = ReminderPolicy()
        let notice = policy.lowCandidates(reading: reading, account: "demo", options: ReminderOptions(lowQuota: true), now: now).first!
        precondition(notice.title == "5 hours — Low allowance" && notice.body == "Demo — 5 hours: 12% remaining.")
        let expiry = now.addingTimeInterval(3600).timeIntervalSince1970
        var resetReading = reading
        resetReading.cards = ResetCredits(availableCount: 1, credits: [ResetCard(status: "available", expiresAt: expiry)])
        let singleReset = policy.cardCandidates(reading: resetReading, account: "demo", options: ReminderOptions(cardExpiry: true), now: now).first!
        precondition(singleReset.title == "Rate-limit reset expires soon" && singleReset.body.contains("1 rate-limit reset expiring"))
        resetReading.cards = ResetCredits(availableCount: 2, credits: Array(repeating: ResetCard(status: "available", expiresAt: expiry), count: 2))
        let multipleResets = policy.cardCandidates(reading: resetReading, account: "demo", options: ReminderOptions(cardExpiry: true), now: now).first!
        precondition(multipleResets.title == "Rate-limit resets expire soon" && multipleResets.body.contains("2 rate-limit resets expiring"))
        precondition(AccountInfo.signedOut.displayName == "Signed out")
        Localization.bundle = Bundle(url: source.appendingPathComponent("zh-Hans.lproj"))!
        precondition(appDisplayName == "Codex T3 · 额度小组件" && window.title == "5 小时")
        precondition(SyncStatusView.status(countdown, at: now) == "30 秒后自动重试")
        let suite = "local.codext3.language-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        precondition(preferences.appLanguage == .system && defaults.object(forKey: AppLanguage.preferenceKey) == nil)
        preferences.appLanguage = .english
        precondition(L("每周") == "Weekly" && Preferences(defaults: defaults).appLanguage == .english)
        let updates = UpdateController(defaults: defaults, bundle: Localization.bundle)
        updates.cancel()
        let failure = UpdateFailure(message: "更新服务暂时不可用（%@）。", arguments: ["503"])
        precondition(updates.message == "Update cancelled." && failure.errorDescription == "The update service is unavailable (503).")
        var englishSnapshot = reading
        englishSnapshot.appLanguage = AppLanguage.english.rawValue
        let serialized = try JSONEncoder().encode(englishSnapshot.widgetSummary)
        let decoded = try JSONDecoder().decode(Reading.self, from: serialized)
        precondition(decoded.appLanguage == "en" && decoded.account == nil)
        WidgetCache.save(englishSnapshot, defaults: defaults)
        preferences.appLanguage = .simplifiedChinese
        precondition(L("每周") == "每周" && Preferences(defaults: defaults).appLanguage == .simplifiedChinese)
        precondition(updates.message == "已取消更新。" && failure.errorDescription == "更新服务暂时不可用（503）。")
        precondition(decoded.statusLabel(at: now) == "Remaining allowance", "Widget snapshot ignored its selected language")
        precondition(window.title(language: decoded.displayLanguage) == "5 hours")
        precondition(WidgetCache.read(defaults: defaults).displayLanguage == .english, "Offline cache lost the widget language")
        var chineseSnapshot = englishSnapshot; chineseSnapshot.appLanguage = "zh-Hans"
        precondition(WidgetReloadCoordinator.signature(for: englishSnapshot) != WidgetReloadCoordinator.signature(for: chineseSnapshot))
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let language: AppLanguage = index.isMultiple(of: 2) ? .english : .simplifiedChinese
            precondition(window.title(language: language) == (language == .english ? "5 hours" : "5 小时"))
        }
        let legacy = try JSONDecoder().decode(Reading.self, from: Data(#"{"message":"已连接","detailsCached":false}"#.utf8))
        precondition(legacy.appLanguage == nil)
        preferences.appLanguage = .system
        precondition(L("每周") == "每周", "Follow system did not restore the system bundle")
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        precondition(Preferences(defaults: defaults).appLanguage == .system)
        preferences.appLanguage = .english
        let transport = LanguageNotifications()
        let controller = ReminderController(transport: transport, defaults: defaults,
            options: ReminderOptions(lowQuota: true, cardExpiry: true), clock: { now })
        let settings = DetailView(state: PanelState(reading: chineseSnapshot), preferences: preferences,
            startup: StartupController(), reminders: controller, updates: updates)
        precondition(settings.reading.displayLanguage == .english,
                     "Settings preview kept the language of a previously hidden window")
        controller.refreshAuthorization()
        var alertReading = reading
        alertReading.cards = ResetCredits(availableCount: 1, credits: [ResetCard(status: "available", expiresAt: now.addingTimeInterval(3 * 86400).timeIntervalSince1970)])
        controller.receive(alertReading)
        precondition(transport.submitted.count == 2 && transport.submitted.filter { $0.kind == .low }.count == 1)
        let scheduled = transport.submitted.first { $0.kind == .card }!
        preferences.appLanguage = .simplifiedChinese
        precondition(settings.reading.displayLanguage == .simplifiedChinese)
        controller.refreshLanguage()
        precondition(transport.submitted.count == 3 && transport.submitted.filter { $0.kind == .low }.count == 1,
                     "Changing language repeated an already acknowledged warning")
        precondition(transport.pending[scheduled.identifier]?.title == "重置卡即将到期")
        precondition(transport.pending[scheduled.identifier]?.fireAt == scheduled.fireAt, "Language change altered the scheduled expiry time")
        print("Passed: bilingual terms/placeholders; first-install system default; persisted language choices and fallback; immediate status translations; snapshot/cache privacy and compatibility; concurrent per-widget language resolution; reload invalidation; localized pending reset notifications without repeated warnings")
    }
}
