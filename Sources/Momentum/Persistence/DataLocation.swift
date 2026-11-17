import AppKit
import Foundation

/// Where Momentum keeps everything: the database, plan documents (Plans/) and backups.
/// Chosen in Settings; stored in UserDefaults (it can't live in the database it locates).
/// MOMENTUM_STORE_DIR overrides it (scratch stores for testing).
enum DataLocation {
    private static let key = "dataDirectory"
    private static let pendingKey = "pendingDataDirectory"

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Momentum", directoryHint: .isDirectory)
    }

    static var isOverriddenByEnvironment: Bool { ProcessInfo.processInfo.environment["MOMENTUM_STORE_DIR"] != nil }

    static var current: URL {
        if let env = ProcessInfo.processInfo.environment["MOMENTUM_STORE_DIR"] { return URL(filePath: env, directoryHint: .isDirectory) }
        if let path = UserDefaults.standard.string(forKey: key) { return URL(filePath: path, directoryHint: .isDirectory) }
        return defaultDirectory
    }

    static var storeURL: URL { current.appending(path: "Momentum.store") }

    /// Ask to move to `folder` on the next launch (the database must be closed to move it safely).
    static func requestMove(to folder: URL) {
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: pendingKey)
    }

    static func hasExistingData(at folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "Momentum.store").path(percentEncoded: false))
    }

    /// Runs at launch, before the database opens. Moves everything from the current folder to the
    /// requested one — unless that folder already has Momentum data, in which case it's used as-is
    /// and the old folder is left untouched. Never deletes anything. Returns a message for the user.
    static func applyPendingMove() -> String? {
        let defaults = UserDefaults.standard
        guard !isOverriddenByEnvironment, let path = defaults.string(forKey: pendingKey) else { return nil }
        defaults.removeObject(forKey: pendingKey)
        let fm = FileManager.default
        let from = current.standardizedFileURL
        let to = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        guard from != to else { return nil }
        do {
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            if hasExistingData(at: to) {
                setCurrent(to)
                return "Now using the Momentum data that was already in \(to.path(percentEncoded: false)). Your previous data is still in \(from.path(percentEncoded: false))."
            }
            let items = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let dest = to.appending(path: item.lastPathComponent)
                guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }
                try fm.moveItem(at: item, to: dest)
            }
            setCurrent(to)
            return "Moved your Momentum data to \(to.path(percentEncoded: false))."
        } catch {
            return "Couldn't move your data (\(error.localizedDescription)). Still using \(from.path(percentEncoded: false))."
        }
    }

    private static func setCurrent(_ url: URL) {
        if url.standardizedFileURL == defaultDirectory.standardizedFileURL {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(url.path(percentEncoded: false), forKey: key)
        }
    }

    /// Restart so the move happens with the database closed.
    @MainActor
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            let task = Process()
            task.executableURL = URL(filePath: "/bin/sh")
            // Wait for this instance to quit, then open the app again.
            task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(bundle.path(percentEncoded: false))\""]
            try? task.run()
        }
        NSApp.terminate(nil)
    }
}
