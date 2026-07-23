import SwiftUI

/// Reversible app-wide Liquid Glass experiment for the iOS target.
///
/// The stored 0...19 value mirrors the macOS experiment. iOS doesn't expose
/// private numbered glass variants, so the value controls the native glass
/// prominence: lower values use clearer glass and higher values add a stronger
/// neutral-dark treatment. The experiment intentionally avoids chromatic and
/// bright white tints because the app's primary interface is dark even when the
/// device itself is using Light Appearance.
struct ExperimentalAppGlassSurface<Content: View>: View {
    let enabled: Bool
    let variant: Int
    let cornerRadius: CGFloat
    let interactive: Bool
    let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        enabled: Bool,
        variant: Int = 11,
        cornerRadius: CGFloat = 16,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.enabled = enabled
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if enabled && !reduceTransparency {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        nativeGlass.interactive(interactive),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            } else {
                content
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
        } else {
            content
        }
    }

    @available(iOS 26.0, *)
    private var nativeGlass: Glass {
        let clamped = min(max(variant, 0), 19)

        if clamped == 0 {
            return .clear
        }

        if clamped < 11 {
            let progress = Double(clamped) / 10.0
            return .clear.tint(Color.black.opacity(0.03 + progress * 0.08))
        }

        let progress = Double(clamped - 11) / 8.0
        return .regular.tint(Color.black.opacity(0.08 + progress * 0.14))
    }
}

struct ExperimentalAppGlassContainer<Content: View>: View {
    let enabled: Bool
    let spacing: CGFloat
    let content: Content

    init(
        enabled: Bool,
        spacing: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) {
        self.enabled = enabled
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if enabled, #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct ExperimentalAppGlassBackdrop: View {
    let variant: Int

    var body: some View {
        // Liquid Glass belongs to the controls above this content layer. Keep
        // the reading canvas opaque so the bright desktop wallpaper cannot
        // wash the whole app in gray.
        Color.black
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func experimentalAppGlass(
        enabled: Bool,
        variant: Int,
        cornerRadius: CGFloat,
        interactive: Bool = false
    ) -> some View {
        ExperimentalAppGlassSurface(
            enabled: enabled,
            variant: variant,
            cornerRadius: cornerRadius,
            interactive: interactive
        ) {
            self
        }
    }
}
