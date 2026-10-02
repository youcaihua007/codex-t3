import Cocoa
import SwiftUI
import WidgetKit
import Network
import CoreServices
import Darwin
enum LocalAccountProfile {
    static func name(for account: AccountInfo, authURL: URL? = nil) -> String? {
        guard account.type == "chatgpt", let email = account.email, !email.isEmpty else { return nil }
        let directory = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let path = authURL ?? directory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any], let token = tokens["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let profileEmail = claims["email"] as? String,
              profileEmail.caseInsensitiveCompare(email) == .orderedSame else { return nil }
        let identity = claims["https://api.openai.com/auth"] as? [String: Any]
        let profileID = identity?["chatgpt_account_id"] as? String ?? tokens["account_id"] as? String
        if let accountID = account.id, let profileID, accountID != profileID { return nil }
        guard let name = claims["name"] as? String else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Local display metadata only; credentials never enter Reading or the bridge.
        return clean.isEmpty ? nil : clean
    }
}
enum CodexExecutable {
    static func locate(customPath: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let path = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        let bundles = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                       "/Applications/Codex.app/Contents/Resources/codex",
                       home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path]
        let search = ["/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = bundles + search.filter { $0.hasPrefix("/") }.map { $0 + "/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
final class Model: ObservableObject {
    @Published var limits: Limits?
    @Published var account: AccountInfo?
    @Published var updated: Date?
    @Published var codexState = "正在连接本机 Codex…"
    @Published var busy = false
    @Published private(set) var executableVersion = "尚未检测" { didSet { onVersionChange?(executableVersion) } }
    var onVersionChange: ((String) -> Void)?
    private var customExecutablePath = ""
    private var checkedExecutable: URL?
    private var versionProcess: Process?
    var onChange: ((Reading) -> Void)?
    var detailsCached = false
    private(set) var refreshInterval = RefreshInterval.everyMinute
    private let binaryURL: URL?
    private let profileAuthURL: URL?
    private var lowQuotaThreshold = QuotaAlert.defaultThreshold
    private var weeklyLowQuotaThreshold = QuotaAlert.defaultThreshold
    private let defaults: UserDefaults
    let weeklySurplus: WeeklySurplusMonitor
    private var refreshCompletions: [(Reading, Bool) -> Void] = []
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private enum Phase { case account, limits }
    private var phase: Phase?
    private var pending: Int?
    private var nextID = 1
    private var cycleAccount: AccountInfo?
    private var timer: Timer?
    private var running = false
    private var lastAttempt: Date?
    private var syncError: String?
    private var failureCount = 0
    private var retrySoon = true
    private var networkAvailable: Bool?
    private var sleeping = false
    private var cardCache: (account: String, cards: ResetCredits)?
    init(binaryURL: URL? = nil, defaults: UserDefaults = .standard, profileAuthURL: URL? = nil) {
        self.binaryURL = binaryURL; self.defaults = defaults; self.profileAuthURL = profileAuthURL
        weeklySurplus = WeeklySurplusMonitor(enabled: defaults.bool(forKey: "notifyWeeklySurplus"))
    }
    func currentReading() -> Reading {
        Reading(bucket: limits?.codex, cards: limits?.rateLimitResetCredits, updated: updated,
                message: codexState, detailsCached: detailsCached, account: account,
                refreshIntervalMinutes: refreshInterval.rawValue, lowQuotaThreshold: lowQuotaThreshold, weeklyLowQuotaThreshold: weeklyLowQuotaThreshold,
                sync: SyncInfo(lastAttempt: lastAttempt, nextAttempt: timer?.fireDate, lastError: syncError,
                               refreshing: busy, networkAvailable: networkAvailable, sleeping: sleeping, failureCount: failureCount),
                weeklyUsageEstimate: weeklySurplus.estimate, appLanguage: AppLanguage.saved(in: defaults).rawValue)
    }
    func setWeeklySurplusEnabled(_ enabled: Bool) {
        guard weeklySurplus.enabled != enabled else { return }
        weeklySurplus.configure(enabled: enabled)
        broadcast()
    }
    func setExecutablePath(_ path: String, refreshNow: Bool = true) {
        guard path != customExecutablePath else { return }
        customExecutablePath = path; checkedExecutable = nil
        versionProcess?.terminate(); versionProcess = nil
        if running && refreshNow { refresh() }
    }
    private func checkVersion(_ url: URL) {
        guard checkedExecutable != url else { return }; checkedExecutable = url
        let process = Process(); let output = Pipe()
        process.executableURL = url; process.arguments = ["--version"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        versionProcess = process
        do { try process.run() } catch { executableVersion = "版本检测失败"; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readData(ofLength: 1024)
            DispatchQueue.main.async {
                guard let self, self.checkedExecutable == url else { return }
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.executableVersion = text.isEmpty ? "版本未提供" : String(text.prefix(100))
                self.versionProcess = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, process] in
            guard process.isRunning else { return }
            process.terminate()
            if self?.checkedExecutable == url { self?.executableVersion = "版本检测超时" }
        }
    }
    func broadcast() { onChange?(currentReading()) }
    func publish(success: Bool = true) {
        let reading = currentReading(); onChange?(reading)
        let completions = refreshCompletions; refreshCompletions.removeAll()
        for completion in completions { completion(reading, success) }
    }
    func start(interval: RefreshInterval = .everyMinute) {
        running = true; refreshInterval = interval; refresh()
    }
    func setRefreshInterval(_ interval: RefreshInterval, refreshNow: Bool = true) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        if running { scheduleTimer() }
        broadcast()
        if running && refreshNow { refresh() }
    }
    func setLowQuotaThreshold(_ value: Double) {
        let threshold = QuotaAlert.threshold(value)
        guard threshold != lowQuotaThreshold else { return }
        lowQuotaThreshold = threshold; broadcast()
    }
    func setWeeklyLowQuotaThreshold(_ value: Double) {
        let threshold = QuotaAlert.threshold(value)
        guard threshold != weeklyLowQuotaThreshold else { return }
        weeklyLowQuotaThreshold = threshold; broadcast()
    }
    private func scheduleTimer() {
        timer?.invalidate(); timer = nil
        guard running, !busy, !sleeping, networkAvailable != false else { return }
        let delay = failureCount > 0 && retrySoon ? RetryPolicy.delay(failures: failureCount, interval: refreshInterval) : refreshInterval.seconds
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
        timer?.tolerance = min(3, delay * 0.1)
    }
    func stop() { running = false; timer?.invalidate(); timer = nil; busy = false; disconnect(); versionProcess?.terminate(); versionProcess = nil }
    func setNetworkAvailable(_ available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        if !available {
            timer?.invalidate(); timer = nil
            syncError = "网络已断开，等待网络恢复。"
            codexState = "网络已断开 · 旧数据仅供参考"
            busy = false; disconnect(); publish(success: false)
        } else { broadcast() }
    }
    func pauseForSleep() {
        sleeping = true; timer?.invalidate(); timer = nil
        busy = false; disconnect(); publish(success: false)
    }
    func resumeAfterWake() { sleeping = false; broadcast() }
    func disconnect() {
        generation = UUID(); pending = nil; phase = nil; cycleAccount = nil
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }; process = nil
    }
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        do { try input.write(contentsOf: data + Data([10])) }
        catch { fail("连接中断，稍后自动重试") }
    }
    func fail(_ message: String, retrySoon: Bool = true) {
        codexState = message; syncError = message; failureCount += 1; self.retrySoon = retrySoon
        busy = false; disconnect(); scheduleTimer(); publish(success: false)
    }
    func refresh(completion: ((Reading, Bool) -> Void)? = nil) {
        if let completion { refreshCompletions.append(completion) }
        guard !busy else { return }
        guard !sleeping else { publish(success: false); return }
        guard networkAvailable != false else { fail("网络已断开，等待网络恢复。"); return }
        // A fresh process loads the locally saved login on every refresh. Account
        // identity and its quota are read through that same authenticated process.
        timer?.invalidate(); timer = nil
        disconnect(); busy = true; lastAttempt = Date(); broadcast()
        let executable = binaryURL ?? CodexExecutable.locate(customPath: customExecutablePath)
        guard let executable else {
            fail(customExecutablePath.isEmpty ? "未找到 Codex · 请先安装并登录" : "所选 Codex 程序不可用 · 请重新选择", retrySoon: false); return
        }
        if binaryURL == nil { checkVersion(executable) }
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        p.executableURL = executable; p.arguments = ["app-server"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        process = p; input = stdin.fileHandleForWriting
        let token = UUID(); generation = token
        do { try p.run() } catch { fail("无法启动 Codex 服务"); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }; buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }; self.receive(line)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.fail("Codex 服务已断开 · 点击刷新重试")
            }
        }
        send(["id":0,"method":"initialize","params":["clientInfo":["name":"gpt_quota_widget","version":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"]]])
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.generation == token, self.busy else { return }
            self.fail("读取超时 · 旧数据仅供参考")
        }
    }
    private func request(_ phase: Phase) {
        nextID += 1; pending = nextID; self.phase = phase
        switch phase {
        case .account:
            send(["id":nextID,"method":"account/read","params":["refreshToken":false]])
        case .limits:
            send(["id":nextID,"method":"account/rateLimits/read","params":["excludeResetCreditDetails":false]])
        }
    }
    private func clearQuota() {
        limits = nil; updated = nil; detailsCached = false; cardCache = nil
        weeklySurplus.select(account: nil)
    }
    func receive(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? Int else { return }
        if id == 0 {
            guard obj["error"] == nil else { fail("初始化失败 · 请更新 Codex", retrySoon: false); return }
            send(["method":"initialized","params":[:]]); request(.account); return
        }
        guard id == pending, let phase else { return }
        pending = nil
        guard obj["error"] == nil else { fail("读取失败 · 请检查登录与网络，或更新 Codex 版本"); return }
        guard let result = obj["result"], let json = try? JSONSerialization.data(withJSONObject: result) else {
            fail("数据格式无法识别"); return
        }
        switch phase {
        case .account:
            guard let response = try? JSONDecoder().decode(AccountResponse.self, from: json) else { fail("账号信息无法识别"); return }
            let next = response.account ?? .signedOut
            let changed = account.map { !$0.matchesIdentity(next) } ?? true
            if changed || next.type != "chatgpt" { clearQuota(); account = next }
            guard next.type == "chatgpt" else {
                fail(next.type == "signedOut" ? "请先登录本机 Codex" : "当前登录方式不提供订阅额度", retrySoon: false); return
            }
            cycleAccount = next
            if changed { codexState = "正在同步当前账号…"; broadcast() }
            request(.limits)
        case .limits:
            guard let parsed = try? JSONDecoder().decode(Limits.self, from: json), var identity = cycleAccount else {
                fail("额度或账号信息无法识别"); return
            }
            identity.id = parsed.accountId
            if identity.name == nil { identity.name = LocalAccountProfile.name(for: identity, authURL: profileAuthURL) }
            var complete = parsed; var cachedDetails = false
            if let accountID = parsed.accountId {
                let cacheKey = "resetCards." + accountID
                if cardCache?.account != accountID {
                    cardCache = defaults.data(forKey: cacheKey).flatMap { data in
                        (try? JSONDecoder().decode(ResetCredits.self, from: data)).map { (accountID, $0) }
                    }
                }
                if let cards = parsed.rateLimitResetCredits, cards.credits != nil {
                    cardCache = (accountID, cards)
                    if let data = try? JSONEncoder().encode(cards) { defaults.set(data, forKey: cacheKey) }
                } else if let cached = cardCache, cached.account == accountID,
                          cached.cards.availableCount == parsed.rateLimitResetCredits?.availableCount {
                    complete.rateLimitResetCredits = cached.cards; cachedDetails = true
                }
            } else { cardCache = nil }
            // Publish identity and usage atomically, including workspace/account ID.
            account = identity; limits = complete; detailsCached = cachedDetails
            guard parsed.codex != nil else { fail("服务未返回 Codex 额度", retrySoon: false); return }
            updated = Date(); codexState = "已连接"; syncError = nil; failureCount = 0; retrySoon = true
            weeklySurplus.receive(currentReading())
            busy = false; disconnect(); scheduleTimer(); publish()
        }
    }
}
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: AppLanguage.preferenceKey)
            Localization.setLanguage(appLanguage); onChange?()
        }
    }
    @Published var showMenuBarQuota: Bool {
        didSet { defaults.set(showMenuBarQuota, forKey: "showMenuBarQuota"); onChange?() }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon"); onChange?() }
    }
    @Published var lowQuotaThreshold: Double {
        didSet { defaults.set(QuotaAlert.threshold(lowQuotaThreshold), forKey: "lowQuotaThreshold"); onChange?() }
    }
    @Published var weeklyLowQuotaThreshold: Double {
        didSet { defaults.set(QuotaAlert.threshold(weeklyLowQuotaThreshold), forKey: "weeklyLowQuotaThreshold"); onChange?() }
    }
    @Published var codexExecutablePath: String {
        didSet { defaults.set(codexExecutablePath, forKey: "codexExecutablePath"); onChange?() }
    }
    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: "refreshIntervalMinutes"); onChange?() }
    }
    @Published var notifyLowQuota: Bool {
        didSet { defaults.set(notifyLowQuota, forKey: "notifyLowQuota"); onChange?() }
    }
    @Published var notifyCardExpiry: Bool {
        didSet { defaults.set(notifyCardExpiry, forKey: "notifyCardExpiry"); onChange?() }
    }
    @Published var cardReminderLead: CardReminderLead {
        didSet { defaults.set(cardReminderLead.rawValue, forKey: "cardReminderLeadHours"); onChange?() }
    }
    @Published var compactMenuBar: Bool {
        didSet { defaults.set(compactMenuBar, forKey: "compactMenuBar"); onChange?() }
    }
    @Published var notifyQuotaRecovery: Bool {
        didSet { defaults.set(notifyQuotaRecovery, forKey: "notifyQuotaRecovery"); onChange?() }
    }
    @Published var notifyAccountChange: Bool {
        didSet { defaults.set(notifyAccountChange, forKey: "notifyAccountChange"); onChange?() }
    }
    @Published var notifyWeeklySurplus: Bool {
        didSet { defaults.set(notifyWeeklySurplus, forKey: "notifyWeeklySurplus"); onChange?() }
    }
    @Published var weeklyReminderLead: WeeklyReminderLead {
        didSet { defaults.set(weeklyReminderLead.rawValue, forKey: "weeklyReminderLeadHours"); onChange?() }
    }
    @Published var weeklyReminderThreshold: Double {
        didSet { defaults.set(WeeklySurplusAlert.threshold(weeklyReminderThreshold), forKey: "weeklyReminderThreshold"); onChange?() }
    }
    var reminderOptions: ReminderOptions {
        ReminderOptions(lowQuota: notifyLowQuota, cardExpiry: notifyCardExpiry, cardLead: cardReminderLead,
                        fiveHourThreshold: QuotaAlert.threshold(lowQuotaThreshold), weeklyThreshold: QuotaAlert.threshold(weeklyLowQuotaThreshold),
                        quotaRecovery: notifyQuotaRecovery, accountChange: notifyAccountChange,
                        weeklySurplus: notifyWeeklySurplus, weeklyLead: weeklyReminderLead,
                        weeklySurplusThreshold: WeeklySurplusAlert.threshold(weeklyReminderThreshold))
    }
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appLanguage = AppLanguage.saved(in: defaults)
        codexExecutablePath = defaults.string(forKey: "codexExecutablePath") ?? ""
        showMenuBarQuota = defaults.bool(forKey: "showMenuBarQuota")
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        lowQuotaThreshold = QuotaAlert.threshold(defaults.object(forKey: "lowQuotaThreshold") as? Double)
        weeklyLowQuotaThreshold = QuotaAlert.threshold(defaults.object(forKey: "weeklyLowQuotaThreshold") as? Double)
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: "refreshIntervalMinutes")) ?? .everyMinute
        notifyLowQuota = defaults.bool(forKey: "notifyLowQuota")
        notifyCardExpiry = defaults.bool(forKey: "notifyCardExpiry")
        cardReminderLead = CardReminderLead(rawValue: defaults.integer(forKey: "cardReminderLeadHours")) ?? .oneDay
        compactMenuBar = defaults.bool(forKey: "compactMenuBar")
        notifyQuotaRecovery = defaults.bool(forKey: "notifyQuotaRecovery")
        notifyAccountChange = defaults.bool(forKey: "notifyAccountChange")
        notifyWeeklySurplus = defaults.bool(forKey: "notifyWeeklySurplus")
        weeklyReminderLead = WeeklyReminderLead(rawValue: defaults.integer(forKey: "weeklyReminderLeadHours")) ?? .twelveHours
        weeklyReminderThreshold = WeeklySurplusAlert.threshold(defaults.object(forKey: "weeklyReminderThreshold") as? Double)
        defaults.removeObject(forKey: "showUsageForecast")
        defaults.removeObject(forKey: "notifyForecastRisk")
        defaults.removeObject(forKey: "recordUsageHistory")
        defaults.removeObject(forKey: "usageHistory.v1")
    }
}

