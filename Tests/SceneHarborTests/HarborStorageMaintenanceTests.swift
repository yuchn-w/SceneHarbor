import Foundation
import XCTest
@testable import SceneHarbor

/// Storage cleanup tests use only a temporary Workshop-shaped directory.  The
/// production Application Support staging root and managed media are never
/// read or modified by these tests.
final class HarborStorageMaintenanceTests: XCTestCase {
    func testActiveAndRecheckEntriesStayProtectedAndMediaIsUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeStaging(id: "100", contents: "active")
        try fixture.writeStaging(id: "200", contents: "recheck")
        try fixture.writeStaging(id: "300", contents: "stale")
        try fixture.writeStagingSymlink(id: "400")
        let originalMedia = try fixture.writeMedia(contents: "managed-media")

        let plan = HarborStorageMaintenance.quarantineInactiveStaging(
            activeWorkshopIDs: ["100"],
            recheckActiveWorkshopIDs: ["200"],
            stagingRoot: fixture.stagingRoot)

        XCTAssertEqual(Set(plan.entries.map(\.workshopID)), ["300"])
        XCTAssertTrue(fixture.existsStaging(id: "100"))
        XCTAssertTrue(fixture.existsStaging(id: "200"))
        XCTAssertTrue(fixture.existsStaging(id: "400"))
        XCTAssertFalse(fixture.existsStaging(id: "300"))
        XCTAssertEqual(try String(contentsOf: originalMedia, encoding: .utf8), "managed-media")

        let result = HarborStorageMaintenance.deleteQuarantinedStaging(plan)

        XCTAssertEqual(result.stagingEntriesRemoved, 1)
        XCTAssertEqual(result.failedEntries, 0)
        XCTAssertTrue(fixture.existsStaging(id: "100"))
        XCTAssertTrue(fixture.existsStaging(id: "200"))
        XCTAssertTrue(fixture.existsStaging(id: "400"))
        XCTAssertEqual(try String(contentsOf: originalMedia, encoding: .utf8), "managed-media")
    }

    func testNewDownloadWithSameIDSurvivesDeletionOfOlderPlan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeStaging(id: "500", contents: "old-download")

        let plan = HarborStorageMaintenance.quarantineInactiveStaging(
            activeWorkshopIDs: [], stagingRoot: fixture.stagingRoot)
        XCTAssertEqual(Set(plan.entries.map(\.workshopID)), ["500"])
        XCTAssertFalse(fixture.existsStaging(id: "500"))

        try fixture.writeStaging(id: "500", contents: "new-download")
        let result = HarborStorageMaintenance.deleteQuarantinedStaging(plan)

        XCTAssertEqual(result.stagingEntriesRemoved, 1)
        XCTAssertEqual(result.failedEntries, 0)
        XCTAssertTrue(fixture.existsStaging(id: "500"))
        XCTAssertEqual(
            try String(contentsOf: fixture.stagingFile(id: "500"), encoding: .utf8),
            "new-download")
    }

    func testFailedQuarantineDeletionCanBeRetriedWithoutTouchingFixtureMedia() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalMedia = try fixture.writeMedia(contents: "retry-media")
        let retryRoot = fixture.workshopContentRoot.appendingPathComponent(
            ".cleanup-retry-\(UUID().uuidString)", isDirectory: true)
        let entry = HarborStagingEntry(
            workshopID: "600",
            bytes: 12,
            modifiedAt: Date(),
            isActive: false,
            isQuarantined: true)
        let plan = HarborStagingCleanupPlan(
            roots: [HarborStagingCleanupRoot(url: retryRoot, entries: [entry])],
            failedEntries: 0)

        let first = HarborStorageMaintenance.deleteQuarantinedStaging(plan)
        XCTAssertEqual(first.stagingEntriesRemoved, 0)
        XCTAssertEqual(first.failedEntries, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retryRoot.path))
        XCTAssertEqual(try String(contentsOf: originalMedia, encoding: .utf8), "retry-media")

        try FileManager.default.createDirectory(at: retryRoot, withIntermediateDirectories: true)
        try fixture.writeFile("retry-data", to: retryRoot.appendingPathComponent("600"))
        let second = HarborStorageMaintenance.deleteQuarantinedStaging(plan)

        XCTAssertEqual(second.stagingEntriesRemoved, 1)
        XCTAssertEqual(second.failedEntries, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retryRoot.path))
        XCTAssertEqual(try String(contentsOf: originalMedia, encoding: .utf8), "retry-media")
    }

    private struct Fixture {
        let root: URL
        let workshopContentRoot: URL
        let stagingRoot: URL
        let mediaRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SceneHarbor-storage-maintenance-\(UUID().uuidString)", isDirectory: true)
            workshopContentRoot = root.appendingPathComponent(
                "Workshop/content/431960", isDirectory: true)
            stagingRoot = workshopContentRoot.appendingPathComponent(".staging", isDirectory: true)
            mediaRoot = root.appendingPathComponent("ManagedMedia", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        }

        func writeStaging(id: String, contents: String) throws {
            let directory = stagingRoot.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeFile(contents, to: directory.appendingPathComponent("payload.txt"))
        }

        func writeStagingSymlink(id: String) throws {
            let target = mediaRoot.appendingPathComponent("symlink-target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try writeFile("outside-target", to: target.appendingPathComponent("payload.txt"))
            let link = stagingRoot.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }

        func writeMedia(contents: String) throws -> URL {
            let file = mediaRoot.appendingPathComponent("original.mp4")
            try writeFile(contents, to: file)
            return file
        }

        func stagingFile(id: String) -> URL {
            stagingRoot.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("payload.txt")
        }

        func existsStaging(id: String) -> Bool {
            FileManager.default.fileExists(
                atPath: stagingRoot.appendingPathComponent(id, isDirectory: true).path)
        }

        func writeFile(_ contents: String, to url: URL) throws {
            try Data(contents.utf8).write(to: url, options: .atomic)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
