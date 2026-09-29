import Foundation

struct HarborLockStorePaths: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    init(applicationSupportDirectory: URL? = nil) {
        let support = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        self.init(root: support.appending(path: "SceneHarbor/LockScreen", directoryHint: .isDirectory))
    }

    var configuration: URL { root.appending(path: "dynamic-lock-screen.json") }
    var backup: URL { root.appending(path: "dynamic-lock-screen-backup.json") }
    var state: URL { root.appending(path: "dynamic-lock-screen-state.json") }
}

private struct HarborLockTransaction: Codable, Equatable, Sendable {
    let version: Int
    let beforeDigest: String
    var activeDigest: String
    /// When a later playlist rotation is prepared, this records the digest
    /// currently on disk.  If the process stops after writing state but
    /// before writing the new configuration, recovery can return to this
    /// active configuration instead of reporting a permanent conflict.
    var previousActiveDigest: String?
    let hadPreviousConfiguration: Bool
    let startedAt: Date
    var updatedAt: Date
}

final class HarborLockConfigurationStore {
    private let fileManager: FileManager
    private let paths: HarborLockStorePaths
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(paths: HarborLockStorePaths = HarborLockStorePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        decoder.dateDecodingStrategy = .iso8601
    }

    var configurationURL: URL { paths.configuration }
    var rootURL: URL { paths.root }

