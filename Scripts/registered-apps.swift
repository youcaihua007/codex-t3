import AppKit
import Foundation

// Use the application's public registry, not only the extension registry.
let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "local.codext3.quota")
let data = try JSONEncoder().encode(urls.map(\.path))
print(String(decoding: data, as: UTF8.self))
