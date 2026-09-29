import Foundation

/// Receive native Data chunks rather than awaiting and appending every byte.
/// Enforce the same cap for declared and chunked responses before decoding.
final class HarborArtworkTransport: @unchecked Sendable {
    static let byteLimit = 16 * 1024 * 1024
    private let session: URLSession
    private let receiver: Receiver

    init(configuration: URLSessionConfiguration = .default) {
        receiver = Receiver()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
    }
    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        if let cached = session.configuration.urlCache?.cachedResponse(for: request),
           let response = cached.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
           cached.data.count <= Self.byteLimit { return cached.data }
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                receiver.insert(task, continuation: continuation)
                ticket.start(task)
            }
        } onCancel: { ticket.cancel() }
    }

    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func start(_ next: URLSessionDataTask) {
            lock.lock(); task = next; let stop = cancelled; lock.unlock()
            if stop { next.cancel() }
            next.resume()
        }
        func cancel() {
            lock.lock(); cancelled = true; let current = task; lock.unlock()
            current?.cancel()
        }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Entry {
            let continuation: CheckedContinuation<Data, Error>
            var data = Data()
            var failure: Error?
        }
        private let lock = NSLock()
        private var entries: [Int: Entry] = [:]
        func insert(_ task: URLSessionDataTask, continuation: CheckedContinuation<Data, Error>) {
            lock.lock(); defer { lock.unlock() }
            entries[task.taskIdentifier] = Entry(continuation: continuation)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let valid = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let oversized = response.expectedContentLength > Int64(HarborArtworkTransport.byteLimit)
            if !valid || oversized {
                lock.lock()
                entries[dataTask.taskIdentifier]?.failure = URLError(oversized ? .dataLengthExceedsMaximum : .badServerResponse)
                lock.unlock()
            }
            completionHandler(valid && !oversized ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let size = entries[dataTask.taskIdentifier]?.data.count ?? 0
            let oversized = data.count > HarborArtworkTransport.byteLimit - size
            if oversized { entries[dataTask.taskIdentifier]?.failure = URLError(.dataLengthExceedsMaximum) }
            else { entries[dataTask.taskIdentifier]?.data.append(data) }
            lock.unlock()
            if oversized { dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let entry = entries.removeValue(forKey: task.taskIdentifier); lock.unlock()
            guard let entry else { return }
            if let error = entry.failure ?? error { entry.continuation.resume(throwing: error); return }
            if let request = task.originalRequest, let response = task.response {
                session.configuration.urlCache?.storeCachedResponse(CachedURLResponse(response: response, data: entry.data), for: request)
            }
            entry.continuation.resume(returning: entry.data)
        }
    }
}