enum MenuBarSymbol {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            // Option 5's transparent outlined body, with C left and grille right.
            NSColor.black.setStroke(); NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 0.8, y: 2, width: 20.4, height: 14), xRadius: 2.5, yRadius: 2.5)
            body.lineWidth = 1.35; body.stroke()
            let monogram = NSBezierPath()
            monogram.appendArc(withCenter: NSPoint(x: 6.5, y: 9), radius: 3.5, startAngle: 45, endAngle: 315, clockwise: false)
            monogram.lineWidth = 1.55; monogram.lineCapStyle = .round; monogram.stroke()
            for row in 0..<4 { for column in 0..<3 {
                let center = NSPoint(x: 13.2 + Double(column) * 2.4, y: 5.4 + Double(row) * 2.4)
                NSBezierPath(ovalIn: NSRect(x: center.x - 0.625, y: center.y - 0.625, width: 1.25, height: 1.25)).fill()
            } }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = appDisplayName
        return image
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case account, display, alerts, about
    var id: Self { self }
    var title: String {
        switch self {
        case .account: return L("账号与同步")
        case .display: return L("显示与启动")
        case .alerts: return L("预警与通知")
        case .about: return L("关于")
        }
    }
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .display: return "rectangle.grid.1x2"
        case .alerts: return "bell"
        case .about: return "info.circle"
        }
    }
}
final class PanelState: ObservableObject {
    @Published var reading: Reading
    @Published var isVisible = false
    @Published var executableVersion = "尚未检测"
    @Published var selectedPage: SettingsPage = .account
    init(reading: Reading = .empty) { self.reading = reading }
}
struct SyncStatusView: View {
    let reading: Reading
    var isVisible = false
    var refresh: () -> Void
    static func status(_ reading: Reading, at now: Date) -> String {
        if reading.sync?.sleeping == true { return L("电脑休眠时暂停，唤醒后自动刷新。") }
        if reading.sync?.networkAvailable == false { return L("网络已断开，恢复连接后立即刷新。") }
        if reading.sync?.refreshing == true { return L("正在同步当前账号…") }
        if let next = reading.sync?.nextAttempt {
            let seconds = max(0, Int(ceil(next.timeIntervalSince(now))))
            return reading.sync?.lastError == nil ? L("%@ 秒后自动刷新", String(seconds)) : L("%@ 秒后自动重试", String(seconds))
        }
        return reading.isStale(at: now) ? L("数据已过期，请点击刷新。") : L("同步正常")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("同步状态")).font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.plain).disabled(reading.sync?.refreshing == true)
                    .accessibilityLabel(L("立即刷新额度"))
            }
            Text(reading.updated.map { L("上次成功 · ") + shortDate($0.timeIntervalSince1970) } ?? L("尚未成功同步"))
                .font(.system(size: 12)).monospacedDigit()
            if let error = reading.sync?.lastError {
                Text(L(error)).font(.system(size: 11)).foregroundStyle(ink.opacity(0.8))
            }
            // Only the countdown depends on the clock. Occluded/closed settings
            // have no live timeline, and static dates aren't formatted every second.
            if isVisible {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    SyncCountdownView(reading: reading, now: timeline.date)
                }
            } else {
                SyncCountdownView(reading: reading, now: Date())
            }
        }
    }
}
struct SyncCountdownView: View {
    let reading: Reading
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SyncStatusView.status(reading, at: now))
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65)).monospacedDigit()
            if reading.updated != nil && reading.isStale(at: now) {
                Text(L("当前显示旧读数，仅供参考。"))
                    .font(.system(size: 11)).foregroundStyle(Color(red: 0.78, green: 0.17, blue: 0.13))
            }
        }
    }
}

