/// Release version of kittymgr, reported by `kittymgr --version`.
///
/// Single source of truth for the version string: the CLI, docs, and release tag
/// all reference this constant. Bump it together with a new `vX.Y.Z` tag.
public enum Kittymgr {
    public static let version = "1.1.1"
}
