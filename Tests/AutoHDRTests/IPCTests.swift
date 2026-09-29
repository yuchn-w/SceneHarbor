import Foundation

enum IPCTests {
    static func run() {
        let json = #"{"version":1,"session":"test-player","sequence":1,"event":"file-loaded","active":true,"path":"/tmp/a.mov","mediaType":"video","transfer":"pq","primaries":"bt.2020","sigPeak":10,"timestamp":1}"#
        func request(_ body: String = json, type: String = "application/json", auth: String = "token", extra: String = "") -> Data {
            Data("POST /auto-hdr/iina HTTP/1.1\r\nHost: 127.0.0.1:48743\r\nAuthorization: Bearer \(auth)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
        }
        func parse(_ data: Data) -> IINAHDRHTTP.ParseResult { IINAHDRHTTP.parse(data, token: "token", port: 48743) }
        if case .event(let e) = parse(request()) { precondition(e.transfer == "pq") } else { fatalError("JSON") }
        let form = "payload=" + json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        if case .event = parse(request(form, type: "application/x-www-form-urlencoded")) {} else { fatalError("IINA form") }
        if case .reject(401) = parse(request(auth: "bad")) {} else { fatalError("token") }
        if case .reject(403) = parse(request(extra: "Origin: https://example.com\r\n")) {} else { fatalError("browser origin") }
        if case .reject(400) = parse(request(extra: "Content-Length: 2\r\n")) {} else { fatalError("duplicate header") }
        if case .reject(413) = parse(Data(repeating: 65, count: 32769)) {} else { fatalError("size") }
        if case .incomplete = parse(Data(request().dropLast())) {} else { fatalError("partial body") }
        if case .reject(400) = parse(request("{}")) {} else { fatalError("schema") }
        print("PASS IPC: JSON + IINA form, token, Origin, duplicate headers, size limit, fragmented body, schema")
    }
}
