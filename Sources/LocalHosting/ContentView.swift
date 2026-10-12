import SwiftUI

enum SidebarItem: String {
    // Raw values are the original names, so a remembered selection still works after renames.
    case browser = "dashboard"
    case servers, databases, console
    /// What Local Hosting needs on this Mac.
    case settings = "setup"
}

/// A fixed sidebar beside the selected page. The sidebar can't be hidden.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("selectedSection") private var selection: SidebarItem = .browser

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
                .frame(width: 248)
            Divider()
            Group {
                switch selection {
                case .browser: BrowserView()
                case .servers: ServersView()
                case .databases: DatabasesView()
                case .console: ConsoleView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 540)
        .tint(Theme.accent)
        .alert("Something went wrong", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
        .onChange(of: state.browseRequest) { _, request in
            if request != nil { selection = .browser }
        }
        .onChange(of: state.navigationRequest) { _, request in
            if let request { selection = request }
            state.navigationRequest = nil
        }
        .onChange(of: state.setup.checked) { _, checked in
            // Screenshot runs that open a sheet stay on the page that has it.
            if checked && !state.setup.complete && Paths.testSheet == nil { selection = .settings }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @Binding var selection: SidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader()
                // Clear of the window's traffic-light buttons.
                .padding(.top, 44)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            Divider()
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                NavButton(item: .browser, title: "Browser", symbol: "tablecells", selection: $selection) {
                    EmptyView()
                }
                .keyboardShortcut("1")
                NavButton(item: .servers, title: "Servers", symbol: "globe", selection: $selection) {
                    EmptyView()
                }
                .keyboardShortcut("2")
                NavButton(item: .databases, title: "Databases", symbol: "cylinder.split.1x2", selection: $selection) {
                    EmptyView()
                }
                .keyboardShortcut("3")
                NavButton(item: .console, title: "Console", symbol: "terminal", selection: $selection) {
                    EmptyView()
                }
                .keyboardShortcut("4")
            }
            .padding(.horizontal, 10)

            Spacer()

            // Settings sits apart from the pages, at the bottom, like the tabs but with a warning while
            // anything in it isn't installed.
            NavButton(item: .settings, title: "Settings", symbol: "gearshape.fill", selection: $selection) {
                if state.setup.checked && !state.everythingInstalled { SetupWarning() }
            }
            .keyboardShortcut(",")
            .help(state.setup.checked && !state.everythingInstalled ? "Settings (⌘,): something isn't installed" : "Settings (⌘,)")
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial().ignoresSafeArea())
    }
}

/// The app's icon, name and tagline at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            // The icon file has transparent margins around its tile; let the tile fill the space.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .padding(-8)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Hosting")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .lineLimit(1)
                Text("Servers and Databases for macOS")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct NavButton<Badge: View>: View {
    let item: SidebarItem
    let title: String
    let symbol: String
    @Binding var selection: SidebarItem
    @ViewBuilder var badge: Badge
    @ViewState private var hovering = false

    var body: some View {
        let selected = selection == item
        Button {
            selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                Text(title)
                Spacer()
                badge
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.system(size: 13, weight: .medium))
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

/// A small warning shown beside Settings while anything in it isn't installed.
struct SetupWarning: View {
    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Color.black.opacity(0.8))
            .frame(width: 15, height: 15)
            .background(Color(light: 0xE5A800, dark: 0xFFD43B), in: Circle())
            .accessibilityLabel("Something isn't installed")
    }
}
