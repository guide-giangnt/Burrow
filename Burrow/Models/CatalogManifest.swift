import Foundation

/// Remote manifest listing the latest published version of each catalog.
/// Hosted as a raw file in the Burrow repo (`catalog-manifest.json` on
/// `main`) and fetched by `CatalogUpdater`. Unknown catalog keys are
/// ignored, so adding a future catalog can't break an older app.
struct CatalogManifest: Decodable, Equatable {
    let manifestVersion: Int
    /// Keyed by `CatalogKind.resourceName` ("CleanRules" / "AppLeftovers").
    let catalogs: [String: Entry]

    struct Entry: Decodable, Equatable {
        let catalogVersion: Int
        let schemaVersion: Int
        let url: URL
        let sha256: String
    }

    func entry(for kind: CatalogKind) -> Entry? {
        catalogs[kind.resourceName]
    }
}
