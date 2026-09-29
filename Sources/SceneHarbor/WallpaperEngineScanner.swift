import Foundation

enum WallpaperEngineProjectKind: String, Sendable {
    case video
    case web
    case scene
    case image
    case unknown

    var canImportIntoVideoLibrary: Bool {
        self == .video
    }
}

struct WallpaperEngineProject: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let kind: WallpaperEngineProjectKind
    let directory: URL
    let entrypoint: URL?
}

struct WallpaperEngineScanSummary: Sendable {
    let projects: [WallpaperEngineProject]

    var playableVideoProjects: [WallpaperEngineProject] {
        projects.filter { $0.kind.canImportIntoVideoLibrary && $0.entrypoint != nil }
    }

    var deferredProjects: [WallpaperEngineProject] {
        projects.filter { !$0.kind.canImportIntoVideoLibrary }
    }
}

struct WallpaperEngineScanner {
    private let fileManager = FileManager.default
    private let videoExtensions = Set(["mp4", "mov", "m4v"])
    private let webExtensions = Set(["html", "htm"])
    private let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "heic"])

    func scan(root: URL) -> WallpaperEngineScanSummary {
        let normalizedRoot = root.standardizedFileURL
        guard isDirectory(normalizedRoot), !isSymbolicLink(normalizedRoot) else {
            return WallpaperEngineScanSummary(projects: [])
        }

        let projectDirectories: [URL]
        if fileManager.fileExists(atPath: normalizedRoot.appending(path: "project.json").path) {
            projectDirectories = [normalizedRoot]
        } else {
            projectDirectories = (try? fileManager.contentsOfDirectory(
                at: normalizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.filter {
                !$0.lastPathComponent.isEmpty
                    && $0.lastPathComponent.allSatisfy(\.isNumber)
                    && isDirectory($0)
                    && !isSymbolicLink($0)
            } ?? []
        }

        let projects = projectDirectories.compactMap { inspect(project: $0, root: normalizedRoot) }
        return WallpaperEngineScanSummary(
            projects: projects.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        )
    }

    private func inspect(project: URL, root: URL) -> WallpaperEngineProject? {
        guard (project.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() || isInside(project, root: root)),
              !isSymbolicLink(project) else {
            return nil
        }

        let manifestURL = project.appending(path: "project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }

        let entrypoint = findEntrypoint(in: project, preferredFile: manifest.file, type: manifest.type)
        let kind = classify(type: manifest.type, entrypoint: entrypoint)
        return WallpaperEngineProject(
            id: project.lastPathComponent,
            title: manifest.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? manifest.title!.trimmingCharacters(in: .whitespacesAndNewlines)
                : project.lastPathComponent,
            kind: kind,
            directory: project,
            entrypoint: entrypoint
        )
    }

    private func findEntrypoint(in project: URL, preferredFile: String?, type: String?) -> URL? {
        // Scene manifests refer to scene.json inside the package; a preview
        // image beside it must never become the renderer's entry point.
        if type?.lowercased() == "scene",
           let package = containedFile(relativePath: "scene.pkg", in: project) {
            return package
        }
        if let preferredFile,
           let preferred = containedFile(relativePath: preferredFile, in: project) {
            return preferred
        }

        guard let enumerator = fileManager.enumerator(
            at: project,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  isRegularFile(url),
                  !isSymbolicLink(url),
                  isInside(url, root: project) else {
                return nil
            }
            let ext = url.pathExtension.lowercased()
            switch type?.lowercased() {
            case "scene": return ext == "pkg" ? url : nil
            case "video": return videoExtensions.contains(ext) ? url : nil
            case "web": return webExtensions.contains(ext) ? url : nil
            case "image": return imageExtensions.contains(ext) ? url : nil
            default: break
            }
            return videoExtensions.contains(ext)
                || webExtensions.contains(ext)
                || imageExtensions.contains(ext)
                || ext == "pkg" ? url : nil
        }
        .sorted { entrypointRank($0) < entrypointRank($1) }
        .first
    }

    private func containedFile(relativePath: String, in project: URL) -> URL? {
        guard !(relativePath as NSString).isAbsolutePath else { return nil }
        let candidate = project.appending(path: relativePath).standardizedFileURL
        guard isInside(candidate, root: project),
              isRegularFile(candidate),
              !isSymbolicLink(candidate) else {
            return nil
        }
        return candidate
    }

    private func classify(type: String?, entrypoint: URL?) -> WallpaperEngineProjectKind {
        switch type?.lowercased() {
        case "video": return .video
        case "web": return .web
        case "scene": return .scene
        case "image": return .image
        default: break
        }

        guard let ext = entrypoint?.pathExtension.lowercased() else { return .unknown }
        if videoExtensions.contains(ext) { return .video }
        if webExtensions.contains(ext) { return .web }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pkg" { return .scene }
        return .unknown
    }

    private func entrypointRank(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return 0
        case "webm", "mkv", "avi": return 1
        case "html", "htm": return 2
        case "jpg", "jpeg", "png", "gif", "heic": return 3
        case "pkg": return 4
        default: return 5
        }
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComponents.count > rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private struct Manifest: Decodable {
        let title: String?
        let type: String?
        let file: String?
    }
}
