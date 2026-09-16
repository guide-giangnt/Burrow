import Foundation
import os

/// Discovers large cache/log folders that no Clean rule covers yet, so users
/// can reclaim that space (and optionally suggest a rule for it) even before
/// the catalog is updated. Read-only — deletion still routes through
/// `SafeFileOps` via the AnalyzeViewModel.
///
/// Only "cleanable" roots are scanned (Caches, Logs) — regenerable data that
/// is safe to suggest clearing. App data (Application Support) is deliberately
/// excluded so this never nudges users to delete real documents.
enum UncoveredCacheScanner {

    private static let logger = Logger(subsystem: "fun.burrow", category: "UncoveredCacheScanner")

    /// Ignore anything smaller than this — sub-threshold folders aren't worth
    /// surfacing and keep the list focused on real wins.
    static let defaultMinBytes: Int64 = 50 * 1024 * 1024   // 50 MB
    static let defaultLimit = 12

    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Logs"),
        ]
    }

    // MARK: - Coverage

    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Path prefixes already targeted by a Clean rule. `~` is expanded; glob
    /// rules contribute the directory before their first `*` segment.
    static func coveredPaths(from catalog: CleanCatalog) -> Set<String> {
        var set = Set<String>()
        for category in catalog.categories {
            for rule in category.rules {
                guard let raw = rule.path else { continue }
                var p = PathResolver.expand(raw)
                if let star = p.firstIndex(of: "*") {
                    // Directory containing the globbed segment: everything up to
                    // the last "/" before the "*".
                    let beforeStar = p[..<star]
                    guard let lastSlash = beforeStar.lastIndex(of: "/") else { continue }
                    p = String(beforeStar[..<lastSlash])
                }
                let s = standardize(p)
                if !s.isEmpty && s != "/" { set.insert(s) }
            }
        }
        return set
    }

    /// True if `path` is the same as, inside, or an ancestor of any covered
    /// rule path — i.e. a rule already addresses this location (or part of it).
    static func isCovered(_ path: String, by covered: Set<String>) -> Bool {
        let p = standardize(path)
        for r in covered where p == r || p.hasPrefix(r + "/") || r.hasPrefix(p + "/") {
            return true
        }
        return false
    }

    // MARK: - Scan

    /// Direct-child directories of `roots` that no rule covers and that are at
    /// least `minBytes`, largest first, capped at `limit`.
    static func scan(
        roots: [URL],
        covered: Set<String>,
        minBytes: Int64 = defaultMinBytes,
        limit: Int = defaultLimit
    ) async -> [DiskEntry] {
        var candidates: [DiskEntry] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let result = await DiskUsageScanner.scan(root)
            for child in result.children
            where child.size >= minBytes && !isCovered(child.url.path, by: covered) {
                candidates.append(child)
            }
        }
        return Array(candidates.sorted { $0.size > $1.size }.prefix(limit))
    }

    /// Production convenience: loads the current Clean catalog (bundled or
    /// updated) and scans the default cache roots.
    static func discover() async -> [DiskEntry] {
        let covered: Set<String>
        do {
            let catalog = try RuleEngine.loadCatalog(from: CatalogStore.shared.url(for: .cleanRules))
            covered = coveredPaths(from: catalog)
        } catch {
            logger.error("Coverage catalog load failed: \(error.localizedDescription, privacy: .public)")
            covered = []
        }
        let found = await scan(roots: defaultRoots(), covered: covered)
        logger.info("Found \(found.count, privacy: .public) uncovered cache folder(s)")
        return found
    }
}
