import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

struct HarborLockCapability: Sendable {
    let osVersion: OperatingSystemVersion
    let supportsWallpaperExtension: Bool
    let supportsScreenSaver: Bool
    let reasons: [String]

    var canPublishRealLockScreen: Bool {
        supportsWallpaperExtension && reasons.isEmpty
    }

    var summary: String {
        if canPublishRealLockScreen { return "macOS Wallpaper Extension 可供鎖定畫面使用" }
        if supportsScreenSaver { return "只可使用標準螢幕保護程式；真正鎖定畫面 extension 尚未可用" }
        return reasons.first ?? "目前沒有可用的鎖定畫面 renderer"
    }

    static func inspect(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        wallpaperExtensionRegistered: Bool? = nil,
        runtimeReady: Bool? = nil,
        applicationBundleURL: URL = Bundle.main.bundleURL
    ) -> HarborLockCapability {
        let supportsExtension = osVersion.majorVersion >= 26
        let supportsSaver = osVersion.majorVersion >= 14
        let extensionURL = [
            applicationBundleURL.appending(path: "Contents/Extensions/SceneHarborWallpaperExtension.appex"),
            applicationBundleURL.appending(path: "Contents/PlugIns/SceneHarborWallpaperExtension.appex")
        ].first { FileManager.default.fileExists(atPath: $0.path) }
        let extensionIsPresent = extensionURL != nil
        // Presence is not enough: a signed extension may still lack the
        // desktop scene ABI or its bundled renderer resources.  The parent
        // app can pass runtimeReady=true only after its registration probe
        // and resource fingerprint succeed.
        let rendererIsReady = runtimeReady ?? false
        var reasons: [String] = []
        if !supportsExtension {
            reasons.append("macOS 26 以上才提供本專案採用的 Wallpaper Extension 路徑")
        } else if !extensionIsPresent {
            reasons.append("Wallpaper Extension bundle 尚未嵌入 App")
        } else if wallpaperExtensionRegistered != true {
            reasons.append("Wallpaper Extension 尚未完成 provider 註冊探測")
        }
        if supportsExtension && !rendererIsReady {
            reasons.append("lock renderer runtime 尚未就緒")
        }
        return HarborLockCapability(
            osVersion: osVersion,
            supportsWallpaperExtension: supportsExtension,
            supportsScreenSaver: supportsSaver,
            reasons: reasons
        )
    }
}

struct HarborLockValidatedSource: Equatable, Sendable {
    let projectID: String
    let title: String
    let kind: HarborLockWallpaperKind
    let renderDirectory: URL
    let entryURL: URL
    let previewURL: URL?
    let fingerprint: String

    var entryPath: String { entryURL.path }
    var renderDirectoryPath: String { renderDirectory.path }
}

enum HarborLockSourceValidator {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let sceneExtensions: Set<String> = ["pkg"]

    static func validate(_ project: WallpaperEngineProject) throws -> HarborLockValidatedSource {
        let kind: HarborLockWallpaperKind
        switch project.kind {
        case .video: kind = .video
        case .scene: kind = .scene
        default: throw HarborLockError.unsupportedWallpaperKind(project.kind.rawValue)
        }

        guard let entrypoint = project.entrypoint else {
            throw HarborLockError.missingEntrypoint
        }
        let rawEntry = entrypoint.standardizedFileURL
        guard FileManager.default.fileExists(atPath: rawEntry.path) else {
            throw HarborLockError.invalidEntrypoint(rawEntry.path)
        }
        if isSymbolicLink(rawEntry) {
            throw HarborLockError.symbolicLinkNotAllowed(rawEntry.path)
        }

        let extensionName = rawEntry.pathExtension.lowercased()
        switch kind {
        case .video where !videoExtensions.contains(extensionName):
            throw HarborLockError.unsupportedFileExtension(extensionName)
        case .scene where !sceneExtensions.contains(extensionName):
            throw HarborLockError.unsupportedFileExtension(extensionName)
        default: break
        }

        let resolvedEntry = rawEntry.resolvingSymlinksInPath()
        let rawDirectory = project.kind == .video && isRegularFile(rawEntry)
            ? rawEntry.deletingLastPathComponent()
            : project.directory
        let canonicalDirectory = rawDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(rawDirectory) else {
            throw HarborLockError.invalidRenderDirectory(canonicalDirectory.path)
        }
        guard isInside(resolvedEntry, root: canonicalDirectory),
              isRegularFile(resolvedEntry) else {
            throw HarborLockError.invalidEntrypoint(resolvedEntry.path)
        }
        if kind == .scene {
            try rejectNestedSymbolicLinks(in: canonicalDirectory)
        }

        let preview = previewURL(in: canonicalDirectory)
        return HarborLockValidatedSource(
            projectID: project.id,
            title: project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? project.id : project.title,
            kind: kind,
            renderDirectory: canonicalDirectory,
            entryURL: resolvedEntry,
            previewURL: preview,
            fingerprint: fingerprint(for: resolvedEntry)
        )
    }

    private static func previewURL(in root: URL) -> URL? {
        ["preview.jpg", "preview.jpeg", "preview.png", "thumbnail.jpg", "thumbnail.png", "cover.jpg", "cover.png"]
            .compactMap { name -> URL? in
                let candidate = root.appending(path: name).standardizedFileURL
                guard isInside(candidate, root: root), isRegularFile(candidate), !isSymbolicLink(candidate) else {
                    return nil
                }
                return candidate.resolvingSymlinksInPath()
            }
            .first
    }

    private static func fingerprint(for url: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .volumeIdentifierKey]
        let values = try? url.resourceValues(forKeys: keys)
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let volume = values?.volumeIdentifier.map { String(describing: $0) } ?? ""
        return HarborLockDigest.hex(Data("\(url.path)|\(size)|\(modified)|\(volume)".utf8))
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func rejectNestedSymbolicLinks(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator where isSymbolicLink(url) {
            throw HarborLockError.symbolicLinkNotAllowed(url.path)
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

enum HarborLockDigest {
    static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return fallback(data)
        #endif
    }

    private static func fallback(_ data: Data) -> String {
        var value: UInt64 = 1469598103934665603
        for byte in data {
            value ^= UInt64(byte)
            value &*= 1099511628211
        }
        return String(format: "%016llx", value)
    }
}
