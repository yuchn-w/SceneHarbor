import SwiftUI

struct HarborPaginationBar: View {
    let page: Int
    let total: Int
    let loading: Bool
    let blended: Bool
    let select: (Int) -> Void
    @State private var entry = ""
    @State private var invalid = false
    private var numbers: [Int] {
        Array(Set([1, total] + Array(max(1, page - 1)...min(total, page + 1)))).sorted()
    }
    private var compactNumbers: [Int] { Array(Set([1, page, total])).sorted() }

    var body: some View {
        VStack(spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pageButtons(numbers)
                    Spacer(minLength: 4)
                    position
                    jumpControls
                }
                VStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        pageButtons(numbers)
                        pageButtons(compactNumbers)
                    }
                    HStack(spacing: 8) {
                        position
                        Spacer(minLength: 4)
                        jumpControls
                    }
                }
            }
            if invalid { Text(HarborLanguage.text("請輸入 1～\(total) 的頁碼", "Enter a page from 1 to \(total)")).font(.caption).foregroundStyle(.orange) }
            if blended { Text(HarborLanguage.text("每頁最多 24 張；合併搜尋會移除重複作品。", "Up to 24 wallpapers per page; duplicate search results are removed.")).font(.caption2).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
        .onAppear { entry = String(page) }
        .onChange(of: page) { _, value in entry = String(value); invalid = false }
    }

    private var position: some View {
        Text(HarborLanguage.text("第 \(page.formatted()) 頁／共 \(total.formatted()) 頁", "Page \(page.formatted()) of \(total.formatted())"))
            .font(.caption.monospacedDigit().weight(.medium))
            .fixedSize()
            .accessibilityIdentifier("harbor-page-position")
    }

    private func pageButtons(_ values: [Int]) -> some View {
        HStack(spacing: 6) {
            Button { select(page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(page <= 1 || loading).help(HarborLanguage.text("上一頁", "Previous page"))
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                if index > 0 && value - values[index - 1] > 1 { Text("…").foregroundStyle(.secondary) }
                Button { select(value) } label: {
                    Text(value.formatted())
                        .font(.callout.monospacedDigit().weight(value == page ? .bold : .regular))
                        .padding(.horizontal, 9)
                        .frame(minWidth: 30, minHeight: 28)
                        .foregroundStyle(value == page ? Color.white : Color.primary)
                        .background(value == page ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(value == page ? Color.primary.opacity(0.25) : .clear, lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .accessibilityLabel(HarborLanguage.text("第 \(value) 頁", "Page \(value)"))
                .accessibilityValue(value == page ? HarborLanguage.text("目前頁面", "Current page") : "")
                .accessibilityAddTraits(value == page ? .isSelected : [])
                .accessibilityIdentifier(value == page ? "harbor-current-page" : "harbor-page-\(value)")
            }
            Button { select(page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(page >= total || loading).help(HarborLanguage.text("下一頁", "Next page"))
        }.fixedSize()
    }

    private var jumpControls: some View {
        HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.small) }
            TextField(HarborLanguage.text("頁碼", "Page"), text: $entry)
                .textFieldStyle(.roundedBorder).frame(width: 54)
                .onSubmit(jump).disabled(loading)
                .accessibilityIdentifier("harbor-page-number")
            Button(HarborLanguage.text("前往", "Go"), action: jump).disabled(loading)
        }.fixedSize()
    }

    private func jump() {
        guard let value = Int(entry.trimmingCharacters(in: .whitespaces)), (1...total).contains(value) else { invalid = true; return }
        invalid = false; select(value)
    }
}
