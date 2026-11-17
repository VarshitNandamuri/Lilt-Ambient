import AppKit
import CoreGraphics
import os

/// Lock-screen lifecycle diagnostics. Never logs song titles, lyrics, tokens or audio samples.
///
/// Collect after a test:
///   cat ~/Library/Logs/Lilt/lockscreen.log
///   log show --last 15m --style compact --predicate 'subsystem == "com.nitrimandylis.lilt"'
enum LifecycleLog {
    private static let logger = Logger(subsystem: "com.nitrimandylis.lilt", category: "lockscreen")
    private static let queue = DispatchQueue(label: "lilt.lifecycle.log", qos: .utility)
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lilt/lockscreen.log")
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Self-tests must not pollute the user's log file.
    nonisolated(unsafe) static var writesFile = true

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        guard writesFile else { return }
        let date = Date()
        queue.async {
            let line = "\(stamp.string(from: date)) \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 2_000_000 {
                let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}

/// What the window server says about the login session (independent of notifications).
enum SessionState {
    struct Snapshot: CustomStringConvertible {
        var onConsole: Bool
        var screenLocked: Bool
        var description: String { "onConsole=\(onConsole) screenLocked=\(screenLocked)" }
    }

    static func current() -> Snapshot {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return Snapshot(onConsole: true, screenLocked: false)
        }
        return Snapshot(onConsole: (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? true,
                        screenLocked: (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false)
    }
}

enum WindowDiagnostics {
    /// Window-server view of one of our own windows (no Screen Recording permission needed).
    @MainActor
    static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "window=nil" }
        var parts = ["win#\(window.windowNumber)", "visible=\(window.isVisible)", "key=\(window.isKeyWindow)",
                     "level=\(window.level.rawValue)", "occluded=\(!window.occlusionState.contains(.visible))",
                     "ignoresMouse=\(window.ignoresMouseEvents)"]
        if window.windowNumber > 0,
           let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
                as? [[String: Any]])?.first {
            parts.append("ws.onscreen=\((info[kCGWindowIsOnscreen as String] as? Bool) ?? false)")
            parts.append("ws.layer=\((info[kCGWindowLayer as String] as? Int) ?? -1)")
        } else {
            parts.append("ws=absent")
        }
        if let spaces = ExperimentalLockScreenBridge.spaces(of: window) { parts.append("spaces=\(spaces)") }
        return parts.joined(separator: " ")
    }
}
