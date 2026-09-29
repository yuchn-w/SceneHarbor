import Foundation

/// One source download serves both cover and motion decoders. Visible requests
/// take precedence; speculative work uses only one otherwise idle lane.
actor HarborArtworkDataCache {
    private static let maxConcurrentDownloads = 4
    private final class Job {
        let id = UUID()
        let url: URL
        let order: Int
        var priority: Int
        var readers: [UUID: CheckedContinuation<Data?, Never>] = [:]
        var task: Task<Void, Never>?
        init(url: URL, order: Int, priority: Int) { self.url = url; self.order = order; self.priority = priority }
    }
    private let memory: HarborMemoryCache<NSString, NSData> = {
        let cache = HarborMemoryCache<NSString, NSData>(costLimit: 16 * 1024 * 1024, countLimit: 128)
        return cache
    }()
    private let transport: HarborArtworkTransport
    private var jobs: [String: Job] = [:]
    private var active = 0
    private var sequence = 0
    private(set) var reads = 0

    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.default
        if configuration == nil {
            config.httpMaximumConnectionsPerHost = Self.maxConcurrentDownloads
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
            config.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024,
                                      diskPath: "org.sceneharbor.SceneHarbor/PreviewArtwork")
        }
        transport = HarborArtworkTransport(configuration: config)
    }

    static func key(_ url: URL) -> String {
        let values = url.isFileURL ? try? FileManager.default.attributesOfItem(atPath: url.path) : nil
        return "\(url.absoluteString)|\((values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((values?[.size] as? NSNumber)?.intValue ?? 0)"
    }

    func promote(_ key: String, priority: Int) {
        if let job = jobs[key] { job.priority = max(job.priority, priority); pump() }
    }

    func load(_ url: URL, key: String, priority: Int) async -> Data? {
        guard !Task.isCancelled else { return nil }
        if let data = memory.object(forKey: key as NSString) { return data as Data }
        let reader = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let job: Job
                if let existing = jobs[key] { job = existing }
                else {
                    sequence += 1
                    job = Job(url: url, order: sequence, priority: priority)
                    jobs[key] = job
                }
                job.priority = max(job.priority, priority)
                job.readers[reader] = continuation
                pump()
            }
        } onCancel: { Task { await self.cancel(key, reader: reader) } }
    }

    private func cancel(_ key: String, reader: UUID) {
        guard let job = jobs[key], let continuation = job.readers.removeValue(forKey: reader) else { return }
        continuation.resume(returning: nil)
        if job.readers.isEmpty {
            jobs[key] = nil
            job.task?.cancel()
            pump()
        }
    }

    private func pump() {
        while active < Self.maxConcurrentDownloads {
            guard let next = jobs.filter({ $0.value.task == nil }).min(by: {
                $0.value.priority == $1.value.priority ? $0.value.order < $1.value.order : $0.value.priority > $1.value.priority
            }) else { return }
            let key = next.key, job = next.value
            if job.priority == 0 && active > 0 { return }
            active += 1; reads += 1
            job.task = Task {
                let data: Data?
                do {
                    if job.url.isFileURL {
                        let read = Task.detached(priority: .userInitiated) { () -> Data? in
                            guard !Task.isCancelled,
                                  let size = (try? FileManager.default.attributesOfItem(atPath: job.url.path)[.size]) as? NSNumber,
                                  size.intValue <= HarborArtworkTransport.byteLimit else { return nil }
                            return try? Data(contentsOf: job.url, options: .mappedIfSafe)
                        }
                        data = await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
                    } else {
                        var request = URLRequest(url: job.url)
                        request.cachePolicy = .returnCacheDataElseLoad
                        data = try await transport.data(for: request)
                    }
                } catch { data = nil }
                finish(key, job: job, data: Task.isCancelled ? nil : data)
            }
        }
    }

    private func finish(_ key: String, job: Job, data: Data?) {
        active -= 1
        if jobs[key]?.id == job.id {
            jobs[key] = nil
            if let data { memory.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
            for reader in job.readers.values { reader.resume(returning: data) }
            job.readers.removeAll()
        }
        pump()
    }
}
