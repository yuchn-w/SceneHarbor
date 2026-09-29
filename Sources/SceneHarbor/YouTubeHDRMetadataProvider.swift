import Darwin
import Foundation

protocol YouTubeMetadataProviding: AnyObject {
    func warmup()
    func lookup(videoID: String, completion: @escaping (YouTubeMetadataResult) -> Void)
    func cancelAll()
    func diagnostics() -> YTDLPDiagnostics
}

enum YouTubeMetadataState: String, Codable, Sendable {
    case hdr
    case sdr
    case unknown
}

struct YouTubeMetadataResult: Sendable {
    let videoID: String
    let state: YouTubeMetadataState
    let dynamicRange: String?
    let cacheHit: Bool
    let detail: String
    let executableSource: String?
    let executablePath: String?
    let executableVersion: String?
    let exitCode: Int?
    let failureReason: String?
}

struct YTDLPDiagnostics: Sendable {
    let source: String
    let path: String
    let version: String
    let versionResult: String
    let metadataResult: String
    let metadataExitCode: Int?
    var metadataLaunchCount: Int = 0
}

/// 可替換的 metadata provider；只取得 YouTube metadata，絕不下載影片或音訊。
final class YTDLPMetadataProvider: YouTubeMetadataProviding {
    private let queue = DispatchQueue(label: "app.dynamicwallpaper.ytdlp", qos: .utility)
    private let versionQueue = DispatchQueue(label: "app.dynamicwallpaper.ytdlp.version", qos: .utility)
    private let cacheKey = "AutoHDR.YouTubeHDRCache"
    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60
    // YouTube metadata 的網路握手在部分網路環境可超過 10 秒；這仍在背景
    // queue 執行，成功後會進 30 天快取，不會在每次輪詢重複付出這個成本。
    private let metadataTimeout: TimeInterval
    private let preferences: UserDefaults
    private let executableOverride: URL?
    private let fastPathEnabled: Bool
    private let diagnosticsLock = NSLock()
    private let processLock = NSLock()
    private var activeProcess: Process?
    private var activeMetadataTask: URLSessionDataTask?
    private var cancellationGeneration = 0
    private var requestID: String?

    init(preferences: UserDefaults = .standard, executableOverride: URL? = nil,
         metadataTimeout: TimeInterval = 30, fastPathEnabled: Bool = true) {
        self.preferences = preferences
        self.executableOverride = executableOverride
        self.metadataTimeout = metadataTimeout
        self.fastPathEnabled = fastPathEnabled
    }

    func cancelAll() {
        processLock.lock()
        cancellationGeneration &+= 1
        requestID = nil
        if let process = activeProcess, process.isRunning { Self.stopProcessTree(process) }
        activeMetadataTask?.cancel()
        activeMetadataTask = nil
        processLock.unlock()
    }

    private var selectedExecutable: ExecutableCandidate?
    private var versionForPath = ""
    private var cachedVersion: String?
    private var versionResult = "尚未執行"
    private var metadataResult = "尚未執行"
    private var metadataExitCode: Int?
    private var metadataLaunchCount = 0

