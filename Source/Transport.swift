import Foundation
import Darwin
import Security

enum LocalTransportError: Error { case unavailable, connectionUnavailable, untrustedPeer, invalidMessage, timeout }
enum LocalOperation: String, Codable { case quota, refresh }
struct LocalRequest: Codable { let operation: LocalOperation }
struct LocalReply: Codable { var success: Bool; var reading: Reading?; var error: String? }

enum LocalIdentity {
    static let hostID = "local.codext3.quota"
    static let widgetID = hostID + ".widget"
    static let service = hostID + ".bridge"
    static var hostBundle: URL {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "appex" ? bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() : bundle
    }
}

// Mach attaches the sender's audit token in a kernel-generated trailer. Never
// trust a caller-provided PID or bundle identifier, or send account credentials.
enum PeerTrust {
    static func matches(_ audit: audit_token_t, executableBundle: URL) -> Bool {
        guard t3_mach_uid(audit) == getuid() else {
            #if QUOTA_TEST_BUILD
            fputs("PeerTrust: different effective UID\n", stderr)
            #endif
            return false
        }
        var token = audit
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData, kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &guest)
        guard guestStatus == errSecSuccess, let guest else {
            #if QUOTA_TEST_BUILD
            fputs("PeerTrust: guest status \(guestStatus)\n", stderr)
            #endif
            return false
        }
        // Universal slices have distinct CDHashes. Allow either installed slice
        // so a native widget also works with the same app running under Rosetta.
        var hashes = Set<Data>()
        for architecture in ["arm64", "x86_64"] {
            var expected: SecStaticCode?
            let attributes = [kSecCodeAttributeArchitecture: architecture] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(executableBundle as CFURL, [], attributes, &expected) == errSecSuccess,
                  let expected else { continue }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(expected, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { continue }
            hashes.insert(hash)
        }
        guard !hashes.isEmpty else {
            #if QUOTA_TEST_BUILD
            fputs("PeerTrust: no installed hashes at \(executableBundle.path)\n", stderr)
            #endif
            return false
        }
        let expression = hashes.map { hash in
            "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        }.joined(separator: " or ")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let validity = SecCodeCheckValidity(guest, [], requirement)
        #if QUOTA_TEST_BUILD
        if validity != errSecSuccess { fputs("PeerTrust: validity \(validity) for \(executableBundle.path)\n", stderr) }
        #endif
        return validity == errSecSuccess
    }
    static func client(_ audit: audit_token_t) -> Bool {
        matches(audit, executableBundle: LocalIdentity.hostBundle) ||
        matches(audit, executableBundle: LocalIdentity.hostBundle.appendingPathComponent("Contents/PlugIns/CodexT3Widget.appex"))
    }
    static func server(_ audit: audit_token_t) -> Bool { matches(audit, executableBundle: LocalIdentity.hostBundle) }
}

enum MachIO {
    struct Message { let data: Data; let replyPort: mach_port_t; let audit: audit_token_t }
    static func send(_ data: Data, to port: mach_port_t, replyPort: mach_port_t = 0, isReply: Bool = false) throws {
        guard data.count <= 65536 else {
            if isReply { t3_mach_release(port) }
            throw LocalTransportError.invalidMessage
        }
        let result = data.withUnsafeBytes {
            t3_mach_send(port, replyPort, $0.baseAddress, UInt32($0.count), isReply ? 1 : 0)
        }
        guard result == KERN_SUCCESS else { throw LocalTransportError.unavailable }
    }
    static func receive(_ port: mach_port_t, maximum: Int, timeout: UInt32, expectsReplyPort: Bool) throws -> Message {
        var bytes = [UInt8](repeating: 0, count: maximum)
        var length: UInt32 = 0, reply: mach_port_t = 0
        var audit = audit_token_t()
        let result = bytes.withUnsafeMutableBytes {
            t3_mach_receive(port, $0.baseAddress, UInt32(maximum), timeout, expectsReplyPort ? 1 : 0, &length, &reply, &audit)
        }
        if result == MACH_RCV_TIMED_OUT { throw LocalTransportError.timeout }
        guard result == KERN_SUCCESS else { throw LocalTransportError.invalidMessage }
        return Message(data: Data(bytes.prefix(Int(length))), replyPort: reply, audit: audit)
    }
}

enum LocalClient {
    static func read(_ operation: LocalOperation) throws -> Reading {
        for attempt in 0..<20 {
            do { return try exchange(operation, service: LocalIdentity.service, trust: PeerTrust.server) }
            catch LocalTransportError.connectionUnavailable where attempt < 19 { Thread.sleep(forTimeInterval: 0.1) }
        }
        throw LocalTransportError.unavailable
    }
    private static func exchange(_ operation: LocalOperation, service: String, trust: (audit_token_t) -> Bool) throws -> Reading {
        var server: mach_port_t = 0
        guard t3_mach_lookup(service, &server) == KERN_SUCCESS else { throw LocalTransportError.connectionUnavailable }
        defer { t3_mach_release(server) }
        var replyPort: mach_port_t = 0
        guard t3_mach_reply_port(&replyPort) == KERN_SUCCESS else { throw LocalTransportError.unavailable }
        defer { t3_mach_destroy(replyPort) }
        try MachIO.send(JSONEncoder().encode(LocalRequest(operation: operation)), to: server, replyPort: replyPort)
        let message = try MachIO.receive(replyPort, maximum: 65536, timeout: operation == .refresh ? 35000 : 8000, expectsReplyPort: false)
        guard trust(message.audit) else { throw LocalTransportError.untrustedPeer }
        let reply = try JSONDecoder().decode(LocalReply.self, from: message.data)
        guard let reading = reply.reading else { throw LocalTransportError.invalidMessage }
        return reading.widgetSummary
    }
    #if QUOTA_TEST_BUILD
    static func testRead(_ operation: LocalOperation, service: String, trust: (audit_token_t) -> Bool = { _ in true }) throws -> Reading {
        try exchange(operation, service: service, trust: trust)
    }
    #endif
}

enum WidgetCache {
    static func save(_ reading: Reading, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(reading.widgetSummary) { defaults.set(data, forKey: "lastReading") }
    }
    static func read(defaults: UserDefaults = .standard) -> Reading {
        let reading = defaults.data(forKey: "lastReading").flatMap { try? JSONDecoder().decode(Reading.self, from: $0) } ?? .empty
        let sanitized = reading.widgetSummary
        if reading.account != nil { save(sanitized, defaults: defaults) }
        return sanitized
    }
}

#if !WIDGET_EXTENSION
final class RefreshResult {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: LocalReply?
    func finish(_ reply: LocalReply) { lock.lock(); value = reply; lock.unlock(); semaphore.signal() }
    func reply() -> LocalReply? { lock.lock(); defer { lock.unlock() }; return value }
}
final class Bridge {
    private let queue = DispatchQueue(label: "local.codext3.bridge")
    private let service: String
    private let trust: (audit_token_t) -> Bool
    private var listener: DispatchSourceMachReceive?
    private var stopped: DispatchSemaphore?
    private var reading = Reading.empty
    private var active = 0
    private var nextRefresh = Date.distantPast
    var onRefresh: ((@escaping (Reading, Bool) -> Void) -> Void)?
    var isRunning: Bool { listener != nil }
    init() { service = LocalIdentity.service; trust = PeerTrust.client }
    #if QUOTA_TEST_BUILD
    init(service: String, trust: @escaping (audit_token_t) -> Bool) { self.service = service; self.trust = trust }
    #endif
    func set(_ reading: Reading) { let summary = reading.widgetSummary; queue.async { self.reading = summary } }
    func start() throws {
        guard listener == nil else { return }
        var port: mach_port_t = 0
        guard t3_mach_register(service, &port) == KERN_SUCCESS else { throw LocalTransportError.unavailable }
        let receivePort = port
        let cancellation = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeMachReceiveSource(port: receivePort, queue: queue)
        source.setCancelHandler { [service] in
            t3_mach_unregister(service, receivePort); cancellation.signal()
        }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while !source.isCancelled {
                do {
                    let message = try MachIO.receive(receivePort, maximum: 1024, timeout: 0, expectsReplyPort: true)
                    guard self.active < 8 else { t3_mach_release(message.replyPort); continue }
                    self.active += 1
                    DispatchQueue.global(qos: .utility).async {
                        self.handle(message)
                        self.queue.async { self.active -= 1 }
                    }
                } catch LocalTransportError.timeout { break }
                catch { continue }
            }
        }
        listener = source; stopped = cancellation; source.resume()
    }
    private func handle(_ message: MachIO.Message) {
        var replyPort = message.replyPort
        defer { t3_mach_release(replyPort) }
        guard trust(message.audit) else { return }
        func send(_ reply: LocalReply) throws {
            let data = try JSONEncoder().encode(reply)
            let destination = replyPort; replyPort = 0
            try MachIO.send(data, to: destination, isReply: true)
        }
        do {
            let request = try JSONDecoder().decode(LocalRequest.self, from: message.data)
            if request.operation == .quota {
                try send(LocalReply(success: true, reading: queue.sync { reading }))
            } else {
                let allowed = queue.sync { () -> Bool in
                    guard Date() >= nextRefresh else { return false }
                    nextRefresh = Date().addingTimeInterval(2); return true
                }
                guard allowed else {
                    try send(LocalReply(success: false, reading: queue.sync { reading }, error: L("刷新过于频繁"))); return
                }
                let result = RefreshResult()
                DispatchQueue.main.async { [weak self] in
                    guard let refresh = self?.onRefresh else { result.finish(LocalReply(success: false, reading: nil, error: L("同步服务不可用"))); return }
                    refresh { reading, success in result.finish(LocalReply(success: success, reading: reading.widgetSummary)) }
                }
                guard result.semaphore.wait(timeout: .now() + 35) == .success, let reply = result.reply() else { throw LocalTransportError.timeout }
                try send(reply)
            }
        } catch { /* Malformed or abandoned requests never expose quota or credentials. */ }
    }
    func stop() {
        guard let source = listener else { return }
        listener = nil; source.cancel()
        _ = stopped?.wait(timeout: .now() + 2); stopped = nil
    }
    deinit { stop() }
}
#endif
