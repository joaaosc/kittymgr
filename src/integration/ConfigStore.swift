import Foundation

/// Persisted state that lets `uninstall` invert `init` exactly.
struct Meta: Sendable, Equatable {
    var createdConf: Bool
    var backup: String?

    func serialized() -> String {
        var lines = ["created_conf=\(createdConf)"]
        if let backup {
            lines.append("backup=\(backup)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> Meta {
        var createdConf = false
        var backup: String?
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "created_conf": createdConf = (parts[1] == "true")
            case "backup": backup = parts[1]
            default: break
            }
        }
        return Meta(createdConf: createdConf, backup: backup)
    }
}

/// File-system helpers shared by the commands: atomic writes, sidecar state, and
/// collision-safe timestamped backups.
enum ConfigStore {
    /// Atomic write (temp file + rename) to avoid leaving a partially written config.
    static func writeAtomically(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeMeta(_ meta: Meta, to url: URL) throws {
        try writeAtomically(meta.serialized(), to: url)
    }

    static func readMeta(from url: URL) -> Meta? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Meta.parse(text)
    }

    /// Copy `url` to `<name>.bak.<timestamp>` (with a counter on collision).
    @discardableResult
    static func makeBackup(of url: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak."
        let stamp = timestamp(now)
        var candidate = dir.appendingPathComponent(prefix + stamp)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(prefix + stamp + "-\(counter)")
            counter += 1
        }
        try fm.copyItem(at: url, to: candidate)
        return candidate
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
