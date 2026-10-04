import AppKit
import Foundation
import UniformTypeIdentifiers

/// Uses the standard user-selected-folder grant. No TCC database edits,
/// Full Disk Access, or unprovisioned App Group claim is involved.
@MainActor
final class HarborLockStorageAuthorization {
    static let shared = HarborLockStorageAuthorization()
    private let bookmarkKey = "HarborLockExtensionDocumentsBookmark.v1"
    private var accessedURL: URL?
    private var panel: NSOpenPanel?
    private(set) var isAuthorized = false

    init(restoreExistingGrant: Bool = true) {
        guard restoreExistingGrant else { return }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard Self.isExpectedFolder(url) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                try Self.verifyAccess(url)
                if stale { try saveBookmark(url) }
                if scoped { accessedURL = url }
                isAuthorized = true
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        } catch { /* Keep a failed grant available for explicit reauthorization. */ }
    }

    deinit { accessedURL?.stopAccessingSecurityScopedResource() }

    static func isExpectedFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath() ==
            HarborNativeLockPaths.extensionDocumentsURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func verifyAccess(_ url: URL) throws {
        let root = url.appending(path: "SceneHarborLock", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appending(path: ".access-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        let payload = Data("SceneHarbor access check".utf8)
        try payload.write(to: probe, options: .atomic)
        guard try Data(contentsOf: probe) == payload else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    func request(completion: @escaping (Result<Bool, Error>) -> Void) {
        guard panel == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "授權 SceneHarbor 鎖定畫面資料"
        picker.message = "只授權 SceneHarbor 鎖定播放元件的 Documents 資料夾，用來儲存桌布副本與播放設定。請保持目前資料夾，按「授權並啟用」。"
        picker.prompt = "授權並啟用"
        picker.allowedContentTypes = [.folder]
        picker.allowsOtherFileTypes = true
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = HarborNativeLockPaths.extensionDocumentsURL
        panel = picker
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer { self.panel = nil }
            guard response == .OK, let url = picker.url else {
                completion(.success(false)); return
            }
            guard Self.isExpectedFolder(url) else {
                completion(.failure(NSError(domain: "HarborLockAuthorization", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "請選取 SceneHarbor 鎖定播放元件的 Documents 資料夾；未授權其他位置。"])))
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                try Self.verifyAccess(url)
                try self.saveBookmark(url)
                self.accessedURL?.stopAccessingSecurityScopedResource()
                self.accessedURL = scoped ? url : nil
                self.isAuthorized = true
                completion(.success(true))
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                completion(.failure(error))
            }
        }
        handleResponse(picker.runModal())
    }
}
