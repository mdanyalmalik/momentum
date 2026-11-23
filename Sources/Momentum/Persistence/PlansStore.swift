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
            .orderedBy(order(in: dir))
    }

    // MARK: Custom order
    // Kept in a hidden ".order.json" (file names) inside the activity's folder. Files missing from it
    // (new ones, or ones added in Finder) come after, alphabetically.

    private static func orderURL(_ dir: URL) -> URL { dir.appending(path: ".order.json") }

    private static func order(in dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: orderURL(dir)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func saveOrder(_ names: [String], in dir: URL) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: orderURL(dir), options: .atomic)
    }

    /// Saves the documents' order as shown after a drag.
    static func setOrder(_ files: [File], for activityID: UUID) {
        saveOrder(files.map(\.url.lastPathComponent), in: folder(for: activityID))
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
        let dir = file.url.deletingLastPathComponent()
        let names = order(in: dir)
        if names.contains(file.url.lastPathComponent) {
            saveOrder(names.map { $0 == file.url.lastPathComponent ? target.lastPathComponent : $0 }, in: dir)
        }
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

private extension Array where Element == PlansStore.File {
    /// Stable: files named in `names` first, in that order; the rest keep their current order after them.
    func orderedBy(_ names: [String]) -> [PlansStore.File] {
        guard !names.isEmpty else { return self }
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return enumerated().sorted { a, b in
            let ra = rank[a.element.url.lastPathComponent] ?? Int.max, rb = rank[b.element.url.lastPathComponent] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
