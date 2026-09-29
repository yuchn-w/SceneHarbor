import Foundation

/// Separate IPC lane: temporary previews never enter the installation list or
/// emit the library-download notification. One content transfer at a time.
@MainActor final class HarborPreviewTransfers {
    static let itemLimit: Int64 = 1_073_741_824
    private struct Job {
        let id: String
        let workshopID: String
        let root: URL
        var continuation: CheckedContinuation<URL, Error>?
        let progress: (Double) -> Void
        let prepare: () throws -> Void
        var timeout: Task<Void, Never>?
    }
    private let send: ([String: Any]) -> Void
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var active: String?
    init(send: @escaping ([String: Any]) -> Void) { self.send = send }

    func fetch(_ workshopID: String, root: URL, progress: @escaping (Double) -> Void, prepare: @escaping () throws -> Void = {}) async throws -> URL {
        let id = "preview-" + UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                jobs[id] = Job(id: id, workshopID: workshopID, root: root, continuation: continuation, progress: progress, prepare: prepare)
                queue.append(id); pump()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } }
    }
    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let job = jobs[id] else { pump(); return }
        active = id
        do { try job.prepare() }
        catch { finish(id, result: .failure(error)); return }
        send(["command": "download", "requestId": id, "taskId": id, "workshopId": job.workshopID,
              "outputRoot": job.root.path, "maxUncompressedBytes": Self.itemLimit])
        jobs[id]?.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.cancel(id, error: SteamWorkshopAPIError.apiMessage("預覽素材載入逾時，請重試。"))
        }
    }
    private func cancel(_ id: String, error: Error = CancellationError()) {
        guard var job = jobs[id] else { return }
        job.continuation?.resume(throwing: error); job.continuation = nil; job.timeout?.cancel(); job.timeout = nil
        jobs[id] = job
        if active == id {
            // Keep the lane occupied until the helper confirms termination.
            send(["command": "cancelDownload", "requestId": "preview-cancel-" + id, "taskId": id])
        } else { jobs[id] = nil; queue.removeAll { $0 == id } }
    }
    @discardableResult func handle(_ payload: [String: Any]) -> Bool {
        let type = payload["type"] as? String
        let id = (type == "response" ? payload["requestId"] : payload["taskId"]) as? String ?? ""
        guard id.hasPrefix("preview-") else { return false }
        // Includes late terminal messages from a cancelled generation.
        guard let job = jobs[id] else { return true }
        if type == "response" {
            if payload["success"] as? Bool != true {
                finish(id, result: .failure(SteamWorkshopAPIError.apiMessage(payload["message"] as? String ?? "預覽素材無法載入。")))
            }
        } else if type == "downloadState" {
            let state = payload["state"] as? String ?? ""
            let total = (payload["totalBytes"] as? NSNumber)?.doubleValue ?? 0
            let received = (payload["receivedBytes"] as? NSNumber)?.doubleValue ?? 0
            job.progress(total > 0 ? min(1, max(0, received / total)) : 0)
            if state == "completed" {
                let expected = job.root.appendingPathComponent(job.workshopID).standardizedFileURL
                guard let path = payload["outputPath"] as? String,
                      URL(fileURLWithPath: path).standardizedFileURL == expected else {
                    finish(id, result: .failure(SteamWorkshopAPIError.invalidResponse)); return true
                }
                finish(id, result: .success(expected))
            } else if state == "failed" || state == "cancelled" {
                let message = payload["errorCode"] as? String == "PREVIEW_SIZE_LIMIT"
                    ? "這張桌布超過 1 GB 的預覽快取上限。"
                    : payload["message"] as? String ?? "預覽素材無法載入，請重試。"
                finish(id, result: .failure(SteamWorkshopAPIError.apiMessage(message)))
            }
        }
        return true
    }
    private func finish(_ id: String, result: Result<URL, Error>) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.timeout?.cancel(); job.continuation?.resume(with: result)
        if active == id { active = nil }
        queue.removeAll { $0 == id }; pump()
    }
    func failAll() {
        let pending = Array(jobs.values); jobs.removeAll(); queue.removeAll(); active = nil
        for job in pending {
            job.timeout?.cancel()
            job.continuation?.resume(throwing: SteamWorkshopAPIError.apiMessage("Steam 連線已結束，請重新登入後預覽。"))
        }
    }
}
