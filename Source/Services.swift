import Cocoa
import Network
import ServiceManagement
import UserNotifications
import CryptoKit

protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
struct SystemLoginService: LoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
final class StartupController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?
    private(set) var diagnostic: String?
    private let service: LoginService
    init(service: LoginService = SystemLoginService()) { self.service = service; refresh() }
    func refresh() {
        isEnabled = service.status == .enabled || service.status == .requiresApproval
        needsApproval = service.status == .requiresApproval
    }
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil; diagnostic = nil
        do {
            if enabled && service.status != .enabled && service.status != .requiresApproval { try service.register() }
            if !enabled && (service.status == .enabled || service.status == .requiresApproval) { try service.unregister() }
        } catch {
            errorMessage = L("设置未完成，请在系统登录项里检查 %@。", String(appDisplayName))
            diagnostic = String(describing: error)
        }
        refresh()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
    func refreshLanguage() {
        if errorMessage != nil { errorMessage = L("设置未完成，请在系统登录项里检查 %@。", String(appDisplayName)) }
    }
}

enum RetryPolicy {
    static func delay(failures: Int, interval: RefreshInterval) -> TimeInterval {
        min(interval.seconds, 15 * pow(2, Double(max(0, min(5, failures - 1)))))
    }
}
final class EnvironmentRefreshMonitor {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var previousNetwork: Bool?
    private var sleeping = false
    private let onNetwork: (Bool) -> Void
    private let onSleep: () -> Void
    private let onWake: () -> Void
    private let onRefresh: () -> Void
    private let debounce: TimeInterval
    init(debounce: TimeInterval = 0.75, onNetwork: @escaping (Bool) -> Void,
         onSleep: @escaping () -> Void, onWake: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.debounce = debounce; self.onNetwork = onNetwork; self.onSleep = onSleep
        self.onWake = onWake; self.onRefresh = onRefresh
    }
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleep() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.wake() })
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async { self?.networkChanged(available) }
        }
        monitor.start(queue: DispatchQueue(label: "local.codext3.network"))
    }
    func networkChanged(_ available: Bool) {
        let previous = previousNetwork; previousNetwork = available
        onNetwork(available)
        if !available { pending?.cancel(); pending = nil }
        else if previous == false && !sleeping { scheduleRefresh() }
    }
    func sleep() { sleeping = true; pending?.cancel(); pending = nil; onSleep() }
    func wake() { sleeping = false; onWake(); scheduleRefresh() }
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.onRefresh() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
    func stop() {
        pending?.cancel(); pending = nil; monitor.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}

