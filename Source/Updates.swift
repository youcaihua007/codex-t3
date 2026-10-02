import Cocoa
import Foundation
import CryptoKit
import Security
import Darwin

struct UpdateFailure: LocalizedError {
    let message: String
    var arguments: [String] = []
    var errorDescription: String? { Localization.text(message, arguments: arguments.map { $0 as CVarArg }) }
}
struct AppVersion: Comparable, Equatable {
    let parts: [Int]
    let text: String
    init(_ raw: String) throws {
        let clean = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let pieces = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), clean.count < 32,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              pieces.allSatisfy({ Int($0).map { $0 <= 99999 } ?? false }) else {
            throw UpdateFailure(message: "发布版本号格式不受支持。")
        }
        parts = pieces.map { Int($0)! } + (pieces.count == 2 ? [0] : [])
        text = clean
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts }
}
struct GitHubRepository: Equatable {
    let owner: String
    let name: String
    init(_ raw: String) throws {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw UpdateFailure(message: "请输入 https://github.com/用户名/仓库名 格式的项目地址。")
        }
        let pieces = url.path.split(separator: "/").map(String.init)
        guard pieces.count == 2 else { throw UpdateFailure(message: "请填写 GitHub 项目首页地址。") }
        let repo = pieces[1].hasSuffix(".git") ? String(pieces[1].dropLast(4)) : pieces[1]
        guard pieces[0].range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil,
              repo.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil,
              repo != ".", repo != ".." else { throw UpdateFailure(message: "GitHub 项目地址无效。") }
        owner = pieces[0]; name = repo
    }
    var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    var latestAPI: URL { URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")! }
    var latestManifest: URL { url.appendingPathComponent("releases/latest/download/update.json") }
    var releasesURL: URL { url.appendingPathComponent("releases") }
    var feedbackURL: URL { url.appendingPathComponent("issues/new/choose") }
    func ownsDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil && url.password == nil &&
        url.path.lowercased().hasPrefix("/\(owner)/\(name)/releases/download/".lowercased()) && url.query == nil && url.fragment == nil
    }
}
struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let digest: String?
    enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url", size, digest }
}
struct ReleaseResponse: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease, assets }
}
struct AppRelease {
    let tag: String
    let version: AppVersion
    let asset: ReleaseAsset?
    let checksum: ReleaseAsset?
    let repository: GitHubRepository
    var page: URL { repository.url.appendingPathComponent("releases/tag/" + tag) }
    static func decode(_ data: Data, repository: GitHubRepository, architecture: String) throws -> AppRelease {
        guard data.count <= 2 * 1024 * 1024 else { throw UpdateFailure(message: "更新信息过大，已停止读取。") }
        let response = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        guard !response.draft && !response.prerelease else { throw UpdateFailure(message: "尚无可用的正式版本。") }
        let version = try AppVersion(response.tagName)
        let names = ["Codex-T3-\(version.text)-universal.zip", "Codex-T3-\(version.text)-\(architecture).zip"]
        let asset: ReleaseAsset? = names.compactMap { name -> ReleaseAsset? in response.assets.first { $0.name == name && $0.size > 0 && $0.size <= UpdatePackage.maximumDownload && repository.ownsDownload($0.browserDownloadURL) } }.first
        let checksum = asset.flatMap { selected in response.assets.first { $0.name == selected.name + ".sha256" && $0.size > 0 && $0.size <= 2048 && repository.ownsDownload($0.browserDownloadURL) } }
        return AppRelease(tag: response.tagName, version: version, asset: asset, checksum: checksum, repository: repository)
    }
    static func decodeManifest(_ data: Data, repository: GitHubRepository, architecture: String) throws -> AppRelease {
        let release = try decode(data, repository: repository, architecture: architecture)
        guard let asset = release.asset, release.embeddedDigest != nil,
              asset.browserDownloadURL == repository.url.appendingPathComponent("releases/download/\(release.tag)/\(asset.name)") else {
            throw UpdateFailure(message: "更新信息无效或过大。")
        }
        return release
    }
    var embeddedDigest: String? {
        guard let digest = asset?.digest, digest.hasPrefix("sha256:") else { return nil }
        return UpdatePackage.validDigest(String(digest.dropFirst(7)))
    }
}

