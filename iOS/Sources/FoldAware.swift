import SwiftUI

/// A row of controls that parts around the iPhone Duo's fold: when a division (the folding region, active while the
/// device is partly open) crosses the row, the controls before the middle go to its leading side and the rest to its
/// trailing side, with the fold's width between them. Elsewhere (and before iOS 27.1) an ordinary evenly spaced row.
struct FoldAwareRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let fold = proxy.reservedRegions(kind: .division).first { $0.isActive && $0.frame.height >= proxy.size.height * 0.5 }
                if let fold, fold.frame.minX > 0, fold.frame.maxX < proxy.size.width {
                    HStack(spacing: 0) {
                        Parted(content: content, half: .leading).frame(width: fold.frame.minX)
                        Color.clear.frame(width: fold.frame.width)
                        Parted(content: content, half: .trailing).frame(maxWidth: .infinity)
                    }
                } else {
                    row
                }
            }
            .frame(height: 64)
        } else {
            row
        }
    }

    private var row: some View {
        HStack { content.frame(maxWidth: .infinity) }
    }
}

/// One side of a parted row: the first half of the controls, or the rest (the middle one goes with the leading side).
private struct Parted<Content: View>: View {
    let content: Content
    let half: HorizontalEdge

    var body: some View {
        Group(subviews: content) { subviews in
            let middle = (subviews.count + 1) / 2
            HStack {
                ForEach(half == .leading ? Array(subviews.prefix(middle)) : Array(subviews.dropFirst(middle))) { subview in
                    subview.frame(maxWidth: .infinity)
                }
            }
        }
    }
}
