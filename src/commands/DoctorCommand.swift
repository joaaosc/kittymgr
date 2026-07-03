import Foundation

/// Severity of a single `doctor` check.
public enum DoctorStatus: String, Sendable, Equatable {
    case ok = "OK"
    case warn = "WARN"
    case fail = "FAIL"
}

/// One line of the `doctor` report.
public struct DoctorFinding: Sendable, Equatable {
    public let status: DoctorStatus
    public let name: String
    public let detail: String

    public init(_ status: DoctorStatus, _ name: String, _ detail: String) {
        self.status = status
        self.name = name
        self.detail = detail
    }
}

/// Non-mutating probes of external tools. Injectable so `doctor` is testable
/// without kitty or git installed and without touching a live kitty.
public protocol EnvironmentProbing: Sendable {
    /// Whether an executable named `tool` is resolvable on `PATH`.
    func toolAvailable(_ tool: String) -> Bool
    /// Whether kitty remote control answers a read-only query (`kitten @ ls`).
    func remoteControlResponds() -> Bool
}

/// Default probe: a pure `PATH` scan for tools (no subprocess) and a read-only
/// `kitten @ ls` / `kitty @ ls` for remote control.
public struct SystemEnvironmentProbe: EnvironmentProbing {
    public init() {}

    public func toolAvailable(_ tool: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let fm = FileManager.default
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate.path) { return true }
        }
        return false
    }

    public func remoteControlResponds() -> Bool {
        for tool in ["kitten", "kitty"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool, "@", "ls"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }
}

/// `doctor`: report on the health of the environment and the managed store,
/// independent of any single profile's config validity (`check` covers that).
///
/// Optional environment pieces (kitty, git, remote control) are `WARN` when absent
/// — kittymgr still works offline. Corruption in the managed store (a snapshot
/// missing its backing object) is `FAIL`. `run` returns `true` only when there is
/// no `FAIL`, which the CLI maps to a non-zero exit.
public struct DoctorCommand {
    public let configDir: ConfigDir
    public let probe: any EnvironmentProbing

    public init(configDir: ConfigDir, probe: any EnvironmentProbing = SystemEnvironmentProbe()) {
        self.configDir = configDir
        self.probe = probe
    }

