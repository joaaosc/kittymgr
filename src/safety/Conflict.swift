import Foundation

/// One source `.conf` snippet contributing to the composed configuration, with a
/// human-readable label (its managed-relative path).
public struct ConfigLayer: Equatable, Sendable {
    public let label: String
    public let content: String

    public init(label: String, content: String) {
        self.label = label
        self.content = content
    }
}

/// A detected conflict across managed layers. Conflicts are advisory warnings:
/// they describe what shadows what, but only the user's intent (via `--force`)
/// decides whether to proceed.
public enum Conflict: Equatable, Sendable {
    /// The same key chord is bound in more than one layer.
    case duplicateKeymap(chord: String, sources: [String])
    /// The same option is set in more than one layer; the last one takes effect.
    case shadowedOption(name: String, sources: [String], effectiveSource: String, effectiveValue: String)

    public var message: String {
        switch self {
        case let .duplicateKeymap(chord, sources):
            return "key '\(chord)' is bound in multiple layers: \(sources.joined(separator: ", ")) (last wins)"
        case let .shadowedOption(name, sources, effectiveSource, effectiveValue):
            return "option '\(name)' is set in multiple layers: \(sources.joined(separator: ", ")); "
                + "effective value '\(effectiveValue)' from \(effectiveSource)"
        }
    }
}

/// Static analysis of the composed managed layers. Detects duplicate key bindings
/// and shadowed options across layers (profile base + enabled plugins). Pure, so
/// it is fully testable without kitty.
///
/// Parsing is intentionally lightweight: it recognizes `map` directives and
/// scalar options, ignores comments and `include`-family directives, and takes
/// the first non-flag token after `map` as the key chord.
public enum ConflictDetector {
    private static let includeDirectives: Set<String> = ["include", "globinclude", "envinclude", "geninclude"]

    public static func detect(_ layers: [ConfigLayer]) -> [Conflict] {
        var keymapSources: [String: [String]] = [:]
        var keymapOrder: [String] = []
        var optionGroups: [String: [(source: String, value: String)]] = [:]
        var optionOrder: [String] = []

        for layer in layers {
            for rawLine in layer.content.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let directive = tokens.first else { continue }
                if includeDirectives.contains(directive) { continue }

                if directive == "map" {
                    guard let chord = keyChord(tokens) else { continue }
                    if keymapSources[chord] == nil { keymapOrder.append(chord) }
                    keymapSources[chord, default: []].append(layer.label)
                } else {
                    let value = tokens.dropFirst().joined(separator: " ")
                    if optionGroups[directive] == nil { optionOrder.append(directive) }
                    optionGroups[directive, default: []].append((layer.label, value))
                }
            }
        }

        var conflicts: [Conflict] = []
        for chord in keymapOrder {
            let sources = keymapSources[chord] ?? []
            if sources.count >= 2 {
                conflicts.append(.duplicateKeymap(chord: chord, sources: sources))
            }
        }
        for name in optionOrder {
            let occurrences = optionGroups[name] ?? []
            if Set(occurrences.map(\.source)).count >= 2, let effective = occurrences.last {
                conflicts.append(.shadowedOption(
                    name: name,
                    sources: occurrences.map(\.source),
                    effectiveSource: effective.source,
                    effectiveValue: effective.value
                ))
            }
        }
        return conflicts
    }

    private static func keyChord(_ tokens: [String]) -> String? {
        for token in tokens.dropFirst() where !token.hasPrefix("-") {
            return token
        }
        return nil
    }
}
