import Foundation
import os

/// The two updatable rule catalogs, treated uniformly so all
/// version/store logic is written once.
enum CatalogKind: String, CaseIterable {
    case cleanRules
    case appLeftovers

    /// Base filename (no extension) shared by the bundled resource, the
    /// cached copy, and the manifest key.
    var resourceName: String {
        switch self {
        case .cleanRules:   return "CleanRules"
        case .appLeftovers: return "AppLeftovers"
        }
    }

    /// The single `schemaVersion` this build knows how to decode. A cached
    /// or downloaded catalog with any other schema is never loaded.
    var supportedSchemaVersion: Int {
        switch self {
        case .cleanRules:   return 1
        case .appLeftovers: return 2
        }
    }
}

/// The two integers at the top of every catalog JSON. Decoded cheaply
/// (ignoring the rest of the file) to compare versions without paying to
/// parse the whole catalog.
struct CatalogVersionHeader: Decodable {
    let schemaVersion: Int
    let catalogVersion: Int?
}

/// Owns the on-disk catalog cache and decides, for each catalog, whether
/// the app should load the bundled resource or a downloaded copy.
///
/// This is the single integration point: `CleanViewModel` and `AppScanner`
/// call `url(for:)` instead of `Bundle.main.url(...)`. Everything else
/// (the network updater) writes through `install(_:for:)`.
final class CatalogStore {

    static let shared = CatalogStore()

    private static let logger = Logger(subsystem: "fun.burrow", category: "CatalogStore")

    /// `~/Library/Application Support/Burrow/Catalogs` in production.
    let catalogsDirectory: URL

    /// Resolves the bundled resource URL for a catalog. Injectable so tests
    /// can point at a fixture instead of `Bundle.main`.
    private let bundleURLResolver: (CatalogKind) -> URL?

    init(
        catalogsDirectory: URL = CatalogStore.defaultDirectory,
        bundleURLResolver: @escaping (CatalogKind) -> URL? = { kind in
            Bundle.main.url(forResource: kind.resourceName, withExtension: "json")
        }
    ) {
        self.catalogsDirectory = catalogsDirectory
        self.bundleURLResolver = bundleURLResolver
    }

    /// `~/Library/Application Support/Burrow/Catalogs`. Uses
    /// `NSHomeDirectory()` — never hardcodes a user name (mirrors
    /// `OperationLog.defaultLogsDirectory`).
    static var defaultDirectory: URL {
        let home = NSHomeDirectory() as NSString
        return URL(fileURLWithPath: home.appendingPathComponent("Library/Application Support/Burrow/Catalogs"))
    }

    // MARK: - URLs

    func bundleURL(for kind: CatalogKind) -> URL? {
        bundleURLResolver(kind)
    }

    func cachedURL(for kind: CatalogKind) -> URL {
        catalogsDirectory.appendingPathComponent("\(kind.resourceName).json")
    }

    /// The URL the app should load: the cached copy when it exists, decodes,
    /// matches the supported schema, and is at least as new as the bundled
    /// copy; otherwise the bundled resource. On any doubt, the bundle wins —
    /// so the app is never left without a working catalog.
    func url(for kind: CatalogKind) -> URL {
        let bundled = bundleURL(for: kind)

        if let cached = installedVersion(for: kind),
           cached.schemaVersion == kind.supportedSchemaVersion {
            let cachedCatalog = cached.catalogVersion ?? 0
            if let bundledHeader = bundledVersion(for: kind) {
                // Strictly newer only — on a tie the bundle wins, so a fresh
                // app install shipping the same-or-newer catalog supersedes a
                // stale cache.
                if cached.schemaVersion == bundledHeader.schemaVersion,
                   cachedCatalog > (bundledHeader.catalogVersion ?? 0) {
                    return cachedURL(for: kind)
                }
            } else {
                // No bundled resource at all (unexpected) — the schema-valid
                // cache is the best we have.
                return cachedURL(for: kind)
            }
        }

        return bundled ?? cachedURL(for: kind)
    }

    // MARK: - Versions

    func bundledVersion(for kind: CatalogKind) -> CatalogVersionHeader? {
        guard let url = bundleURL(for: kind) else { return nil }
        return Self.readHeader(at: url)
    }

    /// Version of the cached copy, or nil if it's missing or unreadable.
    func installedVersion(for kind: CatalogKind) -> CatalogVersionHeader? {
        let url = cachedURL(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Self.readHeader(at: url)
    }

    /// The content version currently in effect — the greater of the bundled
    /// version and the usable cached version. The updater downloads only
    /// when the manifest advertises something strictly greater than this.
    func effectiveVersion(for kind: CatalogKind) -> Int {
        var best = bundledVersion(for: kind)?.catalogVersion ?? 0
        if let cached = installedVersion(for: kind),
           cached.schemaVersion == kind.supportedSchemaVersion {
            best = max(best, cached.catalogVersion ?? 0)
        }
        return best
    }

    private static func readHeader(at url: URL) -> CatalogVersionHeader? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CatalogVersionHeader.self, from: data)
    }

    // MARK: - Install

    /// Atomically writes a downloaded catalog into the cache. Creates the
    /// directory on first use. `.atomic` writes to a sibling temp file and
    /// renames, so a concurrent reader never sees a half-written file.
    func install(_ data: Data, for kind: CatalogKind) throws {
        try FileManager.default.createDirectory(
            at: catalogsDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: cachedURL(for: kind), options: .atomic)
        Self.logger.info("Installed \(kind.resourceName, privacy: .public) catalog to cache")
    }

    /// Removes the cached copy, reverting to the bundled catalog. Used by
    /// tests and any future "reset rules" affordance.
    func clearCache(for kind: CatalogKind) throws {
        let url = cachedURL(for: kind)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
