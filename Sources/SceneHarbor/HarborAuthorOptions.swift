import SwiftUI
import Translation
import NaturalLanguage

@available(macOS 15, *)
struct HarborAuthorOptions: View {
    let installed: HarborInstalledItem
    @ObservedObject var playback: HarborPlayback
    @State private var translated: [String: String] = [:]
    @State private var configuration: TranslationSession.Configuration?
    @State private var batch: [String] = []
    @State private var remaining: [(String, [String])] = []
    @State private var waitingLanguage: String?
    @State private var message: String?
    @State private var busy = false

    private var target: Locale.Language { Locale.Language(identifier: HarborLanguage.language) }
    private func label(_ original: String) -> String {
        guard let value = translated[original], value != original else { return original }
        return "\(value) · \(original)"
    }
    private func localized(_ property: HarborProperty) -> HarborProperty {
        HarborProperty(id: property.id, title: label(property.title), type: property.type, initialValue: property.initialValue,
                       minimum: property.minimum, maximum: property.maximum, options: property.options.map { ($0.0, label($0.1)) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(HarborLanguage.text("保留作者原文，並依系統語言顯示翻譯。", "Original author labels are retained alongside translations."))
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView(HarborLanguage.text("翻譯選項…", "Translating controls…")).controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let waitingLanguage {
                Button(HarborLanguage.text("下載語言並翻譯", "Download language and translate")) {
                    busy = true; message = nil
                    configuration = .init(source: Locale.Language(identifier: waitingLanguage), target: target)
                    self.waitingLanguage = nil
                }.buttonStyle(.bordered)
            }
            ForEach(installed.properties) { property in
                HarborPropertyControl(property: localized(property), value: playback.settings(installed.id)[property.id] ?? property.initialValue,
                                      changed: { playback.set(property.id, value: $0, for: installed.project) })
            }
        }.padding(.top, 12)
            .task {
                let strings = Set(installed.properties.flatMap { [$0.title] + $0.options.map(\.1) })
                var grouped: [String: [String]] = [:]
                for text in strings.sorted() where !text.isEmpty {
                    // Already localized/bilingual labels must not be translated a second time.
                    if HarborLanguage.isChinese && text.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil { continue }
                    let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
                    let language = recognizer.dominantLanguage?.rawValue ?? "en"
                    if language.prefix(2) == HarborLanguage.language.prefix(2) { continue }
                    grouped[language, default: []].append(text)
                }
                remaining = grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                await nextBatch()
            }
            .translationTask(configuration) { session in
                do {
                    let requests = batch.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
                    for try await response in session.translate(batch: requests) {
                        try Task.checkCancellation()
                        if let original = response.clientIdentifier { translated[original] = response.targetText }
                    }
                    busy = false
                    await nextBatch()
                } catch {
                    busy = false
                    message = HarborLanguage.text("翻譯暫時無法使用，已保留原文。", "Translation unavailable; original labels are shown.")
                }
            }
    }
    private func nextBatch() async {
        guard !Task.isCancelled, !remaining.isEmpty else { return }
        let next = remaining.removeFirst()
        batch = next.1
        let source = Locale.Language(identifier: next.0)
        let availability = await LanguageAvailability().status(from: source, to: target)
        guard !Task.isCancelled else { return }
        switch availability {
        case .installed:
            busy = true
            configuration = .init(source: source, target: target)
        case .supported:
            waitingLanguage = next.0
            message = HarborLanguage.text("macOS 尚未安裝這組翻譯語言。", "This translation language is not yet installed on macOS.")
        case .unsupported:
            message = HarborLanguage.text("部分原文語言尚不支援系統翻譯。", "Some author languages are not supported by system translation.")
            await nextBatch()
        @unknown default: break
        }
    }
}
