import Foundation

public enum ManifestError: Error, CustomStringConvertible, Equatable {
    case alreadyExists
    case missing
    case sourceNotFound(String)

    public var description: String {
        switch self {
        case .alreadyExists: return "kittymgr.toml already exists; pass --force to overwrite"
        case .missing: return "no kittymgr.toml; run `kittymgr manifest init` first"
        case let .sourceNotFound(name): return "source '\(name)' not found in the manifest"
        }
    }
}

/// `manifest init | show` and `source add | list | remove`: author and inspect the
/// declarative `kittymgr.toml`. The manifest is opt-in — `init` bootstraps it from
/// the current on-disk state; `sync` (separate command) applies it back.
public struct ManifestCommand {
    public enum Action: Equatable {
        case initialize(force: Bool)
        case show
        case sourceAdd(SourceSpec)
        case sourceList
        case sourceRemove(String)
    }

    public let action: Action
    public let configDir: ConfigDir
    public let dryRun: Bool

    public init(action: Action, configDir: ConfigDir, dryRun: Bool = false) {
        self.action = action
        self.configDir = configDir
        self.dryRun = dryRun
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        switch action {
        case let .initialize(force):
            try initialize(force: force, log: log)
        case .show:
            log(try currentOrBootstrap().serialize())
        case let .sourceAdd(spec):
            try mutate(log: log, describe: "Added source '\(spec.name)'.") { manifest in
                manifest.sources.removeAll { $0.name == spec.name }
                manifest.sources.append(spec)
            }
        case .sourceList:
            listSources(log: log)
        case let .sourceRemove(name):
            try mutate(log: log, describe: "Removed source '\(name)'.") { manifest in
                let before = manifest.sources.count
                manifest.sources.removeAll { $0.name == name }
                guard manifest.sources.count < before else { throw ManifestError.sourceNotFound(name) }
            }
        }
    }

    private func initialize(force: Bool, log: (String) -> Void) throws {
        let exists = FileManager.default.fileExists(atPath: configDir.manifestFile.path)
        guard !exists || force else { throw ManifestError.alreadyExists }
        let manifest = try Manifest.fromDisk(configDir)
        if dryRun {
            log("[dry-run] Would write \(configDir.manifestFile.lastPathComponent):\n" + manifest.serialize())
            return
        }
        try manifest.write(to: configDir.manifestFile)
        log("Wrote \(configDir.manifestFile.lastPathComponent).")
    }

    private func listSources(log: (String) -> Void) {
        let manifest = (try? currentOrBootstrap()) ?? Manifest()
        guard !manifest.sources.isEmpty else { log("No sources."); return }
        for source in manifest.sources {
            let location = source.git ?? source.url ?? "-"
            let ref = source.ref.map { " @\($0)" } ?? ""
            log("\(source.name)\t\(location)\(ref)")
        }
    }

    private func mutate(log: (String) -> Void, describe: String, _ change: (inout Manifest) throws -> Void) throws {
        var manifest = try currentOrBootstrap()
        try change(&manifest)
        if dryRun { log("[dry-run] \(describe)"); return }
        try manifest.write(to: configDir.manifestFile)
        log(describe)
    }

    private func currentOrBootstrap() throws -> Manifest {
        try Manifest.load(configDir.manifestFile) ?? Manifest.fromDisk(configDir)
    }
}
