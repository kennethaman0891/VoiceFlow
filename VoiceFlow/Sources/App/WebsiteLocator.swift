//
//  WebsiteLocator.swift
//  VoiceFlow
//
//  Resolves Website/index.html without ever hardcoding an absolute user path.
//  Resolution order:
//    1) Bundle resource in the "Website" subdirectory (shipped folder reference)
//    2) Flat bundle copy fallback
//    3) Debug-only: walk up from this source file to the project root and look
//       for <root>/Website/index.html (dev builds straight from Xcode)
//  A nil result tells callers to hide/disable website actions instead of crashing.
//

import Foundation

enum WebsiteLocator {
    /// Resolved once per launch. `nil` = website assets not found.
    static let indexURL: URL? = locate()

    /// Folder containing index.html (for "reveal in Finder").
    static var folderURL: URL? { indexURL?.deletingLastPathComponent() }

    private static func locate() -> URL? {
        let fileManager = FileManager.default

        // 1) Shipped as a folder reference: Website/index.html inside the bundle.
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Website"),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        // 2) Flat bundle copy fallback.
        if let flat = Bundle.main.url(forResource: "index", withExtension: "html"),
           fileManager.fileExists(atPath: flat.path) {
            return flat
        }

        // 3) Development fallback (Debug only — release builds rely on the bundle).
        #if DEBUG
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Website/index.html")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            guard dir.path != "/" else { break }
            dir.deleteLastPathComponent()
        }
        #endif

        return nil
    }
}
