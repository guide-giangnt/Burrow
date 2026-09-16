import XCTest
@testable import Burrow

final class UncoveredCacheScannerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-uncovered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - coveredPaths

    func testCoveredPathsExpandsTildeAndGlobPrefix() throws {
        let json = """
        { "schemaVersion": 1, "catalogVersion": 1, "categories": [
          { "id": "x", "title": "X", "summary": "", "group": "developer",
            "icon": "gear", "risk": "low", "defaultEnabled": true, "rules": [
              { "kind": "directoryContents", "path": "~/Library/Caches/Foo" },
              { "kind": "glob", "path": "~/Library/Caches/Bar/*/Cache" }
            ] } ] }
        """
        let catalog = try JSONDecoder().decode(CleanCatalog.self, from: Data(json.utf8))
        let covered = UncoveredCacheScanner.coveredPaths(from: catalog)
        let home = NSHomeDirectory()
        XCTAssertTrue(covered.contains("\(home)/Library/Caches/Foo"))
        XCTAssertTrue(covered.contains("\(home)/Library/Caches/Bar"), "glob prefix before * is covered")
    }

    // MARK: - isCovered

    func testIsCoveredMatchesSelfChildAndAncestor() {
        let covered: Set<String> = ["/a/b"]
        XCTAssertTrue(UncoveredCacheScanner.isCovered("/a/b", by: covered))       // exact
        XCTAssertTrue(UncoveredCacheScanner.isCovered("/a/b/c", by: covered))     // inside a rule
        XCTAssertTrue(UncoveredCacheScanner.isCovered("/a", by: covered))         // ancestor of a rule
        XCTAssertFalse(UncoveredCacheScanner.isCovered("/a/x", by: covered))      // unrelated
        XCTAssertFalse(UncoveredCacheScanner.isCovered("/a/bc", by: covered))     // prefix, not a path boundary
    }

    // MARK: - scan

    func testScanReturnsLargeUncoveredOnly() async throws {
        let root = tmp.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func makeDir(_ name: String, bytes: Int) throws -> URL {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: dir.appendingPathComponent("blob"))
            return dir
        }

        _ = try makeDir("big", bytes: 300 * 1024)          // above threshold, uncovered
        _ = try makeDir("small", bytes: 4 * 1024)          // below threshold
        let coveredDir = try makeDir("covered", bytes: 300 * 1024)  // above threshold but covered

        let covered: Set<String> = [coveredDir.standardizedFileURL.path]
        let result = await UncoveredCacheScanner.scan(
            roots: [root], covered: covered, minBytes: 100 * 1024, limit: 10
        )

        let names = Set(result.map(\.name))
        XCTAssertTrue(names.contains("big"))
        XCTAssertFalse(names.contains("small"), "below threshold excluded")
        XCTAssertFalse(names.contains("covered"), "rule-covered excluded")
    }

    func testScanSkipsMissingRoots() async {
        let missing = tmp.appendingPathComponent("does-not-exist")
        let result = await UncoveredCacheScanner.scan(roots: [missing], covered: [], minBytes: 1)
        XCTAssertTrue(result.isEmpty)
    }
}
