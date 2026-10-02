import Foundation
import CryptoKit
final class FixtureProtocol: URLProtocol {
    static var body = Data()
    static var archive = Data()
    static var status = 200
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let bytes = request.url!.path.hasSuffix(".zip") ? Self.archive : Self.body
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length":String(bytes.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main enum UpdateChecks {
    static func spin(_ done: () -> Bool) {
        let until = Date().addingTimeInterval(15)
        while !done() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(done(), "Update callback timed out")
    }
    static func rejected(line: Int = #line, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid update was accepted at line \(line)") } catch {}
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = try GitHubRepository("https://github.com/example/Codex-T3.git")
        precondition(repo.url.absoluteString == "https://github.com/example/Codex-T3")
        precondition(repo.feedbackURL.path == "/example/Codex-T3/issues/new/choose")
        for input in ["http://github.com/a/b","https://github.com.evil.test/a/b","https://user@github.com/a/b","https://github.com/a/b/releases","https://github.com/a/b?token=x"] { rejected { _ = try GitHubRepository(input) } }
        let newer = try AppVersion("v2.10.0"), older = try AppVersion("2.9.9")
        precondition(newer > older)
        for input in ["v3.0.0-beta", "3", "999999999999999999.0.0"] { rejected { _ = try AppVersion(input) } }
        let archive = root.appendingPathComponent("good.zip")
        let bytes = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try UpdatePackage.verifyDigest(archive, expected: digest)
        rejected { try UpdatePackage.verifyDigest(archive, expected: String(repeating: "0", count: 64)) }
        let checksum = try UpdatePackage.checksum(Data((digest + "  Codex-T3-3.0.0-universal.zip\n").utf8), filename: "Codex-T3-3.0.0-universal.zip")
        precondition(checksum == digest)
        rejected { _ = try UpdatePackage.checksum(Data((digest + "  wrong.zip").utf8), filename: "expected.zip") }
        try UpdatePackage.verifyArchive(archive)
        for name in ["traversal", "symlink", "duplicate", "bomb", "mismatch"] { rejected { try UpdatePackage.verifyArchive(root.appendingPathComponent(name + ".zip")) } }
        for name in ["hidden-bomb", "bad-crc"] {
            let archive = root.appendingPathComponent(name + ".zip")
            let entries = try UpdatePackage.verifyArchive(archive)
            let output = root.appendingPathComponent(name + "-output")
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            rejected { try UpdatePackage.extract(archive,entries:entries,into:output) }
        }
        func response(version: String = "v3.0.0", prerelease: Bool = false, download: String? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name":version,"draft":false,"prerelease":prerelease,"assets":[
                ["name":"Codex-T3-3.0.0-universal.zip","size":bytes.count,"digest":"sha256:" + digest,"browser_download_url":download ?? "https://github.com/example/Codex-T3/releases/download/v3.0.0/Codex-T3-3.0.0-universal.zip"],
                ["name":"Codex-T3-GitHub-source.zip","size":1,"browser_download_url":"https://github.com/example/Codex-T3/releases/download/v3.0.0/source.zip"]]])
        }
        let release = try AppRelease.decode(response(), repository: repo, architecture: "arm64")
        precondition(release.asset?.name == "Codex-T3-3.0.0-universal.zip" && release.embeddedDigest == digest)
        let wrongOrigin = try AppRelease.decode(response(download:"https://evil.test/new.zip"), repository: repo, architecture: "arm64")
        precondition(wrongOrigin.asset == nil)
        rejected { _ = try AppRelease.decode(response(prerelease:true), repository: repo, architecture: "arm64") }
        for code in [403,404,429,500] { rejected { try UpdateNetwork.check(HTTPURLResponse(url: repo.latestAPI, statusCode: code, httpVersion:nil,headerFields:nil)) } }
        let current = root.appendingPathComponent("current/Codex T3.app")
        let prepared = try UpdatePackage.prepare(archive, digest: digest, version: release.version, current: current)
        rejected { try UpdatePackage.verifyApp(prepared, version: AppVersion("4.0.0"), current:current) }
        let tampered = root.appendingPathComponent("tampered/Codex T3.app")
        try FileManager.default.createDirectory(at:tampered.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:prepared,to:tampered)
        let executable = tampered.appendingPathComponent("Contents/MacOS/Codex T3")
        var code = try Data(contentsOf:executable);code[4096] ^= 1;try code.write(to:executable)
        rejected { _ = try UpdatePackage.codeInfo(tampered) }
        let rollback = root.appendingPathComponent("rollback/Codex T3.app")
        try FileManager.default.createDirectory(at: rollback.deletingLastPathComponent(), withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:current,to:rollback)
        var registrationCalls = 0
        rejected { try UpdateInstaller.replace(prepared, destination:rollback, register: { _ in registrationCalls += 1 }, launch:{ _ in throw UpdateFailure(message:"simulated launch error") }) }
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf:rollback.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
        precondition(restored["CFBundleShortVersionString"] as? String == "2.9.2" && registrationCalls == 2)
        try UpdateInstaller.replace(prepared,destination:rollback,register:{_ in},launch:{_ in})
        let replaced = try PropertyListSerialization.propertyList(from: Data(contentsOf:rollback.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
        precondition(replaced["CFBundleShortVersionString"] as? String == "3.0.0")
        let suite = "local.codext3.updates-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses=[FixtureProtocol.self]
        let updater = UpdateController(defaults:defaults,bundle:Bundle(url:current)!,network:UpdateNetwork(configuration:config))
        defer { updater.stop() }
        let unconfigured = UpdateController(defaults:defaults,bundle:Bundle(url:root.appendingPathComponent("unconfigured-current/Codex T3.app"))!,network:UpdateNetwork(configuration:config))
        unconfigured.check();precondition(FixtureProtocol.requests.isEmpty && unconfigured.repository == nil)
        precondition(updater.repository == repo)
        FixtureProtocol.body = try response();FixtureProtocol.archive=bytes
        updater.check();spin { updater.phase == .idle }
        precondition(updater.release?.version == release.version && updater.lastChecked != nil)
        updater.download();spin { updater.phase == .ready || updater.phase == .idle }
        precondition(updater.phase == .ready, updater.message)
        updater.cancel();precondition(updater.phase == .idle)
        FixtureProtocol.status=404;updater.check();spin { updater.phase == .idle }
        precondition(updater.release == nil && updater.message.contains("暂无"))
        precondition(FixtureProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField:"Authorization") == nil && $0.value(forHTTPHeaderField:"Cookie") == nil })
        defaults.set("https://github.com/other/old-project", forKey:"update.repository")
        defaults.set(Date(), forKey:"update.lastChecked")
        let fixed = UpdateController(defaults:defaults,bundle:Bundle(url:root.appendingPathComponent("fixed-current/Codex T3.app"))!,network:UpdateNetwork(configuration:config))
        defer { fixed.stop() }
        precondition(fixed.repository == repo)
        precondition(defaults.string(forKey:"update.repository") == nil && fixed.lastChecked == nil)
        defaults.set("https://github.com/other/new-project", forKey:"update.repository")
        precondition(fixed.repository == repo)
        FixtureProtocol.status=200;fixed.check();spin { fixed.phase == .idle }
        precondition(FixtureProtocol.requests.last?.url == repo.latestAPI && fixed.release?.version == release.version)
        print("Passed: fixed embedded update/feedback source overrides old preferences and rejects redirection; repository/version rules, release selection, HTTP failures, SHA-256, archive traversal/symlink/duplicate/bomb/header/CRC rejection and bounded decompression, code signatures/version validation, atomic install/rollback, cookie-free check/download/prepare/cancel without live network")
    }
}
