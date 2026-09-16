import CryptoKit
import Foundation
import os

/// Best-effort updater that keeps the rule catalogs current between app
/// releases. Fetches a manifest, and for each catalog that advertises a
/// newer version, downloads it, verifies its sha256, decode-validates it,
/// and installs it into `CatalogStore`. Any failure is swallowed — the app
/// keeps using whatever catalog it already had.
///
/// Layered safety: HTTPS from the maintainer's own repo → sha256 must match
/// the manifest → schemaVersion gate → the bytes must decode into the real
/// catalog type → and, at deletion time, `SafeFileOps.validate(_:)` still
/// blocks every protected path regardless of where a rule came from.
enum CatalogUpdater {

    private static let logger = Logger(subsystem: "fun.burrow", category: "CatalogUpdater")

    /// Raw manifest in the Burrow repo. Publishing new rules = committing an
    /// updated catalog + bumped manifest to `main` (see scripts/publish_catalogs.sh).
    static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/guide-vinh/Burrow/main/catalog-manifest.json"
    )!

    /// Same ephemeral, non-blocking style as `AppStoreLookup`.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    enum UpdateOutcome: Equatable {
        case upToDate
        case installed(Int)        // the new catalogVersion
        case skippedSchema         // remote schema this build can't read
        case failed(String)
    }

    enum ValidationError: Error, Equatable {
        case checksumMismatch
        case schemaMismatch
        case versionMismatch
        case malformed

        var message: String {
            switch self {
            case .checksumMismatch: return "sha256 did not match the manifest"
            case .schemaMismatch:   return "schemaVersion is not supported by this build"
            case .versionMismatch:  return "catalogVersion did not match the manifest"
            case .malformed:        return "catalog did not decode"
            }
        }
    }

    /// Checks every catalog and installs any that are newer. Returns a
    /// per-catalog outcome (empty if the manifest itself couldn't be fetched).
    @discardableResult
    static func checkForUpdates(
        store: CatalogStore = .shared,
        manifestURL: URL = CatalogUpdater.manifestURL
    ) async -> [CatalogKind: UpdateOutcome] {
        guard let manifest = await fetchManifest(from: manifestURL) else {
            logger.debug("No manifest — keeping existing catalogs")
            return [:]
        }
        var results: [CatalogKind: UpdateOutcome] = [:]
        for kind in CatalogKind.allCases {
            results[kind] = await update(kind, manifest: manifest, store: store)
        }
        return results
    }

    private static func fetchManifest(from url: URL) async -> CatalogManifest? {
        do {
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode(CatalogManifest.self, from: data)
        } catch {
            logger.debug("Manifest fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func update(
        _ kind: CatalogKind,
        manifest: CatalogManifest,
        store: CatalogStore
    ) async -> UpdateOutcome {
        guard let entry = manifest.entry(for: kind) else { return .upToDate }
        guard entry.schemaVersion == kind.supportedSchemaVersion else { return .skippedSchema }
        guard entry.catalogVersion > store.effectiveVersion(for: kind) else { return .upToDate }

        let data: Data
        do {
            (data, _) = try await session.data(from: entry.url)
        } catch {
            return .failed("download failed: \(error.localizedDescription)")
        }

        switch validate(data: data, against: entry, kind: kind) {
        case .failure(let error):
            logger.error("Rejected \(kind.resourceName, privacy: .public) update: \(error.message, privacy: .public)")
            return .failed(error.message)
        case .success:
            do {
                try store.install(data, for: kind)
                logger.info("Updated \(kind.resourceName, privacy: .public) to catalogVersion \(entry.catalogVersion, privacy: .public)")
                return .installed(entry.catalogVersion)
            } catch {
                return .failed("install failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pure verification core — no network, no disk. Unit-testable.
    static func validate(
        data: Data,
        against entry: CatalogManifest.Entry,
        kind: CatalogKind
    ) -> Result<Void, ValidationError> {
        // 1. Checksum must match the manifest exactly.
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == entry.sha256.lowercased() else { return .failure(.checksumMismatch) }

        // 2. Cheap header gate: schema must be one this build reads, and the
        //    file's own versions must agree with the manifest.
        guard let header = try? JSONDecoder().decode(CatalogVersionHeader.self, from: data) else {
            return .failure(.malformed)
        }
        guard header.schemaVersion == kind.supportedSchemaVersion,
              header.schemaVersion == entry.schemaVersion else {
            return .failure(.schemaMismatch)
        }
        guard (header.catalogVersion ?? -1) == entry.catalogVersion else {
            return .failure(.versionMismatch)
        }

        // 3. Full decode into the concrete catalog type — never install bytes
        //    that won't parse at load time.
        do {
            switch kind {
            case .cleanRules:   _ = try JSONDecoder().decode(CleanCatalog.self, from: data)
            case .appLeftovers: _ = try JSONDecoder().decode(AppLeftoversCatalog.self, from: data)
            }
        } catch {
            return .failure(.malformed)
        }

        return .success(())
    }
}
