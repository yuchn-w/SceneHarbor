import Foundation
import CoreGraphics

/// The renderer is deliberately an external process.  SceneHarbor owns the
/// lifecycle and the control pipe, while the Vulkan/MoltenVK implementation
/// stays replaceable and is not linked into the video-wallpaper target.
struct SceneRendererToolchainStatus: Sendable {
    let rendererURL: URL?
    let assetsURL: URL?
    let missingRequirements: [String]

    var isReady: Bool {
        rendererURL != nil && assetsURL != nil && missingRequirements.isEmpty
    }

    var summary: String {
        if isReady { return "Scene renderer 已就緒" }
        if let first = missingRequirements.first {
            return "Scene renderer 尚未就緒：" + first
        }
        return "Scene renderer 尚未設定"
    }

    static func inspect(
        rendererURL: URL? = nil,
        assetsURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SceneRendererToolchainStatus {
        let fileManager = FileManager.default
        let resolvedRenderer = rendererURL ?? firstExistingExecutable(
            candidates: rendererCandidates(environment: environment),
            fileManager: fileManager
        )
        let resolvedAssets = assetsURL ?? firstExistingDirectory(
            candidates: assetsCandidates(environment: environment),
            fileManager: fileManager
        )

        var missing: [String] = []
        if resolvedRenderer == nil {
            missing.append("Scene renderer 執行檔")
        }
        if resolvedAssets == nil {
            missing.append("Wallpaper Engine assets 資料夾")
        }
        return SceneRendererToolchainStatus(
            rendererURL: resolvedRenderer,
            assetsURL: resolvedAssets,
            missingRequirements: missing
        )
    }

    private static func rendererCandidates(environment: [String: String]) -> [URL] {
        var candidates: [URL] = []
        if let configured = environment["SCENE_HARBOR_SCENE_RENDERER"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let bundled = Bundle.main.url(
            forResource: "SceneHarborSceneRenderer",
            withExtension: nil
        ) {
            candidates.append(bundled)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                Bundle.main.bundleURL
                    .appending(path: "Contents/Helpers/SceneHarborSceneRenderer")
            )
            candidates.append(resources.appending(path: "SceneHarborSceneRenderer"))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable
                    .deletingLastPathComponent()
                    .appending(path: "SceneHarborSceneRenderer")
            )
        }
        return candidates
    }

    private static func assetsCandidates(environment: [String: String]) -> [URL] {
        if let configured = environment["SCENE_HARBOR_WE_ASSETS_DIR"], !configured.isEmpty {
            return [URL(fileURLWithPath: configured)]
        }

        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appending(path: "assets") {
            candidates.append(bundled)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        let steam = support?.appending(path: "Steam/steamapps/workshop/content/431960")
        if let steam { candidates.append(steam) }
        return candidates
    }

    private static func firstExistingExecutable(
        candidates: [URL],
        fileManager: FileManager
    ) -> URL? {
        candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
                && !isSymbolicLink($0, fileManager: fileManager)
        }
    }

    private static func firstExistingDirectory(
        candidates: [URL],
        fileManager: FileManager
    ) -> URL? {
        candidates.first {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && !isSymbolicLink($0, fileManager: fileManager)
        }
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// Web projects use Mirage's WebKit-based renderer and do not need the Scene
/// assets directory.  It is kept as a separate status type so a missing Web
/// helper does not make the working Scene path look broken.
struct WebRendererToolchainStatus: Sendable {
    let rendererURL: URL?
    let missingRequirements: [String]

    var isReady: Bool { rendererURL != nil && missingRequirements.isEmpty }

    var summary: String {
        if isReady { return "Web renderer 已就緒" }
        if let first = missingRequirements.first {
            return "Web renderer 尚未就緒：" + first
        }
        return "Web renderer 尚未設定"
    }

    static func inspect(
        rendererURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WebRendererToolchainStatus {
        let fileManager = FileManager.default
        let resolved = rendererURL ?? firstExistingExecutable(
            candidates: rendererCandidates(environment: environment),
            fileManager: fileManager
        )
        return WebRendererToolchainStatus(
            rendererURL: resolved,
            missingRequirements: resolved == nil ? ["Web renderer 執行檔"] : []
        )
    }

    private static func rendererCandidates(environment: [String: String]) -> [URL] {
        var candidates: [URL] = []
        if let configured = environment["SCENE_HARBOR_WEB_RENDERER"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(Bundle.main.bundleURL.appending(path: "Contents/Helpers/SceneHarborWebRenderer"))
            candidates.append(resources.appending(path: "SceneHarborWebRenderer"))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appending(path: "SceneHarborWebRenderer"))
        }
        return candidates
    }

    private static func firstExistingExecutable(
        candidates: [URL],
        fileManager: FileManager
    ) -> URL? {
        candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
                && (try? fileManager.destinationOfSymbolicLink(atPath: $0.path)) == nil
        }
    }
}

enum SceneRendererBridgeError: LocalizedError {
    case rendererNotReady(SceneRendererToolchainStatus)
    case scenePackageMissing(URL)
    case wallpaperDirectoryMissing(URL)
    case portableVulkanFrameworksMissing(URL)
    case portableVulkanLibraryMissing(URL)
    case portableVulkanICDMissing(URL)
    case processAlreadyRunning
    case processNotRunning

