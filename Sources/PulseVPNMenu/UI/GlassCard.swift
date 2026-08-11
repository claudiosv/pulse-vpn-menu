import SwiftUI

/// The rounded translucent panel every list row / preference group in the
/// main window sits on. Factored out so Status, Connections, and General
/// all share one corner radius, stroke, and material instead of each
/// re-deriving them.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 14
    var material: Material = .thinMaterial
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(material))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.06))
            )
    }
}

extension View {
    /// Small grey explanatory line under a control, matching the footers
    /// the old `Form`-based Settings window used.
    func cardFootnote() -> some View {
        self
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
