import Foundation
import Network

struct IINAHDREvent: Codable {
    let version: Int
    let session: String
    let sequence: Int
    let event: String
    let active: Bool
    let path: String?
    let mediaType: String?
    let transfer: String?
    let primaries: String?
    let sigPeak: Double?
    let dolbyVisionProfile: Int?
    let paused: Bool?
    let timestamp: Double

    var isValid: Bool {
        version == 1 && !session.isEmpty && session.count <= 100 && sequence >= 0 &&
        ["heartbeat", "start-file", "file-loaded", "video-reconfig", "end-file", "shutdown"].contains(event) &&
        (path?.utf8.count ?? 0) <= 8192 && timestamp.isFinite
    }
}

/// Bounded one-request HTTP parser. No CORS, remote hosts, chunked bodies or pipelining.
enum IINAHDRHTTP {
    enum ParseResult { case incomplete, reject(Int), event(IINAHDREvent) }
    static func parse(_ data: Data, token: String, port: UInt16) -> ParseResult {
        guard data.count <= 32768 else { return .reject(413) }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 8192 ? .reject(431) : .incomplete
        }
        guard split.lowerBound <= 8192,
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return .reject(400) }
        let lines = head.components(separatedBy: "\r\n")
        guard lines.first == "POST /auto-hdr/iina HTTP/1.1" else { return .reject(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return .reject(400) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil,
              headers["transfer-encoding"] == nil else { return .reject(403) }
        guard headers["authorization"] == "Bearer \(token)" else { return .reject(401) }
        guard let sizeText = headers["content-length"], let size = Int(sizeText), size > 0, size <= 24576 else { return .reject(413) }
        let body = data[split.upperBound...]
        guard body.count >= size else { return .incomplete }
        guard body.count == size else { return .reject(400) }
        let json: Data
        let contentType = headers["content-type"]?.lowercased() ?? ""
        if contentType.hasPrefix("application/json") { json = Data(body) }
        else if contentType.hasPrefix("application/x-www-form-urlencoded"),
                let form = String(data: body, encoding: .utf8) {
            let fields = form.components(separatedBy: "&")
            guard fields.count == 1, fields[0].hasPrefix("payload="),
                  let value = String(fields[0].dropFirst(8)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return .reject(400) }
            json = Data(value.utf8)
        } else { return .reject(415) }
        guard let event = try? JSONDecoder().decode(IINAHDREvent.self, from: json), event.isValid else { return .reject(400) }
        return .event(event)
    }
}

@MainActor
final class IINAHDRIPC {
    static let port: UInt16 = 48743
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SceneHarbor/AutoHDR/iina.json")
    }
    private let configurationURL: URL
    private let listenPort: UInt16
    init(configurationURL: URL? = nil, port: UInt16 = 48743) {
        self.configurationURL = configurationURL ?? Self.configURL
        self.listenPort = port
    }

    var onEvent: ((IINAHDREvent) -> Void)?
    var onStatus: ((String) -> Void)?
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var token = ""

    func start() {
        guard listener == nil else { return }
        do {
            let config = configurationURL
            let fm = FileManager.default
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if let bytes = try? Data(contentsOf: config),
               let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let saved = value["token"] as? String, saved.count >= 32 {
                token = saved
            } else { token = UUID().uuidString + UUID().uuidString }
            let data = try JSONSerialization.data(withJSONObject: ["token": token, "port": listenPort])
            try data.write(to: config, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!)
            let server = try NWListener(using: parameters)
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.onStatus?("IINA 整合尚未連線") }
                    if case .failed = state {
                        self?.onStatus?("IINA 連線服務無法啟動（連接埠可能已使用）")
                        self?.stop()
                    }
                }
            }
            listener = server
            server.start(queue: .main)
        } catch { onStatus?("IINA 連線服務無法啟動：\(error.localizedDescription)") }
    }

    func stop() {
        listener?.cancel(); listener = nil
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        clients.values.forEach { $0.cancel() }; clients.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 8 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = connection
        deadlines[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.close(id)
        }
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32769) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                var data = buffer
                if let bytes { data.append(bytes) }
                switch IINAHDRHTTP.parse(data, token: self.token, port: self.listenPort) {
                case .incomplete:
                    if complete || error != nil { self.close(id) }
                    else { self.receive(connection, id: id, buffer: data) }
                case .reject(let status): self.reply(status, connection: connection, id: id)
                case .event(let event):
                    self.onEvent?(event)
                    self.reply(204, connection: connection, id: id)
                }
            }
        }
    }

    private func reply(_ status: Int, connection: NWConnection, id: UUID) {
        let response = Data("HTTP/1.1 \(status) \(status == 204 ? "No Content" : "Rejected")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }
}
