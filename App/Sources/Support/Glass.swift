import SwiftUI

// Liquid Glass exists only on macOS 26. These wrappers use it there and the closest older look (blur materials and
// bordered buttons) on macOS 15.

extension View {
    /// Glass behind the view, or a blur material before macOS 26.
    @ViewBuilder func glassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// A glass button, or a bordered one before macOS 26.
    @ViewBuilder func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A clear glass button (over artwork), or a bordered one before macOS 26.
    @ViewBuilder func clearGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass(.clear))
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A prominent glass button, or a bordered prominent one before macOS 26.
    @ViewBuilder func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Groups glass shapes so they blend into each other on macOS 26; before that it only lays out its content.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
