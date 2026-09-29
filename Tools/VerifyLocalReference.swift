import Foundation

@main struct VerifyLocalReference {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "SceneHarbor-local-reference-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let id = UUID(), file = root.appending(path: "\(id).mp4")
        try Data("fixture".utf8).write(to: file)
        let item = WallpaperItem(id: id, title: "自訂標題", videoPath: file.path, thumbnailPath: nil,
                                 duration: 1, width: 16, height: 9, isFavorite: false, dateAdded: Date())
        let resolved = HarborProjectResolver.resolve(path: file.path, items: [item])!
        precondition(resolved.id == "local-\(id)" && resolved.title == item.title && resolved.entrypoint == file)
        precondition(HarborProjectResolver.resolve(path: file.path)?.id == resolved.id)
        let link = root.appending(path: "\(UUID()).mp4")
        try manager.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(HarborProjectResolver.resolve(path: link.path) == nil)
        precondition(HarborProjectResolver.resolve(path: root.appending(path: "missing.mp4").path) == nil)
        let folder = root.appending(path: "1234")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"title":"工坊測試","type":"video","file":"movie.mp4"}"#.utf8).write(to: folder.appending(path: "project.json"))
        try Data("fixture".utf8).write(to: folder.appending(path: "movie.mp4"))
        precondition(HarborProjectResolver.resolve(path: folder.path)?.title == "工坊測試")
        print("PASS: local video references preserve identity/title/source, missing and symlink files are rejected, Workshop references remain supported")
    }
}
