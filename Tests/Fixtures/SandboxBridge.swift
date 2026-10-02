import Foundation
import Darwin

@main enum SandboxBridge {
    static func main() throws {
        let arguments = CommandLine.arguments
        let mode = arguments[1], service = arguments[2]
        if mode == "server" {
            let bridge = Bridge(service: service, trust: PeerTrust.client)
            let reading = Reading(bucket: Bucket(primary: QuotaWindow(usedPercent: 25, windowDurationMins: 300)),
                                  updated: Date(timeIntervalSince1970: 1), message: "已连接",
                                  account: AccountInfo(type: "chatgpt", email: "demo@example.com", id: "fixture"))
            bridge.set(reading)
            bridge.onRefresh = { completion in
                var fresh = reading; fresh.updated = Date(); completion(fresh, true)
            }
            try bridge.start()
            defer { bridge.stop() }
            fputs("READY\n", stdout); fflush(stdout)
            let stop = URL(fileURLWithPath: arguments[3])
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: stop.path), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return
        }
        // The client has only one named Mach lookup exception, no file or network grants.
        let forbidden = URL(fileURLWithPath: arguments[3]).appendingPathComponent("forbidden-write")
        do {
            try Data("not allowed".utf8).write(to: forbidden)
            preconditionFailure("Fixture is not actually sandboxed")
        } catch {}
        precondition(NSHomeDirectory() != arguments[4], "Sandbox container was not activated")
        if mode == "untrusted" {
            do {
                _ = try LocalClient.testRead(.quota, service: service)
                preconditionFailure("Untrusted sandbox client received a reading")
            } catch { print("Untrusted sandbox client rejected") }
            return
        }
        precondition(Bundle.main.bundleURL.pathExtension == "appex")
        if mode == "impostor" {
            do {
                _ = try LocalClient.testRead(.quota, service: service, trust: PeerTrust.server)
                preconditionFailure("Impostor host's reading was accepted")
            } catch LocalTransportError.untrustedPeer { print("Impostor signed host rejected") }
            return
        }
        let reading = try LocalClient.testRead(.quota, service: service, trust: PeerTrust.server)
        precondition(reading.account == nil && reading.fiveHourQuota?.remaining == 75)
        let fresh = try LocalClient.testRead(.refresh, service: service, trust: PeerTrust.server)
        precondition(fresh.account == nil && fresh.updated! > reading.updated!)
        print("Sandbox first activation, signed peers, summary privacy and refresh passed")
    }
}