struct SettingsSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var description: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 14))
                Spacer(minLength: 16)
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).fixedSize()
                    .accessibilityLabel(title)
            }
            if let description {
                Text(description).font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct SettingsCanScrollDownKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct SettingsScrollContent<Content: View>: View {
    @State private var canScrollDown = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    content().fixedSize(horizontal: false, vertical: true)
                        // Overlay scrollers stay in this lane, outside the text and controls.
                        .padding(.trailing, 20)
                        .background {
                            GeometryReader { document in
                                Color.clear.preference(key: SettingsCanScrollDownKey.self,
                                    value: document.frame(in: .named("settingsScrollViewport")).maxY > viewport.size.height + 2)
                            }
                        }
                }
                .coordinateSpace(name: "settingsScrollViewport")
                .scrollIndicators(.visible)
            }
            HStack(spacing: 5) {
                Text(L("向下滚动查看更多设置"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }
            .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
            // Keep the footer's height stable as the hint disappears at the bottom.
            .frame(maxWidth: .infinity).padding(.trailing, 20).frame(height: 24)
            .opacity(canScrollDown ? 1 : 0).accessibilityHidden(!canScrollDown)
        }
        .onPreferenceChange(SettingsCanScrollDownKey.self) { canScrollDown = $0 }
    }
}

