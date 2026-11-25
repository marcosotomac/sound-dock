import AppKit
import SwiftUI

/// Shared metrics and building blocks, so every part of the panel lines up and behaves the same.
@MainActor
enum PanelStyle {
    static let width: CGFloat = 340
    static let padding: CGFloat = 10
    /// Inset of row content inside its hover highlight.
    static let rowInset: CGFloat = 4
    static let iconSize: CGFloat = 20
    static let columnSpacing: CGFloat = 8
    static let levelColumnWidth: CGFloat = 38
    static let nameFont = NSFont.systemFont(ofSize: 12.5)
    static let hoverAnimation = Animation.easeOut(duration: 0.12)
    static let listAnimation = Animation.smooth(duration: 0.28)

    static func highlight(_ isHovering: Bool) -> some ShapeStyle {
        Color.primary.opacity(isHovering ? 0.07 : 0)
    }
}

/// A quiet, menu-like label: secondary text that brightens and gains a soft highlight on hover.
struct HoverLabel<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        content
            .font(.system(size: 12))
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.horizontal, PanelStyle.rowInset)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(PanelStyle.highlight(isHovering)))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(PanelStyle.hoverAnimation, value: isHovering)
    }
}

/// Width of the app-name column: wide enough for the longest visible name, within limits, so names
/// are not truncated needlessly and every slider starts at the same x.
@MainActor
enum NameColumn {
    private static let range: ClosedRange<CGFloat> = 56...124
    static var maximumWidth: CGFloat { range.upperBound }
    private static var cache: [String: CGFloat] = [:]

    static func width(for names: some Sequence<String>) -> CGFloat {
        width(for: names.map { ($0, 0) })
    }

    /// `entries` pair each name with the width of the badges shown after it.
    static func width(for entries: [(name: String, badges: CGFloat)]) -> CGFloat {
        let widest = entries.map { measure($0.name) + $0.badges }.max() ?? range.lowerBound
        return min(max(widest.rounded(.up) + 1, range.lowerBound), range.upperBound)
    }

    private static func measure(_ name: String) -> CGFloat {
        if let width = cache[name] {
            return width
        }
        let width = (name as NSString).size(withAttributes: [.font: PanelStyle.nameFont]).width
        cache[name] = width
        return width
    }
}

/// Right-aligned level readout. Boosted levels read stronger instead of relying on color,
/// which would clash with an orange accent color.
struct PercentLabel: View {
    let level: Double

    var body: some View {
        let isBoosted = level > 1.0005
        Text(level, format: .percent.precision(.fractionLength(0)))
            .font(.system(size: 11, weight: isBoosted ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isBoosted ? .primary : .secondary)
            .frame(width: PanelStyle.levelColumnWidth, alignment: .trailing)
    }
}
