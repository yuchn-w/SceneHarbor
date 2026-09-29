import Foundation

struct HarborNativeLockRequest: Sendable {
    let project: WallpaperEngineProject
    let settings: [String: HarborLockAnyValue]
    let displayID: UInt32

    init(project: WallpaperEngineProject, settings: [String: Any], displayID: UInt32) {
        self.project = project
        self.settings = settings.mapValues(HarborLockAnyValue.init)
        self.displayID = displayID
    }

    init(project: WallpaperEngineProject, encodedSettings: [String: HarborLockAnyValue], displayID: UInt32) {
        self.project = project
        self.settings = encodedSettings
        self.displayID = displayID
    }
}

struct HarborNativeLockPublishResult: Sendable {
    let wallpaperID: String
    let title: String
    let displayID: UInt32
    let configurationURL: URL
    let configurationDigest: String
    let deploymentURL: URL
}

private struct HarborNativeLockPreparedSource: Sendable {
    let request: HarborNativeLockRequest
    let source: HarborLockValidatedSource
    let deploymentURL: URL
}

/// Performs expensive source validation and copies away from the main actor.
/// Generations are per display: a newer choice for one display cannot erase a
/// concurrently prepared choice for another display, while an older cancelled
/// choice for the same display can never win the final atomic publish.
actor HarborNativeLockPublisher {
    private let paths: HarborNativeLockPaths
    private var generations: [UInt32: UInt64] = [:]
    private var generationCounter: UInt64 = 0
    /// Controller-owned epochs serialize enabled/disabled configuration
    /// mutations.  The actor may suspend while a large source is copied, so
    /// every commit checks this value again before touching the config file.
    private var latestOperationEpoch: UInt64 = 0

    init(paths: HarborNativeLockPaths) {
        self.paths = paths
    }

    func cancel(displayIDs: [UInt32]? = nil) {
        let ids = displayIDs ?? Array(generations.keys)
        for id in ids {
            generationCounter &+= 1
            generations[id] = generationCounter
        }
    }

    /// Publishes an enabled configuration for a controller-owned epoch.
    /// An older epoch is rejected even when its detached staging task happens
    /// to finish after a newer disable/re-enable operation.
    func publish(
        _ requests: [HarborNativeLockRequest],
        epoch: UInt64
    ) async throws -> [HarborNativeLockPublishResult] {
        guard acceptOperation(epoch) else { throw HarborNativeLockError.stalePublish }
        let uniqueRequests = Dictionary(
            requests.map { ($0.displayID, $0) },
            uniquingKeysWith: { _, newer in newer }
        ).values
        guard !uniqueRequests.isEmpty else { return [] }
        let ordered = uniqueRequests.sorted { $0.displayID < $1.displayID }
        var tokens: [UInt32: UInt64] = [:]
        for request in ordered {
            generationCounter &+= 1
            generations[request.displayID] = generationCounter
            tokens[request.displayID] = generationCounter
        }

        let paths = self.paths
        let prepared: [HarborNativeLockPreparedSource]
        do {
            let worker = Task.detached(priority: .utility) {
                try Self.prepare(ordered, paths: paths)
            }
            prepared = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
        } catch {
            throw error
        }

        guard isCurrent(tokens), isCurrentOperation(epoch), !Task.isCancelled else {
            cleanup(prepared)
            throw HarborNativeLockError.stalePublish
        }

        let store = HarborNativeLockAppGroupStore(paths: paths)
        let existing = try store.loadIfPresent()
        var displays = existing?.mode == .wallpaperExtension ? (existing?.displays ?? [:]) : [:]
        for item in prepared {
            displays["display-\(item.request.displayID)"] = Self.makeDisplay(item)
        }
        let configuration = HarborLockConfiguration(
            version: HarborLockConfiguration.currentVersion,
            enabled: true,
            mode: .wallpaperExtension,
            displays: displays,
            updatedAt: Date()
        )

        guard isCurrent(tokens), isCurrentOperation(epoch), !Task.isCancelled else {
            cleanup(prepared)
            throw HarborNativeLockError.stalePublish
        }

        let digest: String
        do {
            digest = try store.atomicWrite(configuration)
        } catch {
            cleanup(prepared)
            throw error
        }

        cleanupOldDeployments(configuration: configuration, preserving: prepared.map(\.deploymentURL))
        let results = prepared.map {
            HarborNativeLockPublishResult(
                wallpaperID: $0.request.project.id,
                title: $0.source.title,
                displayID: $0.request.displayID,
                configurationURL: paths.configurationURL,
                configurationDigest: digest,
                deploymentURL: $0.deploymentURL
            )
        }
        return results
    }

    /// Writes the disabled fallback through this same actor as publish.  It
    /// leaves notification delivery to the controller after this atomic write
    /// completes and its operation epoch is still current.
    func disable(epoch: UInt64) throws {
        guard acceptOperation(epoch) else { throw HarborNativeLockError.stalePublish }
        for id in generations.keys {
            generationCounter &+= 1
            generations[id] = generationCounter
        }
        _ = try HarborNativeLockAppGroupStore(paths: paths).disable()
    }

    private func isCurrent(_ tokens: [UInt32: UInt64]) -> Bool {
        tokens.allSatisfy { generations[$0.key] == $0.value }
    }

    private func acceptOperation(_ epoch: UInt64) -> Bool {
        guard epoch >= latestOperationEpoch else { return false }
        latestOperationEpoch = epoch
        return true
    }

    private func isCurrentOperation(_ epoch: UInt64) -> Bool {
        latestOperationEpoch == epoch
    }

    private nonisolated static func prepare(
        _ requests: [HarborNativeLockRequest],
        paths: HarborNativeLockPaths
    ) throws -> [HarborNativeLockPreparedSource] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.deploymentsURL, withIntermediateDirectories: true)
        var prepared: [HarborNativeLockPreparedSource] = []
        do {
            for request in requests {
                try Task.checkCancellation()
                let source = try HarborLockSourceValidator.validate(request.project)
                let deploymentURL = paths.deploymentsURL.appending(
                    path: "\(UUID().uuidString)-\(request.displayID)", directoryHint: .isDirectory
                )
                let renderURL = deploymentURL.appending(path: "render", directoryHint: .isDirectory)
                try fileManager.createDirectory(at: deploymentURL, withIntermediateDirectories: true)
                do {
                    let stagedEntry: URL
                    let stagedPreview: URL?
                    switch source.kind {
                    case .scene:
                        try fileManager.copyItem(at: source.renderDirectory, to: renderURL)
                        try Task.checkCancellation()
                        stagedEntry = try stagedURL(
                            for: source.entryURL, root: source.renderDirectory, destinationRoot: renderURL
                        )
                        stagedPreview = try source.previewURL.map {
                            try stagedURL(for: $0, root: source.renderDirectory, destinationRoot: renderURL)
                        }
                    case .video:
                        try fileManager.createDirectory(at: renderURL, withIntermediateDirectories: true)
                        stagedEntry = renderURL.appending(path: source.entryURL.lastPathComponent)
                        try fileManager.copyItem(at: source.entryURL, to: stagedEntry)
                        try Task.checkCancellation()
                        if let preview = source.previewURL {
                            let destination = renderURL.appending(path: preview.lastPathComponent)
                            try fileManager.copyItem(at: preview, to: destination)
                            stagedPreview = destination
                        } else {
                            stagedPreview = nil
                        }
                    }
                    let stagedSource = HarborLockValidatedSource(
                        projectID: source.projectID,
                        title: source.title,
                        kind: source.kind,
                        renderDirectory: renderURL,
                        entryURL: stagedEntry,
                        previewURL: stagedPreview,
                        fingerprint: source.fingerprint
                    )
                    prepared.append(HarborNativeLockPreparedSource(
                        request: request, source: stagedSource, deploymentURL: deploymentURL
                    ))
                } catch {
                    try? fileManager.removeItem(at: deploymentURL)
                    throw error
                }
            }
            return prepared
        } catch {
            for item in prepared { try? fileManager.removeItem(at: item.deploymentURL) }
            throw error
        }
    }

    private nonisolated static func stagedURL(for sourceURL: URL, root: URL, destinationRoot: URL) throws -> URL {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath.hasPrefix(rootPath + "/") else {
            throw HarborLockError.invalidEntrypoint(sourcePath)
        }
        let relative = String(sourcePath.dropFirst(rootPath.count + 1))
        let destination = destinationRoot.appending(path: relative)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw HarborLockError.invalidEntrypoint(destination.path)
        }
        return destination
    }

    private nonisolated static func makeDisplay(
        _ item: HarborNativeLockPreparedSource
    ) -> HarborLockDisplayConfiguration {
        let fps: Int
        if case let .number(value) = item.request.settings["__fps"] {
            let finite = value.isFinite ? value : 30
            fps = Int(min(max(finite, 10), 60).rounded())
        } else if case let .string(value) = item.request.settings["__fps"], let parsed = Int(value) {
            fps = min(max(parsed, 10), 60)
        } else {
            fps = 30
        }
        let fillMode: HarborLockFillMode
        if case let .string(value) = item.request.settings["__fill"] {
            fillMode = HarborLockFillMode(rawValue: value)
        } else {
            fillMode = .cover
        }
        let properties = item.request.settings.filter { !$0.key.hasPrefix("__") }
        return HarborLockDisplayConfiguration(
            displayID: item.request.displayID,
            wallpaperID: item.source.projectID,
            title: item.source.title,
            kind: item.source.kind,
            renderDirectory: item.source.renderDirectory.path,
            entryPath: item.source.entryURL.path,
            previewPath: item.source.previewURL?.path,
            runtimeProperties: properties,
            fps: fps,
            fillMode: fillMode,
            audioMuted: true,
            sourceFingerprint: item.source.fingerprint,
            desktopFallbackPath: item.source.previewURL?.path
        )
    }

    private func cleanup(_ prepared: [HarborNativeLockPreparedSource]) {
        for item in prepared { try? FileManager.default.removeItem(at: item.deploymentURL) }
    }

    private func cleanupOldDeployments(
        configuration: HarborLockConfiguration,
        preserving current: [URL]
    ) {
        let fileManager = FileManager.default
        let currentRoots = Set(current.map { $0.standardizedFileURL.path })
        let configuredRoots = Set(configuration.displays.values.map {
            URL(fileURLWithPath: $0.renderDirectory).deletingLastPathComponent().standardizedFileURL.path
        })
        let keep = currentRoots.union(configuredRoots)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.deploymentsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where !keep.contains(entry.standardizedFileURL.path) {
            try? fileManager.removeItem(at: entry)
        }
    }
}
