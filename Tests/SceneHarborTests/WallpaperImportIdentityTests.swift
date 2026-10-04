import XCTest
@testable import SceneHarbor

final class WallpaperImportIdentityTests: XCTestCase {
    func testIdenticalBytesAtRenamedSourceAreSkipped() {
        let identity = WallpaperImportIdentity(
            title: "既有影片",
            storedPath: "/tmp/sceneharbor-managed-existing.mp4",
            sourcePath: "/Volumes/Media/original.mp4",
            sourceFingerprint: "same-bytes"
        )

        let duplicate = WallpaperImportDuplicateMatcher.firstDuplicate(
            sourcePath: "/Volumes/Archive/renamed-copy.mp4",
            sourceFingerprint: "same-bytes",
            identities: [identity],
            storedFileExists: { _ in true },
            storedFingerprint: { $0.sourceFingerprint }
        )

        XCTAssertEqual(duplicate?.title, "既有影片")
    }

    func testChangedContentAtSameSourcePathIsImportedAgain() {
        let identity = WallpaperImportIdentity(
            title: "舊版本",
            storedPath: "/tmp/sceneharbor-managed-old.mp4",
            sourcePath: "/Volumes/Media/original.mp4",
            sourceFingerprint: "old-bytes"
        )

        let duplicate = WallpaperImportDuplicateMatcher.firstDuplicate(
            sourcePath: "/Volumes/Media/original.mp4",
            sourceFingerprint: "new-bytes",
            identities: [identity],
            storedFileExists: { _ in true },
            storedFingerprint: { $0.sourceFingerprint }
        )

        XCTAssertNil(duplicate)
    }

    func testMissingManagedCopyDoesNotBlockRepairImport() {
        let identity = WallpaperImportIdentity(
            title: "遺失的管理副本",
            storedPath: "/tmp/sceneharbor-managed-missing.mp4",
            sourcePath: "/Volumes/Media/original.mp4",
            sourceFingerprint: "same-bytes"
        )

        let duplicate = WallpaperImportDuplicateMatcher.firstDuplicate(
            sourcePath: "/Volumes/Archive/renamed-copy.mp4",
            sourceFingerprint: "same-bytes",
            identities: [identity],
            storedFileExists: { _ in false },
            storedFingerprint: { $0.sourceFingerprint }
        )

        XCTAssertNil(duplicate)
    }
}
