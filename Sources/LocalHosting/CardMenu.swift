import AppKit
import SwiftUI

// A right-click menu drawn in SwiftUI. The standard macOS menu always indents its separators;
// this one runs them edge to edge and adds a header naming what the menu acts on.

extension View {
    /// Shows `content` as a menu where the card is right-clicked or Control-clicked.
    func cardMenu<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        overlay(RightClickCatcher { point in
            ContextMenuPresenter.shared.show(AnyView(MenuPanel(content: content)), at: point)
        })
    }
}

/// A full-width line between groups of items.
struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.vertical, 5)
    }
}

struct MenuItem: View {
    let title: String
    let symbol: String
    var destructive = false
    var enabled = true
    let action: () -> Void
    @ViewState private var hovering = false

    private var highlighted: Bool { hovering && enabled }

    var body: some View {
        Button {
            ContextMenuPresenter.shared.dismiss()
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 20)
            }
            .font(.system(size: 13))
            .foregroundStyle(highlighted ? Color.white : destructive ? Theme.danger : Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlighted ? (destructive ? Theme.danger : Theme.accentFill) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
    }
}

private struct MenuPanel<Content: View>: View {
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220)
        .fixedSize()
        .background(MenuMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Shows one menu at a time in a borderless floating panel and closes it on any outside
/// click, Escape, or when the app loses focus.
@MainActor
final class ContextMenuPresenter {
    static let shared = ContextMenuPresenter()

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    func show<Content: View>(at point: NSPoint, @ViewBuilder content: @escaping () -> Content) {
        show(AnyView(MenuPanel(content: content)), at: point)
    }

    func show(_ content: AnyView, at point: NSPoint) {
        dismiss()
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize

        // Open down and to the right of the pointer, like a native menu, staying on screen.
        var origin = NSPoint(x: point.x + 2, y: point.y - size.height - 2)
        if let frame = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            if origin.x + size.width > frame.maxX - 4 { origin.x = point.x - size.width - 2 }
            if origin.y < frame.minY + 4 { origin.y = point.y + 2 }
        }

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = host
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        self.panel = panel

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { self?.dismiss() }
            }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(monitor) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A transparent layer that only takes right clicks (and Control-clicks); every other click
/// falls through to the card underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (NSPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((NSPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isRightClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isRightClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(NSEvent.mouseLocation)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onRightClick?(NSEvent.mouseLocation) }
        }
    }
}