    var errorDescription: String? {
        switch self {
        case let .rendererNotReady(status):
            return status.summary
        case let .scenePackageMissing(url):
            return "找不到 Scene package：" + url.path
        case let .wallpaperDirectoryMissing(url):
            return "找不到 Wallpaper Engine Web 作品資料夾：" + url.path
        case let .portableVulkanFrameworksMissing(url):
            return "找不到 Scene renderer 的 Vulkan Frameworks：" + url.path
        case let .portableVulkanLibraryMissing(url):
            return "找不到 Scene renderer 的 Vulkan 動態函式庫：" + url.path
        case let .portableVulkanICDMissing(url):
            return "找不到 Scene renderer 的 Vulkan ICD 設定：" + url.path
        case .processAlreadyRunning:
            return "Scene renderer 已在執行"
        case .processNotRunning:
            return "Scene renderer 尚未執行"
        }
    }
}

/// A small, line-oriented host for the renderer protocol used by Mirage's
/// SceneWallpaper process.  It is intentionally not tied to the current video
/// window implementation; the child process owns its desktop-level window.
@MainActor
final class SceneRendererBridge: NSObject {
    private(set) var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var temporaryFiles: [URL] = []
    /// Every launch gets a new identity.  Termination and readability
    /// callbacks are delivered asynchronously by Process/Pipe, so a callback
    /// from an older child must never mutate the state of a newer child.
    private var launchGeneration: UInt = 0

    var onEvent: (([String: Any]) -> Void)?
    var onOutput: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    func launch(
        rendererURL: URL,
        assetsURL: URL,
        scenePackageURL: URL,
        displayID: CGDirectDisplayID,
        fps: Int = 30,
        renderScale: Double = 1,
        muted: Bool = true,
        deferredShow: Bool = true,
        acceptsExternalSpectrum: Bool = true,
        previewResolution: CGSize? = nil
    ) throws {
        guard process == nil else { throw SceneRendererBridgeError.processAlreadyRunning }
        guard FileManager.default.fileExists(atPath: scenePackageURL.path) else {
            throw SceneRendererBridgeError.scenePackageMissing(scenePackageURL)
        }

        var arguments: [String] = [
            assetsURL.path,
            scenePackageURL.path,
            "--fps", String(max(5, fps)),
            "--render-scale", String(format: "%.3f", min(max(renderScale, 0.25), 1)),
            "--display-id", String(displayID),
            "--metalfx",
            "--control-stdin"
        ]
        if let size = previewResolution { arguments += ["--resolution", "\(Int(size.width))x\(Int(size.height))"] }
        arguments.append(acceptsExternalSpectrum ? "--external-spectrum" : "--no-spectrum")
        if muted { arguments.append("--muted") }
        if deferredShow { arguments.append("--deferred-show") }
        try launchProcess(executableURL: rendererURL, arguments: arguments, configurePortableVulkan: true)
    }

    func launchWeb(
        rendererURL: URL,
        wallpaperDirectoryURL: URL,
        displayID: CGDirectDisplayID,
        fps: Int = 30,
        volume: Double = 0,
        deferredShow: Bool = true,
        networkPolicy: String = "block",
        acceptsExternalSpectrum: Bool = true,
        previewOnly: Bool = false,
        widescreenPreview: Bool = false
    ) throws {
        guard FileManager.default.fileExists(atPath: wallpaperDirectoryURL.path) else {
            throw SceneRendererBridgeError.wallpaperDirectoryMissing(wallpaperDirectoryURL)
        }
        try launchProcess(
            executableURL: rendererURL,
            arguments: [
                wallpaperDirectoryURL.path,
                "--fps", String(max(5, fps)),
                "--volume", String(format: "%.3f", min(max(volume, 0), 1)),
                "--display-id", String(displayID),
                "--network-policy", networkPolicy,
                "--control-stdin"
            ] + (acceptsExternalSpectrum && !previewOnly ? ["--external-spectrum"] : ["--no-spectrum"]) + (deferredShow ? ["--deferred-show"] : []) + (previewOnly ? ["--preview-only"] : [])
              + (previewOnly && widescreenPreview ? ["--preview-widescreen"] : []),
            configurePortableVulkan: false
        )
    }