enum CardReminderLead: Int, CaseIterable, Identifiable {
    case oneDay = 24, threeDays = 72
    var id: Int { rawValue }
    var seconds: TimeInterval { Double(rawValue * 3600) }
    var title: String { self == .oneDay ? L("提前24小时") : L("提前3天") }
}
struct ReminderOptions: Equatable {
    var lowQuota = false
    var cardExpiry = false
    var cardLead = CardReminderLead.oneDay
    var fiveHourThreshold = QuotaAlert.defaultThreshold
    var weeklyThreshold = QuotaAlert.defaultThreshold
    var quotaRecovery = false
    var accountChange = false
    var weeklySurplus = false
    var weeklyLead = WeeklyReminderLead.twelveHours
    var weeklySurplusThreshold = WeeklySurplusAlert.defaultThreshold
    var anyEnabled: Bool { lowQuota || cardExpiry || quotaRecovery || accountChange || weeklySurplus }
    var enabledKinds: Set<Reminder.Kind> {
        var kinds: Set<Reminder.Kind> = []
        if lowQuota { kinds.insert(.low) }; if cardExpiry { kinds.insert(.card) }
        if quotaRecovery { kinds.insert(.recovery) }
        if accountChange { kinds.insert(.accountChange) }; if weeklySurplus { kinds.insert(.weeklySurplus) }
        return kinds
    }
}
struct Reminder: Equatable {
    enum Kind: String, Codable, Hashable {
        case low, card, recovery, accountChange, weeklySurplus
        // Decode old ledgers without discarding unrelated once-per-cycle history.
        case legacyForecastRisk = "forecastRisk"
    }
    var identifier: String
    var accountKey: String
    var kind: Kind
    var title: String
    var body: String
    var fireAt: Date
    var period: Int? = nil
    var reset: Double? = nil
    var expiry: Double? = nil
    var count: Int? = nil
    var lead: CardReminderLead? = nil
    var settingsPage: String {
        switch kind {
        case .accountChange: return "account"
        case .low, .recovery, .card, .weeklySurplus, .legacyForecastRisk: return "alerts"
        }
    }
}
struct ReminderLedger: Codable {
    struct Low: Codable {
        var remaining: Double
        var reset: Double?
        var sent = false
    }
    struct Card: Codable {
        var fireAt: Date
        var expiry: Double
        var count: Int
    }
    struct Observation: Codable {
        var remaining: Double
        var observedAt: Date
    }
    struct Event: Codable {
        var kind: Reminder.Kind
        var account: String
        var period: Int?
        var reset: Double?
        var lastObserved: Date?
        var streak = 0
        var eligible = false
        var sent = false
        var validUntil: Date
    }
    var low: [String: Low] = [:]
    var cards: [String: Card] = [:]
    var observations: [String: Observation] = [:]
    var events: [String: Event] = [:]
    var confirmedAccount: String?
    var accountChangeID: String?
    init() {}
    private enum CodingKeys: String, CodingKey { case low, cards, observations, events, confirmedAccount, accountChangeID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        low = try values.decodeIfPresent([String: Low].self, forKey: .low) ?? [:]
        cards = try values.decodeIfPresent([String: Card].self, forKey: .cards) ?? [:]
        observations = try values.decodeIfPresent([String: Observation].self, forKey: .observations) ?? [:]
        events = try values.decodeIfPresent([String: Event].self, forKey: .events) ?? [:]
        confirmedAccount = try values.decodeIfPresent(String.self, forKey: .confirmedAccount)
        accountChangeID = try values.decodeIfPresent(String.self, forKey: .accountChangeID)
    }
}
final class ReminderPolicy {
    var ledger: ReminderLedger
    init(ledger: ReminderLedger = ReminderLedger()) { self.ledger = ledger }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    static func accountKey(_ account: AccountInfo?) -> String? {
        guard let account, account.type == "chatgpt", let id = account.id, !id.isEmpty else { return nil }
        return hash((account.email ?? "") + "|" + id)
    }
    private func lowKey(_ account: String, _ period: Int) -> String { account + "." + String(period) }
    func lowID(account: String, period: Int, reset: Double?) -> String {
        "codext3.low." + lowKey(account, period) + "." + Self.hash(reset.map(String.init(describing:)) ?? "unknown")
    }
    func lowIDs(account: String) -> [String] {
        [300, 10080].compactMap { period in
            ledger.low[lowKey(account, period)].map { lowID(account: account, period: period, reset: $0.reset) }
        }
    }
    func lowCandidates(reading: Reading, account: String, options: ReminderOptions, now: Date) -> [Reminder] {
        var candidates: [Reminder] = []
        for (window, threshold) in [(reading.fiveHourQuota, options.fiveHourThreshold), (reading.weeklyQuota, options.weeklyThreshold)] {
            guard let window, let remaining = window.remaining, let period = window.windowDurationMins else { continue }
            let key = lowKey(account, period)
            let reset = window.resetsAt.flatMap { $0.isFinite ? $0 : nil }
            var record = ledger.low[key] ?? ReminderLedger.Low(remaining: remaining, reset: reset)
            if let old = record.reset, let reset, old != reset { record.sent = false }
            if remaining > record.remaining && remaining > threshold { record.sent = false }
            record.remaining = remaining
            if let reset { record.reset = reset }
            ledger.low[key] = record
            guard options.lowQuota, remaining <= threshold, !record.sent else { continue }
            candidates.append(Reminder(identifier: lowID(account: account, period: period, reset: record.reset), accountKey: account,
                                       kind: .low, title: window.title + L("额度预警"),
                                       body: String(format: L("%@的%@额度还剩 %.0f%%。"), reading.account?.displayName ?? L("当前账号"), window.title, remaining),
                                       fireAt: now.addingTimeInterval(1), period: period, reset: record.reset))
        }
        return candidates
    }
    func cardGroups(reading: Reading, now: Date) -> [Double: Int] {
        guard !reading.detailsCached, let cards = reading.cards, let count = cards.availableCount, count > 0,
              let entries = cards.credits else { return [:] }
        let available = entries.filter { $0.status == "available" && ($0.expiresAt.map { $0.isFinite && $0 > now.timeIntervalSince1970 } ?? false) }
            .sorted { $0.expiresAt! < $1.expiresAt! }.prefix(count)
        return Dictionary(grouping: available, by: { $0.expiresAt! }).mapValues { $0.count }
    }
    func cardID(account: String, expiry: Double) -> String { "codext3.card." + account + "." + Self.hash(String(expiry)) }
    func cardCandidates(reading: Reading, account: String, options: ReminderOptions, now: Date) -> [Reminder] {
        guard options.cardExpiry else { return [] }
        return cardGroups(reading: reading, now: now).sorted { $0.key < $1.key }.compactMap { expiry, count in
            let identifier = cardID(account: account, expiry: expiry)
            let fireAt = Date(timeIntervalSince1970: expiry).addingTimeInterval(-options.cardLead.seconds)
            if let old = ledger.cards[identifier] {
                if old.fireAt <= now { return nil }
                if old.count == count && (old.fireAt == fireAt || fireAt <= now) { return nil }
            }
            return Reminder(identifier: identifier, accountKey: account, kind: .card,
                            title: count == 1 ? L("单张重置卡即将到期") : L("重置卡即将到期"),
                            body: count == 1
                                ? L("%@的 1 张重置卡将于 %@ 到期。", reading.account?.displayName ?? L("当前账号"), shortDate(expiry))
                                : L("%@的 %@ 张重置卡将于 %@ 到期。", reading.account?.displayName ?? L("当前账号"), String(count), shortDate(expiry)),
                            fireAt: max(now.addingTimeInterval(1), fireAt), expiry: expiry, count: count, lead: options.cardLead)
        }
    }
    func acknowledge(_ reminder: Reminder) {
        switch reminder.kind {
        case .low:
            guard let period = reminder.period else { return }
            let key = lowKey(reminder.accountKey, period)
            if ledger.low[key]?.reset == reminder.reset { ledger.low[key]?.sent = true }
        case .card:
            guard let expiry = reminder.expiry, let count = reminder.count else { return }
            ledger.cards[reminder.identifier] = ReminderLedger.Card(fireAt: reminder.fireAt, expiry: expiry, count: count)
        case .recovery, .accountChange, .weeklySurplus:
            ledger.events[reminder.identifier]?.sent = true
        case .legacyForecastRisk: break
        }
    }
    func validLowIDs(reading: Reading, account: String, options: ReminderOptions) -> Set<String> {
        guard options.lowQuota else { return [] }
        return Set([(reading.fiveHourQuota, options.fiveHourThreshold), (reading.weeklyQuota, options.weeklyThreshold)].compactMap { window, threshold in
            guard let window, let remaining = window.remaining, remaining <= threshold, let period = window.windowDurationMins else { return nil }
            return lowID(account: account, period: period, reset: ledger.low[lowKey(account, period)]?.reset)
        })
    }
    func cancelFutureCards(now: Date) -> [String] {
        let identifiers = ledger.cards.filter { $0.value.fireAt > now }.map(\.key)
        for identifier in identifiers { ledger.cards.removeValue(forKey: identifier) }
        return identifiers
    }
    func reconcileCards(validIDs: Set<String>, now: Date) -> [String] {
        let obsolete = ledger.cards.filter { !validIDs.contains($0.key) && $0.value.fireAt > now }.map(\.key)
        for id in obsolete { ledger.cards.removeValue(forKey: id) }
        ledger.cards = ledger.cards.filter { $0.value.expiry > now.timeIntervalSince1970 }
        return obsolete
    }
}

