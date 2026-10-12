import AppKit
import SwiftUI

/// SwiftUI's `@State` property wrapper under another name. Recent SDKs expand `@State` with a
/// macro whose plugin ships only with full Xcode; this alias lets the app build with the
/// Command Line Tools alone.
typealias ViewState = SwiftUI.State

enum Theme {
    /// The blue from the app icon: anything routed to this Mac.
    static let accent = Color(light: 0x3B5BDB, dark: 0x7C95FF)
    /// Running servers and services.
    static let live = Color(light: 0x1F8A5B, dark: 0x4CCB8F)
    /// Something needs the person's attention (setup incomplete).
    static let attention = Color(light: 0xC2540A, dark: 0xF5A25B)
    /// Destructive actions.
    static let danger = Color(light: 0xC92A2A, dark: 0xFF7B7B)
    /// Fill for primary buttons: deep enough in both modes for white text.
    static let accentFill = Color(light: 0x3B5BDB, dark: 0x4263EB)
    /// The fill behind white text on a destructive button; `danger` is too pale in the dark to carry it.
    static let dangerFill = Color(light: 0xC92A2A, dark: 0xD64545)

    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let pageTitle = Font.system(size: 22, weight: .bold)
    /// Hostnames, paths and credentials: things people copy or type elsewhere.
    static let data = Font.system(size: 12, design: .monospaced)

    static let pagePadding: CGFloat = 28
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

// MARK: Page structure

/// Title, one line of status and the page's main action. Every page starts with one.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.pageTitle)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            actions
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 30)
        .padding(.bottom, 20)
    }
}

/// One panel holding a list of rows separated by hairlines.
struct Surface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.top, 26)
            .padding(.bottom, 10)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

// MARK: Small components

struct StatusIndicator: View {
    let running: Bool
    var busy = false

    var body: some View {
        ZStack {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(running ? Theme.live : Color.secondary.opacity(0.3))
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(busy ? "Working" : running ? "Running" : "Off")
    }
}

/// The translucent macOS sidebar material.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: Buttons

/// The look every button, tab, menu and switch-like control in the app shares: a rounded pill, 28 points tall.
/// Neutral by default; the main action (or the selected tab) is filled with the accent colour.
struct PillSurface: ViewModifier {
    var prominent = false
    var hovering = false
    var pressed = false
    /// The fill of a prominent pill, when it isn't the accent colour.
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(tint ?? Theme.accentFill)
                                    : AnyShapeStyle(Color.primary.opacity(pressed ? 0.12 : hovering ? 0.09 : 0.06)))
                    .brightness(prominent ? (pressed ? -0.08 : hovering ? 0.06 : 0) : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? Color.white.opacity(0.14) : Theme.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension View {
    func pillSurface(prominent: Bool = false, hovering: Bool = false, pressed: Bool = false, tint: Color? = nil) -> some View {
        modifier(PillSurface(prominent: prominent, hovering: hovering, pressed: pressed, tint: tint))
    }
}

/// A button as a pill. `.primary` is the filled one, `.secondary` the neutral one.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, prominent: prominent, tint: tint)
    }

    private struct PillLabel: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let tint: Color?
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .pillSurface(prominent: prominent, hovering: hovering && isEnabled, pressed: configuration.isPressed, tint: tint)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

typealias PrimaryButtonStyle = PillButtonStyle
typealias SecondaryButtonStyle = PillButtonStyle

extension ButtonStyle where Self == PillButtonStyle {
    static var primary: PillButtonStyle { PillButtonStyle(prominent: true) }
    static var secondary: PillButtonStyle { PillButtonStyle() }
    /// The filled pill for an action that can't be undone.
    static var destructive: PillButtonStyle { PillButtonStyle(prominent: true, tint: Theme.dangerFill) }
}

// MARK: Sheets

/// The header shared by every sheet: icon on the left, title and description beside it,
/// never taller than the icon.
struct SheetHeader: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 52)
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }
}

struct SheetFooter: View {
    var confirmTitle = "Continue"
    var confirmSymbol = "checkmark"
    /// The main button is red: what it does can't be undone.
    var destructive = false
    let canConfirm: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(action: confirm) {
                Label(confirmTitle, systemImage: confirmSymbol).labelStyle(ButtonLabelStyle())
            }
                .buttonStyle(destructive ? .destructive : .primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }
}

// MARK: Cards

// MARK: Sheet fields

/// Rows of label and field in one rounded box, separated by full-width hairlines.
struct FieldGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct FieldRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 100, alignment: .leading)
            // Values sit on the right, the way they do in System Settings.
            field
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
    }
}

/// Explanation under a field group.
struct FieldNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, -8)
    }
}

/// A problem that keeps a sheet from continuing.
struct FieldProblem: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(Theme.attention)
    }
}

func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

// MARK: Tabs

/// A row of tabs with a raised pill that slides to the selected one. Used by the Browser
/// (Rows, Structure, SQL) and the Console (Servers, PHP, MySQL).
struct TabSwitcher<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let symbol: String
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                TabPill(option: option, selected: option.value == selection) {
                    withAnimation(.snappy(duration: 0.2)) { selection = option.value }
                }
            }
        }
    }

    private struct TabPill: View {
        let option: Option
        let selected: Bool
        let action: () -> Void
        @ViewState private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: option.symbol).font(.system(size: 11, weight: .medium))
                    Text(option.title)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .pillSurface(prominent: selected, hovering: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// A choice among a few options, as a button that opens a menu: the current option's icon and name,
/// with a chevron, in the app's pill.
struct OptionMenu<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String?
    }

    @Binding var selection: Value
    let options: [Option]
    @ViewState private var hovering = false

    private var current: Option? { options.first { $0.value == selection } }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let symbol = current?.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 14)
                }
                Text(current?.title ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .pillSurface(hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

/// A small capsule stating whether something is ready.
struct StatusPill: View {
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Theme.live : Theme.attention).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(ok ? Theme.live : Theme.attention)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background((ok ? Theme.live : Theme.attention).opacity(0.12), in: Capsule())
    }
}

