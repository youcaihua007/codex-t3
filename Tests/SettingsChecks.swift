import Foundation
import Cocoa
@main enum SettingsChecks {
    static func main() throws {
        let suite = "local.codext3.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = URL(fileURLWithPath: CommandLine.arguments[1])
        let stateURL = work.appendingPathComponent("fake-account-state.json")
        let profileURL = work.appendingPathComponent("fake-profile.json")
        func profile(email: String, id: String, name: String) throws {
            let claims: [String:Any] = ["email":email,"name":name,"https://api.openai.com/auth":["chatgpt_account_id":id]]
            let payload = try JSONSerialization.data(withJSONObject:claims).base64EncodedString()
                .replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            let fixture: [String:Any] = ["tokens":["id_token":"e30." + payload + ".fixture","account_id":id]]
            try JSONSerialization.data(withJSONObject:fixture).write(to:profileURL,options:.atomic)
        }
        func state(email: String?, id: String, used: Double, details: Bool, error: Bool = false, type: String = "chatgpt", weeklyOnly: Bool = false) throws {
            let account: Any = email.map { ["type":type,"email":$0,"planType":weeklyOnly ? "pro" : "plus"] } ?? NSNull()
            let cards: [String:Any] = ["availableCount":3,"credits":details ? [["status":"available","expiresAt":2000000000.0]] : NSNull()]
            let bucket: [String:Any] = weeklyOnly
                ? ["limitId":"codex","primary":NSNull(),"secondary":["usedPercent":used,"windowDurationMins":10080]]
                : ["limitId":"codex","primary":["usedPercent":used,"windowDurationMins":300],"secondary":["usedPercent":50,"windowDurationMins":10080]]
            let limits: [String:Any] = ["accountId":id,"rateLimitsByLimitId":["codex":bucket],"rateLimitResetCredits":cards]
            let data = try JSONSerialization.data(withJSONObject:["account":account,"limits":limits,"quotaError":error])
            try data.write(to: stateURL, options: .atomic)
        }
        func spin(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(done(), "Test refresh timed out")
        }
        let prefs = Preferences(defaults: defaults)
        precondition(prefs.refreshInterval == .everyMinute)
        precondition(prefs.showMenuBarIcon && prefs.lowQuotaThreshold == 20)
        precondition(!prefs.notifyLowQuota && !prefs.notifyCardExpiry && prefs.cardReminderLead == .oneDay)
        prefs.notifyLowQuota = true; prefs.notifyCardExpiry = true; prefs.cardReminderLead = .threeDays
        precondition(Preferences(defaults: defaults).reminderOptions == ReminderOptions(lowQuota: true, cardExpiry: true, cardLead: .threeDays))
        prefs.showMenuBarIcon = false; prefs.lowQuotaThreshold = 35; prefs.weeklyLowQuotaThreshold = 50
        precondition(!Preferences(defaults:defaults).showMenuBarIcon && Preferences(defaults:defaults).lowQuotaThreshold == 35)
        precondition(Preferences(defaults:defaults).weeklyLowQuotaThreshold == 50)
        let separate = Reading(bucket:Bucket(primary:QuotaWindow(usedPercent:65,windowDurationMins:300),secondary:QuotaWindow(usedPercent:49,windowDurationMins:10080)),message:"ok",lowQuotaThreshold:35,weeklyLowQuotaThreshold:50)
        precondition(separate.fiveHourQuotaIsLow && !separate.weeklyQuotaIsLow)
        let weeklyBoundary = Reading(bucket:Bucket(primary:QuotaWindow(usedPercent:65,windowDurationMins:300),secondary:QuotaWindow(usedPercent:50,windowDurationMins:10080)),message:"ok",lowQuotaThreshold:34,weeklyLowQuotaThreshold:50)
        precondition(!weeklyBoundary.fiveHourQuotaIsLow && weeklyBoundary.weeklyQuotaIsLow)
        precondition(!Reading.empty.weeklyQuotaIsLow)
        let boundary = Reading(bucket:Bucket(primary:QuotaWindow(usedPercent:65,windowDurationMins:300)),message:"ok",lowQuotaThreshold:35)
        precondition(boundary.fiveHourQuotaIsLow)
        let above = Reading(bucket:Bucket(primary:QuotaWindow(usedPercent:64,windowDurationMins:300)),message:"ok",lowQuotaThreshold:35)
        precondition(!above.fiveHourQuotaIsLow && !Reading.empty.fiveHourQuotaIsLow)
        precondition(QuotaAlert.threshold(-1)==0 && QuotaAlert.threshold(101)==100 && QuotaAlert.threshold(.nan)==20)
        try profile(email:"first@example.com",id:"account-a",name:"First Account")
        precondition(LocalAccountProfile.name(for:AccountInfo(type:"chatgpt",email:"first@example.com",id:"account-a"),authURL:profileURL)=="First Account")
        precondition(LocalAccountProfile.name(for:AccountInfo(type:"chatgpt",email:"other@example.com",id:"account-a"),authURL:profileURL)==nil)
        precondition(LocalAccountProfile.name(for:AccountInfo(type:"chatgpt",email:"first@example.com",id:"other-workspace"),authURL:profileURL)==nil)
        for interval in RefreshInterval.allCases {
            prefs.refreshInterval = interval
            precondition(Preferences(defaults: defaults).refreshInterval == interval, "Frequency was not persisted")
        }
        defaults.set(3, forKey: "refreshIntervalMinutes")
        precondition(Preferences(defaults: defaults).refreshInterval == .everyMinute)
        let old = try JSONDecoder().decode(Reading.self, from: Data("{\"message\":\"ok\",\"detailsCached\":false}".utf8))
        precondition(old.refreshInterval == .everyMinute && old.account == nil, "Existing widget cache is incompatible")
        let timestamp = Date(timeIntervalSince1970:1000)
        let slow = Reading(updated:timestamp,message:"已连接",refreshIntervalMinutes:5)
        precondition(!slow.isStale(at:timestamp.addingTimeInterval(301)))
        precondition(slow.isStale(at:timestamp.addingTimeInterval(421)))
        try state(email:"first@example.com",id:"account-a",used:25,details:true)
        let model = Model(binaryURL:work.appendingPathComponent("fake-codex.py"),defaults:defaults,profileAuthURL:profileURL)
        defer { model.stop() }
        func scheduled(_ seconds: TimeInterval?) -> Bool {
            guard let seconds else { return model.currentReading().sync?.nextAttempt == nil }
            guard let next = model.currentReading().sync?.nextAttempt else { return false }
            return abs(next.timeIntervalSinceNow - seconds) < 1
        }
        var published = [Reading]()
        model.onChange = { published.append($0) }
        model.start()
        var results = [(Reading,Bool)]()
        model.refresh { results.append(($0,$1)) }
        model.refresh { results.append(($0,$1)) }
        spin { results.count == 2 }
        precondition(results.allSatisfy { $0.1 && $0.0.account?.email == "first@example.com" && $0.0.bucket?.primary?.remaining == 75 })
        precondition(results[0].0.account?.name == "First Account")
        precondition(results[0].0.updated == results[1].0.updated, "Concurrent requests did not share the same reading")
        let originalUpdate = model.updated
        model.setWeeklyLowQuotaThreshold(90)
        precondition(model.currentReading().weeklyQuotaIsLow && !model.currentReading().fiveHourQuotaIsLow)
        model.setWeeklyLowQuotaThreshold(20)
        precondition(!model.currentReading().weeklyQuotaIsLow)
        model.setLowQuotaThreshold(90)
        precondition(model.currentReading().fiveHourQuotaIsLow && model.updated == originalUpdate)
        model.setLowQuotaThreshold(20)
        precondition(!model.currentReading().fiveHourQuotaIsLow)
        for interval in RefreshInterval.allCases {
            model.setRefreshInterval(interval,refreshNow:false)
            precondition(scheduled(interval.seconds), "Live timer did not change")
            precondition(model.currentReading().refreshInterval == interval)
        }
        try state(email:"first@example.com",id:"account-a",used:32,details:false,weeklyOnly:true)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        let pro = results[0].0
        precondition(pro.account?.planType == "pro" && pro.quotaWindows.count == 1 && pro.fiveHourQuota == nil)
        precondition(pro.weeklyQuota?.remaining == 68 && pro.menuBarTitle(at: pro.updated!) == "周 68%")
        precondition(DetailView.height(for: pro) == 620)
        try state(email:"first@example.com",id:"account-a",used:25,details:false)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(results[0].0.quotaWindows.count == 2 && DetailView.height(for: results[0].0) == 620)
        try state(email:"second@example.com",id:"account-b",used:70,details:false)
        results.removeAll(); published.removeAll()
        model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        let second = results[0].0
        precondition(second.account?.name == nil, "An old profile name leaked into a new account")
        precondition(second.account?.email == "second@example.com" && second.account?.id == "account-b")
        precondition(second.bucket?.primary?.remaining == 30 && second.cards?.credits == nil && !second.detailsCached)
        precondition(published.contains { $0.account?.email == "second@example.com" && $0.bucket == nil && $0.cards == nil })
        precondition(!published.contains { $0.account?.email == "second@example.com" && $0.bucket?.primary?.remaining == 75 }, "Account and quota were mixed")
        try profile(email:"second@example.com",id:"account-b",name:"Second Account")
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(results[0].0.account?.name == "Second Account")
        try state(email:"third@example.com",id:"account-c",used:90,details:false,error:true)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(!results[0].1 && results[0].0.account?.email == "third@example.com" && results[0].0.bucket == nil && results[0].0.cards == nil)
        try profile(email:"first@example.com",id:"account-a",name:"First Account")
        try state(email:"first@example.com",id:"account-a",used:40,details:false)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(results[0].0.detailsCached && results[0].0.cards?.credits?.first?.expiresAt == 2000000000.0, "Same-account reset-card cache was lost")
        try state(email:"first@example.com",id:"other-workspace",used:45,details:false)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(results[0].0.account?.id == "other-workspace" && results[0].0.cards?.credits == nil, "Workspace cache leaked")
        try state(email:nil,id:"",used:0,details:false)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(!results[0].1 && results[0].0.account == .signedOut && results[0].0.bucket == nil && results[0].0.updated == nil)
        try state(email:"unused@example.com",id:"",used:0,details:false,type:"apiKey")
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(!results[0].1 && results[0].0.account?.type == "apiKey" && results[0].0.bucket == nil)
        try state(email:"first@example.com",id:"account-a",used:40,details:true)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        let lastSuccess = model.updated!
        try state(email:"first@example.com",id:"account-a",used:40,details:false,error:true)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        let failure = results[0].0
        precondition(!results[0].1 && failure.updated == lastSuccess && failure.fiveHourQuota?.remaining == 60)
        precondition(failure.sync?.lastError != nil && failure.sync?.failureCount == 1 && failure.isStale(at:Date()))
        precondition(scheduled(15) && failure.sync?.nextAttempt != nil)
        precondition(failure.statusLabel(at:Date()) == "刷新失败")
        precondition(SyncStatusView.status(failure,at:failure.sync!.nextAttempt!.addingTimeInterval(-10)) == "10 秒后自动重试")
        model.setNetworkAvailable(false)
        precondition(scheduled(nil) && model.currentReading().sync?.networkAvailable == false)
        results.removeAll(); model.refresh { results.append(($0,$1)) }
        precondition(results.count == 1 && !results[0].1 && model.updated == lastSuccess)
        precondition(SyncStatusView.status(model.currentReading(),at:Date()) == "网络已断开，恢复连接后立即刷新。")
        try state(email:"first@example.com",id:"account-a",used:35,details:true)
        model.setNetworkAvailable(true)
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(results[0].1 && results[0].0.sync?.lastError == nil && results[0].0.sync?.failureCount == 0)
        precondition(!results[0].0.isStale(at:Date()) && scheduled(model.refreshInterval.seconds))
        model.refresh { results.append(($0,$1)) }; model.pauseForSleep()
        precondition(!model.busy && scheduled(nil) && model.currentReading().sync?.sleeping == true)
        precondition(model.currentReading().isStale(at:Date()) && results.count == 2 && !results[1].1)
        model.resumeAfterWake()
        results.removeAll(); model.refresh { results.append(($0,$1)) }; spin { results.count == 1 }
        precondition(results[0].1 && results[0].0.sync?.sleeping == false && results[0].0.sync?.refreshing == false)
        precondition(published.contains { $0.sync?.refreshing == true && $0.sync?.lastAttempt != nil && $0.sync?.nextAttempt == nil })
        print("Passed: Plus/Pro same-account plan switching and fixed paged-settings height; independent 5-hour/weekly boundaries and persistence; profile name ownership and switching; icon preference; frequency persistence and live timers; old cache migration; 5-minute freshness; account switch and failure isolation; workspace cache isolation; sign-out/API-key handling; concurrent refreshes.")
        print("Passed: notification preferences/defaults; last-success retention and immediate stale marking; retry countdown; offline/sleep cancellation; recovery clears errors and resets retry cadence; in-flight sync metadata.")
    }
}
