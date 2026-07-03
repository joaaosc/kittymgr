import Foundation

/// Combined safety assessment of a profile's composed configuration.
public struct SafetyReport: Sendable {
    public let conflicts: [Conflict]
    public let validation: ValidationResult
}

/// Builds the composed layers for a profile and runs conflict detection plus
/// parser validation. Shared by `check` (report only) and `switch` (gate
/// activation) so both behave identically.
public enum SafetyGate {
    public static func evaluate(
        profile: ProfileName,
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        validator: any ConfigValidating
    ) throws -> SafetyReport {
        // `profileStore.root` is `<configDir>/kittymgr/profiles`; recover the config
        // root so composition can see the active modular blocks.
        let configDir = ConfigDir(url: profileStore.root.deletingLastPathComponent().deletingLastPathComponent())
        let composed = try ProfileComposer.compose(
            profile: profile,
            configDir: configDir,
            profileStore: profileStore,
            pluginStore: pluginStore
        )
        return SafetyReport(
            conflicts: composed.conflicts,
            validation: validator.validate(content: composed.validationContent)
        )
    }
}
