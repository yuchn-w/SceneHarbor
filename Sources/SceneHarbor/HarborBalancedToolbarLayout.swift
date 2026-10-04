import SwiftUI

/// Keeps the original controls at their intrinsic sizes and distributes free
/// space between every control. A wrapped final row uses the same spacing and
/// is centered, so neither side acquires an unexplained empty area.
struct HarborBalancedToolbarLayout: Layout {
    var minimumSpacing: CGFloat = 4
    var rowSpacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(sizes: [CGSize], width: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()
        for (index, size) in sizes.enumerated() {
            let added = size.width + (row.indices.isEmpty ? 0 : minimumSpacing)
            if !row.indices.isEmpty, row.width + added > width + 0.5 {
                result.append(row)
                row = Row()
            }
            row.width += size.width + (row.indices.isEmpty ? 0 : minimumSpacing)
            row.indices.append(index)
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let intrinsic = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * minimumSpacing
        let width = max(sizes.map(\.width).max() ?? 0, proposal.width ?? intrinsic)
        let rows = rows(sizes: sizes, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes: sizes, width: bounds.width)
        let first = rows.first
        let spacing = first.map { row -> CGFloat in
            guard row.indices.count > 1 else { return minimumSpacing }
            let content = row.indices.reduce(CGFloat.zero) { $0 + sizes[$1].width }
            return max(minimumSpacing, (bounds.width - content) / CGFloat(row.indices.count - 1))
        } ?? minimumSpacing
        var y = bounds.minY
        for row in rows {
            let content = row.indices.reduce(CGFloat.zero) { $0 + sizes[$1].width }
            let rowSpacing = row.indices.count > 1 ? min(spacing, max(minimumSpacing, (bounds.width - content) / CGFloat(row.indices.count - 1))) : spacing
            let rowWidth = content + CGFloat(max(0, row.indices.count - 1)) * rowSpacing
            var x = bounds.minX + max(0, (bounds.width - rowWidth) / 2)
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - sizes[index].height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + rowSpacing
            }
            y += row.height + self.rowSpacing
        }
    }
}
