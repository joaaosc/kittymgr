import Foundation

/// `check <profile>`: report conflicts and validation status without switching.
///
/// Conflicts are advisory warnings (exit 0). An invalid composed configuration is
/// an error (the command reports `passed == false`, which the CLI maps to a
/// non-zero exit).
public struct CheckCommand {
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let rawName: String
    public let validator: any ConfigValidating

    public init(
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        rawName: String,
        validator: any ConfigValidating = KittyConfigValidator()
    ) {
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.rawName = rawName
        self.validator = validator
    }

    /// Returns `true` when the composed configuration is valid (warnings allowed).
    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) throws -> Bool {
        let name = try ProfileName(validating: rawName)
        guard profileStore.exists(name) else {
            throw ProfileError.notFound(name.value)
        }

        let report = try SafetyGate.evaluate(
            profile: name,
            profileStore: profileStore,
            pluginStore: pluginStore,
            validator: validator
        )

        if report.conflicts.isEmpty {
            log("\(name.value): no conflicts.")
        } else {
            for conflict in report.conflicts {
                log("warning: \(conflict.message)")
            }
        }

        switch report.validation {
        case .valid:
            log("\(name.value): configuration valid.")
            return true
        case let .skipped(reason):
            log("\(name.value): validation skipped (\(reason)).")
            return true
        case let .invalid(diagnostics):
            log("error: \(name.value) has an invalid configuration:")
            log(diagnostics)
            return false
        }
    }
}
