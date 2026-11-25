import AppKit
import SwiftUI

/// The floating panel that hosts the SwiftUI content, styled like the system's menu bar windows.
///
/// Its top edge stays fixed: when the content grows or shrinks (an app starts playing, a section is
/// hidden) the panel resizes downward with a short animation instead of drifting away from the menu bar.
final class MenuBarPanel: NSPanel {
    static let cornerRadius: CGFloat = 12
    private static let resizeDuration: TimeInterval = 0.22

    /// Called when the user presses Esc.
    var onCancel: (() -> Void)?

    private let hostingController: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?

    init<Content: View>(content: Content) {
        let root = content
            .frame(maxHeight: .infinity, alignment: .top) // Content stays pinned to the top while the frame animates.
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = [.preferredContentSize]

        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = makeBackground()

        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fitContent(animated: true) }
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Places the panel so its top edge sits at `top`, centered on `centerX`, inside `screen`.
    func place(top: CGFloat, centerX: CGFloat, on screen: NSScreen) {
        let size = contentSize
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 0)
        let x = min(max(centerX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: - Sizing

    private var contentSize: NSSize {
        let size = hostingController.preferredContentSize
        let maximumHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
        return NSSize(width: size.width.rounded(.up), height: min(size.height.rounded(.up), maximumHeight - 16))
    }

    private func fitContent(animated: Bool) {
        let size = contentSize
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let target = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)

        guard animated, isVisible, frame.height > 0 else {
            setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.invalidateShadow() }
        }
    }

    // MARK: - Appearance

    private func makeBackground() -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius) // Also shapes the window shadow.

        let content = hostingController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    /// A stretchable rounded rectangle; only its corners are drawn at fixed size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
