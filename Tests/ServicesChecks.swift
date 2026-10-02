import Foundation
import Cocoa
import ServiceManagement

final class FakeLogin: LoginService {
    var status = SMAppService.Status.notRegistered
    var registers = 0, unregisters = 0
    var failure = false, approval = false
    func register() throws {
        registers += 1
        if failure { throw NSError(domain: "fixture", code: 1) }
        status = approval ? .requiresApproval : .enabled
    }
    func unregister() throws { unregisters += 1; status = .notRegistered }
}
final class FakeNotifications: NotificationTransport {
    var allowed = true
    var permissionRequests = 0, cleared = 0
    var submitted: [Reminder] = []
    var pending: [String: Reminder] = [:]
    var cancellations: [String] = []
    var held: [(Reminder, (Error?) -> Void)] = []
    var hold = false, fail = false
    func authorization(_ done: @escaping (Bool, String) -> Void) { done(allowed, allowed ? "allowed" : "denied") }
    func requestAuthorization(_ done: @escaping (Bool, String) -> Void) { permissionRequests += 1; authorization(done) }
    func add(_ reminder: Reminder, completion: @escaping (Error?) -> Void) {
        submitted.append(reminder); pending[reminder.identifier] = reminder
        if hold { held.append((reminder, completion)) }
        else { completion(fail ? NSError(domain: "fixture", code: 1) : nil) }
    }
    func cancel(_ ids: [String]) { cancellations += ids; for id in ids { pending.removeValue(forKey: id) } }
    func clearAll() { cleared += 1; pending.removeAll() }
    func finish(_ index: Int, error: Error? = nil) { held[index].1(error) }
}
@main enum ServicesChecks {
    static func main() throws {
        var suites: [String] = []
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        func defaults() -> UserDefaults {
            let suite = "local.codext3.services-tests." + UUID().uuidString; suites.append(suite)
            return UserDefaults(suiteName: suite)!
        }
        let date = Date(timeIntervalSince1970: 1800000000)
        var now = date
        let reset = date.addingTimeInterval(3600).timeIntervalSince1970
        let expiry = date.addingTimeInterval(2 * 86400).timeIntervalSince1970
        func reading(_ remaining: Double = 80, weekly: Double = 80, resetAt: Double? = nil, id: String = "account-a", cards: ResetCredits? = nil, weeklyOnly: Bool = false) -> Reading {
            let five = QuotaWindow(usedPercent: 100 - remaining, windowDurationMins: 300, resetsAt: resetAt ?? reset)
            let week = QuotaWindow(usedPercent: 100 - weekly, windowDurationMins: 10080, resetsAt: reset + 86400)
            return Reading(bucket: Bucket(primary: weeklyOnly ? week : five, secondary: weeklyOnly ? nil : week), cards: cards, updated: now,
                           message: "已连接", account: AccountInfo(type: "chatgpt", email: id + "@example.com", id: id, name: "Fixture"),
                           sync: SyncInfo(networkAvailable: true))
        }
        let low = ReminderOptions(lowQuota: true)
        let transport = FakeNotifications(); let persisted = defaults()
        let controller = ReminderController(transport: transport, defaults: persisted, options: low, clock: { now })
        controller.refreshAuthorization()
        precondition(transport.permissionRequests == 0)
        controller.receive(reading()); precondition(transport.submitted.isEmpty)
        controller.receive(reading(20)); precondition(transport.submitted.count == 1 && transport.submitted[0].period == 300)
        for _ in 0..<10 { controller.receive(reading(15)) }
        precondition(transport.submitted.count == 1, "Polling repeated a low-quota notification")
        var threshold = low; threshold.fiveHourThreshold = 35; controller.configure(threshold)
        precondition(transport.submitted.count == 1, "Changing threshold rearmed an already sent alert")
        controller.receive(reading(80)); controller.receive(reading(10))
        precondition(transport.submitted.count == 2, "Restored quota did not rearm alert")
        controller.receive(reading(10, resetAt: reset + 60)); controller.receive(reading(10, resetAt: reset + 60))
        precondition(transport.submitted.count == 3, "A new reset window did not rearm exactly once")
        let restartTransport = FakeNotifications()
        let restarted = ReminderController(transport: restartTransport, defaults: persisted, options: threshold, clock: { now })
        restarted.refreshAuthorization(); restarted.receive(reading(10, resetAt: reset + 60))
        precondition(restartTransport.submitted.isEmpty && restartTransport.cleared == 0, "Restart lost deduplication/account ownership")
        controller.receive(reading(80, weekly: 15, weeklyOnly: true))
        precondition(transport.submitted.last?.period == 10080 && transport.submitted.count == 4, "Pro weekly window was interpreted as five hours")
        controller.receive(reading(15, id: "account-b"))
        precondition(transport.cleared == 2 && transport.submitted.count == 5)
        controller.receive(Reading(message: "请先登录", account: .signedOut))
        precondition(transport.cleared == 3 && transport.pending.isEmpty)
        let unbound = FakeNotifications()
        let signedOut = ReminderController(transport: unbound, defaults: defaults(), options: low, clock: { now })
        signedOut.receive(Reading(message: "未登录", account: .signedOut))
        precondition(unbound.cleared == 1, "Unbound startup left another account's notifications")

        let denied = FakeNotifications(); denied.allowed = false
        let permission = ReminderController(transport: denied, defaults: defaults(), clock: { now })
        permission.refreshAuthorization(); permission.receive(reading(5))
        permission.configure(low, requestPermission: true)
        precondition(denied.permissionRequests == 1 && denied.submitted.isEmpty)
        permission.configure(low, requestPermission: true)
        precondition(denied.permissionRequests == 1, "An unrelated setting prompted for permission again")
        denied.allowed = true; permission.refreshAuthorization()
        precondition(denied.submitted.count == 1, "Denied notification was incorrectly marked sent")
        permission.configure(ReminderOptions()); precondition(denied.pending.isEmpty)
        permission.configure(low, requestPermission: true)
        precondition(denied.submitted.count == 1, "Turning reminders back on repeated an alert")
        let failedTransport = FakeNotifications(); failedTransport.fail = true
        let failed = ReminderController(transport: failedTransport, defaults: defaults(), options: low, clock: { now })
        failed.refreshAuthorization(); failed.receive(reading(5)); precondition(failed.deliveryError != nil)
        failedTransport.fail = false; failed.receive(reading(5)); failed.receive(reading(5))
        precondition(failedTransport.submitted.count == 2 && failed.deliveryError == nil)

        let asyncTransport = FakeNotifications(); asyncTransport.hold = true
        let asynchronous = ReminderController(transport: asyncTransport, defaults: defaults(), options: low, clock: { now })
        asynchronous.refreshAuthorization(); asynchronous.receive(reading(5)); asynchronous.receive(reading(5))
        precondition(asyncTransport.submitted.count == 1, "In-flight notification was submitted twice")
        asynchronous.receive(reading(80)); precondition(asyncTransport.pending.isEmpty)
        asyncTransport.finish(0); asynchronous.receive(reading(5))
        precondition(asyncTransport.submitted.count == 2)
        asynchronous.configure(ReminderOptions()); asynchronous.configure(low)
        precondition(asyncTransport.submitted.count == 3)
        asyncTransport.finish(1)
        precondition(asyncTransport.pending.count == 1, "A superseded callback canceled a newer notification with the same ID")
        asyncTransport.finish(2); asynchronous.receive(reading(5))
        precondition(asyncTransport.submitted.count == 3)
        var stale = reading(5); stale.updated = now.addingTimeInterval(-500)
        let never = FakeNotifications()
        let freshOnly = ReminderController(transport: never, defaults: defaults(), options: low, clock: { now })
        freshOnly.refreshAuthorization(); freshOnly.receive(stale)
        stale.updated = now; stale.sync?.lastError = "failed"; freshOnly.receive(stale)
        stale.sync?.lastError = nil; stale.sync?.refreshing = true; freshOnly.receive(stale)
        precondition(never.submitted.isEmpty, "Stale/failed/in-progress data triggered a notification")
        freshOnly.configure(ReminderOptions(lowQuota: true, fiveHourThreshold: 99))
        precondition(never.submitted.isEmpty)

        let entries = [ResetCard(status: "available", expiresAt: expiry), ResetCard(status: "available", expiresAt: expiry),
                       ResetCard(status: "available", expiresAt: expiry + 86400), ResetCard(status: "available", expiresAt: expiry + 2 * 86400),
                       ResetCard(status: "used", expiresAt: expiry), ResetCard(status: "available", expiresAt: date.addingTimeInterval(-1).timeIntervalSince1970)]
        var cards = ResetCredits(availableCount: 3, credits: entries)
        let cardOptions = ReminderOptions(cardExpiry: true)
        let cardTransport = FakeNotifications(); let cardDefaults = defaults()
        let cardController = ReminderController(transport: cardTransport, defaults: cardDefaults, options: cardOptions, clock: { now })
        cardController.refreshAuthorization(); cardController.receive(reading(cards: cards))
        precondition(cardTransport.submitted.count == 2 && cardTransport.submitted[0].count == 2)
        precondition(cardTransport.submitted[0].fireAt == date.addingTimeInterval(86400))
        for _ in 0..<10 { cardController.receive(reading(cards: cards)) }
        precondition(cardTransport.submitted.count == 2, "Card reminders were repeated by polling")
        let cardRestartTransport = FakeNotifications()
        let cardRestart = ReminderController(transport: cardRestartTransport, defaults: cardDefaults, options: cardOptions, clock: { now })
        cardRestart.refreshAuthorization(); cardRestart.receive(reading(cards: cards))
        precondition(cardRestartTransport.submitted.isEmpty && cardRestartTransport.cleared == 0)
        let usedID = cardTransport.submitted[0].identifier
        cards = ResetCredits(availableCount: 1, credits: [entries[2]])
        cardController.receive(reading(cards: cards))
        precondition(cardTransport.cancellations.contains(usedID) && cardTransport.pending.count == 1, "Redeemed cards left a pending expiry notification")
        var threeDays = cardOptions; threeDays.cardLead = .threeDays
        cardController.configure(threeDays)
        precondition(cardTransport.submitted.count == 3 && cardTransport.submitted.last?.fireAt == now.addingTimeInterval(1))
        cardController.receive(reading(cards: cards))
        precondition(cardTransport.submitted.count == 3, "An overdue reminder duplicated before its first delivery")
        now = date.addingTimeInterval(2)
        cardController.receive(reading(cards: cards)); precondition(cardTransport.submitted.count == 3)
        cardController.configure(cardOptions); cardController.receive(reading(cards: cards))
        precondition(cardTransport.submitted.count == 3, "Changing lead time repeated an already due reminder")
        cardController.configure(ReminderOptions()); precondition(cardTransport.pending.count <= 1)
        let unsafeCards = FakeNotifications()
        let verifiedCards = ReminderController(transport: unsafeCards, defaults: defaults(), options: cardOptions, clock: { now })
        verifiedCards.refreshAuthorization()
        var cached = reading(cards: cards); cached.detailsCached = true; verifiedCards.receive(cached)
        verifiedCards.receive(reading(cards: ResetCredits(availableCount: nil, credits: entries)))
        verifiedCards.receive(reading(cards: ResetCredits(availableCount: 0, credits: entries)))
        precondition(unsafeCards.submitted.isEmpty, "Cached/unverified reset-card details scheduled notifications")
        verifiedCards.receive(reading(cards: cards)); precondition(unsafeCards.pending.count == 1)
        verifiedCards.receive(cached); precondition(unsafeCards.pending.isEmpty)

        let login = FakeLogin(); let startup = StartupController(service: login)
        precondition(!startup.isEnabled)
        startup.setEnabled(true); startup.setEnabled(true)
        precondition(startup.isEnabled && login.registers == 1)
        startup.setEnabled(false); precondition(!startup.isEnabled && login.unregisters == 1)
        login.approval = true; startup.setEnabled(true)
        precondition(startup.isEnabled && startup.needsApproval)
        startup.setEnabled(false); login.failure = true; startup.setEnabled(true)
        precondition(!startup.isEnabled && startup.errorMessage != nil)
        precondition(RetryPolicy.delay(failures: 1, interval: .everyFiveMinutes) == 15)
        precondition(RetryPolicy.delay(failures: 2, interval: .everyFiveMinutes) == 30)
        precondition(RetryPolicy.delay(failures: 9, interval: .everyFiveMinutes) == 300)
        precondition(RetryPolicy.delay(failures: 9, interval: .everyMinute) == 60)

        var refreshes = 0, sleeps = 0, wakes = 0, network: [Bool] = []
        let monitor = EnvironmentRefreshMonitor(debounce: 0.03, onNetwork: { network.append($0) }, onSleep: { sleeps += 1 }, onWake: { wakes += 1 }, onRefresh: { refreshes += 1 })
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        monitor.networkChanged(true); drain(); precondition(refreshes == 0)
        monitor.networkChanged(false); monitor.networkChanged(true); monitor.wake(); drain()
        precondition(refreshes == 1 && wakes == 1, "Wake/network restoration was not coalesced")
        monitor.networkChanged(false); monitor.networkChanged(true); monitor.sleep(); drain()
        precondition(refreshes == 1 && sleeps == 1)
        monitor.networkChanged(false); monitor.networkChanged(true); drain(); precondition(refreshes == 1)
        monitor.wake(); drain(); precondition(refreshes == 2)
        monitor.wake(); monitor.stop(); drain(); precondition(refreshes == 2)
        print("Passed: notification permission timing; independent quota windows/crossings/reset/refill and restart deduplication; account/sign-out cancellation; asynchronous delivery race; failure retry; stale data suppression; grouped card expiry/lead changes/redemption/cache validation; startup approval/error states; bounded retry policy; coalesced wake/network refresh and sleep cancellation.")
    }
}
