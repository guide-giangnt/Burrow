import Foundation

struct CleanCatalog: Codable, Hashable {
    let schemaVersion: Int
    /// Monotonic content version, bumped on every published catalog change.
    /// Optional so older bundled files (and tests) that predate it still
    /// decode. Compared only within a matching `schemaVersion`.
    let catalogVersion: Int?
    let categories: [CleanCategory]

    init(schemaVersion: Int, catalogVersion: Int? = nil, categories: [CleanCategory]) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.categories = categories
    }
}
