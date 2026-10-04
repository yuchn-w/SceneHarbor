import Combine
import Foundation
import LocalAuthentication
import OSLog
import Security

struct SteamDownloadProgress: Identifiable, Equatable {
    let taskID: String
    let workshopID: String
    var state: String
    var progress: Double
    var speed: String
    var message: String?

    var id: String { taskID }
}

private enum SteamServiceKeychain {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SceneHarbor",
        category: "Keychain"
    )

    static func value(service: String, account: String) -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Session restoration runs in the background at launch. Do not
            // put a password dialog over the user's work when an old/ad-hoc
            // build's Keychain ACL needs re-authorization. Explicit login can
            // still save a new session after the user starts that action.
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain read failed with OSStatus \(status)")
            }
            return nil
        }
        guard let data = result as? Data else {
            logger.error("Keychain read returned an unexpected value")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, service: String, account: String) -> OSStatus {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        if updateStatus != errSecItemNotFound {
            logger.error("Keychain update failed with OSStatus \(updateStatus)")
            return updateStatus
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus != errSecSuccess {
            logger.error("Keychain add failed with OSStatus \(addStatus)")
        }
        return addStatus
    }

    @discardableResult
    static func remove(service: String, account: String) -> OSStatus {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed with OSStatus \(status)")
        }
        return status
    }
}

struct SteamServiceToolchainStatus: Sendable {
    let serviceURL: URL?
    let missingRequirements: [String]

    var isReady: Bool { serviceURL != nil && missingRequirements.isEmpty }

    var summary: String {
        if isReady { return "Steam 工坊服務已就緒" }
        if let first = missingRequirements.first {
            return "Steam 工坊服務尚未就緒：" + first
        }
        return "Steam 工坊服務尚未設定"
    }

    static func inspect(
        serviceURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SteamServiceToolchainStatus {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let configured = environment["SCENE_HARBOR_STEAM_SERVICE"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(Bundle.main.bundleURL.appending(path: "Contents/Helpers/SceneHarborSteamService"))
            candidates.append(resources.appending(path: "SceneHarborSteamService"))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appending(path: "SceneHarborSteamService"))
        }
        let resolved = serviceURL ?? candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
                && (try? fileManager.destinationOfSymbolicLink(atPath: $0.path)) == nil
        }
        return SteamServiceToolchainStatus(
            serviceURL: resolved,
            missingRequirements: resolved == nil ? ["Steam 工坊服務執行檔"] : []
        )
    }
}

@MainActor
final class SteamServiceBridge: ObservableObject {
    @Published private(set) var state = "Steam 工坊尚未啟動"
    @Published private(set) var authState = "loggedOut"
    @Published private(set) var accountName = ""
    @Published private(set) var challengeURL: URL?
    @Published private(set) var challengeMessage = ""
    @Published private(set) var authErrorCode = ""
    @Published private(set) var downloadState = ""
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadSpeed = ""
    @Published private(set) var downloads: [String: SteamDownloadProgress] = [:]
    /// Rebuilt once per published download snapshot so cards/inspector do not
    /// scan every task independently.
    var downloadByWorkshopID: [String: SteamDownloadProgress] {
        Dictionary(uniqueKeysWithValues: downloads.values.map { ($0.workshopID, $0) })
    }

    /// Queued, resolving, downloading, validating, and cancelling tasks all
    /// keep their Workshop staging directory protected. Only terminal states
    /// (`completed`, `failed`, `cancelled`) are safe to classify as inactive.
    var activeDownloadWorkshopIDs: Set<String> {
        Set(downloads.values.filter { !$0.isFinished }.map(\.workshopID))
    }

