import XCTest
@testable import Burrow

final class CatalogManifestTests: XCTestCase {

    private func decode(_ json: String) throws -> CatalogManifest {
        try JSONDecoder().decode(CatalogManifest.self, from: Data(json.utf8))
    }

    func testDecodesBothCatalogs() throws {
        let manifest = try decode("""
        { "manifestVersion": 1, "catalogs": {
            "CleanRules":   { "catalogVersion": 7, "schemaVersion": 1,
                              "url": "https://example.com/CleanRules.json", "sha256": "abc" },
            "AppLeftovers": { "catalogVersion": 4, "schemaVersion": 2,
                              "url": "https://example.com/AppLeftovers.json", "sha256": "def" } } }
        """)
        XCTAssertEqual(manifest.manifestVersion, 1)
        XCTAssertEqual(manifest.entry(for: .cleanRules)?.catalogVersion, 7)
        XCTAssertEqual(manifest.entry(for: .appLeftovers)?.schemaVersion, 2)
        XCTAssertEqual(manifest.entry(for: .cleanRules)?.url.absoluteString,
                       "https://example.com/CleanRules.json")
    }

    func testUnknownCatalogKeyIsIgnored() throws {
        let manifest = try decode("""
        { "manifestVersion": 1, "catalogs": {
            "CleanRules": { "catalogVersion": 1, "schemaVersion": 1,
                            "url": "https://example.com/c.json", "sha256": "x" },
            "FutureCatalog": { "catalogVersion": 1, "schemaVersion": 1,
                               "url": "https://example.com/f.json", "sha256": "y" } } }
        """)
        XCTAssertNotNil(manifest.entry(for: .cleanRules))
        XCTAssertNil(manifest.entry(for: .appLeftovers))
    }

    func testMissingCatalogEntryIsNil() throws {
        let manifest = try decode("""
        { "manifestVersion": 1, "catalogs": {
            "CleanRules": { "catalogVersion": 1, "schemaVersion": 1,
                            "url": "https://example.com/c.json", "sha256": "x" } } }
        """)
        XCTAssertNil(manifest.entry(for: .appLeftovers))
    }

    func testMalformedManifestThrows() {
        XCTAssertThrowsError(try decode("{ not json"))
    }
}
