import AppKit
import Foundation

/// Plain Markdown files on disk, one folder per activity:
/// `~/Library/Application Support/Momentum/Plans/<activity id>/*.md` (or under MOMENTUM_STORE_DIR).
/// Real files, so you can also open them in any editor or back them up.
enum PlansStore {
    struct File: Identifiable, Hashable {
        var url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        var modified: Date
    }

    static var root: URL {
        DataLocation.current.appending(path: "Plans", directoryHint: .isDirectory)
    }

    static func folder(for activityID: UUID) -> URL {
        root.appending(path: activityID.uuidString, directoryHint: .isDirectory)
    }

    static func files(for activityID: UUID) -> [File] {
        let dir = folder(for: activityID)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
            .map { File(url: $0, modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func count(for activityID: UUID) -> Int { files(for: activityID).count }

    /// Creates "<name>.md" (or "<name> 2.md"…) and returns it.
    @discardableResult
    static func create(in activityID: UUID, name: String, contents: String) throws -> File {
        let dir = folder(for: activityID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = sanitize(name).isEmpty ? "Untitled" : sanitize(name)
        var url = dir.appending(path: "\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path()) {
            url = dir.appending(path: "\(base) \(n).md"); n += 1
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return File(url: url, modified: .now)
    }

    static func read(_ file: File) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    static func write(_ text: String, to file: File) {
        try? text.write(to: file.url, atomically: true, encoding: .utf8)
    }

    static func rename(_ file: File, to name: String) -> File? {
        let clean = sanitize(name)
        guard !clean.isEmpty else { return nil }
        let target = file.url.deletingLastPathComponent().appending(path: "\(clean).\(file.url.pathExtension)")
        guard target != file.url, !FileManager.default.fileExists(atPath: target.path()) else { return nil }
        do { try FileManager.default.moveItem(at: file.url, to: target) } catch { return nil }
        return File(url: target, modified: .now)
    }

    /// Moves to the Trash (recoverable), never a hard delete.
    static func trash(_ file: File) {
        try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
    }

    static func reveal(_ activityID: UUID) {
        let dir = folder(for: activityID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    static func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
