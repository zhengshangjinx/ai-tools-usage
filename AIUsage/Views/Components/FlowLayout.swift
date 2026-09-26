import SwiftUI

/// 从左到右排列、放不下就折到下一行的布局。
///
/// 环境 chips 的数量随用户装的工具增长，用 HStack 的话宽度不够时 SwiftUI 会把每个
/// chip 压扁，文字被截成 "Cla ud..." 这种两行省略号 —— 比换行难看得多。
/// 所以 chips 一律走这个布局：宁可多占一行，也不截断。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let vGap = rowSpacing ?? spacing
        var used: CGFloat = 0        // 当前行已占用宽度
        var done: CGFloat = 0        // 已完成行的总高度
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let advance = size.width + (used == 0 ? 0 : spacing)
            if used > 0 && used + advance > maxWidth {
                done += rowHeight + vGap
                used = size.width
                rowHeight = size.height
            } else {
                used += advance
                rowHeight = max(rowHeight, size.height)
            }
            widest = max(widest, used)
        }
        return CGSize(width: min(widest, maxWidth), height: done + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let vGap = rowSpacing ?? spacing
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + vGap
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
