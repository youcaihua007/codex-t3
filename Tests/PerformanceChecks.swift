import Cocoa
import Foundation
@main enum PerformanceChecks {
    static func spin(_ duration: Double = 0.1) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            NSApplication.shared.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2000000000)
        let fresh = Reading(bucket: Bucket(primary: QuotaWindow(usedPercent: 25, windowDurationMins: 300)),
                            updated: now, message: "已连接", account: AccountInfo(type: "chatgpt", email: "fixture@example.com"),
                            sync: SyncInfo(lastAttempt: now, nextAttempt: now.addingTimeInterval(60), networkAvailable: true))
        var reloadCount = 0
        let reloads = WidgetReloadCoordinator(delay: 0.03) { reloadCount += 1 }
        reloads.submit(fresh); spin()
        precondition(reloadCount == 1)
        var busy = fresh; busy.sync?.refreshing = true; busy.sync?.lastAttempt = now.addingTimeInterval(60); busy.sync?.nextAttempt = nil
        reloads.submit(busy); spin()
        precondition(reloadCount == 1, "Routine refresh start rendered cached data again")
        var success = fresh; success.updated = now.addingTimeInterval(62)
        reloads.submit(success); reloads.submit(success); spin()
        precondition(reloadCount == 2, "Completion was not deduplicated")
        var warning = success; warning.lowQuotaThreshold = 80
        var latestWarning = warning; latestWarning.weeklyLowQuotaThreshold = 25
        reloads.submit(warning); reloads.submit(latestWarning); spin()
        precondition(reloadCount == 3, "Rapid preference changes were not coalesced")
        var switched = busy; switched.updated = nil; switched.bucket = nil; switched.account?.email = "new@example.com"; switched.message = "正在同步当前账号…"
        reloads.submit(switched); spin()
        precondition(reloadCount == 4, "Account switch failed to invalidate old quota")
        var failed = success; failed.markSyncUnavailable("刷新失败")
        reloads.submit(failed); spin(); precondition(reloadCount == 5)
        reloads.submit(fresh); reloads.stop(); spin(); precondition(reloadCount == 5)
        precondition(MenuBarRefreshPolicy.nextUpdate(for: fresh, visible: false, now: now) == nil)
        precondition(MenuBarRefreshPolicy.nextUpdate(for: fresh, visible: true, now: now) == now.addingTimeInterval(180.1))
        precondition(MenuBarRefreshPolicy.nextUpdate(for: fresh, visible: true, now: now.addingTimeInterval(181)) == nil)
        precondition(MenuBarRefreshPolicy.nextUpdate(for: failed, visible: true, now: now) == nil)
        var slow = fresh; slow.refreshIntervalMinutes = 5
        precondition(MenuBarRefreshPolicy.nextUpdate(for: slow, visible: true, now: now) == now.addingTimeInterval(420.1))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = .autoupdatingCurrent; formatter.dateFormat = "MM/dd HH:mm"
        let dates: [Double] = [0, 1791091371, 2000000000]
        for date in dates { precondition(shortDate(date) == formatter.string(from: Date(timeIntervalSince1970: date))) }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let date = dates[index % dates.count]
            precondition(shortDate(date) == formatter.string(from: Date(timeIntervalSince1970: date)))
        }
        print("Passed: widget coalescing/deduplication, success/error/account switch/threshold updates, cancelled work, one-shot menu deadlines, cached concurrent date formatting")
        guard CommandLine.arguments.contains("--ui") else { return }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let delegate = AppDelegate()
        delegate.reading = fresh
        delegate.show(); spin(0.3)
        precondition(delegate.window != nil && delegate.detailHostingView != nil)
        delegate.window?.orderOut(nil); spin(1)
        precondition(!delegate.panelState.isVisible, "Hidden settings retained a live countdown")
        delegate.window?.close(); spin(0.3)
        precondition(delegate.window == nil && delegate.detailHostingView == nil && !delegate.panelState.isVisible)
        delegate.reading = switched; delegate.show(); spin(0.3)
        precondition(delegate.panelState.reading.account?.email == "new@example.com", "Reopened settings displayed a previous account")
        delegate.window?.close(); spin(0.2)
        precondition(delegate.window == nil && delegate.detailHostingView == nil)
        UserDefaults.standard.removePersistentDomain(forName: "local.codext3.preview-reminders")
        print("Passed: hidden settings pause countdown; closing releases host view and window; reopening loads current account")
    }
}
