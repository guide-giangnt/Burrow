import XCTest
@testable import Burrow

final class CatalogStoreTests: XCTestCase {

    private var tmp: URL!
    private var bundleDir: URL!
    private var cacheDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-catalogstore-\(UUID().uuidString)")
        bundleDir = tmp.appendingPathComponent("bundle")
        cacheDir = tmp.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes a minimal but valid CleanRules-shaped catalog.
    private func writeCatalog(to url: URL, schema: Int, catalog: Int?) throws {
        var dict: [String: Any] = ["schemaVersion": schema, "categories": []]
        if let catalog { dict["catalogVersion"] = catalog }
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
    }

    /// Store whose bundled CleanRules resource we control, cache in a tmp dir.
    private func makeStore(bundleSchema: Int = 1, bundleCatalog: Int? = 1) throws -> (CatalogStore, URL) {
        let bundleURL = bundleDir.appendingPathComponent("CleanRules.json")
        try writeCatalog(to: bundleURL, schema: bundleSchema, catalog: bundleCatalog)
        let store = CatalogStore(catalogsDirectory: cacheDir, bundleURLResolver: { kind in
            kind == .cleanRules ? bundleURL : nil
        })
        return (store, bundleURL)
    }

    private func writeCache(_ store: CatalogStore, schema: Int, catalog: Int?) throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try writeCatalog(to: store.cachedURL(for: .cleanRules), schema: schema, catalog: catalog)
    }

    // MARK: - url(for:) selection

    func testNoCacheReturnsBundle() throws {
        let (store, bundleURL) = try makeStore()
        XCTAssertEqual(store.url(for: .cleanRules), bundleURL)
    }

    func testStrictlyNewerCacheWins() throws {
        let (store, _) = try makeStore(bundleCatalog: 1)
        try writeCache(store, schema: 1, catalog: 5)
        XCTAssertEqual(store.url(for: .cleanRules), store.cachedURL(for: .cleanRules))
        XCTAssertEqual(store.effectiveVersion(for: .cleanRules), 5)
    }

    func testEqualCacheUsesBundle() throws {
        let (store, bundleURL) = try makeStore(bundleCatalog: 3)
        try writeCache(store, schema: 1, catalog: 3)
        XCTAssertEqual(store.url(for: .cleanRules), bundleURL, "tie must favor the bundle")
    }

    func testOlderCacheUsesBundle() throws {
        let (store, bundleURL) = try makeStore(bundleCatalog: 4)
        try writeCache(store, schema: 1, catalog: 2)
        XCTAssertEqual(store.url(for: .cleanRules), bundleURL)
        XCTAssertEqual(store.effectiveVersion(for: .cleanRules), 4)
    }

    func testSchemaMismatchCacheIgnored() throws {
        let (store, bundleURL) = try makeStore(bundleCatalog: 1)
        // Cache is "newer" but a schema this build doesn't support → ignored.
        try writeCache(store, schema: 99, catalog: 100)
        XCTAssertEqual(store.url(for: .cleanRules), bundleURL)
    }

    func testCorruptCacheFallsBackToBundle() throws {
        let (store, bundleURL) = try makeStore(bundleCatalog: 1)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.cachedURL(for: .cleanRules))
        XCTAssertEqual(store.url(for: .cleanRules), bundleURL)
    }

    // MARK: - install

    func testInstallThenReadsBackNewVersion() throws {
        let (store, _) = try makeStore(bundleCatalog: 1)
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "catalogVersion": 7, "categories": [],
        ])
        try store.install(payload, for: .cleanRules)
        XCTAssertEqual(store.installedVersion(for: .cleanRules)?.catalogVersion, 7)
        XCTAssertEqual(store.url(for: .cleanRules), store.cachedURL(for: .cleanRules))
    }

    func testInstallReplacesPriorCache() throws {
        let (store, _) = try makeStore(bundleCatalog: 1)
        try writeCache(store, schema: 1, catalog: 2)
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "catalogVersion": 9, "categories": [],
        ])
        try store.install(payload, for: .cleanRules)
        XCTAssertEqual(store.installedVersion(for: .cleanRules)?.catalogVersion, 9)
    }

    func testClearCacheRevertsToBundle() throws {
        let (store, bundleURL) = try makeStore(bundleCatalog: 1)
        try writeCache(store, schema: 1, catalog: 5)
        XCTAssertEqual(store.url(for: .cleanRules), store.cachedURL(for: .cleanRules))
        try store.clearCache(for: .cleanRules)
        XCTAssertEqual(store.url(for: .cleanRules), bundleURL)
    }
}