/// Icon and title for buttons, with tighter spacing than the default label.
struct ButtonLabelStyle: LabelStyle {
    var trailingIcon = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if trailingIcon {
                configuration.title
                configuration.icon.font(.system(size: 10, weight: .bold))
            } else {
                configuration.icon.font(.system(size: 11, weight: .bold))
                configuration.title
            }
        }
    }
}

/// A square icon button, 30 by 30, matching the secondary buttons. `active` tints it with the
/// accent colour, for toggles that are on.


// MARK: Wide rows

/// A titled group of rows in one rounded panel, separated by full-width hairlines. Settings uses it.
struct SectionPanel<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A pill button with an icon, for an action next to the choices around it.
struct PillButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 14)
                }
                Text(title)
            }
        }
        .buttonStyle(.secondary)
    }
}

/// A button with an icon and the shortcut that does the same.
struct ShortcutButton: View {
    let symbol: String
    let shortcut: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(shortcut).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small icon-only button, for actions beside a value: copy it, open it, show it in Finder.
struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering && enabled ? Theme.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(hovering && enabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Copies a value to the pasteboard. There's no confirmation: the pasteboard has it.
struct CopyButton: View {
    let value: String
    let label: String

    var body: some View {
        IconButton(symbol: "doc.on.doc", help: "Copy the \(label)") { copyToPasteboard(value) }
    }
}

/// A value in a table: monospaced, on one line.
struct FieldValue: View {
    let text: String
    var tint: Color?
    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(Theme.data)
            .foregroundStyle(tint ?? Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// Memory and disk use as the rows show them. Nothing used reads as zero, not as a dash.
enum Usage {
    static func memory(_ bytes: Int?) -> String {
        format(Int64(bytes ?? 0), style: .memory, units: [.useMB, .useGB])
    }

    static func disk(_ bytes: Int64?) -> String {
        format(bytes ?? 0, style: .file, units: [.useKB, .useMB, .useGB, .useTB])
    }

    private static func format(_ bytes: Int64, style: ByteCountFormatter.CountStyle, units: ByteCountFormatter.Units) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        // "0 KB", not "Zero KB" or "0 bytes".
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = units
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: Servers and databases: a list and the selected one's details

/// The page layout for servers and databases: a slim list on the left, the selected item's details on the right,
/// in a rounded container like the Browser's.
struct MasterDetail<List: View, Detail: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { list.padding(8) }
                .frame(width: 270)
                .background(Color.primary.opacity(0.02))
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, Theme.pagePadding)
    }
}

/// A fold-away group in the list: a header (chevron, icon, title, how many) over its rows.
struct ListGroup<Content: View>: View {
    let title: String
    let symbol: String
    let count: Int
    @AppStorage private var collapsed: Bool
    @ViewBuilder var content: Content

    init(title: String, symbol: String, count: Int, key: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.count = count
        _collapsed = AppStorage(wrappedValue: false, "collapsed.\(key)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 12)
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 14)
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityHint(collapsed ? "Show" : "Hide")
            if !collapsed {
                content
            }
        }
    }
}

/// One item in the list: its icon, name, a line under it and whether it's on.
struct ListItemRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let live: Bool
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(live ? Theme.live : Theme.accent)
                    .frame(width: 28, height: 28)
                    .background((live ? Theme.live : Theme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Color.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(live ? Theme.live : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The top of the details: a big icon, the name, whether it's on, and its switch.
struct DetailHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let status: String
    let live: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(live ? Theme.live : Theme.accent)
                .frame(width: 48, height: 48)
                .background((live ? Theme.live : Theme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.snappy, value: live)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(live ? Theme.live : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                    Text(status)
                        .font(.system(size: 12.5))
                        .foregroundStyle(live ? Theme.live : Color.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

/// A titled block of details: rows of label and value in one rounded box.
struct DetailBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            FieldGroup { content }
        }
    }
}

/// A titled part of the details that isn't a box of rows, like the usage tiles.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content
        }
    }
}

/// One detail: its label on the left, its value on the right, with a copy button when it's something to paste.
struct DetailRow: View {
    let label: String
    let value: String
    var tint: Color?
    var copy: String?

    var body: some View {
        FieldRow(label: label) {
            HStack(spacing: 6) {
                FieldValue(value, tint: tint).help(value)
                if let copy { CopyButton(value: copy, label: label.lowercased()) }
            }
        }
    }
}

/// A sheet that asks before something that can't be undone: the same header and buttons as every other sheet,
/// with the main button in red.
struct ConfirmSheet: View {
    let symbol: String
    let title: String
    let message: String
    var confirmTitle = "Delete"
    var confirmSymbol = "trash"
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(symbol: symbol, title: title, message: message, tint: Theme.danger)
            Color.clear.frame(height: 22)
            SheetFooter(confirmTitle: confirmTitle, confirmSymbol: confirmSymbol, destructive: true, canConfirm: true,
                        cancel: cancel, confirm: confirm)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A figure on its own tile: a label and the amount in large type, with a caption at the bottom under a line that
/// runs the full width of the tile.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // The digits roll to the new figure.
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.5), value: value)
            }
            .padding(14)
            Spacer(minLength: 0)
            if let caption {
                Divider()
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}