    /// 只先解析 App 內建 executable。PyInstaller 冷啟動可能需要數秒，
    /// 不可排在第一次 Watch metadata 判斷前面阻塞 Auto HDR。
    func warmup() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let executable = self.resolveExecutable() else {
                self.updateDiagnostics {
                    $0.selectedExecutable = nil
                    $0.versionForPath = ""
                    $0.cachedVersion = nil
                    $0.versionResult = "executable missing"
                }
                return
            }
            self.updateDiagnostics { $0.selectedExecutable = executable }
            self.versionQueue.async { [weak self] in _ = self?.version(for: executable) }
        }
    }

    func lookup(videoID: String, completion: @escaping (YouTubeMetadataResult) -> Void) {
        processLock.lock()
        if requestID != nil && requestID != videoID {
            cancellationGeneration &+= 1
            if let process = activeProcess, process.isRunning { Self.stopProcessTree(process) }
        }
        requestID = videoID
        let token = cancellationGeneration
        processLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.processLock.lock()
            let valid = token == self.cancellationGeneration
            self.processLock.unlock()
            guard valid else { return }
            self.lookupOnQueue(videoID: videoID, completion: completion)
        }
    }

    private func lookupOnQueue(videoID: String, completion: @escaping (YouTubeMetadataResult) -> Void) {
        if let cached = readCached(videoID: videoID) {
            let info = diagnosticsSnapshot()
            updateDiagnostics {
                $0.metadataResult = "cache hit · no metadata process"
                $0.metadataExitCode = nil
            }
            DispatchQueue.main.async {
                completion(YouTubeMetadataResult(
                    videoID: videoID,
                    state: cached.state,
                    dynamicRange: cached.dynamicRange,
                    cacheHit: true,
                    detail: "使用 30 天內的快取",
                    executableSource: info.source == "—" ? nil : info.source,
                    executablePath: info.path == "—" ? nil : info.path,
                    executableVersion: info.version == "Unknown" ? nil : info.version,
                    exitCode: nil,
                    failureReason: nil
                ))
            }
            return
        }

            let result = self.lookupWithoutCache(videoID: videoID)
            if result.state != .unknown {
                self.writeCached(
                    videoID: videoID,
                    state: result.state,
                    dynamicRange: result.dynamicRange
                )
            }
            DispatchQueue.main.async { completion(result) }
    }

    func diagnostics() -> YTDLPDiagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        let executable = selectedExecutable
        return YTDLPDiagnostics(
            source: executable?.source ?? "—",
            path: executable?.url.path ?? "—",
            version: cachedVersion ?? "Unknown",
            versionResult: versionResult,
            metadataResult: metadataResult,
            metadataExitCode: metadataExitCode,
            metadataLaunchCount: metadataLaunchCount
        )
    }

    private func lookupWithoutCache(videoID: String) -> YouTubeMetadataResult {
        guard let executable = resolveExecutable() else {
            updateDiagnostics {
                $0.selectedExecutable = nil
                $0.versionForPath = ""
                $0.cachedVersion = nil
                $0.versionResult = "executable missing"
                $0.metadataResult = "executable missing"
                $0.metadataExitCode = nil
            }
            return unknown(
                videoID: videoID,
                detail: "executable missing",
                failureReason: "executable missing"
            )
        }

        let currentDiagnostics = diagnosticsSnapshot()
        let knownVersion = currentDiagnostics.version == "Unknown" ? nil : currentDiagnostics.version
        // The Watch page already contains the active video's player response. This
        // metadata-only path normally finishes in ~1 s and avoids spawning Python.
        // yt-dlp remains the authoritative fallback whenever the response is absent,
        // challenged, malformed, or does not belong to the requested video.
        if fastPathEnabled,
           let fast = lookupFromWatchPage(videoID: videoID, executable: executable,
                                          executableVersion: knownVersion) {
            return fast
        }
        let executableVersion = version(for: executable)
        diagnosticsLock.lock()
        metadataLaunchCount += 1
        diagnosticsLock.unlock()
        let process = run(
            executable: executable.url,
            arguments: [
                "--ignore-config",
                "--no-plugin-dirs",
                "--dump-single-json",
                "--skip-download",
                "--simulate",
                "--no-playlist",
                "--no-cache-dir",
                "--socket-timeout", "6",
                "--retries", "0",
                "--extractor-retries", "0",
                "--no-warnings",
                "--no-progress",
                "https://www.youtube.com/watch?v=\(videoID)"
            ],
            timeout: metadataTimeout
        )

        if process.timedOut {
            updateMetadataDiagnostics(result: "timeout after \(metadataTimeout)s", exitCode: nil)
            return unknown(
                videoID: videoID,
                detail: "timeout after \(metadataTimeout)s",
                executable: executable,
                executableVersion: executableVersion,
                failureReason: "timeout after \(metadataTimeout)s"
            )
        }
        if let launchError = process.launchError {
            let reason = "process launch failure: \(launchError.localizedDescription)"
            updateMetadataDiagnostics(result: reason, exitCode: nil)
            return unknown(
                videoID: videoID,
                detail: reason,
                executable: executable,
                executableVersion: executableVersion,
                failureReason: reason
            )
        }
        guard process.exitCode == 0 else {
            let stderr = Self.tail(process.stderr)
            let reason = stderr.isEmpty
                ? "exit code \(process.exitCode)"
                : "exit code \(process.exitCode) · \(stderr)"
            updateMetadataDiagnostics(result: reason, exitCode: Int(process.exitCode))
            return unknown(
                videoID: videoID,
                detail: reason,
                executable: executable,
                executableVersion: executableVersion,
                exitCode: Int(process.exitCode),
                failureReason: reason
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: process.stdout) as? [String: Any],
              let formats = json["formats"] as? [[String: Any]],
              formats.contains(where: { ($0["vcodec"] as? String).map { $0 != "none" } == true })
        else {
            let reason = "metadata parse failure"
            updateMetadataDiagnostics(result: reason, exitCode: Int(process.exitCode))
            return unknown(
                videoID: videoID,
                detail: reason,
                executable: executable,
                executableVersion: executableVersion,
                exitCode: Int(process.exitCode),
                failureReason: reason
            )
        }

        let ranges = formats.compactMap(Self.hdrRange(in:))
        if let range = ranges.first {
            let detail = "metadata 標示：\(range)"
            updateMetadataDiagnostics(result: detail, exitCode: Int(process.exitCode))
            return YouTubeMetadataResult(
                videoID: videoID,
                state: .hdr,
                dynamicRange: range,
                cacheHit: false,
                detail: detail,
                executableSource: executable.source,
                executablePath: executable.url.path,
                executableVersion: executableVersion,
                exitCode: Int(process.exitCode),
                failureReason: nil
            )
        }

        let detail = "formats 沒有 HDR dynamic range"
        updateMetadataDiagnostics(result: detail, exitCode: Int(process.exitCode))
        return YouTubeMetadataResult(
            videoID: videoID,
            state: .sdr,
            dynamicRange: nil,
            cacheHit: false,
            detail: detail,
            executableSource: executable.source,
            executablePath: executable.url.path,
            executableVersion: executableVersion,
            exitCode: Int(process.exitCode),
            failureReason: nil
        )
    }

    private func lookupFromWatchPage(videoID: String, executable: ExecutableCandidate,
                                     executableVersion: String?) -> YouTubeMetadataResult? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.2)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/152 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        let semaphore = DispatchSemaphore(value: 0)
        let box = FastResponseBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.statusCode = (response as? HTTPURLResponse)?.statusCode
            box.error = error
            semaphore.signal()
        }
        processLock.lock()
        activeMetadataTask = task
        processLock.unlock()
        task.resume()
        let completed = semaphore.wait(timeout: .now() + 2.4) == .success
        if !completed { task.cancel() }
        processLock.lock()
        if activeMetadataTask === task { activeMetadataTask = nil }
        processLock.unlock()
        guard completed, box.statusCode == 200, box.error == nil, let data = box.data,
              let classification = Self.classifyWatchPage(data: data, expectedVideoID: videoID) else {
            return nil
        }
        let detail = classification.range.map { "Watch metadata 標示：\($0)" }
            ?? "Watch metadata formats 沒有 HDR colorInfo"
        updateMetadataDiagnostics(result: "fast path · \(detail)", exitCode: nil)
        return YouTubeMetadataResult(
            videoID: videoID, state: classification.range == nil ? .sdr : .hdr,
            dynamicRange: classification.range, cacheHit: false, detail: detail,
            executableSource: executable.source, executablePath: executable.url.path,
            executableVersion: executableVersion, exitCode: nil, failureReason: nil
        )
    }

    static func classifyWatchPage(data: Data, expectedVideoID: String) -> (hasFormats: Bool, range: String?)? {
        guard let page = String(data: data, encoding: .utf8),
              let marker = page.range(of: "ytInitialPlayerResponse = ") else { return nil }
        let tail = page[marker.upperBound...]
        guard let start = tail.firstIndex(of: "{") else { return nil }
        var depth = 0, quoted = false, escaped = false, end: String.Index?
        for index in tail.indices[start...] {
            let character = tail[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { end = tail.index(after: index); break }
            }
        }
        guard let end, let jsonData = String(tail[start..<end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let details = json["videoDetails"] as? [String: Any],
              details["videoId"] as? String == expectedVideoID,
              let streaming = json["streamingData"] as? [String: Any] else { return nil }
        let formats = ((streaming["formats"] as? [[String: Any]]) ?? [])
            + ((streaming["adaptiveFormats"] as? [[String: Any]]) ?? [])
        guard !formats.isEmpty else { return nil }
        for format in formats where (format["mimeType"] as? String)?.hasPrefix("video/") == true {
            guard let color = format["colorInfo"] as? [String: Any] else { continue }
            let transfer = (color["transferCharacteristics"] as? String)?.uppercased() ?? ""
            let primaries = (color["primaries"] as? String)?.uppercased() ?? ""
            if transfer.contains("2084") || transfer.contains("ST2084") { return (true, "HDR10") }
            if transfer.contains("B67") || transfer.contains("HLG") { return (true, "HLG") }
            if primaries.contains("BT2020") && !transfer.contains("BT709") { return (true, "HDR") }
        }
        return (true, nil)
    }

    private func resolveExecutable() -> ExecutableCandidate? {
        var candidates: [ExecutableCandidate] = []
        if let executableOverride {
            candidates.append(ExecutableCandidate(url: executableOverride, source: "Test"))
        }
        if let bundled = Bundle.main.url(forResource: "yt-dlp_macos", withExtension: nil) {
            candidates.append(ExecutableCandidate(url: bundled, source: "Bundled"))
        }
        candidates.append(ExecutableCandidate(
            url: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            source: "Homebrew"
        ))
        candidates.append(ExecutableCandidate(
            url: URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
            source: "Local"
        ))
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                ExecutableCandidate(url: URL(fileURLWithPath: "\($0)/yt-dlp"), source: "PATH")
            })
        }

        let fileManager = FileManager.default
        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.url.path)
        }) else { return nil }
        updateDiagnostics { $0.selectedExecutable = executable }
        return executable
    }

    private func version(for executable: ExecutableCandidate) -> String? {
        diagnosticsLock.lock()
        let alreadyResolved = versionForPath == executable.url.path
            && versionResult != "尚未執行"
        let existingVersion = cachedVersion
        diagnosticsLock.unlock()
        if alreadyResolved { return existingVersion }

        let process = run(
            executable: executable.url,
            arguments: ["--ignore-config", "--version"],
            timeout: 8,
            trackedForCancellation: false
        )
        if process.timedOut {
            updateDiagnostics {
                $0.selectedExecutable = executable
                $0.versionForPath = executable.url.path
                $0.cachedVersion = nil
                $0.versionResult = "timeout after 8s"
            }
            return nil
        }
        if let launchError = process.launchError {
            updateDiagnostics {
                $0.selectedExecutable = executable
                $0.versionForPath = executable.url.path
                $0.cachedVersion = nil
                $0.versionResult = "process launch failure: \(launchError.localizedDescription)"
            }
            return nil
        }
        guard process.exitCode == 0 else {
            let reason = Self.tail(process.stderr)
            updateDiagnostics {
                $0.selectedExecutable = executable
                $0.versionForPath = executable.url.path
                $0.cachedVersion = nil
                $0.versionResult = reason.isEmpty
                    ? "exit code \(process.exitCode)"
                    : "exit code \(process.exitCode) · \(reason)"
            }
            return nil
        }

        let version = String(data: process.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        updateDiagnostics {
            $0.selectedExecutable = executable
            $0.versionForPath = executable.url.path
            $0.cachedVersion = version
            $0.versionResult = version.map { "exit code 0 · \($0)" } ?? "exit code 0"
        }
        return version
    }

    private func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        trackedForCancellation: Bool = true
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        do {
            if trackedForCancellation { processLock.lock() }
            try process.run()
            if trackedForCancellation {
                activeProcess = process
                processLock.unlock()
            }
        } catch {
            if trackedForCancellation { processLock.unlock() }
            return ProcessResult(
                stdout: Data(),
                stderr: Data(),
                exitCode: -1,
                timedOut: false,
                launchError: error
            )
        }
        defer {
            if trackedForCancellation {
                processLock.lock()
                if activeProcess === process { activeProcess = nil }
                processLock.unlock()
            }
        }

        let outputGroup = DispatchGroup()
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                Self.stopProcessTree(process)
            }
            _ = outputGroup.wait(timeout: .now() + 1)
            return ProcessResult(
                stdout: stdoutBox.data,
                stderr: stderrBox.data,
                exitCode: -1,
                timedOut: true,
                launchError: nil
            )
        }

        _ = outputGroup.wait(timeout: .now() + 1)
        return ProcessResult(
            stdout: stdoutBox.data,
            stderr: stderrBox.data,
            exitCode: process.terminationStatus,
            timedOut: false,
            launchError: nil
        )
    }

    static func hdrRange(in format: [String: Any]) -> String? {
        if let codec = format["vcodec"] as? String, codec == "none" { return nil }
        let fields = ["dynamic_range", "dynamicRange", "format_note"].compactMap {
            format[$0] as? String
        }
        return fields.compactMap(normalizedHDRRange).first
    }

    private static func normalizedHDRRange(_ value: String) -> String? {
        let label = value.uppercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label.contains("DOLBY VISION") || label.contains("DOLBYVISION") || label == "DV" {
            return "Dolby Vision"
        }
        if label.contains("HDR10+") || label.contains("HDR10 PLUS") {
            return "HDR10+"
        }
        if label.contains("HDR10") {
            return "HDR10"
        }
        if label.contains("HLG") {
            return "HLG"
        }
        if label.contains("HDR") {
            return "HDR"
        }
        return nil
    }

    private static func tail(_ data: Data) -> String {
        guard let string = String(data: data, encoding: .utf8) else { return "" }
        let normalized = string
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= 320 { return normalized }
        return String(normalized.suffix(320))
    }

    private func updateMetadataDiagnostics(result: String, exitCode: Int?) {
        updateDiagnostics {
            $0.metadataResult = result
            $0.metadataExitCode = exitCode
        }
    }

    private func diagnosticsSnapshot() -> YTDLPDiagnostics {
        diagnostics()
    }

    private func unknown(
        videoID: String,
        detail: String,
        executable: ExecutableCandidate? = nil,
        executableVersion: String? = nil,
        exitCode: Int? = nil,
        failureReason: String
    ) -> YouTubeMetadataResult {
        YouTubeMetadataResult(
            videoID: videoID,
            state: .unknown,
            dynamicRange: nil,
            cacheHit: false,
            detail: detail,
            executableSource: executable?.source,
            executablePath: executable?.url.path,
            executableVersion: executableVersion,
            exitCode: exitCode,
            failureReason: failureReason
        )
    }

    private func readCached(videoID: String) -> CacheEntry? {
        guard let data = preferences.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([String: CacheEntry].self, from: data),
              let entry = entries[videoID],
              Date().timeIntervalSince(entry.cachedAt) < cacheTTL
        else { return nil }
        return entry
    }

    private func writeCached(videoID: String, state: YouTubeMetadataState, dynamicRange: String?) {
        let existingData = preferences.data(forKey: cacheKey)
        var entries = existingData
            .flatMap { try? JSONDecoder().decode([String: CacheEntry].self, from: $0) } ?? [:]
        entries = entries.filter { Date().timeIntervalSince($0.value.cachedAt) < cacheTTL }
        entries[videoID] = CacheEntry(
            state: state,
            dynamicRange: dynamicRange,
            cachedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(entries) else { return }
        preferences.set(data, forKey: cacheKey)
    }

    private func updateDiagnostics(_ update: (inout DiagnosticsStorage) -> Void) {
        diagnosticsLock.lock()
        var storage = DiagnosticsStorage(
            selectedExecutable: selectedExecutable,
            versionForPath: versionForPath,
            cachedVersion: cachedVersion,
            versionResult: versionResult,
            metadataResult: metadataResult,
            metadataExitCode: metadataExitCode
        )
        update(&storage)
        selectedExecutable = storage.selectedExecutable
        versionForPath = storage.versionForPath
        cachedVersion = storage.cachedVersion
        versionResult = storage.versionResult
        metadataResult = storage.metadataResult
        metadataExitCode = storage.metadataExitCode
        diagnosticsLock.unlock()
    }

    private struct ExecutableCandidate {
        let url: URL
        let source: String
    }

    private struct DiagnosticsStorage {
        var selectedExecutable: ExecutableCandidate?
        var versionForPath: String
        var cachedVersion: String?
        var versionResult: String
        var metadataResult: String
        var metadataExitCode: Int?
    }

    private struct ProcessResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        let timedOut: Bool
        let launchError: Error?
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        var data: Data {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private final class FastResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedData: Data?, storedStatus: Int?, storedError: Error?
        var data: Data? { get { lock.lock(); defer { lock.unlock() }; return storedData } set { lock.lock(); storedData = newValue; lock.unlock() } }
        var statusCode: Int? { get { lock.lock(); defer { lock.unlock() }; return storedStatus } set { lock.lock(); storedStatus = newValue; lock.unlock() } }
        var error: Error? { get { lock.lock(); defer { lock.unlock() }; return storedError } set { lock.lock(); storedError = newValue; lock.unlock() } }
    }

    // PyInstaller's standalone executable has a bootloader parent and Python child.
    // Terminating only the parent can leave the child holding our pipes open.
    private static func stopProcessTree(_ process: Process) {
        func descendants(_ pid: pid_t, depth: Int) -> [pid_t] {
            guard depth < 8 else { return [] }
            var pids = [pid_t](repeating: 0, count: 128)
            let bytes = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            let children = Array(pids.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size))).filter { $0 > 0 }
            return children.flatMap { descendants($0, depth: depth + 1) } + children
        }
        let children = descendants(process.processIdentifier, depth: 0)
        children.forEach { kill($0, SIGTERM) }
        process.terminate()
        children.forEach { kill($0, SIGKILL) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private struct CacheEntry: Codable {
        let state: YouTubeMetadataState
        let dynamicRange: String?
        let cachedAt: Date
    }
}