// All update requests are public, cookie-free HTTPS requests. Quota/login data
// never enters this session. Redirects may reach GitHub's release CDN over HTTPS.
final class UpdateNetwork: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration; super.init() }
    struct Download {
        let progress: (Double?) -> Void
        let completion: (Result<URL, Error>) -> Void
    }
    private let lock = NSLock()
    private var downloads: [Int: Download] = [:]
    lazy var session: URLSession = {
        let configuration = self.configuration
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        } else { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        request.setValue("Codex-T3", forHTTPHeaderField: "User-Agent")
        return request
    }
    @discardableResult func data(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: request(url)) { data, response, error in
            do {
                if let error { throw error }
                try Self.check(response)
                guard let data, data.count <= 2 * 1024 * 1024 else { throw UpdateFailure(message: "更新信息无效或过大。") }
                completion(.success(data))
            } catch { completion(.failure(error)) }
        }; task.resume(); return task
    }
    @discardableResult func download(_ url: URL, progress: @escaping (Double?) -> Void, completion: @escaping (Result<URL, Error>) -> Void) -> URLSessionDownloadTask {
        var request = self.request(url); request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        lock.lock(); downloads[task.taskIdentifier] = Download(progress: progress, completion: completion); lock.unlock()
        task.resume(); return task
    }
    static func check(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateFailure(message: "更新服务返回了无效响应。") }
        switch http.statusCode {
        case 200: return
        case 404: throw UpdateFailure(message: "该项目暂无正式发布版本，或项目地址不正确。")
        case 403, 429: throw UpdateFailure(message: "GitHub 检测次数暂时受限，请稍后重试。")
        default: throw UpdateFailure(message: "更新服务暂时不可用（%@）。", arguments: [String(http.statusCode)])
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > UpdatePackage.maximumDownload || totalBytesExpectedToWrite > UpdatePackage.maximumDownload { downloadTask.cancel(); return }
        lock.lock(); let callback = downloads[downloadTask.taskIdentifier]?.progress; lock.unlock()
        callback?(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let pending = downloads.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
        guard let pending else { return }
        do {
            try Self.check(downloadTask.response)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-t3-download-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let owned = folder.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: location, to: owned)
            pending.completion(.success(owned))
        } catch { pending.completion(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock(); let pending = downloads.removeValue(forKey: task.taskIdentifier); lock.unlock()
        pending?.completion(.failure(error))
    }
    func stop() { session.invalidateAndCancel() }
}

enum UpdatePackage {
    static let maximumDownload: Int64 = 100 * 1024 * 1024
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func validDigest(_ text: String) -> String? {
        text.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) == nil ? nil : text.lowercased()
    }
    static func checksum(_ data: Data, filename: String) throws -> String {
        guard data.count <= 2048, let text = String(data: data, encoding: .utf8) else { throw UpdateFailure(message: "校验文件无效。") }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let digest = validDigest(String(fields[0])), fields[1] == Substring(filename) else { throw UpdateFailure(message: "校验文件与更新包不匹配。") }
        return digest
    }
    static func verifyDigest(_ file: URL, expected: String) throws {
        guard let digest = validDigest(expected) else { throw UpdateFailure(message: "缺少有效的更新包校验值。") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(); var size: Int64 = 0
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            size += Int64(block.count); guard size <= maximumDownload else { throw UpdateFailure(message: "更新包超过大小限制。") }
            hash.update(data: block)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw UpdateFailure(message: "更新包校验失败，请重新下载。") }
    }
    static func word(_ data: Data, _ offset: Int, _ bytes: Int) throws -> UInt64 {
        guard offset >= 0 && offset + bytes <= data.count else { throw UpdateFailure(message: "更新压缩包结构不完整。") }
        return (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    // Validate both central and local ZIP names before extraction, and reject
    // symlinks, encrypted entries, traversal, duplicates and expansion bombs.
    struct ArchiveEntry {
        let name: String
        let offset: Int
        let compressed: Int
        let expanded: Int
        let method: UInt64
        let checksum: UInt64
        let mode: UInt64
    }
    @discardableResult static func verifyArchive(_ url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 && data.count <= maximumDownload else { throw UpdateFailure(message: "更新压缩包大小无效。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try word(data, offset, 4) == 0x06054b50,
               offset + 22 + Int(try word(data, offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try word(data, end + 4, 4) == 0 else { throw UpdateFailure(message: "不支持该更新压缩包。") }
        let count = Int(try word(data, end + 10, 2))
        let directory = Int(try word(data, end + 16, 4)); let length = Int(try word(data, end + 12, 4))
        guard count > 0 && count <= 4096, try word(data, end + 8, 2) == UInt64(count),
              directory >= 0 && length <= 4 * 1024 * 1024 && directory + length == end else { throw UpdateFailure(message: "更新压缩包目录无效。") }
        var position = directory; var names = Set<String>(); var expanded: UInt64 = 0; var entries: [ArchiveEntry] = []
        for _ in 0..<count {
            guard try word(data, position, 4) == 0x02014b50 else { throw UpdateFailure(message: "更新压缩包目录损坏。") }
            let flags = try word(data, position + 8, 2), method = try word(data, position + 10, 2)
            let compressed = Int(try word(data, position + 20, 4)), uncompressed = try word(data, position + 24, 4)
            let nameLength = Int(try word(data, position + 28, 2)), extra = Int(try word(data, position + 30, 2)), comment = Int(try word(data, position + 32, 2))
            let mode = try word(data, position + 38, 4) >> 16
            let local = Int(try word(data, position + 42, 4))
            guard flags & 1 == 0, method == 0 || method == 8, mode & 0xf000 != 0xa000,
                  nameLength > 0 && nameLength < 1024, position + 46 + nameLength + extra + comment <= end else { throw UpdateFailure(message: "更新包包含不安全的文件类型。") }
            let nameBytes = data[(position + 46)..<(position + 46 + nameLength)]
            guard let name = String(data: nameBytes, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.contains("\n"),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }), names.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw UpdateFailure(message: "更新包包含无效文件路径。") }
            guard try word(data, local, 4) == 0x04034b50,
                  try word(data, local + 8, 2) == method,
                  Int(try word(data, local + 26, 2)) == nameLength else { throw UpdateFailure(message: "更新压缩包文件头不匹配。") }
            let start = local + 30 + nameLength + Int(try word(data, local + 28, 2))
            guard local + 30 + nameLength <= directory, start + compressed <= directory,
                  data[(local + 30)..<(local + 30 + nameLength)] == nameBytes else { throw UpdateFailure(message: "更新包文件数据越界。") }
            guard uncompressed <= 64 * 1024 * 1024 else { throw UpdateFailure(message: "更新包中的单个文件过大。") }
            entries.append(ArchiveEntry(name: name, offset: start, compressed: compressed, expanded: Int(uncompressed), method: method, checksum: try word(data, position + 16, 4), mode: mode))
            expanded += uncompressed
            guard expanded <= 250 * 1024 * 1024 else { throw UpdateFailure(message: "更新包解压大小超过限制。") }
            position += 46 + nameLength + extra + comment
        }
        guard position == end else { throw UpdateFailure(message: "更新压缩包目录不完整。") }
        return entries
    }
    static func extract(_ archive: URL, entries: [ArchiveEntry], into directory: URL) throws {
        let input = try Data(contentsOf: archive, options: .mappedIfSafe)
        for entry in entries {
            let target = directory.appendingPathComponent(entry.name)
            if entry.name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                continue
            }
            let compressed = input[entry.offset..<(entry.offset + entry.compressed)]
            let output: Data
            if entry.method == 0 {
                guard entry.compressed == entry.expanded else { throw UpdateFailure(message: "更新文件长度不匹配。") }
                output = Data(compressed)
            } else {
                var buffer = Data(count: max(1, entry.expanded)); var stream = z_stream()
                let status = compressed.withUnsafeBytes { source in buffer.withUnsafeMutableBytes { destination -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(source.count)
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Z_DATA_ERROR }
                    defer { inflateEnd(&stream) }
                    return inflate(&stream, Z_FINISH)
                } }
                guard status == Z_STREAM_END, stream.total_out == entry.expanded, stream.total_in == entry.compressed else { throw UpdateFailure(message: "更新文件解压失败或超出大小限制。") }
                output = Data(buffer.prefix(entry.expanded))
            }
            let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
            guard checksum == entry.checksum else { throw UpdateFailure(message: "更新文件校验失败。") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try output.write(to: target, options: .atomic)
            let executable = entry.mode & 0o111 != 0 || entry.name.contains("/Contents/MacOS/")
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
    }
    static func codeInfo(_ url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else { throw UpdateFailure(message: "更新应用的代码签名或完整性校验失败。") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { throw UpdateFailure(message: "无法读取更新应用的签名。") }
        return info as? [String: Any] ?? [:]
    }
    static func supportsArchitecture(_ executable: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: executable); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        let cpu: UInt64 = architecture == "arm64" ? 0x0100000c : 0x01000007
        let magic = try word(data, 0, 4)
        if magic == 0xfeedfacf || magic == 0xfeedface { return try word(data, 4, 4) == cpu }
        if magic == 0xbebafeca || magic == 0xbfbafeca {
            func big(_ offset: Int) throws -> UInt64 {
                let value = try word(data, offset, 4)
                return ((value & 0xff) << 24) | ((value & 0xff00) << 8) | ((value >> 8) & 0xff00) | ((value >> 24) & 0xff)
            }
            let count = Int(try big(4)); guard count > 0 && count <= 16 else { return false }
            for index in 0..<count { if try big(8 + index * (magic == 0xbebafeca ? 20 : 32)) == cpu { return true } }
        }
        return false
    }
    static func verifyApp(_ app: URL, version: AppVersion, current: URL) throws {
        func info(_ app: URL) throws -> [String: Any] {
            guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { throw UpdateFailure(message: "更新应用的信息无效。") }
            return result
        }
        let properties = try info(app)
        guard app.lastPathComponent == "Codex T3.app", properties["CFBundleIdentifier"] as? String == LocalIdentity.hostID,
              let rawVersion = properties["CFBundleShortVersionString"] as? String, try AppVersion(rawVersion) == version,
              properties["CFBundleExecutable"] as? String == "Codex T3" else { throw UpdateFailure(message: "更新包中的应用或版本不匹配。") }
        if let minimum = properties["LSMinimumSystemVersion"] as? String, let required = try? AppVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            if try AppVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") < required { throw UpdateFailure(message: "此更新需要更高版本的 macOS。") }
        }
        let widget = app.appendingPathComponent("Contents/PlugIns/CodexT3Widget.appex")
        let widgetInfo = try info(widget)
        guard widgetInfo["CFBundleIdentifier"] as? String == LocalIdentity.widgetID,
              widgetInfo["CFBundleExecutable"] as? String == "CodexT3Widget",
              let widgetVersion = widgetInfo["CFBundleShortVersionString"] as? String,
              try AppVersion(widgetVersion) == version else { throw UpdateFailure(message: "更新包缺少正确的小组件。") }
        guard try supportsArchitecture(app.appendingPathComponent("Contents/MacOS/Codex T3")),
              try supportsArchitecture(widget.appendingPathComponent("Contents/MacOS/CodexT3Widget")) else { throw UpdateFailure(message: "更新包不支持当前 Mac 的处理器。") }
        let hostCode = try codeInfo(app), widgetCode = try codeInfo(widget)
        let old = try codeInfo(current)
        if let team = old[kSecCodeInfoTeamIdentifier as String] as? String {
            guard hostCode[kSecCodeInfoTeamIdentifier as String] as? String == team,
                  widgetCode[kSecCodeInfoTeamIdentifier as String] as? String == team else { throw UpdateFailure(message: "更新包的开发者身份与当前应用不一致。") }
            guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw UpdateFailure(message: "当前应用的开发者身份无效。") }
            for (bundle, identifier) in [(app, LocalIdentity.hostID), (widget, LocalIdentity.widgetID)] {
                var requirement: SecRequirement?; var code: SecStaticCode?
                let rule = "anchor apple generic and certificate leaf[subject.OU] = \"" + team + "\" and identifier \"" + identifier + "\""
                guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                      SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code, let requirement,
                      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw UpdateFailure(message: "更新包的开发者证书校验失败。") }
            }
        }
    }
    @discardableResult static func tool(_ path: String, _ arguments: [String], timeout: Double = 60) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure(message: "更新文件处理失败，请通过发布页面手动安装。") }
        return output
    }
    static func prepare(_ archive: URL, digest: String, version: AppVersion, current: URL) throws -> URL {
        try verifyDigest(archive, expected: digest); let entries = try verifyArchive(archive)
        let extracted = archive.deletingLastPathComponent().appendingPathComponent("Extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try extract(archive, entries: entries, into: extracted)
        let app = extracted.appendingPathComponent("Codex T3.app")
        try verifyApp(app, version: version, current: current)
        return app
    }
}

