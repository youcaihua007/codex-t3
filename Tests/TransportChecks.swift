import Foundation
import Darwin
@main enum TransportChecks {
    static func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done())
    }
    static func main() throws {
        let service = "local.codext3.transport-test." + UUID().uuidString
        let bridge = Bridge(service: service, trust: { _ in true })
        let reading = Reading(bucket: Bucket(primary: QuotaWindow(usedPercent: 25, windowDurationMins: 300)),
                              updated: Date(), message: "已连接", account: AccountInfo(type: "chatgpt", email: "fixture@example.com", id: "fixture-id", name: "Fixture"))
        bridge.set(reading); try bridge.start()
        defer { bridge.stop() }
        fputs("Transport test: first launch and signed summary\n", stderr)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let got = try LocalClient.testRead(.quota, service: service, trust: { audit in
            precondition(PeerTrust.matches(audit, executableBundle: executable), "Kernel audit token failed code-signature validation")
            precondition(!PeerTrust.matches(audit, executableBundle: URL(fileURLWithPath: "/bin/ls")), "A different signed binary was accepted")
            return true
        })
        precondition(got.account == nil && got.fiveHourQuota?.remaining == 75)
        let suite = "local.codext3.transport-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(reading), forKey: "lastReading")
        precondition(WidgetCache.read(defaults: defaults).account == nil)
        let migrated = try JSONDecoder().decode(Reading.self, from: defaults.data(forKey: "lastReading")!)
        precondition(migrated.account == nil && migrated.fiveHourQuota?.remaining == 75)
        WidgetCache.save(reading, defaults: defaults)
        let saved = try JSONDecoder().decode(Reading.self, from: defaults.data(forKey: "lastReading")!)
        precondition(saved.account == nil)
        // Exercise the actual receiver's size bound and malformed-message cleanup.
        for payload in [Data(repeating: 65, count: 2048), Data("not json".utf8)] {
            var server: mach_port_t = 0, reply: mach_port_t = 0
            precondition(t3_mach_lookup(service, &server) == KERN_SUCCESS)
            precondition(t3_mach_reply_port(&reply) == KERN_SUCCESS)
            defer { t3_mach_release(server); t3_mach_destroy(reply) }
            try MachIO.send(payload, to: server, replyPort: reply)
            do {
                _ = try MachIO.receive(reply, maximum: 65536, timeout: 2000, expectsReplyPort: false)
                preconditionFailure("Malformed request received a reading")
            } catch {}
            let afterMalformed = try LocalClient.testRead(.quota, service: service)
            precondition(afterMalformed.fiveHourQuota?.remaining == 75,
                         "Malformed request blocked subsequent reads")
        }
        fputs("Transport test: duplicate, restart and refresh\n", stderr)
        let second = Bridge(service: service, trust: { _ in true })
        do { try second.start(); preconditionFailure("Duplicate host replaced a live service") } catch {}
        let afterDuplicate = try LocalClient.testRead(.quota, service: service)
        precondition(afterDuplicate.account == nil)
        bridge.stop(); try bridge.start()
        let afterRestart = try LocalClient.testRead(.quota, service: service)
        precondition(afterRestart.fiveHourQuota?.remaining == 75)
        var refreshCount = 0
        bridge.onRefresh = { done in
            refreshCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var new = reading; new.updated = Date(); done(new, true)
            }
        }
        let result = RefreshResult()
        DispatchQueue.global().async {
            do { result.finish(LocalReply(success: true, reading: try LocalClient.testRead(.refresh, service: service))) }
            catch { result.finish(LocalReply(success: false, reading: nil)) }
        }
        var received: Reading?
        spin { received = result.reply()?.reading; return received != nil }
        precondition(received!.updated! > reading.updated! && received!.account == nil && refreshCount == 1)
        _ = try LocalClient.testRead(.refresh, service: service)
        precondition(refreshCount == 1, "Burst requests bypassed refresh rate limit")
        do { _ = try LocalClient.testRead(.quota, service: service, trust: { _ in false }); preconditionFailure("Untrusted server accepted") } catch {}
        let deniedService = service + ".denied"
        let denied = Bridge(service: deniedService, trust: { _ in false }); try denied.start(); defer { denied.stop() }
        do { _ = try LocalClient.testRead(.quota, service: deniedService); preconditionFailure("Unauthorized client received data") } catch {}
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t3-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        precondition(CodexExecutable.locate(customPath: fake.path) == fake)
        precondition(CodexExecutable.locate(customPath: fake.path + ".missing") == nil)
        print("Passed: first-launch Mach bridge, kernel audit-token validation, duplicate and restart protection, bounded malformed requests, untrusted client/server rejection, summary privacy and cache migration, completed refresh and custom Codex discovery")
    }
}
