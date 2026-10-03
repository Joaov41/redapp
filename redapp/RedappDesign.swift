import SwiftUI
import Kingfisher

#if os(iOS)
import UIKit
#endif

extension Color {
    /// A color that resolves per appearance, from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        #if os(iOS)
        self.init(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(rgb: isDark ? dark : light, alpha: isDark ? darkOpacity : lightOpacity)
        })
        #else
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: isDark ? darkOpacity : lightOpacity
            )
        })
        #endif
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(light: hex, dark: hex, lightOpacity: opacity, darkOpacity: opacity)
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#endif

/// Shared design tokens for redapp.
///
/// The palette follows the "community briefing" mockup: a charcoal sidebar,
/// a warm paper-white reading canvas, white side panels and a single
/// orange-red accent. Every token resolves for Light and Dark appearance.
enum RedappDesign {
    // MARK: Surfaces

    /// Reading canvas behind feeds, posts and reports.
    static let canvas = Color(light: 0xF7F6F3, dark: 0x1C1C1E)
    /// Navigation sidebar: soft paper in Light, charcoal in Dark.
    static let sidebar = Color(light: 0xEFEDE8, dark: 0x202022)
    /// Selected sidebar row (warm tint behind the orange bar).
    static let sidebarSelection = Color(light: 0xF7E3D9, dark: 0x33282A)
    /// Search field on the sidebar.
    static let sidebarField = Color(light: 0xFFFFFF, dark: 0x28282B)
    /// Primary and secondary text on the sidebar.
    static let sidebarText = Color(light: 0x1C1C1E, dark: 0xF2F2F2)
    static let sidebarSecondaryText = Color(light: 0x6B6966, dark: 0xA3A3A8)
    /// Transient toasts: charcoal with white text in both appearances.
    static let toast = Color(hex: 0x2B2B2E)
    static let toastText = Color(hex: 0xF2F2F2)
    /// Right-hand panels (source evidence, thread summary) and sheets.
    static let panel = Color(light: 0xFFFFFF, dark: 0x202022)
    /// Sheets and modal panels.
    static let elevated = Color(light: 0xF7F6F3, dark: 0x202022)
    /// Cards that sit on the canvas.
    static let card = Color(light: 0xFFFFFF, dark: 0x242427)
    /// Cards that sit on an elevated sheet or panel.
    static let cardOnElevated = Color(light: 0xFFFFFF, dark: 0x2C2C30)
    /// Selected feed row.
    static let rowSelection = Color(light: 0xFBEDE7, dark: 0x352722)
    /// Text fields and quiet controls.
    static let field = Color(light: 0xFFFFFF, dark: 0x28282B)

    /// Hairline used for pane dividers and card outlines.
    static let hairline = Color(light: 0xE6E3DD, dark: 0xFFFFFF, darkOpacity: 0.08)
    static let hairlineStrong = Color(light: 0xD8D4CD, dark: 0xFFFFFF, darkOpacity: 0.14)

    // MARK: Text

    static let ink = Color(light: 0x1C1C1E, dark: 0xF4F4F5)
    static let inkSecondary = Color(light: 0x6B6966, dark: 0xA1A1A6)
    static let inkTertiary = Color(light: 0x9A9791, dark: 0x6E6E73)

    // MARK: Color

    /// Single brand accent: Reddit orange-red.
    static let accent = Color(light: 0xE8542A, dark: 0xFF6A3D)
    /// Tinted fill behind accent chips ("View supporting comments").
    static let accentSoft = Color(light: 0xFCEBE4, dark: 0xFF6A3D, darkOpacity: 0.16)
    static let upvote = accent
    static let downvote = Color(light: 0x5B6CF0, dark: 0x7C8BFF)

    // Sentiment (analysis charts and infographics)
    static let positive = Color(light: 0x1F9D57, dark: 0x3DD68C)
    static let neutral = Color(light: 0xA8A49D, dark: 0x6E6E73)
    static let negative = Color(light: 0xD64532, dark: 0xFF6B5A)

