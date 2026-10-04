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
    @State private var batchLanguage: String?
    @State private var failedLanguage: String?

    private var target: Locale.Language { Locale.Language(identifier: HarborLanguage.language) }
    private func label(_ original: String) -> String {
        guard let value = translated[original], value != original else { return original }
        return value
    }
    private func localized(_ property: HarborProperty) -> HarborProperty {
        var result = property
        result.title = label(property.title)
        result.options = property.options.map { ($0.0, label($0.1)) }
        result.groupTitle = property.groupTitle.map(label)
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(HarborLanguage.text("開關控制功能，滑桿調整數值。將游標停在選項上可查看作者原文。", "Switches turn features on or off; sliders adjust values. Hover for the author's original label."))
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView(HarborLanguage.text("翻譯選項…", "Translating controls…")).controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let failedLanguage {
                Button(HarborLanguage.text("重試翻譯", "Retry translation")) {
                    busy = true; message = nil; self.failedLanguage = nil
                    if configuration != nil { configuration?.invalidate() }
                    else { configuration = .init(source: Locale.Language(identifier: failedLanguage), target: target) }
                }.buttonStyle(.bordered)
            }
            if let waitingLanguage {
                Button(HarborLanguage.text("下載語言並翻譯", "Download language and translate")) {
                    busy = true; message = nil
                    configuration = .init(source: Locale.Language(identifier: waitingLanguage), target: target)
                    self.waitingLanguage = nil
                }.buttonStyle(.bordered)
            }
            HarborAuthorPropertyList(properties: installed.properties.map(localized), values: playback.settings(installed.id),
                                     changed: { playback.set($0, value: $1, for: installed.project) })
        }.padding(.top, 12)
            .task {
                let strings = Set(installed.properties.filter { $0.unsupportedReason == nil }.flatMap { [$0.title] + $0.options.map(\.1) + [$0.groupTitle].compactMap { $0 } })
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
                    busy = false; failedLanguage = nil
                    await nextBatch()
                } catch {
                    guard !Task.isCancelled else { return }
                    busy = false; failedLanguage = batchLanguage
                    message = HarborLanguage.text("翻譯暫時無法使用，已保留原文。", "Translation unavailable; original labels are shown.")
                }
            }
    }
    private func nextBatch() async {
        guard !Task.isCancelled, !remaining.isEmpty else { return }
        let next = remaining.removeFirst()
        batch = next.1
        batchLanguage = next.0
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