    /// Runs every check, prints the report, and returns `true` when nothing failed.
    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) -> Bool {
        let findings = environmentFindings() + managedLayerFindings() + integrityFindings()

        for finding in findings {
            log("[\(finding.status.rawValue)] \(finding.name): \(finding.detail)")
        }
        let fails = findings.filter { $0.status == .fail }.count
        let warns = findings.filter { $0.status == .warn }.count
        log("")
        log("doctor: \(findings.count - fails - warns) ok, \(warns) warning(s), \(fails) failure(s).")
        return fails == 0
    }

    // MARK: Checks

    private func environmentFindings() -> [DoctorFinding] {
        [
            probe.toolAvailable("kitty")
                ? DoctorFinding(.ok, "kitty", "found on PATH")
                : DoctorFinding(.warn, "kitty", "not found on PATH; config validation and live reload are skipped"),
            probe.toolAvailable("git")
                ? DoctorFinding(.ok, "git", "found on PATH")
                : DoctorFinding(.warn, "git", "not found on PATH; git sources cannot be fetched"),
            probe.remoteControlResponds()
                ? DoctorFinding(.ok, "remote control", "kitty responds; live reload available")
                : DoctorFinding(.warn, "remote control", "no response; switch/sync persist but reload is manual (needs a running kitty with allow_remote_control)"),
        ]
    }

    private func managedLayerFindings() -> [DoctorFinding] {
        let fm = FileManager.default
        let layout = configDir.detectedLayout(fileManager: fm)
        var out = [configDirectoryWritableFinding(fileManager: fm)]
        switch layout {
        case .absent:
            out.append(DoctorFinding(.warn, "layout", "not initialized; run `kittymgr init`"))
            return out
        case .legacy:
            out.append(
                DoctorFinding(
                    .warn,
                    "layout",
                    "legacy layout at managed/; run `kittymgr init` to migrate to kittymgr/"
                )
            )
            return out
        case .mixed(let detail):
            out.append(
                DoctorFinding(
                    .fail,
                    "layout",
                    "mixed layout detected (\(detail)); repair manually, then run `kittymgr init`"
                )
            )
            return out
        case .current:
            break
        }
        out.append(DoctorFinding(.ok, "layout", "new layout at \(configDir.relativePath(of: configDir.managedDir))/"))
        out.append(DoctorFinding(.ok, "managed layer", "present at \(configDir.relativePath(of: configDir.managedDir))"))
        out.append(kittyConfLinkFinding(fileManager: fm))

        if let content = try? String(contentsOf: configDir.kittyConf, encoding: .utf8) {
            out.append(anchorFinding(for: content))
        } else {
            out.append(DoctorFinding(.warn, "kitty.conf block", "kitty.conf not found; run `kittymgr init`"))
        }
        return out
    }

    private func integrityFindings() -> [DoctorFinding] {
        var out: [DoctorFinding] = []

        let fm = FileManager.default
        if fm.fileExists(atPath: configDir.legacyLockFile.path) {
            out.append(DoctorFinding(.fail, "lockfile", "orphan root lockfile at kittymgr.lock; move it to kittymgr/kittymgr.lock or remove it"))
        } else if fm.fileExists(atPath: configDir.lockFile.path) {
            let lock = Lockfile.load(configDir.lockFile)
            out.append(DoctorFinding(.ok, "lockfile", "\(lock.sources.count) pinned source(s)"))
        } else {
            out.append(DoctorFinding(.ok, "lockfile", "not present"))
        }

        let store = SnapshotStore(configDir: configDir)
        let snapshots = store.list()
        if !snapshots.isEmpty {
            let missing = store.missingObjects()
            out.append(missing.isEmpty
                ? DoctorFinding(.ok, "backups", "\(snapshots.count) snapshot(s), all objects present")
                : DoctorFinding(.fail, "backups", "\(missing.count) snapshot object(s) missing from the store"))
        }
        return out
    }

    private func configDirectoryWritableFinding(fileManager fm: FileManager) -> DoctorFinding {
        if fm.fileExists(atPath: configDir.url.path) {
            return fm.isWritableFile(atPath: configDir.url.path)
                ? DoctorFinding(.ok, "config dir", "writable at \(configDir.url.path)")
                : DoctorFinding(.fail, "config dir", "not writable at \(configDir.url.path)")
        }

        let parent = configDir.url.deletingLastPathComponent()
        return fm.isWritableFile(atPath: parent.path)
            ? DoctorFinding(.ok, "config dir", "missing; parent is writable")
            : DoctorFinding(.fail, "config dir", "missing and parent is not writable")
    }

    private func kittyConfLinkFinding(fileManager fm: FileManager) -> DoctorFinding {
        if let destination = try? fm.destinationOfSymbolicLink(atPath: configDir.kittyConf.path) {
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : configDir.kittyConf.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
            return DoctorFinding(.ok, "kitty.conf", "symlink -> \(target.path) (preserved by writes)")
        }
        return DoctorFinding(.ok, "kitty.conf", "regular file")
    }

    private func anchorFinding(for content: String) -> DoctorFinding {
        do {
            switch try Guard.state(of: content) {
            case .current:
                return DoctorFinding(.ok, "kitty.conf block", "managed include block present")
            case .legacy:
                return DoctorFinding(.fail, "kitty.conf block", "legacy include points at managed/active.conf; run `kittymgr init`")
            case .absent:
                return DoctorFinding(.warn, "kitty.conf block", "managed block missing while kittymgr/ is present; run `kittymgr init`")
            }
        } catch let error as SafetyError {
            return DoctorFinding(.fail, "kitty.conf block", error.description)
        } catch {
            return DoctorFinding(.fail, "kitty.conf block", "\(error)")
        }
    }
}
