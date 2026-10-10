import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

// Public-key-only verification of Sparkle 2.10 signed feeds and ZIP updates.
// The signing block format follows Sparkle's SPUExtractSignedFeed implementation.
// This tool never reads Keychain or an Ed25519 private key.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    let args = CommandLine.arguments
    try require(args.count == 4, "Usage: VerifyUpdateSignatures.swift Info.plist appcast.xml update.zip")
    let plistData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    guard let keyText = plist?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: keyText) else {
        throw NSError(domain: "UpdateVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing public update key"])
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let feed = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let start = feed.range(of: prefix, options: .backwards),
          let end = feed.range(of: Data("-->".utf8), in: start.upperBound..<feed.endIndex),
          let block = String(data: feed[start.upperBound..<end.lowerBound], encoding: .utf8),
          let trailing = String(data: feed[end.upperBound...], encoding: .utf8) else {
        throw NSError(domain: "UpdateVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing or malformed feed signature"])
    }
    try require(trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Unexpected bytes after feed signature")
    var fields: [String: String] = [:]
    for line in block.split(separator: "\n") {
        guard let separator = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<separator])
        try require(fields[name] == nil, "Duplicate signature field")
        fields[name] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
    let content = feed[..<start.lowerBound]
    guard let signatureText = fields["edSignature"], let signature = Data(base64Encoded: signatureText),
          let expectedLength = fields["length"].flatMap(Int.init) else {
        throw NSError(domain: "UpdateVerification", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid signature fields"])
    }
    try require(content.count == expectedLength, "Feed content length mismatch")
    try require(key.isValidSignature(signature, for: content), "Feed signature rejected")
    let xml = try XMLDocument(data: Data(content), options: [.nodeLoadExternalEntitiesNever])
    let enclosures = try xml.nodes(forXPath: "/rss/channel/item/enclosure").compactMap { $0 as? XMLElement }
    let archiveURL = URL(fileURLWithPath: args[3])
    guard let enclosure = enclosures.first(where: { URL(string: $0.attribute(forName: "url")?.stringValue ?? "")?.lastPathComponent == archiveURL.lastPathComponent }),
          let archiveSignatureText = enclosure.attribute(forLocalName: "edSignature", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle")?.stringValue,
          let archiveSignature = Data(base64Encoded: archiveSignatureText),
          let archiveLength = enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init) else {
        throw NSError(domain: "UpdateVerification", code: 5, userInfo: [NSLocalizedDescriptionKey: "Archive is not listed in signed feed"])
    }
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    try require(archive.count == archiveLength, "Archive length mismatch")
    try require(key.isValidSignature(archiveSignature, for: archive), "Archive signature rejected")
    print("PASS: feed and update archive signatures match the bundled public key; no Keychain access")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