    func load() throws -> HarborLockConfiguration {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: paths.configuration)
        let configuration = try decoder.decode(HarborLockConfiguration.self, from: data)
        guard configuration.isValid else { throw HarborLockError.invalidConfiguration }
        return configuration
    }

    func loadIfPresent() throws -> HarborLockConfiguration? {
        guard fileManager.fileExists(atPath: paths.configuration.path) else { return nil }
        return try load()
    }

    func currentData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: paths.configuration.path) else { return nil }
        return try Data(contentsOf: paths.configuration)
    }

    func currentDigest() throws -> String {
        HarborLockDigest.hex(try currentData() ?? Data())
    }

    /// Atomically publishes a new lock configuration.  Once the first commit
    /// succeeds, subsequent commits are allowed only when the current file is
    /// still the last file written by this store.  This lets the existing
    /// playlist rotate without creating a second timer while still rejecting
    /// an external edit.
    @discardableResult
    func commit(_ configuration: HarborLockConfiguration, expectedCurrentDigest: String? = nil) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard configuration.isValid else { throw HarborLockError.invalidConfiguration }
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)

        var transaction = try loadTransactionLocked()
        if transaction == nil, fileManager.fileExists(atPath: paths.backup.path) {
            throw HarborLockError.orphanedBackup
        }

        let current = try readDataLocked(at: paths.configuration)
        let currentDigest = HarborLockDigest.hex(current ?? Data())
        if let expectedCurrentDigest, expectedCurrentDigest != currentDigest {
            throw HarborLockError.configurationConflict
        }

        if let existing = transaction {
            guard existing.activeDigest == currentDigest else {
                throw HarborLockError.configurationConflict
            }
            transaction = existing
            transaction?.previousActiveDigest = currentDigest
        } else {
            let hadPrevious = current != nil
            if let current {
                try writeAtomicallyLocked(current, to: paths.backup)
            }
            transaction = HarborLockTransaction(
                version: 1,
                beforeDigest: currentDigest,
                activeDigest: "",
                previousActiveDigest: nil,
                hadPreviousConfiguration: hadPrevious,
                startedAt: Date(),
                updatedAt: Date()
            )
        }

        let data = try encoder.encode(configuration)
        let activeDigest = HarborLockDigest.hex(data)
        transaction?.activeDigest = activeDigest
        transaction?.updatedAt = Date()
        guard let transaction else { throw HarborLockError.invalidConfiguration }
        try writeAtomicallyLocked(try encoder.encode(transaction), to: paths.state)
        try writeAtomicallyLocked(data, to: paths.configuration)
        // A second state write marks the config publication complete.  If it
        // fails after the config is already atomic, recovery sees
        // currentDigest == activeDigest and can safely clear the pending
        // marker on its next launch rather than treating it as a conflict.
        var committed = transaction
        committed.previousActiveDigest = nil
        committed.updatedAt = Date()
        try? writeAtomicallyLocked(try encoder.encode(committed), to: paths.state)
        return activeDigest
    }

    /// Removes the active SceneHarbor lock configuration and restores the
    /// exact previous SceneHarbor configuration only if no external writer
    /// changed the active file.  The Apple wallpaper store is deliberately
    /// outside this type and is never touched here.
    @discardableResult
    func restorePreviousConfiguration() throws -> HarborLockStoreRecovery {
        lock.lock()
        defer { lock.unlock() }
        guard let transaction = try loadTransactionLocked() else {
            if fileManager.fileExists(atPath: paths.backup.path) {
                throw HarborLockError.orphanedBackup
            }
            throw HarborLockError.noTransaction
        }
        let current = try readDataLocked(at: paths.configuration)
        let currentDigest = HarborLockDigest.hex(current ?? Data())
        guard currentDigest == transaction.activeDigest else {
            throw HarborLockError.recoveryConflict
        }

        if transaction.hadPreviousConfiguration {
            guard let previous = try readDataLocked(at: paths.backup) else {
                throw HarborLockError.orphanedBackup
            }
            try writeAtomicallyLocked(previous, to: paths.configuration)
        } else if fileManager.fileExists(atPath: paths.configuration.path) {
            try fileManager.removeItem(at: paths.configuration)
        }
        removeTransactionArtifactsLocked()
        return .rolledBack
    }

    /// Verifies an interrupted atomic update without overwriting an external
    /// edit.  A valid active transaction is intentionally retained because a
    /// later playlist rotation may still need to update the same lock source.
    func recoverIfNeeded() throws -> HarborLockStoreRecovery {
        lock.lock()
        defer { lock.unlock() }
        guard let transaction = try loadTransactionLocked() else {
            if fileManager.fileExists(atPath: paths.backup.path) {
                throw HarborLockError.orphanedBackup
            }
            return .clean
        }
        let current = try readDataLocked(at: paths.configuration)
        let currentDigest = HarborLockDigest.hex(current ?? Data())
        if currentDigest == transaction.activeDigest {
            if transaction.previousActiveDigest != nil {
                var committed = transaction
                committed.previousActiveDigest = nil
                committed.updatedAt = Date()
                try? writeAtomicallyLocked(try encoder.encode(committed), to: paths.state)
            }
            return .clean
        }
        if let previousActiveDigest = transaction.previousActiveDigest,
           currentDigest == previousActiveDigest {
            var rolledBack = transaction
            rolledBack.activeDigest = previousActiveDigest
            rolledBack.previousActiveDigest = nil
            rolledBack.updatedAt = Date()
            try writeAtomicallyLocked(try encoder.encode(rolledBack), to: paths.state)
            return .rolledBack
        }
        if currentDigest == transaction.beforeDigest {
            removeTransactionArtifactsLocked()
            return .rolledBack
        }
        return .conflict
    }

    func removeAllOwnedState() throws {
        lock.lock()
        defer { lock.unlock() }
        removeTransactionArtifactsLocked()
        if fileManager.fileExists(atPath: paths.configuration.path) {
            try fileManager.removeItem(at: paths.configuration)
        }
    }

    private func loadTransactionLocked() throws -> HarborLockTransaction? {
        guard let data = try readDataLocked(at: paths.state) else { return nil }
        return try decoder.decode(HarborLockTransaction.self, from: data)
    }

    private func readDataLocked(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func writeAtomicallyLocked(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func removeTransactionArtifactsLocked() {
        try? fileManager.removeItem(at: paths.state)
        try? fileManager.removeItem(at: paths.backup)
    }
}