    private lazy var previewTransfers = HarborPreviewTransfers { [weak self] in self?.send($0) }
    func fetchPreviewContent(_ id: String, root: URL, progress: @escaping (Double) -> Void, prepare: @escaping () throws -> Void = {}) async throws -> URL {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw SteamWorkshopAPIError.invalidURL }
        guard isLoggedIn, isRunning else { throw SteamWorkshopAPIError.apiMessage("登入 Steam 即可載入動態預覽。") }
        return try await previewTransfers.fetch(id, root: root, progress: progress, prepare: prepare)
    }

    private var requests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var downloadRequests: [String: String] = [:]
    private var queuedDownloads: [String] = []
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var activeTaskID: String?
    // Keep this namespace stable. Changing it on every rebuild creates orphaned
    // Keychain entries and does not fix the underlying signing requirement.
    private let keychainService = "org.sceneharbor.SceneHarbor.SteamService.v2"
    private let usernameKey = "SceneHarborSteamUsername"
    private let sessionAccountKey = "SceneHarborSteamSessionAccount"
    private let rememberAccountKey = "SceneHarborRememberSteamAccount"
    private let rememberSessionKey = "SceneHarborRememberSteamSession"
    private var shouldRememberAccount = true
    private var shouldRememberSession = true

    private var sessionPersistenceDisabled: Bool {
        ProcessInfo.processInfo.environment["SCENE_HARBOR_DISABLE_SESSION_PERSISTENCE"] == "1"
    }

    var isRunning: Bool { process?.isRunning == true }
    var isLoggedIn: Bool { authState == "loggedIn" }
    var isSessionPersistenceDisabled: Bool { sessionPersistenceDisabled }

    func start() {
        guard process == nil else { return }
        let toolchain = SteamServiceToolchainStatus.inspect()
        guard let serviceURL = toolchain.serviceURL else {
            state = toolchain.summary
            return
        }

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let child = Process()
        child.executableURL = serviceURL
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.state = "Steam 服務：" + message
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.process === child else { return }
                self.inputPipe?.fileHandleForWriting.closeFile()
                self.inputPipe = nil
                self.outputPipe = nil
                self.errorPipe = nil
                self.process = nil
                self.state = "Steam 工坊服務已停止"
                self.authState = "loggedOut"
                self.failRequests()
                self.failDownloads("Steam 服務已停止，請重新登入後重試。")
            }
        }

        inputPipe = input
        outputPipe = output
        errorPipe = errors
        process = child
        do {
            try child.run()
            state = "Steam 工坊服務已啟動"
            send(["command": "hello", "requestId": UUID().uuidString])
            restoreSessionIfAvailable()
        } catch {
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            state = "Steam 服務啟動失敗：" + error.localizedDescription
        }
    }

    func loginWithQR(rememberAccount: Bool = true, rememberSession: Bool = true) {
        preparePersistence(rememberAccount: rememberAccount, rememberSession: rememberSession)
        start()
        challengeURL = nil
        authErrorCode = ""
        challengeMessage = "正在向 Steam 申請 QR 登入…"
        send(["command": "loginQr", "requestId": UUID().uuidString])
    }

    func login(username: String, password: String, rememberAccount: Bool = true, rememberSession: Bool = true) {
        preparePersistence(rememberAccount: rememberAccount, rememberSession: rememberSession)
        start()
        challengeURL = nil
        authErrorCode = ""
        challengeMessage = "正在登入 Steam…"
        let oldUsername = UserDefaults.standard.string(forKey: sessionAccountKey)
            ?? UserDefaults.standard.string(forKey: usernameKey)
            ?? ""
        if rememberAccount {
            UserDefaults.standard.set(username, forKey: usernameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: usernameKey)
        }
        if rememberSession {
            UserDefaults.standard.set(username, forKey: sessionAccountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionAccountKey)
            if !oldUsername.isEmpty {
                let service = keychainService
                let oldRefreshAccount = refreshTokenAccount(oldUsername)
                let oldGuardAccount = guardDataAccount(oldUsername)
                if !sessionPersistenceDisabled {
                    Task.detached {
                        _ = SteamServiceKeychain.remove(service: service, account: oldRefreshAccount)
                        _ = SteamServiceKeychain.remove(service: service, account: oldGuardAccount)
                    }
                }
            }
        }
        let service = keychainService
        let guardAccount = guardDataAccount(username)
        let persistenceDisabled = sessionPersistenceDisabled
        Task.detached { [weak self] in
            let guardData = persistenceDisabled
                ? nil
                : SteamServiceKeychain.value(service: service, account: guardAccount)
            await MainActor.run { [weak self] in
                var command: [String: Any] = [
                    "command": "loginPassword",
                    "requestId": UUID().uuidString,
                    "username": username,
                    "password": password
                ]
                if let guardData, !guardData.isEmpty {
                    command["guardData"] = guardData
                }
                self?.send(command)
            }
        }
    }

    func submitChallenge(_ code: String) {
        send(["command": "submitChallenge", "requestId": UUID().uuidString, "code": code])
    }

    func cancelLogin() {
        send(["command": "cancelLogin", "requestId": UUID().uuidString])
        challengeURL = nil
        challengeMessage = ""
    }

    func logout() {
        send(["command": "logout", "requestId": UUID().uuidString])
        let username = UserDefaults.standard.string(forKey: sessionAccountKey)
            ?? UserDefaults.standard.string(forKey: usernameKey)
            ?? ""
        let service = keychainService
        let refreshAccount = refreshTokenAccount(username)
        let guardAccount = guardDataAccount(username)
        if !sessionPersistenceDisabled {
            Task.detached {
                _ = SteamServiceKeychain.remove(service: service, account: refreshAccount)
                _ = SteamServiceKeychain.remove(service: service, account: guardAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: sessionAccountKey)
        authState = "loggedOut"
        accountName = ""
        authErrorCode = ""
    }

    func clearSavedSession() {
        let username = UserDefaults.standard.string(forKey: sessionAccountKey)
            ?? UserDefaults.standard.string(forKey: usernameKey)
            ?? ""
        let service = keychainService
        if !username.isEmpty {
            let refreshAccount = refreshTokenAccount(username)
            let guardAccount = guardDataAccount(username)
            Task.detached {
                SteamServiceKeychain.remove(service: service, account: refreshAccount)
                SteamServiceKeychain.remove(service: service, account: guardAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: sessionAccountKey)
    }

    @discardableResult
    func download(workshopID: String) -> String? {
        let trimmed = workshopID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty else {
            downloadState = "請輸入純數字的 Workshop ID"
            return nil
        }
        guard isLoggedIn, isRunning else {
            downloadState = "請先登入 Steam"
            return nil
        }
        if let existing = downloads.values.first(where: {
            $0.workshopID == trimmed && !["completed", "failed", "cancelled"].contains($0.state)
        }) { return existing.taskID }
        downloads = downloads.filter { $0.value.workshopID != trimmed }
        let taskID = UUID().uuidString
        activeTaskID = taskID
        downloadState = "正在準備下載…"
        downloadProgress = 0
        downloads[taskID] = SteamDownloadProgress(
            taskID: taskID,
            workshopID: trimmed,
            state: "queued",
            progress: 0,
            speed: "",
            message: nil
        )
        queuedDownloads.append(taskID)
        pumpDownloads()
        return taskID
    }

    private func pumpDownloads() {
        guard isRunning, isLoggedIn else { return }
        let active = downloads.values.filter { !$0.isFinished && $0.state != "queued" }.count
        for _ in active..<max(active, 3) {
            guard !queuedDownloads.isEmpty else { break }
            let taskID = queuedDownloads.removeFirst()
            guard var item = downloads[taskID], item.state == "queued" else { continue }
            item.state = "resolving"
            downloads[taskID] = item
            let requestID = UUID().uuidString
            downloadRequests[requestID] = taskID
            send([
            "command": "download",
            "requestId": requestID,
            "taskId": taskID,
            "workshopId": item.workshopID,
            "outputRoot": managedWorkshopDirectory().path
            ])
        }
    }

    private func failDownloads(_ message: String) {
        queuedDownloads.removeAll()
        downloadRequests.removeAll()
        for key in Array(downloads.keys) where downloads[key]?.isFinished == false {
            downloads[key]?.state = "failed"
            downloads[key]?.message = message
        }
    }

    func cancelDownload() {
        guard let activeTaskID else { return }
        cancelDownload(taskID: activeTaskID)
    }

    func cancelDownload(taskID: String) {
        if downloads[taskID]?.state == "queued" {
            queuedDownloads.removeAll { $0 == taskID }
            downloads[taskID]?.state = "cancelled"
            return
        }
        send(["command": "cancelDownload", "requestId": UUID().uuidString, "taskId": taskID])
    }

    func stop() {
        failRequests()
        failDownloads("Steam 服務已停止")
        if isRunning { send(["command": "shutdown", "requestId": UUID().uuidString]) }
        inputPipe?.fileHandleForWriting.closeFile()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func restoreSessionIfAvailable() {
        guard !sessionPersistenceDisabled else { return }
        shouldRememberAccount = UserDefaults.standard.object(forKey: rememberAccountKey) as? Bool ?? true
        shouldRememberSession = UserDefaults.standard.object(forKey: rememberSessionKey) as? Bool ?? true
        guard shouldRememberSession else { return }
        let username = UserDefaults.standard.string(forKey: sessionAccountKey)
            ?? UserDefaults.standard.string(forKey: usernameKey)
            ?? ""
        guard !username.isEmpty else { return }
        let service = keychainService
        let account = refreshTokenAccount(username)
        Task.detached { [weak self] in
            guard let token = SteamServiceKeychain.value(service: service, account: account),
                  !token.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.send([
                    "command": "restoreSession",
                    "requestId": UUID().uuidString,
                    "username": username,
                    "refreshToken": token
                ])
            }
        }
    }

    func accountLibrary(category: String, startIndex: Int) async throws -> [String: Any] {
        try await request(["command": "accountLibrary", "text": category, "startIndex": startIndex])
    }

    func setSubscription(_ id: String, subscribed: Bool) async throws {
        _ = try await request(["command": subscribed ? "subscribe" : "unsubscribe", "workshopId": id])
    }

    func setFavorite(_ id: String, favorite: Bool) async throws {
        _ = try await request(["command": favorite ? "favorite" : "unfavorite", "workshopId": id])
    }

    private func request(_ command: [String: Any]) async throws -> [String: Any] {
        guard isLoggedIn, isRunning else {
            throw SteamWorkshopAPIError.apiMessage("請先登入 Steam，才能讀取你的作品。")
        }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            requests[id] = continuation
            var payload = command
            payload["requestId"] = id
            send(payload)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                self?.requests.removeValue(forKey: id)?.resume(throwing:
                    SteamWorkshopAPIError.apiMessage("讀取作品逾時，請重試。"))
            }
        }
    }

    private func failRequests() {
        previewTransfers.failAll()
        let pending = Array(requests.values)
        requests.removeAll()
        for request in pending {
            request.resume(throwing: SteamWorkshopAPIError.apiMessage("Steam 連線已結束，請重新登入。"))
        }
    }

    private func send(_ command: [String: Any]) {
        guard isRunning, let inputPipe,
              JSONSerialization.isValidJSONObject(command) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        var line = data
        line.append(0x0A)
        try? inputPipe.fileHandleForWriting.write(contentsOf: line)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let payload = object as? [String: Any] else { continue }
            handle(payload)
        }
        if outputBuffer.count > 1_048_576 { outputBuffer.removeAll() }
    }

    private func handle(_ payload: [String: Any]) {
        if previewTransfers.handle(payload) { return }
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "hello":
            state = "Steam 工坊服務可用"
        case "response":
            if let id = payload["requestId"] as? String,
               let taskID = downloadRequests.removeValue(forKey: id),
               payload["success"] as? Bool != true {
                downloads[taskID]?.state = "failed"
                downloads[taskID]?.message = payload["message"] as? String ?? "Steam 拒絕下載，請重試。"
                pumpDownloads()
            }
            if let id = payload["requestId"] as? String,
               let continuation = requests.removeValue(forKey: id) {
                if payload["success"] as? Bool == true {
                    continuation.resume(returning: payload["data"] as? [String: Any] ?? [:])
                } else {
                    continuation.resume(throwing: SteamWorkshopAPIError.apiMessage(
                        payload["message"] as? String ?? "讀取 Steam 作品失敗。"))
                }
                return
            }
            let success = payload["success"] as? Bool ?? false
            let message = payload["message"] as? String
            if !success, let message {
                state = "Steam 服務：" + message
            }
        case "authState":
            handleAuthState(payload)
        case "downloadState":
            handleDownloadState(payload)
        default:
            break
        }
    }

    private func handleAuthState(_ payload: [String: Any]) {
        guard let nextState = payload["state"] as? String else { return }
        authState = nextState
        authErrorCode = payload["errorCode"] as? String ?? ""
        accountName = payload["accountName"] as? String ?? accountName
        challengeMessage = payload["message"] as? String ?? ""
        if let urlString = payload["challengeUrl"] as? String {
            challengeURL = URL(string: urlString)
        }
        if nextState == "loggedIn" {
            state = accountName.isEmpty ? "Steam 已登入" : "Steam 已登入：" + accountName
            let resolvedUsername = accountName.isEmpty
                ? (UserDefaults.standard.string(forKey: sessionAccountKey) ?? "")
                : accountName
            if shouldRememberAccount, !resolvedUsername.isEmpty {
                UserDefaults.standard.set(resolvedUsername, forKey: usernameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: usernameKey)
            }
            if shouldRememberSession, !resolvedUsername.isEmpty {
                UserDefaults.standard.set(resolvedUsername, forKey: sessionAccountKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sessionAccountKey)
            }
            let username = resolvedUsername
            if let token = payload["refreshToken"] as? String, !token.isEmpty {
                let service = keychainService
                let account = refreshTokenAccount(username)
                if shouldRememberSession, !sessionPersistenceDisabled {
                    Task.detached { _ = SteamServiceKeychain.save(token, service: service, account: account) }
                } else {
                    if !sessionPersistenceDisabled {
                        Task.detached { _ = SteamServiceKeychain.remove(service: service, account: account) }
                    }
                }
            }
            if let guardData = payload["guardData"] as? String, !guardData.isEmpty {
                let service = keychainService
                let account = guardDataAccount(username)
                if shouldRememberSession, !sessionPersistenceDisabled {
                    Task.detached { _ = SteamServiceKeychain.save(guardData, service: service, account: account) }
                } else {
                    if !sessionPersistenceDisabled {
                        Task.detached { _ = SteamServiceKeychain.remove(service: service, account: account) }
                    }
                }
            }
            challengeURL = nil
            challengeMessage = ""
        } else if nextState == "failed" {
            challengeURL = nil
            let code = authErrorCode.isEmpty ? "" : "（\(authErrorCode)）"
            state = "Steam 登入失敗\(code)：" + (challengeMessage.isEmpty ? "請查看登入面板中的錯誤訊息。" : challengeMessage)
        } else if nextState == "loggedOut" {
            state = "Steam 尚未登入"
            failRequests()
            failDownloads("Steam 已登出，請重新登入後重試。")
        } else {
            state = "Steam 登入狀態：" + nextState
        }
    }

    private func handleDownloadState(_ payload: [String: Any]) {
        guard let taskID = payload["taskId"] as? String else { return }
        let nextState = payload["state"] as? String ?? ""
        let received = payload["receivedBytes"] as? Double ?? 0
        let total = payload["totalBytes"] as? Double ?? 0
        let progress = total > 0 ? min(max(received / total, 0), 1) : 0
        var speedText = downloads[taskID]?.speed ?? ""
        if let speed = payload["bytesPerSecond"] as? Double, speed > 0 {
            speedText = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
        }
        let message = payload["message"] as? String
        let workshopID = downloads[taskID]?.workshopID ?? ""
        downloads[taskID] = SteamDownloadProgress(
            taskID: taskID,
            workshopID: workshopID,
            state: nextState,
            progress: nextState == "completed" ? 1 : progress,
            speed: speedText,
            message: message
        )

        if ["completed", "failed", "cancelled"].contains(nextState) { pumpDownloads() }

        guard taskID == activeTaskID else {
            if nextState == "completed" {
                NotificationCenter.default.post(name: .sceneHarborWorkshopDownloaded, object: nil)
            }
            return
        }

        downloadState = nextState
        downloadProgress = progress
        downloadSpeed = speedText
        if nextState == "completed" {
            downloadState = "下載完成"
            downloadProgress = 1
            activeTaskID = nil
            NotificationCenter.default.post(name: .sceneHarborWorkshopDownloaded, object: nil)
        } else if nextState == "failed" || nextState == "cancelled" {
            downloadState = message.map { nextState + "：" + $0 } ?? nextState
            activeTaskID = nil
        }
    }

    private func managedWorkshopDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appending(path: "SceneHarbor/Workshop/content/431960", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func refreshTokenAccount(_ username: String) -> String { "refreshToken." + username }
    private func guardDataAccount(_ username: String) -> String { "guardData." + username }

    private func preparePersistence(rememberAccount: Bool, rememberSession: Bool) {
        shouldRememberAccount = rememberAccount
        shouldRememberSession = rememberSession
        UserDefaults.standard.set(rememberAccount, forKey: rememberAccountKey)
        UserDefaults.standard.set(rememberSession, forKey: rememberSessionKey)
    }
}

extension Notification.Name {
    static let sceneHarborWorkshopDownloaded = Notification.Name("SceneHarborWorkshopDownloaded")
}