protocol NotificationTransport {
    func authorization(_ completion: @escaping (Bool, String) -> Void)
    func requestAuthorization(_ completion: @escaping (Bool, String) -> Void)
    func add(_ reminder: Reminder, completion: @escaping (Error?) -> Void)
    func cancel(_ identifiers: [String])
    func clearAll()
}
// Native snapshot mode must never request permission or change real notifications.
struct PreviewNotifications: NotificationTransport {
    func authorization(_ completion: @escaping (Bool, String) -> Void) { completion(false, L("预览不会发送系统通知。")) }
    func requestAuthorization(_ completion: @escaping (Bool, String) -> Void) { authorization(completion) }
    func add(_ reminder: Reminder, completion: @escaping (Error?) -> Void) { completion(nil) }
    func cancel(_ identifiers: [String]) {}
    func clearAll() {}
}
final class SystemNotifications: NSObject, NotificationTransport, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: ((String) -> Void)?
    override init() { super.init(); center.delegate = self }
    func authorization(_ completion: @escaping (Bool, String) -> Void) {
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                let status = allowed ? L("系统通知已允许") : settings.authorizationStatus == .denied ? L("系统通知已关闭，请在系统设置 → 通知中允许 %@。", String(appDisplayName)) : L("开启提醒时，macOS 会询问通知权限。")
                completion(allowed, status)
            }
        }
    }
    func requestAuthorization(_ completion: @escaping (Bool, String) -> Void) {
        center.requestAuthorization(options: [.alert]) { [weak self] _, _ in self?.authorization(completion) }
    }
    func add(_ reminder: Reminder, completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title; content.body = reminder.body
        content.threadIdentifier = reminder.accountKey
        content.userInfo = ["settingsPage": reminder.settingsPage]
        let delay = max(1, reminder.fireAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }
    func cancel(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func clearAll() { center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications() }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let page = response.notification.request.content.userInfo["settingsPage"] as? String ?? "account"
        DispatchQueue.main.async { [weak self] in self?.onOpen?(page); completionHandler() }
    }
}
final class ReminderController: ObservableObject {
    @Published private(set) var authorized = false
    @Published private(set) var permissionText = L("正在检查系统通知权限…")
    @Published private(set) var deliveryError: String?
    private let transport: NotificationTransport
    private let defaults: UserDefaults
    private let policy: ReminderPolicy
    private var options: ReminderOptions
    private var activeAccount: String?
    private var identityResolved = false
    private var lastGoodReading: Reading?
    private struct Delivery { let token: UUID; let reminder: Reminder }
    private var inFlight: [String: Delivery] = [:]
    private var persistedLedgerData: Data?
    private let clock: () -> Date
    init(transport: NotificationTransport, defaults: UserDefaults = .standard, options: ReminderOptions = ReminderOptions(), clock: @escaping () -> Date = Date.init) {
        self.transport = transport; self.defaults = defaults; self.options = options; self.clock = clock
        persistedLedgerData = defaults.data(forKey: "reminderLedger.v1")
        var saved = persistedLedgerData.flatMap { try? JSONDecoder().decode(ReminderLedger.self, from: $0) } ?? ReminderLedger()
        let removed = saved.events.filter { $0.value.kind == .legacyForecastRisk }.map(\.key)
        saved.events = saved.events.filter { $0.value.kind != .legacyForecastRisk }
        self.policy = ReminderPolicy(ledger: saved)
        activeAccount = defaults.string(forKey: "reminderAccount.v1")
        if policy.ledger.confirmedAccount == nil { policy.ledger.confirmedAccount = activeAccount }
        if !removed.isEmpty { transport.cancel(removed); persist() }
    }
    func refreshAuthorization() {
        transport.authorization { [weak self] allowed, status in
            guard let self else { return }; self.authorized = allowed; self.permissionText = status
            if allowed { self.evaluateLastGood() }
            else { self.cancelPending(clearLow: true, clearCards: true); self.cancelUsagePending(kinds: [.recovery, .accountChange, .weeklySurplus], resetEligibility: false) }
        }
    }
    func refreshLanguage() {
        let ids = Array(inFlight.keys)
        inFlight.removeAll(); transport.cancel(ids)
        cancelPending(clearLow: false, clearCards: true)
        if deliveryError != nil { deliveryError = L("提醒发送失败，请检查系统通知设置。") }
        refreshAuthorization()
    }
    func configure(_ new: ReminderOptions, requestPermission: Bool = false) {
        let old = options; options = new
        if !new.lowQuota { cancelPending(clearLow: true, clearCards: false) }
        if !new.cardExpiry || old.cardLead != new.cardLead { cancelPending(clearLow: false, clearCards: true) }
        let disabled = old.enabledKinds.subtracting(new.enabledKinds)
        cancelUsagePending(kinds: disabled)
        if requestPermission && !authorized && !new.enabledKinds.subtracting(old.enabledKinds).isEmpty {
            transport.requestAuthorization { [weak self] allowed, status in
                guard let self else { return }; self.authorized = allowed; self.permissionText = status
                if allowed { self.evaluateLastGood() }
            }
        } else { evaluateLastGood() }
    }
    func receive(_ reading: Reading) {
        let now = clock()
        guard reading.account != nil else { return }
        let account = ReminderPolicy.accountKey(reading.account)
        if account != activeAccount || (!identityResolved && account == nil) {
            transport.clearAll(); inFlight.removeAll()
            _ = policy.cancelFutureCards(now: now); persist()
            activeAccount = account; lastGoodReading = nil
            defaults.set(account, forKey: "reminderAccount.v1")
        }
        identityResolved = true
        guard let account, reading.message == "已连接", !reading.isStale(at: now), reading.sync?.refreshing != true else {
            lastGoodReading = nil; return
        }
        lastGoodReading = reading
        evaluate(reading, account: account, now: now)
    }
    private func evaluateLastGood() {
        guard let reading = lastGoodReading, let account = activeAccount, !reading.isStale(at: clock()) else { return }
        evaluate(reading, account: account, now: clock())
    }
    func weeklyWidgetReminder(for reading: Reading) -> WeeklyUsageReminder? {
        guard ReminderPolicy.accountKey(reading.account) == activeAccount else { return nil }
        return policy.weeklyWidgetReminder(reading: reading, options: options, now: clock())
    }
    private func evaluate(_ reading: Reading, account: String, now: Date) {
        let oldLowIDs = policy.lowIDs(account: account)
        let low = policy.lowCandidates(reading: reading, account: account, options: options, now: now)
        let validLow = policy.validLowIDs(reading: reading, account: account, options: options)
        let groups = policy.cardGroups(reading: reading, now: now)
        let valid = options.cardExpiry ? Set(groups.keys.map { policy.cardID(account: account, expiry: $0) }) : []
        let invalidInFlight = inFlight.values.filter { !stillValid($0.reminder) }.map { $0.reminder.identifier }
        for id in invalidInFlight { inFlight.removeValue(forKey: id) }
        transport.cancel(invalidInFlight + oldLowIDs.filter { !validLow.contains($0) })
        transport.cancel(policy.reconcileCards(validIDs: valid, now: now))
        let cards = policy.cardCandidates(reading: reading, account: account, options: options, now: now)
        let usage = policy.usageCandidates(reading: reading, account: account, options: options, now: now)
        let invalidUsage = inFlight.values.filter { !stillValid($0.reminder) }.map { $0.reminder.identifier }
        for id in invalidUsage { inFlight.removeValue(forKey: id) }
        transport.cancel(invalidUsage)
        persist()
        guard authorized else { return }
        for reminder in low + cards + usage where inFlight[reminder.identifier] == nil { send(reminder) }
    }
    private func send(_ reminder: Reminder) {
        let token = UUID()
        inFlight[reminder.identifier] = Delivery(token: token, reminder: reminder)
        transport.add(reminder) { [weak self] error in
            guard let self else { return }
            guard self.inFlight[reminder.identifier]?.token == token else {
                if self.inFlight[reminder.identifier] == nil { self.transport.cancel([reminder.identifier]) }
                return
            }
            self.inFlight.removeValue(forKey: reminder.identifier)
            if error != nil {
                self.deliveryError = L("提醒发送失败，请检查系统通知设置。")
                return
            }
            guard self.stillValid(reminder) else { self.transport.cancel([reminder.identifier]); return }
            self.deliveryError = nil; self.policy.acknowledge(reminder); self.persist()
        }
    }
    private func stillValid(_ reminder: Reminder) -> Bool {
        guard authorized, activeAccount == reminder.accountKey, let reading = lastGoodReading, !reading.isStale(at: clock()) else { return false }
        switch reminder.kind {
        case .low:
            guard options.lowQuota, let period = reminder.period,
                  let window = reading.quotaWindows.first(where: { $0.windowDurationMins == period }), let remaining = window.remaining else { return false }
            return policy.validLowIDs(reading: reading, account: reminder.accountKey, options: options).contains(reminder.identifier)
                && remaining <= (period == 300 ? options.fiveHourThreshold : options.weeklyThreshold)
        case .card:
            return options.cardExpiry && options.cardLead == reminder.lead && reminder.expiry.flatMap { policy.cardGroups(reading: reading, now: clock())[$0] } == reminder.count
        case .recovery, .accountChange, .weeklySurplus:
            return policy.usageStillValid(reminder, reading: reading, options: options, now: clock())
        case .legacyForecastRisk: return false
        }
    }
    private func cancelPending(clearLow: Bool, clearCards: Bool) {
        var ids = inFlight.values.map(\.reminder).filter { (clearLow && $0.kind == .low) || (clearCards && $0.kind == .card) }.map(\.identifier)
        for id in ids { inFlight.removeValue(forKey: id) }
        if clearLow, let account = activeAccount { ids += policy.lowIDs(account: account) }
        if clearCards { ids += policy.cancelFutureCards(now: clock()) }
        transport.cancel(ids); persist()
    }
    private func persist() {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(policy.ledger), data != persistedLedgerData {
            defaults.set(data, forKey: "reminderLedger.v1"); persistedLedgerData = data
        }
    }
    private func cancelUsagePending(kinds: Set<Reminder.Kind>, resetEligibility: Bool = true) {
        let ids = Set(inFlight.values.filter { kinds.contains($0.reminder.kind) }.map { $0.reminder.identifier })
            .union(policy.ledger.events.filter { kinds.contains($0.value.kind) }.map(\.key))
        for id in ids {
            inFlight.removeValue(forKey: id)
            if resetEligibility { policy.ledger.events[id]?.eligible = false; policy.ledger.events[id]?.streak = 0 }
        }
        transport.cancel(Array(ids)); persist()
    }
    func openSettings() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
}