    private func launchProcess(
        executableURL: URL,
        arguments: [String],
        configurePortableVulkan: Bool
    ) throws {
        guard process == nil else { throw SceneRendererBridgeError.processAlreadyRunning }

        let portableVulkan: PortableVulkanRuntime?
        if configurePortableVulkan {
            portableVulkan = try portableVulkanRuntime(for: executableURL)
        } else {
            portableVulkan = nil
        }

        launchGeneration &+= 1
        let generation = launchGeneration
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        child.currentDirectoryURL = portableVulkan?.frameworksURL
        if let portableVulkan {
            var environment = ProcessInfo.processInfo.environment
            environment["VK_DRIVER_FILES"] = portableVulkan.icdURL.path
            environment["VK_ICD_FILENAMES"] = portableVulkan.icdURL.path
            child.environment = environment
        }
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(data, generation: generation)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self, self.launchGeneration == generation else { return }
                self.onOutput?(text)
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in
                self?.handleTermination(of: child, generation: generation)
            }
        }

        outputBuffer.removeAll(keepingCapacity: true)
        inputPipe = input
        outputPipe = output
        errorPipe = errors
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            closePipes()
            throw error
        }
    }

    private struct PortableVulkanRuntime {
        let frameworksURL: URL
        let icdURL: URL
    }

    private func portableVulkanRuntime(for executableURL: URL) throws -> PortableVulkanRuntime? {
        let fileManager = FileManager.default
        let helpersURL = executableURL.deletingLastPathComponent()
        let contentsURL = helpersURL.deletingLastPathComponent()
        let appURL = contentsURL.deletingLastPathComponent()
        // Test and development launchers may intentionally provide a renderer
        // outside an app bundle. Preserve that contract; the portable closure
        // is required only for the shipped Contents/Helpers renderer.
        guard helpersURL.lastPathComponent == "Helpers",
              contentsURL.lastPathComponent == "Contents",
              appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }

        let frameworksURL = helpersURL.appending(path: "Frameworks")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: frameworksURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SceneRendererBridgeError.portableVulkanFrameworksMissing(frameworksURL)
        }

        for name in ["libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib"] {
            let libraryURL = frameworksURL.appending(path: name)
            guard fileManager.fileExists(atPath: libraryURL.path) else {
                throw SceneRendererBridgeError.portableVulkanLibraryMissing(libraryURL)
            }
        }

        let icdURL = contentsURL.appending(path: "Resources/vulkan/icd.d/MoltenVK_icd.json")
        guard fileManager.fileExists(atPath: icdURL.path) else {
            throw SceneRendererBridgeError.portableVulkanICDMissing(icdURL)
        }
        return PortableVulkanRuntime(frameworksURL: frameworksURL, icdURL: icdURL)
    }

    func send(_ command: [String: Any]) throws {
        guard isRunning, let inputPipe else {
            throw SceneRendererBridgeError.processNotRunning
        }
        let data = try JSONSerialization.data(withJSONObject: command, options: [])
        var line = data
        line.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: line)
    }

    func activate() throws { try send(["cmd": "activate"]) }
    func deactivate() throws { try send(["cmd": "deactivate"]) }
    func pause() throws { try send(["cmd": "power", "state": "pause"]) }
    func resume(fps: Int = 30) throws {
        try send(["cmd": "power", "state": "run", "fps": max(5, fps)])
    }
    func setFps(_ fps: Int) throws { try send(["cmd": "fps", "value": max(5, fps)]) }
    func setVolume(_ volume: Double) throws {
        try send(["cmd": "volume", "value": min(max(volume, 0), 1)])
    }
    func setMuted(_ muted: Bool) throws { try send(["cmd": "muted", "value": muted]) }
    func setHorizontalFlip(_ enabled: Bool) throws { try send(["cmd": "flip", "value": enabled]) }

    func stop() {
        let oldProcess = process
        if oldProcess?.isRunning == true { try? send(["cmd": "quit"]) }

        // Invalidate callbacks before terminating the old child.  Its
        // terminationHandler can run after a subsequent launch and must not
        // clear that launch's pipes or process reference.
        launchGeneration &+= 1
        closePipes()
        process = nil
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
        removeTemporaryFiles()
    }

    private func consumeOutput(_ data: Data, generation: UInt) {
        guard self.launchGeneration == generation else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            guard self.launchGeneration == generation else { return }
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            onOutput?(line)
            guard self.launchGeneration == generation else { return }
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let event = json as? [String: Any] else { continue }
            onEvent?(event)
            guard self.launchGeneration == generation else { return }
        }
        if outputBuffer.count > 1_048_576 { outputBuffer.removeAll() }
    }

    private func handleTermination(of child: Process, generation: UInt) {
        guard launchGeneration == generation,
              let current = process,
              current === child else { return }
        launchGeneration &+= 1
        closePipes()
        process = nil
        removeTemporaryFiles()
        onTermination?(child.terminationStatus)
    }

    private func closePipes() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func removeTemporaryFiles() {
        for file in temporaryFiles {
            try? FileManager.default.removeItem(at: file)
        }
        temporaryFiles.removeAll()
    }
}