struct InstallPlan: Codable {
    let source: URL
    let destination: URL
    let archive: URL
    let digest: String
    let version: String
    let parentPID: Int32
}
enum UpdateInstaller {
    static let flag = "--install-update"
    static func register(_ app: URL) throws {
        let extensionURL = app.appendingPathComponent("Contents/PlugIns/CodexT3Widget.appex")
        let ls = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
        try UpdatePackage.tool(ls, ["-f", "-R", app.path])
        try UpdatePackage.tool("/usr/bin/pluginkit", ["-a", extensionURL.path])
    }
    static func replace(_ source: URL, destination: URL, register: (URL) throws -> Void, launch: (URL) throws -> Void) throws {
        let file = FileManager.default
        let suffix = UUID().uuidString
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Codex-T3-update-\(suffix).app")
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".Codex-T3-backup-\(suffix).bundle-backup")
        guard file.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateFailure(message: "当前安装位置需要管理员权限，请从发布页面下载并手动替换。") }
        defer { try? file.removeItem(at: staging) }
        try file.copyItem(at: source, to: staging)
        _ = try UpdatePackage.codeInfo(staging)
        _ = try UpdatePackage.codeInfo(staging.appendingPathComponent("Contents/PlugIns/CodexT3Widget.appex"))
        try file.moveItem(at: destination, to: backup)
        do {
            try file.moveItem(at: staging, to: destination)
            try register(destination); try launch(destination)
            try? file.removeItem(at: backup)
        } catch {
            try? file.removeItem(at: destination)
            try file.moveItem(at: backup, to: destination)
            try? register(destination); try? launch(destination)
            throw error
        }
    }
    static func helper(_ manifest: URL) -> Int32 {
        var plan: InstallPlan?
        do {
            let candidate = try JSONDecoder().decode(InstallPlan.self, from: Data(contentsOf: manifest))
            guard getppid() == candidate.parentPID,
                  candidate.destination.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
                  candidate.source == candidate.archive.deletingLastPathComponent().appendingPathComponent("Extracted/Codex T3.app"),
                  manifest == candidate.archive.deletingLastPathComponent().appendingPathComponent("install.json") else { throw UpdateFailure(message: "更新安装请求无效。") }
            let version = try AppVersion(candidate.version)
            try UpdatePackage.verifyDigest(candidate.archive, expected: candidate.digest)
            try UpdatePackage.verifyApp(candidate.source, version: version, current: candidate.destination)
            plan = candidate
            print("READY"); fflush(stdout)
            let deadline = Date().addingTimeInterval(12)
            while kill(candidate.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            guard kill(candidate.parentPID, 0) != 0 else { throw UpdateFailure(message: "主程序未能退出，已取消更新。") }
            let widgetPath = candidate.destination.appendingPathComponent("Contents/PlugIns/CodexT3Widget.appex/Contents/MacOS/CodexT3Widget").path
            let processes = try UpdatePackage.tool("/bin/ps", ["-axo", "pid=,comm="])
            for line in (String(data: processes, encoding: .utf8) ?? "").split(separator: "\n") {
                let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if fields.count == 2, String(fields[1]).trimmingCharacters(in: .whitespaces) == widgetPath, let pid = Int32(fields[0]) { _ = kill(pid, SIGTERM) }
            }
            _ = try? UpdatePackage.tool("/usr/bin/pluginkit", ["-r", candidate.destination.appendingPathComponent("Contents/PlugIns/CodexT3Widget.appex").path])
            let defaults = UserDefaults(suiteName: LocalIdentity.hostID)!
            try replace(candidate.source, destination: candidate.destination, register: register, launch: { url in
                defaults.set("已更新到 %@。", forKey: "update.result")
                defaults.set([candidate.version], forKey: "update.resultArguments")
                defaults.removeObject(forKey: "update.resultPrefix")
                defaults.synchronize()
                try UpdatePackage.tool("/usr/bin/open", ["-n", url.path])
            })
            try? FileManager.default.removeItem(at: candidate.archive.deletingLastPathComponent())
            return 0
        } catch {
            if let plan {
                let defaults = UserDefaults(suiteName: LocalIdentity.hostID)!
                defaults.set((error as? UpdateFailure)?.message ?? error.localizedDescription, forKey: "update.result")
                defaults.set((error as? UpdateFailure)?.arguments ?? [], forKey: "update.resultArguments")
                defaults.set("更新未完成：", forKey: "update.resultPrefix"); defaults.synchronize()
                if kill(plan.parentPID, 0) != 0 { _ = try? UpdatePackage.tool("/usr/bin/open", ["-n", plan.destination.path]) }
            }
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

final class UpdateController: ObservableObject {
    enum Phase { case idle, checking, downloading, preparing, ready, installing }
    @Published private(set) var phase = Phase.idle
    let repository: GitHubRepository?
    @Published private var messageKey = "检测是否有新的版本。"
    private var messageArguments: [String] = []
    private var messageError: Error?
    var message: String {
        let error = (messageError as? UpdateFailure)?.errorDescription ?? messageError?.localizedDescription ?? ""
        return Localization.text(messageKey, arguments: messageArguments.map { $0 as CVarArg }) + error
    }
    private func showMessage(_ key: String, _ arguments: String...) {
        messageArguments = arguments; messageError = nil; messageKey = key
    }
    private func showError(_ error: Error, prefix: String = "") {
        messageArguments = []; messageError = error; messageKey = prefix
    }
    @Published private(set) var release: AppRelease?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var progress: Double?
    let hasInstallationResult: Bool
    let currentVersion: String
    let buildNumber: String
    private let defaults: UserDefaults
    private let currentApp: URL
    private let network: UpdateNetwork
    private var task: URLSessionTask?
    private var prepared: URL?
    private var ownedArchive: URL?
    private var verifiedDigest: String?
    private var generation = UUID()
    var busy: Bool { phase == .checking || phase == .downloading || phase == .preparing || phase == .installing }
    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, network: UpdateNetwork = UpdateNetwork()) {
        self.defaults = defaults; currentApp = bundle.bundleURL
        self.network = network
        currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("开发版本")
        buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let configured = bundle.infoDictionary?["CodexT3RepositoryURL"] as? String ?? ""
        repository = try? GitHubRepository(configured)
        let savedRepository = defaults.string(forKey: "update.repository")
        defaults.removeObject(forKey: "update.repository")
        if let savedRepository, (try? GitHubRepository(savedRepository)) != repository {
            defaults.removeObject(forKey: "update.lastChecked")
        }
        hasInstallationResult = defaults.string(forKey: "update.result") != nil
        lastChecked = defaults.object(forKey: "update.lastChecked") as? Date
        if let result = defaults.string(forKey: "update.result") {
            let arguments = defaults.stringArray(forKey: "update.resultArguments") ?? []
            if let prefix = defaults.string(forKey: "update.resultPrefix") {
                showError(UpdateFailure(message: result, arguments: arguments), prefix: prefix)
            } else { messageArguments = arguments; messageKey = result }
            for key in ["update.result", "update.resultArguments", "update.resultPrefix"] { defaults.removeObject(forKey: key) }
        }
        else if repository == nil { showMessage("此构建尚未配置更新来源。") }
    }
    func check() {
        guard !busy else { return }
        guard let repository else { showMessage("此构建尚未配置更新来源。"); return }
        guard (try? AppVersion(currentVersion)) != nil else { showMessage("开发版本不参与在线更新。"); return }
        clearDownload(); release = nil; phase = .checking; showMessage("正在检测更新…")
        let token = UUID(); generation = token
        requestRelease(repository, token: token, manifest: true)
    }
    private func requestRelease(_ repository: GitHubRepository, token: UUID, manifest: Bool) {
        // Release assets use GitHub's download service rather than the shared
        // unauthenticated REST API allowance. Keep older releases/forks usable.
        task = network.data(manifest ? repository.latestManifest : repository.latestAPI) { [weak self] result in
            let decoded = result.flatMap { data -> Result<AppRelease, Error> in Result {
                if manifest { return try AppRelease.decodeManifest(data, repository: repository, architecture: UpdatePackage.architecture) }
                return try AppRelease.decode(data, repository: repository, architecture: UpdatePackage.architecture)
            } }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if manifest, case .failure = decoded {
                    self.requestRelease(repository, token: token, manifest: false)
                    return
                }
                self.task = nil; self.phase = .idle
                switch decoded {
                case .success(let latest):
                    self.lastChecked = Date(); self.defaults.set(self.lastChecked, forKey: "update.lastChecked")
                    if let current = try? AppVersion(self.currentVersion), latest.version > current {
                        self.release = latest
                        self.showMessage(latest.asset == nil ? "发现 %@，该版本暂未提供适用的应用包。" : "发现新版本 %@。", latest.version.text)
                    } else { self.showMessage("当前已是最新版本。") }
                case .failure(let error): self.showError(error, prefix: "检测失败：")
                }
            }
        }
    }
    func download() {
        guard !busy, let release, let asset = release.asset else { return }
        phase = .downloading; progress = nil; showMessage("正在下载 %@…", String(release.version.text))
        let token = UUID(); generation = token
        func begin(_ digest: String) {
            task = network.download(asset.browserDownloadURL, progress: { [weak self] value in
                DispatchQueue.main.async { if self?.generation == token { self?.progress = value } }
            }, completion: { [weak self] result in
                switch result {
                case .failure(let error): DispatchQueue.main.async { self?.failed(error, token: token) }
                case .success(let archive):
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()); return }
                        self.ownedArchive = archive; self.verifiedDigest = digest; self.phase = .preparing; self.showMessage("正在校验更新包…")
                        DispatchQueue.global(qos: .utility).async {
                            let prepared = Result { try UpdatePackage.prepare(archive, digest: digest, version: release.version, current: self.currentApp) }
                            DispatchQueue.main.async {
                                guard self.generation == token else { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()); return }
                                self.task = nil
                                switch prepared {
                                case .success(let app): self.prepared = app; self.phase = .ready; self.showMessage("更新包已验证，可以安装并重启。")
                                case .failure(let error): self.failed(error, token: token)
                                }
                            }
                        }
                    }
                }
            })
        }
        if let digest = release.embeddedDigest { begin(digest) }
        else if let checksum = release.checksum {
            task = network.data(checksum.browserDownloadURL) { [weak self] result in
                let checked = result.flatMap { data in Result { try UpdatePackage.checksum(data, filename: asset.name) } }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    switch checked { case .success(let digest): begin(digest); case .failure(let error): self.failed(error, token: token) }
                }
            }
        } else { failed(UpdateFailure(message: "该版本缺少 SHA-256 校验信息，请通过发布页面手动下载。"), token: token) }
    }
    private func failed(_ error: Error, token: UUID) {
        guard generation == token else { return }; task = nil; phase = .idle; showError(error); clearDownload()
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; phase = .idle; progress = nil; showMessage("已取消更新。"); clearDownload() }
    private func clearDownload() {
        if let archive = ownedArchive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        ownedArchive = nil; prepared = nil; verifiedDigest = nil
    }
    func install() {
        guard phase == .ready, let prepared, let archive = ownedArchive, let digest = verifiedDigest, let release else { return }
        guard currentApp.pathExtension == "app", FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
            showMessage("当前安装位置无法写入，请从发布页面下载后手动替换。"); return
        }
        do {
            let manifest = archive.deletingLastPathComponent().appendingPathComponent("install.json")
            let plan = InstallPlan(source: prepared, destination: currentApp, archive: archive, digest: digest, version: release.version.text, parentPID: getpid())
            try JSONEncoder().encode(plan).write(to: manifest, options: .atomic)
            let helper = Process(); helper.executableURL = Bundle.main.executableURL; helper.arguments = [UpdateInstaller.flag, manifest.path]
            let pipe = Pipe(); helper.standardOutput = pipe; helper.standardError = FileHandle.nullDevice
            try helper.run(); phase = .installing; showMessage("正在安装，应用即将重启…")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var data = Data()
                while data.count < 1024, let byte = try? pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                    data.append(byte)
                    if byte[0] == 10 { break }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if String(data: data, encoding: .utf8)?.hasPrefix("READY") == true { self.ownedArchive = nil; NSApp.terminate(nil) }
                    else { self.phase = .ready; self.showMessage("无法启动更新安装，请通过发布页面手动安装。") }
                }
            }
        } catch { phase = .ready; showError(error) }
    }
    func openRelease() { if let url = release?.page ?? repository?.releasesURL { NSWorkspace.shared.open(url) } }
    func openFeedback() { if let url = repository?.feedbackURL { NSWorkspace.shared.open(url) } }
    func stop() { generation = UUID(); task?.cancel(); network.stop(); if phase != .installing { clearDownload() } }
}