struct DetailView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var preferences: Preferences
    @ObservedObject var startup: StartupController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var updates: UpdateController
    @State private var widgetPreviewSize: T3WidgetSize = .medium
    @State private var activeReminderExample: Reminder.Kind?
    var refresh: () -> Void = {}
    var executableVersion: String { state.executableVersion }
    var chooseExecutable: () -> Void = {}
    var reading: Reading {
        var current = state.reading
        current.appLanguage = preferences.appLanguage.rawValue
        return current
    }
    static func height(for reading: Reading) -> CGFloat { 620 }
    var divider: some View { Rectangle().fill(ink.opacity(0.15)).frame(height: 0.5) }
    var tabs: some View {
        HStack(spacing: 8) {
            ForEach(SettingsPage.allCases) { page in
                let selected = state.selectedPage == page
                Button { state.selectedPage = page } label: {
                    VStack(spacing: 7) {
                        Image(systemName: page.icon).font(.system(size: 19, weight: .regular))
                        Text(page.title).font(.system(size: 11, weight: selected ? .medium : .regular))
                    }
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .foregroundStyle(selected ? ink : ink.opacity(0.55))
                    .background(selected ? ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) {
                        if selected { Circle().fill(Color(red: 0.79, green: 0.35, blue: 0.17)).frame(width: 4, height: 4).padding(.bottom, 4) }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).accessibilityLabel(page.title)
                .accessibilityValue(selected ? L("已选择") : "")
            }
        }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
    }
    var accountSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("当前同步账号")).font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.65))
            Text(reading.account?.displayName ?? L("正在读取账号…"))
                .font(.system(size: 17, weight: .medium)).textSelection(.enabled)
            if let account = reading.account {
                if account.name != nil, let email = account.email {
                    Text(email).font(.system(size: 12)).textSelection(.enabled)
                }
                Text(account.detail).font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
            }
            Text(L("跟随本机 Codex 登录，刷新时检查账号变化。"))
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
        }
    }
    var codexSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Codex 程序")).font(.system(size: 12, weight: .medium))
                Spacer()
                Button(L("选择…"), action: chooseExecutable).font(.system(size: 11))
                if !preferences.codexExecutablePath.isEmpty {
                    Button(L("自动查找")) { preferences.codexExecutablePath = "" }.font(.system(size: 11))
                }
            }
            Text(preferences.codexExecutablePath.isEmpty ? L("自动查找本机 Codex") : preferences.codexExecutablePath)
                .font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
            Text(L(executableVersion)).font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
        }
    }
    var frequencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("自动刷新频率")).font(.system(size: 12, weight: .medium))
            Picker(L("自动刷新频率"), selection: $preferences.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in Text(interval.title).tag(interval) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(L("控制额度查询频率；桌面显示仍由 macOS 调度。"))
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
        }
    }
    @ViewBuilder var thresholdSections: some View {
        if reading.fiveHourQuota != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("5 小时额度预警阈值")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(preferences.lowQuotaThreshold))%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                Slider(value: $preferences.lowQuotaThreshold, in: 0...100, step: 1)
                    .tint(ink).accessibilityLabel(L("5 小时额度预警阈值"))
                Text(L("剩余 ≤ %@%% 时，对应百分比变红。", String(Int(preferences.lowQuotaThreshold))))
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
            }
        }
        if reading.weeklyQuota != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("每周额度预警阈值")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(preferences.weeklyLowQuotaThreshold))%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                Slider(value: $preferences.weeklyLowQuotaThreshold, in: 0...100, step: 1)
                    .tint(ink).accessibilityLabel(L("每周额度预警阈值"))
                Text(L("剩余 ≤ %@%% 时，对应百分比变红。", String(Int(preferences.weeklyLowQuotaThreshold))))
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
            }
        }
        if reading.fiveHourQuota == nil && reading.weeklyQuota == nil {
            Text(L("额度同步后可设置预警阈值。"))
                .font(.system(size: 12)).foregroundStyle(ink.opacity(0.65))
        }
    }
    var menuSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSwitchRow(title: L("菜单栏显示图标"), isOn: $preferences.showMenuBarIcon)
            SettingsSwitchRow(title: L("菜单栏显示额度"), isOn: $preferences.showMenuBarQuota,
                description: L("在顶部菜单栏显示百分比，如「5h 73% · 周 42%」。"))
            SettingsSwitchRow(title: L("菜单栏精简模式"), isOn: $preferences.compactMenuBar,
                description: L("只显示最需关注的一项，如「周 42%」；点击菜单查看全部。"))
                .disabled(!preferences.showMenuBarQuota)
                .help(L("优先显示已耗尽的额度，其次显示剩余最少的一项；展开菜单可查看全部。"))
            if !preferences.showMenuBarIcon && !preferences.showMenuBarQuota {
                Text(L("菜单栏已隐藏，可点击小组件或重新打开 %@ 进入设置。", String(appDisplayName)))
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
            }
        }
    }
    var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("界面语言")).font(.system(size: 12, weight: .medium))
            Picker(L("界面语言"), selection: $preferences.appLanguage) {
                ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(L("首次安装跟随系统；切换后立即生效，并同步到小组件和通知。"))
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
        }
    }
    var startupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSwitchRow(title: L("开机自启动"), isOn: Binding(get: { startup.isEnabled }, set: { startup.setEnabled($0) }))
            Text(L("登录这台 Mac 后自动开始同步。"))
                .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
            if startup.needsApproval {
                Button(L("在系统登录项中允许")) { startup.openSettings() }.font(.system(size: 12))
            }
            if let error = startup.errorMessage { Text(error).font(.system(size: 11)) }
        }
    }
    func reminderSection<Options: View>(_ kind: Reminder.Kind, title: String, description: String,
        isOn: Binding<Bool>, disabled: Bool = false, optionsAlwaysVisible: Bool = false, @ViewBuilder options: () -> Options) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSwitchRow(title: title, isOn: isOn, description: description).disabled(disabled)
            if isOn.wrappedValue || optionsAlwaysVisible { options().disabled(disabled) }
            if isOn.wrappedValue {
                HStack {
                    Button {
                        activeReminderExample = activeReminderExample == kind ? nil : kind
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: activeReminderExample == kind ? "chevron.up" : "chevron.down")
                            Text(activeReminderExample == kind ? L("收起效果示例") : L("查看效果示例"))
                        }.font(.system(size: 11))
                    }.buttonStyle(.plain)
                    Spacer()
                    if activeReminderExample == kind { Text(L("演示数据")).font(.system(size: 10)).foregroundStyle(ink.opacity(0.55)) }
                }
                if activeReminderExample == kind { ReminderExampleView(kind: kind, preferences: preferences, template: reading) }
            }
        }.id(kind)
            .onChange(of: isOn.wrappedValue) { _, enabled in
                if enabled { activeReminderExample = kind }
                else if activeReminderExample == kind { activeReminderExample = nil }
            }
    }
    var notificationSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            reminderSection(.low, title: L("低额度通知"), description: L("降到下方阈值时发通知；阈值也控制组件百分比颜色，关闭通知仍可调整。"), isOn: $preferences.notifyLowQuota, optionsAlwaysVisible: true) {
                thresholdSections
            }
            divider
            reminderSection(.recovery, title: L("额度恢复通知"), description: L("5 小时或每周额度从 0% 恢复可用时分别通知；首次同步不视为恢复。"), isOn: $preferences.notifyQuotaRecovery) { EmptyView() }
            reminderSection(.accountChange, title: L("账号切换提示"), description: L("切换账号或工作区后发通知，点击可核对当前账号。"), isOn: $preferences.notifyAccountChange) { EmptyView() }
            reminderSection(.weeklySurplus, title: L("每周余量使用提醒"),
                description: L("临近重置且预计剩余大于所设比例时，通知和组件小字同步提醒，提示安排任务。"),
                isOn: $preferences.notifyWeeklySurplus) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("每周余量提前提醒")).font(.system(size: 12, weight: .medium))
                    Picker(L("每周余量提前提醒"), selection: $preferences.weeklyReminderLead) {
                        ForEach(WeeklyReminderLead.allCases) { lead in Text(lead.title).tag(lead) }
                    }.pickerStyle(.segmented).labelsHidden()
                    HStack {
                        Text(L("预计剩余大于")).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(String(format: "%.0f%%", preferences.weeklyReminderThreshold))
                            .font(.system(size: 12)).monospacedDigit()
                    }.padding(.top, 8)
                    Slider(value: $preferences.weeklyReminderThreshold, in: 0...100, step: 1)
                        .tint(ink).accessibilityLabel(L("每周余量提醒阈值"))
                    if preferences.weeklyReminderThreshold == 100 {
                        Text(L("设置为 100% 时不会触发提醒。"))
                            .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                    }
                }
            }
            reminderSection(.card, title: L("重置卡到期通知"), description: L("卡片临近到期时发通知，同一到期时间合并提醒。"), isOn: $preferences.notifyCardExpiry) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("重置卡到期提醒时间")).font(.system(size: 12, weight: .medium))
                    Picker(L("到期提醒时间"), selection: $preferences.cardReminderLead) {
                        ForEach(CardReminderLead.allCases) { lead in Text(lead.title).tag(lead) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
            notificationPermissionSection
        }
    }
    @ViewBuilder var notificationPermissionSection: some View {
        if preferences.reminderOptions.anyEnabled {
            divider
            VStack(alignment: .leading, spacing: 6) {
                Text(reminders.permissionText).font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                if !reminders.authorized { Button(L("打开系统设置")) { reminders.openSettings() }.font(.system(size: 12)) }
                if let error = reminders.deliveryError { Text(error).font(.system(size: 11)) }
            }
        }
    }
    func selectReminderExample() {
        let choices: [(Bool, Reminder.Kind)] = [(preferences.notifyWeeklySurplus, .weeklySurplus),
            (preferences.notifyLowQuota, .low), (preferences.notifyQuotaRecovery, .recovery),
            (preferences.notifyAccountChange, .accountChange), (preferences.notifyCardExpiry, .card)]
        activeReminderExample = choices.first { $0.0 }?.1
    }
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: MenuBarSymbol.make()).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 54).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex T3").font(.system(size: 23, weight: .medium))
                    Text(L("额度小组件")).font(.system(size: 12)).foregroundStyle(ink.opacity(0.65))
                    Text(L("版本 %@ · 构建 %@", String(updates.currentVersion), String(updates.buildNumber)))
                        .font(.system(size: 12)).foregroundStyle(ink.opacity(0.65)).monospacedDigit()
                }
            }.padding(.vertical, 6)
            divider
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("软件更新")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(L("检测更新")) { updates.check() }.disabled(updates.busy || updates.repository == nil)
                        .font(.system(size: 12))
                }
                Text(updates.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if updates.phase == .downloading || updates.phase == .preparing {
                    if let progress = updates.progress, updates.phase == .downloading { ProgressView(value: progress) }
                    else { ProgressView().controlSize(.small) }
                    Button(L("取消")) { updates.cancel() }.font(.system(size: 11))
                }
                if let release = updates.release {
                    HStack {
                        if release.asset != nil {
                            Button(updates.phase == .ready ? L("安装更新并重启") : L("下载更新")) {
                                if updates.phase == .ready { updates.install() } else { updates.download() }
                            }.disabled(updates.busy).font(.system(size: 12))
                        }
                        Button(L("查看发布说明")) { updates.openRelease() }.font(.system(size: 11))
                    }
                }
                if let checked = updates.lastChecked {
                    Text(L("上次成功检测 · ") + shortDate(checked.timeIntervalSince1970))
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65)).monospacedDigit()
                }
            }
            divider
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("建议与反馈")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(L("提交建议与反馈")) { updates.openFeedback() }.disabled(updates.repository == nil)
                        .font(.system(size: 12))
                }
                Text(L("在 GitHub 提交建议或报告问题；请勿附上登录凭据或真实账号截图。"))
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
            }
            divider
            VStack(alignment: .leading, spacing: 8) {
                Text(L("GitHub 项目")).font(.system(size: 12, weight: .medium))
                if let repository = updates.repository {
                    Link(repository.url.absoluteString, destination: repository.url)
                        .font(.system(size: 12)).tint(ink)
                    Text(L("更新与反馈由此项目提供。"))
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                } else {
                    Text(L("此构建尚未配置项目地址。"))
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                }
            }
        }
    }
    var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch state.selectedPage {
            case .account:
                accountSection
                divider
                codexSection
                frequencySection
                divider
                SyncStatusView(reading: reading, isVisible: state.isVisible, refresh: refresh)
            case .display:
                languageSection
                divider
                VStack(spacing: 10) {
                    Picker(L("组件尺寸预览"), selection: $widgetPreviewSize) {
                        ForEach(T3WidgetSize.allCases) { size in Text(size.title).tag(size) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(L("组件尺寸预览"))
                    T3SizePreview(reading: reading, size: widgetPreviewSize, maxHeight: 150)
                    Text(L("此处仅切换预览；在桌面右键点击小组件可选择尺寸。"))
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                divider
                menuSection
                divider
                startupSection
            case .alerts:
                notificationSections
            case .about:
                aboutSection
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(spacing: 0) {
            tabs
            divider
            ScrollViewReader { proxy in
                SettingsScrollContent { pageContent }
                    .id(state.selectedPage)
                    .onChange(of: activeReminderExample) { _, kind in
                        if let kind { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(kind, anchor: .top) } }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The scroller uses 20 points of the original 24-point right margin.
            .padding(.leading, 24).padding(.trailing, 4).padding(.vertical, 20)
        }.foregroundStyle(ink).background(ivory).id(preferences.appLanguage)
            .onAppear {
                if state.selectedPage == .alerts { selectReminderExample() }
            }
            .onChange(of: state.selectedPage) { _, page in
                if page == .alerts { selectReminderExample() }
            }
    }
}

struct MenuBarPreview: View {
    let reading: Reading
    var body: some View {
        VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 10) {
                    Image(nsImage: MenuBarSymbol.make()).renderingMode(.template)
                    Text(reading.menuBarTitle(at: Date())).font(.system(size: 11)).monospacedDigit()
                }.foregroundStyle(dark ? Color.white : ink)
                    .frame(width: 280, height: 40).background(dark ? Color(white: 0.15) : ivory)
            }
        }
    }
}