    /// Thread rails cycle through these by depth so nesting is readable.
    static let depthColors: [Color] = [
        Color(red: 1.0, green: 0.42, blue: 0.2),
        Color(red: 0.33, green: 0.62, blue: 1.0),
        Color(red: 0.22, green: 0.78, blue: 0.72),
        Color(red: 0.98, green: 0.76, blue: 0.25),
        Color(red: 0.45, green: 0.80, blue: 0.36),
        Color(red: 0.62, green: 0.66, blue: 0.74)
    ]

    static func depthColor(_ depth: Int) -> Color {
        depthColors[max(depth - 1, 0) % depthColors.count]
    }

    // MARK: Shape

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let sheet: CGFloat = 24
    }

    // MARK: Layout

    /// Comfortable measure for long-form reading (~70 characters at body size).
    static let readingWidth: CGFloat = 720
    /// Wider measure for AI reports that mix prose with tables.
    static let reportWidth: CGFloat = 760
    /// Navigation sidebar.
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 264
    static let sidebarMaxWidth: CGFloat = 300
    /// Feed list column inside Browse.
    static let feedColumnWidth: CGFloat = 380
    /// Right-hand evidence / summary panel.
    static let panelWidth: CGFloat = 380
}

// MARK: - Typography

enum RedappType {
    /// Big report / post titles ("What r/iOS is talking about").
    static let display = Font.system(.largeTitle, design: .default).weight(.bold)
    /// Section titles ("Key themes", "Discussion").
    static let section = Font.title2.weight(.bold)
    /// Uppercase eyebrow ("COMMUNITY BRIEFING", "SAVED RESEARCH").
    static let eyebrow = Font.caption.weight(.semibold)
}

// MARK: - Relative time

enum RedappTime {
    /// Compact Reddit-style age: "now", "12m", "5h", "3d", "4mo", "2y".
    static func shortAge(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<2_592_000: return "\(Int(seconds / 86_400))d"
        case ..<31_536_000: return "\(Int(seconds / 2_592_000))mo"
        default: return "\(Int(seconds / 31_536_000))y"
        }
    }

    static func shortAge(fromUnix timestamp: Double?) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        return shortAge(from: Date(timeIntervalSince1970: timestamp))
    }
}

// MARK: - Compact numbers

enum RedappNumber {
    /// 950 → "950", 1_240 → "1.2k", 18_400 → "18k".
    static func compact(_ value: Int) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        switch magnitude {
        case ..<1_000:
            return "\(value)"
        case ..<10_000:
            let tenths = (Double(magnitude) / 1_000 * 10).rounded() / 10
            return tenths == tenths.rounded()
                ? "\(sign)\(Int(tenths))k"
                : "\(sign)\(String(format: "%.1f", tenths))k"
        case ..<1_000_000:
            return "\(sign)\(magnitude / 1_000)k"
        default:
            return "\(sign)\(String(format: "%.1f", Double(magnitude) / 1_000_000))M"
        }
    }
}

// MARK: - Metadata line

/// "r/iOS · u/someone · 5h" — the quiet line of context above titles.
struct RedappMetaLine: View {
    var subreddit: String? = nil
    var author: String? = nil
    var age: String? = nil
    var trailing: String? = nil

    private var parts: [String] {
        var parts: [String] = []
        if let subreddit, !subreddit.isEmpty { parts.append("r/\(subreddit)") }
        if let author, !author.isEmpty { parts.append("u/\(author)") }
        if let age, !age.isEmpty { parts.append(age) }
        if let trailing, !trailing.isEmpty { parts.append(trailing) }
        return parts
    }

