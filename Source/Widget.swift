import SwiftUI
import WidgetKit

struct Entry: TimelineEntry { let date: Date; let reading: Reading }
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), reading: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        load { completion(Entry(date: Date(), reading: $0)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        load { reading in
            let now = Date()
            // Advance stale labels even if WidgetKit defers the next fetch.
            let staleDate = (reading.updated ?? now).addingTimeInterval(reading.refreshInterval.staleAfter + 1)
            var dates = [now, max(now.addingTimeInterval(1), staleDate), now.addingTimeInterval(1800)]
            if reading.sync?.refreshing == true, let attempt = reading.sync?.lastAttempt {
                dates.append(max(now.addingTimeInterval(1), attempt.addingTimeInterval(36)))
            }
            let entries = dates.sorted().map { Entry(date: $0, reading: reading) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(reading.refreshInterval.seconds))))
        }
    }
    func load(completion: @escaping (Reading) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            if let reading = try? LocalClient.read(.quota) {
                WidgetCache.save(reading); completion(reading)
            } else {
                var reading = WidgetCache.read()
                reading.markSyncUnavailable("请打开 Codex T3 同步")
                completion(reading)
            }
        }
    }
}
@main struct CodexT3Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: Provider()) { entry in
            T3WidgetView(reading: entry.reading, now: entry.date)
                .containerBackground(ivory, for: .widget)
                .widgetURL(URL(string: "codext3://refresh"))
        }
        .configurationDisplayName(Text(Localization.text("Codex T3 · 额度小组件", language: WidgetCache.read().displayLanguage)))
        .description(Text(Localization.text("Codex 剩余额度、重置时间与重置卡。", language: WidgetCache.read().displayLanguage)))
        .supportedFamilies(T3WidgetSize.allCases.map(\.family))
        .contentMarginsDisabled()
    }
}