enum MenuBarRefreshPolicy {
    static func nextUpdate(for reading: Reading, visible: Bool, now: Date) -> Date? {
        guard visible, !reading.isStale(at: now), let updated = reading.updated else { return nil }
        return updated.addingTimeInterval(reading.refreshInterval.staleAfter + 0.1)
    }
}
final class WidgetReloadCoordinator {
    private var signature: Data?
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    private let reload: () -> Void
    init(delay: TimeInterval = 0.4, reload: @escaping () -> Void) {
        self.delay = delay; self.reload = reload
    }
    static func signature(for reading: Reading) -> Data? {
        var content = reading
        // Countdown metadata is shown in settings only. Don't render the widget
        // twice for a routine refresh of an existing healthy reading.
        if content.updated != nil && content.message == "已连接" && content.sync?.lastError == nil {
            content.sync?.refreshing = false
        }
        content.sync?.lastAttempt = nil; content.sync?.nextAttempt = nil
        content.sync?.failureCount = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(content)
    }
    func submit(_ reading: Reading) {
        let next = Self.signature(for: reading)
        guard next == nil || next != signature else { return }
        signature = next
        work?.cancel()
        let pending = DispatchWorkItem { [weak self] in self?.reload() }
        work = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: pending)
    }
    func stop() { work?.cancel(); work = nil; signature = nil }
}
final class SettingsWindow: NSWindow {
    var onHide: (() -> Void)?
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onHide?()
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model(); let bridge = Bridge()
    let preferences = Preferences()
    let startup = StartupController()
    #if QUOTA_TEST_BUILD
    var isPreview: Bool { true }
    #else
    var isPreview: Bool { false }
    #endif
    lazy var notifications = SystemNotifications()
    lazy var reminders = ReminderController(transport: isPreview ? PreviewNotifications() : notifications,
                                           defaults: isPreview ? UserDefaults(suiteName: "local.codext3.preview-reminders")! : .standard,
                                           options: isPreview ? ReminderOptions() : preferences.reminderOptions)
    var environment: EnvironmentRefreshMonitor?
    var item: NSStatusItem!
    var quotaMenuItem: NSMenuItem!
    var quotaDetailsItem: NSMenuItem!
    var menuBarTimer: Timer?
    var window: NSWindow?
    var reading = Reading.empty
    let panelState = PanelState()
    let updates = UpdateController()
    private var activeLanguage = AppLanguage.system
    var transportError: String?
    let menuIcon = MenuBarSymbol.make()
    var detailHostingView: NSHostingView<DetailView>?
    let widgetReloads = WidgetReloadCoordinator { WidgetCenter.shared.reloadTimelines(ofKind: widgetKind) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activeLanguage = preferences.appLanguage
        Localization.setLanguage(activeLanguage)
        reminders.configure(isPreview ? ReminderOptions() : preferences.reminderOptions)
        reminders.refreshAuthorization()
        if !isPreview { notifications.onOpen = { [weak self] page in
            guard let self else { return }
            self.panelState.selectedPage = SettingsPage(rawValue: page) ?? .account
            self.show(); self.refresh()
        } }
        bridge.onRefresh = { [weak self] completion in
            guard let self else { return }
            self.model.refresh { [weak self] raw, success in completion(self?.reading ?? raw, success) }
        }
        startBridge()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuIcon
        let menu = NSMenu()
        menu.addItem(withTitle: L("Codex T3 · 正在同步"), action: nil, keyEquivalent: "")
        quotaDetailsItem = menu.addItem(withTitle: L("额度正在同步"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("额度与设置…"), action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: L("立即刷新"), action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        quotaMenuItem = menu.addItem(withTitle: L("菜单栏显示额度"), action: #selector(toggleMenuBarQuota), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出同步服务"), action: #selector(quit), keyEquivalent: "q")
        for i in menu.items { i.target = self }; item.menu = menu
        preferences.onChange = { [weak self] in
            guard let self else { return }
            if self.activeLanguage != self.preferences.appLanguage {
                self.activeLanguage = self.preferences.appLanguage
                self.startup.refreshLanguage()
                self.reminders.refreshLanguage()
                self.updateMenuLanguage()
            }
            self.reminders.configure(self.isPreview ? ReminderOptions() : self.preferences.reminderOptions, requestPermission: !self.isPreview)
            self.model.setExecutablePath(self.preferences.codexExecutablePath)
            self.model.setRefreshInterval(self.preferences.refreshInterval)
            self.model.setLowQuotaThreshold(self.preferences.lowQuotaThreshold)
            self.model.setWeeklyLowQuotaThreshold(self.preferences.weeklyLowQuotaThreshold)
            self.model.setWeeklySurplusEnabled(self.preferences.notifyWeeklySurplus)
            self.model.broadcast()
            self.updateMenuBar()
        }
        updateMenuBar()
        model.onVersionChange = { [weak self] version in
            if self?.panelState.isVisible == true { self?.panelState.executableVersion = version }
        }
        model.onChange = { [weak self] reading in
            guard let self else { return }; self.startBridge(); var reading = reading
            if let error = self.transportError { reading.markSyncUnavailable(L(error, String(appDisplayName))) }
            self.reminders.receive(reading)
            reading.weeklyUsageReminder = self.reminders.weeklyWidgetReminder(for: reading)
            self.reading = reading; self.bridge.set(reading)
            if self.panelState.isVisible {
                self.panelState.reading = reading
            }
            self.item.menu?.items.first?.title = "Codex T3 · \(L(reading.message))"
            self.updateMenuBar()
            self.updateWindowSize()
            self.widgetReloads.submit(reading)
        }
        model.setLowQuotaThreshold(preferences.lowQuotaThreshold)
        model.setWeeklyLowQuotaThreshold(preferences.weeklyLowQuotaThreshold)
        model.setWeeklySurplusEnabled(preferences.notifyWeeklySurplus)
        model.setExecutablePath(preferences.codexExecutablePath, refreshNow: false)
        model.start(interval: preferences.refreshInterval)
        environment = EnvironmentRefreshMonitor(onNetwork: { [weak self] in self?.model.setNetworkAvailable($0) },
                                                onSleep: { [weak self] in self?.model.pauseForSleep() },
                                                onWake: { [weak self] in self?.model.resumeAfterWake() },
                                                onRefresh: { [weak self] in self?.refresh() })
        environment?.start()
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        if !preferences.showMenuBarIcon && !preferences.showMenuBarQuota && !launchedAtLogin { show() }
        if updates.hasInstallationResult { panelState.selectedPage = .about; show() }
    }

    func startBridge() {
        guard !bridge.isRunning else { return }
        do {
            try bridge.start(); transportError = nil
            var reading = model.currentReading()
            reading.weeklyUsageReminder = reminders.weeklyWidgetReminder(for: reading)
            bridge.set(reading)
        } catch {
            transportError = "小组件通信启动失败，请退出其他 %@ 副本后重新打开。"
        }
    }
    func updateWindow() {
        panelState.reading = reading
        panelState.executableVersion = model.executableVersion
        if detailHostingView == nil {
            detailHostingView = NSHostingView(rootView: DetailView(state: panelState, preferences: preferences, startup: startup, reminders: reminders, updates: updates,
                refresh: { [weak self] in self?.refresh() }, chooseExecutable: { [weak self] in self?.chooseCodex() }))
        }
        window?.contentView = detailHostingView
        updateWindowSize()
    }
    func updateWindowSize() {
        guard let window else { return }
        let availableHeight = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 852) - 72
        let size = NSSize(width: 392, height: min(DetailView.height(for: reading), availableHeight))
        if window.contentView?.frame.size != size { window.setContentSize(size) }
    }
    func updateMenuLanguage() {
        for menuItem in item.menu?.items ?? [] {
            switch menuItem.action {
            case #selector(show): menuItem.title = L("额度与设置…")
            case #selector(refresh): menuItem.title = L("立即刷新")
            case #selector(toggleMenuBarQuota): menuItem.title = L("菜单栏显示额度")
            case #selector(quit): menuItem.title = L("退出同步服务")
            default: break
            }
        }
    }
    func updateMenuBar() {
        item.isVisible = preferences.showMenuBarIcon || preferences.showMenuBarQuota
        item.button?.image = preferences.showMenuBarIcon ? menuIcon : nil
        item.button?.title = preferences.showMenuBarQuota ? reading.menuBarTitle(at: Date(), compact: preferences.compactMenuBar) : ""
        quotaDetailsItem.title = reading.menuBarTitle(at: Date())
        item.button?.imagePosition = preferences.showMenuBarIcon ? (preferences.showMenuBarQuota ? .imageLeading : .imageOnly) : .noImage
        item.button?.imageHugsTitle = true
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        item.button?.toolTip = (reading.account?.displayName ?? appDisplayName) + " · " + reading.menuBarTitle(at: Date())
        item.button?.setAccessibilityLabel(appDisplayName + ", " + (reading.account?.displayName ?? L("正在同步")))
        quotaMenuItem.state = preferences.showMenuBarQuota ? .on : .off
        menuBarTimer?.invalidate(); menuBarTimer = nil
        if let next = MenuBarRefreshPolicy.nextUpdate(for: reading, visible: item.isVisible, now: Date()) {
            // Quota text only changes on new readings or at the stale boundary.
            // There is no periodic menu-bar polling while data is unchanged.
            let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.updateMenuBar() }
            timer.tolerance = 1
            menuBarTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    func chooseCodex() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true; panel.title = L("选择 Codex 可执行程序")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let path = panel.url?.path else { return }
            guard FileManager.default.isExecutableFile(atPath: path) else { return }
            self?.preferences.codexExecutablePath = path
        }
    }
    @objc func toggleMenuBarQuota() { preferences.showMenuBarQuota.toggle() }
    @objc func show() {
        if window == nil {
            let height = min(DetailView.height(for: reading), (NSScreen.main?.visibleFrame.height ?? 852) - 72)
            let settings = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.onHide = { [weak self] in self?.panelState.isVisible = false }
            window = settings
            window?.title = "Codex T3"; window?.isReleasedWhenClosed = false; window?.delegate = self; window?.center()
        }
        if detailHostingView != nil {
            detailHostingView?.rootView = DetailView(state: panelState, preferences: preferences, startup: startup, reminders: reminders, updates: updates,
                refresh: { [weak self] in self?.refresh() }, chooseExecutable: { [weak self] in self?.chooseCodex() })
        }
        updateWindow(); panelState.isVisible = true
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        panelState.isVisible = false
        closing.contentView = nil
        detailHostingView = nil; window = nil
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        let visible = changed.isVisible && !changed.isMiniaturized && changed.occlusionState.contains(.visible)
        if visible { panelState.reading = reading }
        panelState.isVisible = visible
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { startup.refresh(); reminders.refreshAuthorization() }
    @objc func refresh() {
        model.refresh()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func application(_ application: NSApplication, open urls: [URL]) { refresh(); show() }
    func applicationWillTerminate(_ notification: Notification) { environment?.stop(); menuBarTimer?.invalidate(); widgetReloads.stop(); model.stop(); bridge.stop(); updates.stop() }
}
#if !QUOTA_TEST_BUILD
@main enum Main { static func main() {
Localization.setLanguage(AppLanguage.saved())
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == UpdateInstaller.flag {
    exit(UpdateInstaller.helper(URL(fileURLWithPath: CommandLine.arguments[2])))
}
let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate; app.run()
}}
#endif
