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
        let metadata = profileStore.metadata(for: profile)
        let layers = try IncludeBuilder.layers(
            profile: profile,
            profileStore: profileStore,
            pluginStore: pluginStore,
            enabledPlugins: metadata.enabledPlugins
        )
        let conflicts = ConflictDetector.detect(layers)
        let validation = validator.validate(content: IncludeBuilder.compose(layers))
        return SafetyReport(conflicts: conflicts, validation: validation)
    }
}
