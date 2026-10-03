import SwiftUI

#if os(macOS)
import AppKit

enum ExperimentalSettingsGlassVariant: Int, CaseIterable, Identifiable, Sendable {
    case v0 = 0, v1, v2, v3, v4, v5, v6, v7, v8, v9
    case v10 = 10, v11, v12, v13, v14, v15, v16, v17, v18, v19

    var id: Int { rawValue }
}

/// Settings-only experiment based on the Redbar reference implementation.
/// NSGlassEffectView and its variant selector are private, so both are looked
/// up dynamically and fall back to a standard visual-effect view.
struct ExperimentalSettingsGlassBackground<Content: View>: NSViewRepresentable {
    let variant: ExperimentalSettingsGlassVariant
    let cornerRadius: CGFloat
    let content: Content

    init(
        variant: ExperimentalSettingsGlassVariant = .v11,
        cornerRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    private typealias VariantSetter = @convention(c) (AnyObject, Selector, Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let hosting = makeHostingView()

        if let glassType = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassType.init(frame: .zero)
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            setVariant(variant.rawValue, on: glass)
            glass.setValue(hosting, forKey: "contentView")
            return glass
        }

        let fallback = NSVisualEffectView()
        fallback.material = .hudWindow
        fallback.blendingMode = .behindWindow
        fallback.state = .active
        fallback.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: fallback.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: fallback.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: fallback.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: fallback.bottomAnchor)
        ])
        return fallback
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPrivateGlass(nsView) {
            if let hosting = nsView.value(forKey: "contentView") as? NSHostingView<Content> {
                hosting.rootView = content
            }
            nsView.setValue(cornerRadius, forKey: "cornerRadius")
            setVariant(variant.rawValue, on: nsView)
        } else if let hosting = nsView.subviews.first as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }

    private func makeHostingView() -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        return hosting
    }

    private func isPrivateGlass(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).contains("NSGlassEffectView")
    }

    private func setVariant(_ value: Int, on object: AnyObject) {
        let selector = NSSelectorFromString("set_variant:")
        guard
            let objectClass = object_getClass(object),
            let method = class_getInstanceMethod(objectClass, selector)
        else { return }

        let implementation = method_getImplementation(method)
        let setter = unsafeBitCast(implementation, to: VariantSetter.self)
        setter(object, selector, value)
    }
}
#endif

extension View {
    @ViewBuilder
    func experimentalSettingsGlass(
        enabled: Bool,
        variant: Int,
        cornerRadius: CGFloat
    ) -> some View {
        #if os(macOS)
        if enabled {
            ExperimentalSettingsGlassBackground(
                variant: ExperimentalSettingsGlassVariant(rawValue: variant) ?? .v11,
                cornerRadius: cornerRadius
            ) {
                self
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
