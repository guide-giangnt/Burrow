import XCTest
import CryptoKit
@testable import Burrow

/// Covers the pure verification core (`CatalogUpdater.validate`) — the
/// network path is best-effort and exercised via the manual e2e recipe.
final class CatalogUpdaterTests: XCTestCase {

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func catalogData(schema: Int = 1, catalog: Int, categories: Any = []) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": schema, "catalogVersion": catalog, "categories": categories,
        ])
    }

    private func entry(
        catalog: Int, schema: Int = 1, sha: String
    ) -> CatalogManifest.Entry {
        CatalogManifest.Entry(
            catalogVersion: catalog,
            schemaVersion: schema,
            url: URL(string: "https://example.com/x.json")!,
            sha256: sha
        )
    }

    private func assertFailure(
        _ result: Result<Void, CatalogUpdater.ValidationError>,
        _ expected: CatalogUpdater.ValidationError,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .failure(let err) = result {
            XCTAssertEqual(err, expected, message, file: file, line: line)
        } else {
            XCTFail("expected .failure(\(expected)), got success. \(message)", file: file, line: line)
        }
    }

    func testValidCatalogPasses() {
        let data = catalogData(catalog: 7)
        let result = CatalogUpdater.validate(
            data: data, against: entry(catalog: 7, sha: sha256Hex(data)), kind: .cleanRules
        )
        XCTAssertNoThrow(try result.get())
    }

    func testChecksumMismatch() {
        let data = catalogData(catalog: 7)
        let result = CatalogUpdater.validate(
            data: data, against: entry(catalog: 7, sha: "deadbeef"), kind: .cleanRules
        )
        assertFailure(result, .checksumMismatch)
    }

    func testSchemaMismatchRejected() {
        // File + manifest agree on schema 2, but this build supports 1 for CleanRules.
        let data = catalogData(schema: 2, catalog: 7)
        let result = CatalogUpdater.validate(
            data: data, against: entry(catalog: 7, schema: 2, sha: sha256Hex(data)), kind: .cleanRules
        )
        assertFailure(result, .schemaMismatch)
    }

    func testVersionMismatchRejected() {
        // Bytes say catalogVersion 7 but the manifest claims 8.
        let data = catalogData(catalog: 7)
        let result = CatalogUpdater.validate(
            data: data, against: entry(catalog: 8, sha: sha256Hex(data)), kind: .cleanRules
        )
        assertFailure(result, .versionMismatch)
    }

    func testMalformedHeaderRejected() {
        let data = Data("garbage".utf8)
        let result = CatalogUpdater.validate(
            data: data, against: entry(catalog: 1, sha: sha256Hex(data)), kind: .cleanRules
        )
        assertFailure(result, .malformed)
    }

    // Exercises the full fetch → verify → install → select pipeline using
    // local file:// URLs (URLSession serves them), so no network is needed.
    func testEndToEndInstallFromFileURL() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = tmp.appendingPathComponent("bundle-CleanRules.json")
        try catalogData(catalog: 1).write(to: bundleURL)

        let remoteURL = tmp.appendingPathComponent("remote-CleanRules.json")
        let remoteData = catalogData(catalog: 999)
        try remoteData.write(to: remoteURL)

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "manifestVersion": 1,
            "catalogs": ["CleanRules": [
                "catalogVersion": 999, "schemaVersion": 1,
                "url": remoteURL.absoluteString, "sha256": sha256Hex(remoteData),
            ]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let store = CatalogStore(
            catalogsDirectory: tmp.appendingPathComponent("cache"),
            bundleURLResolver: { $0 == .cleanRules ? bundleURL : nil }
        )

        let results = await CatalogUpdater.checkForUpdates(store: store, manifestURL: manifestURL)
        XCTAssertEqual(results[.cleanRules], .installed(999))
        XCTAssertEqual(store.installedVersion(for: .cleanRules)?.catalogVersion, 999)
        XCTAssertEqual(store.url(for: .cleanRules), store.cachedURL(for: .cleanRules))
    }

    func testHeaderOkButBodyUndecodableRejected() {
        // Header (schema/version) is fine, but `categories` is the wrong type,
        // so the full CleanCatalog decode fails.
        let data = catalogData(catalog: 3, categories: "not-an-array")
        let result = CatalogUpdater.validate(
            data: data, against: entry(catalog: 3, sha: sha256Hex(data)), kind: .cleanRules
        )
        assertFailure(result, .malformed)
    }
}
