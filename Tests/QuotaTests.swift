import Foundation
@main enum Checks {
 static func main() throws {
  func decode(_ s: String) throws -> Limits { try JSONDecoder().decode(Limits.self, from: Data(s.utf8)) }
  let missing = try decode("{\"rateLimitsByLimitId\":{},\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":25}}}")
  assert(missing.codex == nil, "authoritative multi-bucket map must not fall back")
  let nilQuota = QuotaWindow(); assert(nilQuota.remaining == nil)
  assert(QuotaWindow(usedPercent: 110).remaining == 0)
  let unknown = Reading(cards: ResetCredits(availableCount: 4), message: "ok")
  assert(unknown.expiryLines == ["明细暂不可用"])
  let rows = [ResetCard(status:"available",expiresAt:1791091371),ResetCard(status:"available",expiresAt:1791091371),ResetCard(status:"redeemed",expiresAt:1)]
  let detail = Reading(cards: ResetCredits(availableCount:3,credits:rows), message:"ok")
  assert(detail.expiryLines.count == 2 && detail.expiryLines[0].hasSuffix("×2") && detail.expiryLines[1].contains("1 张"))
  let nextExpiry = 1893520800.0
  let expiryReading = Reading(cards:ResetCredits(availableCount:3,credits:[
   ResetCard(status:"available",expiresAt:nextExpiry + 86400),
   ResetCard(status:"redeemed",expiresAt:nextExpiry - 86400),
   ResetCard(status:"available",expiresAt:nil),
   ResetCard(status:"available",expiresAt:nextExpiry)
  ]),updated:Date(timeIntervalSince1970:1800000000),message:"已连接")
  assert(expiryReading.nextCardExpiry == nextExpiry, "Small footer must show the nearest available-card expiry, independently of the refresh timestamp")
  var staleExpiryReading = expiryReading
  staleExpiryReading.markSyncUnavailable("离线")
  assert(staleExpiryReading.nextCardExpiry == nextExpiry, "Offline data must retain its known card expiry")
  assert(unknown.nextCardExpiry == nil)
  assert(Reading(cards:ResetCredits(availableCount:0,credits:rows),message:"ok").nextCardExpiry == nil)
  assert(Reading(cards:ResetCredits(availableCount:1,credits:[ResetCard(status:"available",expiresAt:nil)]),message:"ok").nextCardExpiry == nil)
  assert(Reading(updated:Date(timeIntervalSince1970:0),message:"ok").isStale(at:Date(timeIntervalSince1970:181)))
  let now = Date(timeIntervalSince1970: 1000)
  let fresh = Reading(bucket: Bucket(primary: QuotaWindow(usedPercent: 25, windowDurationMins: 300), secondary: QuotaWindow(usedPercent: 100, windowDurationMins: 10080)), updated: now, message: "ok")
  assert(fresh.menuBarTitle(at: now) == "5h 75% · 周 0%")
  assert(fresh.menuBarTitle(at: now.addingTimeInterval(181)).hasSuffix("待同步"))
  assert(Reading.empty.menuBarTitle(at: now) == "额度未提供 · 待同步")
  func viewReading(_ bucket: Bucket) -> Reading {
   Reading(bucket:bucket,updated:now,message:"已连接",lowQuotaThreshold:90,weeklyLowQuotaThreshold:20)
  }
  for weeklyInPrimary in [true,false] {
   let week = QuotaWindow(usedPercent:32,windowDurationMins:10080,resetsAt:2000000000)
   let reading = viewReading(Bucket(primary:weeklyInPrimary ? week : nil,secondary:weeklyInPrimary ? nil : week))
   assert(reading.quotaWindows.count == 1 && reading.weeklyQuota?.remaining == 68 && reading.fiveHourQuota == nil)
   assert(reading.menuBarTitle(at:now) == "周 68%")
   assert(!reading.weeklyQuotaIsLow && !reading.fiveHourQuotaIsLow, "Weekly quota must use the weekly threshold in either slot")
  }
  let reversed = viewReading(Bucket(primary:QuotaWindow(usedPercent:90,windowDurationMins:10080),secondary:QuotaWindow(usedPercent:5,windowDurationMins:300)))
  assert(reversed.menuBarTitle(at:now) == "5h 95% · 周 10%")
  assert(reversed.weeklyQuotaIsLow && !reversed.fiveHourQuotaIsLow)
  let onlyShort = viewReading(Bucket(primary:QuotaWindow(usedPercent:100,windowDurationMins:300)))
  assert(onlyShort.quotaWindows.count == 1 && onlyShort.menuBarTitle(at:now) == "5h 0%" && onlyShort.fiveHourQuotaIsLow)
  let absent = viewReading(Bucket(limitId:"codex"))
  assert(absent.quotaWindows.isEmpty && absent.menuBarTitle(at:now) == "额度未提供" && absent.statusLabel(at:now) == "额度未提供")
  assert(!absent.fiveHourQuotaIsLow && !absent.weeklyQuotaIsLow)
  let unknownPeriod = viewReading(Bucket(primary:QuotaWindow(usedPercent:50)))
  assert(unknownPeriod.menuBarTitle(at:now) == "额度 50%" && unknownPeriod.fiveHourQuota == nil && unknownPeriod.weeklyQuota == nil)
  let unreportedValue = viewReading(Bucket(primary:QuotaWindow(windowDurationMins:10080)))
  assert(unreportedValue.quotaWindows.count == 1 && unreportedValue.menuBarTitle(at:now) == "周 —" && !unreportedValue.weeklyQuotaIsLow)
  let nonstandard = viewReading(Bucket(primary:QuotaWindow(usedPercent:40,windowDurationMins:15)))
  assert(nonstandard.menuBarTitle(at:now) == "15m 60%" && nonstandard.quotaWindows[0].title == "15 分钟")
  let wire = try decode(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":32,"windowDurationMins":10080},"secondary":null}}}"#)
  assert(viewReading(wire.codex!).menuBarTitle(at:now) == "周 68%")
  var inProgress = viewReading(wire.codex!)
  inProgress.sync = SyncInfo(lastAttempt:now,refreshing:true,networkAvailable:true)
  assert(inProgress.statusLabel(at:now) == "同步中")
  assert(inProgress.statusLabel(at:now.addingTimeInterval(36)) == "待同步")
  inProgress.markSyncUnavailable("请打开 Codex T3 同步")
  assert(inProgress.sync?.refreshing == false && inProgress.isStale(at:now))
  assert(inProgress.weeklyQuota?.remaining == 68 && inProgress.updated == now)
  print("Passed: quota/expiry checks; weekly-only in either slot; reversed windows; independent semantic thresholds; one/zero windows; unknown duration/value; nonstandard period; wire decoding and dynamic menu labels")
 }
}