    var body: some View {
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Citations

/// Detects Reddit evidence tokens emitted by the summarizers, e.g.
/// `[t1_abc123]`, `[SOURCE:t1_abc123]` or grouped `[t1_a, SOURCE:t1_b]`,
/// so they can be rendered as numbered citation links instead of raw IDs.
enum RedappCitations {
    private static let idPattern = try! NSRegularExpression(
        pattern: #"^(?:source\s*:\s*)?(t[1-6]_[A-Za-z0-9]+)$"#,
        options: [.caseInsensitive]
    )

    private static let groupPattern = try! NSRegularExpression(
        pattern: #"\[((?:\s*(?:SOURCE\s*:\s*)?t[1-6]_[A-Za-z0-9]+\s*,?)+)\]"#,
        options: [.caseInsensitive]
    )

    /// Returns the source IDs inside a bracket group body, or nil when the
    /// group contains anything that is not a citation token.
    static func sourceIDs(inGroupBody body: String) -> [String]? {
        let tokens = body
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var ids: [String] = []
        for token in tokens {
            let range = NSRange(token.startIndex..<token.endIndex, in: token)
            guard let match = idPattern.firstMatch(in: token, range: range),
                  let idRange = Range(match.range(at: 1), in: token) else {
                return nil
            }
            ids.append(String(token[idRange]))
        }
        return ids
    }

    /// Stable 1-based numbering in order of first appearance.
    static func numbering(in text: String) -> [String: Int] {
        var numbers: [String: Int] = [:]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in groupPattern.matches(in: text, range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: text),
                  let ids = sourceIDs(inGroupBody: String(text[bodyRange])) else { continue }
            for id in ids where numbers[id] == nil {
                numbers[id] = numbers.count + 1
            }
        }
        return numbers
    }
}

// MARK: - Surfaces

extension View {
    /// Rounded card with a hairline edge, used for grouped content on the canvas.
    func redappCard(
        fill: Color = RedappDesign.card,
        cornerRadius: CGFloat = RedappDesign.Radius.medium,
        padding: CGFloat = 16
    ) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RedappDesign.hairline, lineWidth: 1)
            )
    }

    /// Centers content in a column no wider than `width`.
    func redappReadableColumn(_ width: CGFloat = RedappDesign.readingWidth) -> some View {
        self
            .frame(maxWidth: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Inline messages

/// Inline status message used in place of raw red "X Error: …" strings.
struct RedappInlineMessage: View {
    enum Kind {
        case error, warning, info

        var symbol: String {
            switch self {
            case .error: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return RedappDesign.accent
            }
        }
    }

    var title: String? = nil
    let message: String
    var kind: Kind = .error

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: RedappDesign.Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mockup components

/// Uppercase, letter-spaced label ("COMMUNITY BRIEFING").
struct RedappEyebrow: View {
    let text: String
    var color: Color = RedappDesign.inkSecondary

    init(_ text: String, color: Color = RedappDesign.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(RedappType.eyebrow)
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// Filled orange button ("Save report", "Summarize thread").
struct RedappPrimaryButtonStyle: ButtonStyle {
    var isCapsule = false
    /// Smaller padding and type, for rows that must fit narrow columns.
    var isCompact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.vertical, isCompact ? 8 : 10)
            .background(
                RoundedRectangle(cornerRadius: isCapsule ? 999 : 10, style: .continuous)
                    .fill(RedappDesign.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45))
            )
            .contentShape(RoundedRectangle(cornerRadius: isCapsule ? 999 : 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet outlined button ("Listen to briefing", "Export").
struct RedappSecondaryButtonStyle: ButtonStyle {
    var isCapsule = true
    var isBordered = true
    /// Label color; destructive actions pass `RedappDesign.negative`.
    var foreground: Color = RedappDesign.ink
    /// Smaller padding and type, for rows that must fit narrow columns.
    var isCompact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: isCapsule ? 999 : 10, style: .continuous)
        return configuration.label
            .font(isCompact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, isBordered ? (isCompact ? 11 : 16) : 10)
            .padding(.vertical, isCompact ? 8 : 10)
            .background {
                if isBordered {
                    shape
                        .fill(RedappDesign.field)
                        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                }
            }
            .overlay {
                if isBordered {
                    shape.strokeBorder(RedappDesign.hairlineStrong, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(shape)
    }
}

/// Accent chip ("View supporting comments ↗", "6 sources ↗").
struct RedappChipButtonStyle: ButtonStyle {
    var isFilled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RedappDesign.accent)
            .padding(.horizontal, isFilled ? 12 : 0)
            .padding(.vertical, isFilled ? 6 : 4)
            .background {
                if isFilled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RedappDesign.accentSoft)
                }
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

/// Plain icon button used in top bars (bookmark, share, more).
struct RedappIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(RedappDesign.ink)
            .frame(width: 40, height: 40)
            .background(
                Circle().fill(RedappDesign.ink.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .contentShape(Circle())
    }
}

/// Text tabs with an orange underline on the selected tab.
struct RedappUnderlineTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.self) { tab in
                    let isSelected = tab == selection
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
                    } label: {
                        VStack(spacing: 8) {
                            Text(title(tab))
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? RedappDesign.ink : RedappDesign.inkSecondary)
                                .padding(.horizontal, 14)
                            ZStack {
                                Rectangle().fill(Color.clear).frame(height: 2)
                                if isSelected {
                                    Rectangle()
                                        .fill(RedappDesign.accent)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(RedappDesign.hairline)
                .frame(height: 1)
        }
    }
}

/// Initials avatar with a stable per-name color.
struct RedappAvatar: View {
    let name: String
    var size: CGFloat = 32

    private static let palette: [UInt32] = [0xE8542A, 0x3B82F6, 0x14B8A6, 0x8B5CF6, 0xF59E0B, 0xEC4899, 0x22C55E, 0x64748B]

    private var initials: String {
        let cleaned = name
            .replacingOccurrences(of: "u/", with: "")
            .replacingOccurrences(of: "r/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(2)).uppercased()
    }

    private var color: Color {
        let checksum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hex: Self.palette[abs(checksum) % Self.palette.count])
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Reddit-style community badge (circle with the first letter).
struct RedappCommunityBadge: View {
    let name: String
    var size: CGFloat = 28
    var isHome = false
    @ObservedObject private var icons = SubredditIconStore.shared

    var body: some View {
        ZStack {
            letterBadge
            if !isHome, let url = icons.url(for: name) {
                // The subreddit's own icon, with the letter badge underneath while it loads.
                KFImage(url)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(RedappDesign.hairline, lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: name) {
            if !isHome { icons.load(name) }
        }
    }

    private var letterBadge: some View {
        ZStack {
            Circle().fill(RedappDesign.accent.gradient)
            if isHome {
                Image(systemName: "house.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(String(name.replacingOccurrences(of: "r/", with: "").prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// The orange app mark from the mockup.
struct RedappBrandMark: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(RedappDesign.accent.gradient)
            .overlay {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: 1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Rounded "Ask about this research…" field with a sparkle and send button.
struct RedappAskBar: View {
    let placeholder: String
    @Binding var text: String
    var isBusy = false
    let onSubmit: () -> Void

    private var canSubmit: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RedappDesign.inkSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit { if canSubmit { onSubmit() } }
            Button(action: onSubmit) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(canSubmit || isBusy ? RedappDesign.accent : RedappDesign.inkTertiary.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Send question")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(RedappDesign.field)
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(RedappDesign.hairlineStrong, lineWidth: 1)
        )
    }
}

/// Header for right-hand panels ("Source evidence", "Thread summary").
struct RedappPanelHeader: View {
    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(RedappDesign.ink)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(RedappDesign.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(RedappIconButtonStyle())
            .accessibilityLabel("Close panel")
        }
    }
}

/// Quote block with an orange leading bar (source evidence).
struct RedappQuote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule()
                .fill(RedappDesign.accent)
                .frame(width: 3)
            Text("“\(text)”")
                .font(.body)
                .foregroundStyle(RedappDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


/// Subtle press feedback for tile-like buttons.
struct RedappTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}


extension View {
    /// Wraps the view in `AnyView` to cut a deep generic type chain.
    func erased() -> AnyView { AnyView(self) }
}


/// Icon button inside a floating Liquid Glass pill.
struct RedappGlassPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(RedappDesign.ink)
            .frame(width: 44, height: 40)
            .background(Capsule().fill(RedappDesign.ink.opacity(configuration.isPressed ? 0.1 : 0)))
            .contentShape(Capsule())
    }
}
