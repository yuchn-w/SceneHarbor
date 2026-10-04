import Foundation
import XCTest
@testable import SceneHarbor

final class CatalogCachePolicyTests: XCTestCase {
    func testRepeatedReadsCannotExtendFetchedFreshness() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fetchedAt = now.addingTimeInterval(-HarborStorageMaintenance.catalogCacheTTL - 1)
        let recentAccess = now.addingTimeInterval(-1)

        XCTAssertFalse(HarborCatalogCachePolicy.isFresh(fetchedAt: fetchedAt, now: now))
        let evicted = HarborCatalogCachePolicy.evictionKeys(
            records: [HarborCatalogCachePolicyRecord(
                key: "old",
                fetchedAt: fetchedAt,
                lastAccess: recentAccess,
                bytes: 10
            )],
            now: now,
            limit: 100
        )
        XCTAssertEqual(evicted, Set(["old"]))
    }

    func testCapacityEvictsLeastRecentlyAccessedRecords() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [
            HarborCatalogCachePolicyRecord(key: "old", fetchedAt: now, lastAccess: now.addingTimeInterval(-30), bytes: 120),
            HarborCatalogCachePolicyRecord(key: "middle", fetchedAt: now, lastAccess: now.addingTimeInterval(-20), bytes: 120),
            HarborCatalogCachePolicyRecord(key: "new", fetchedAt: now, lastAccess: now.addingTimeInterval(-10), bytes: 120)
        ]

        let evicted = HarborCatalogCachePolicy.evictionKeys(records: records, now: now, limit: 240)

        XCTAssertEqual(evicted, Set(["old"]))
    }
}
