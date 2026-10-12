import SwiftUI

struct ServersView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var resources: ResourceMonitor
    @ViewState private var creating = false
    @ViewState private var editing: Server?
    @ViewState private var deleting: Server?
    @AppStorage("selectedServer") private var selectedRaw = ""

    /// The server whose details are open: the one picked, or the first when none is (or it's gone).
    private var selected: Server? {
        state.config.servers.first { $0.id.uuidString == selectedRaw } ?? state.config.servers.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Servers", subtitle: "Websites and apps from folders on This Mac, served by Apache or Nginx, each at its own address.") {
                Button { creating = true } label: {
                    Label("New server", systemImage: "plus").labelStyle(ButtonLabelStyle())
                }
                .buttonStyle(.primary)
                .keyboardShortcut("n")
                .disabled(!state.setup.complete)
                .help(state.setup.complete ? "New server (⌘N)" : "Finish setup in Settings first")
            }

            if state.config.servers.isEmpty {
                EmptyState(
                    symbol: "globe",
                    title: "No servers yet",
                    message: "A server shows a website or app from a folder on This Mac at an address you choose. Create one to get started."
                )
            } else {
                MasterDetail {
                    // One group for each kind of server there is.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(SiteKind.allCases) { kind in
                            let servers = state.config.servers.filter { $0.siteKind == kind }
                            if !servers.isEmpty {
                                ListGroup(title: "\(kind.name) servers", symbol: kind.symbol, count: servers.count, key: "servers-\(kind.rawValue)") {
                                    ForEach(servers) { server in
                                        ListItemRow(symbol: kind.symbol, title: server.name, subtitle: server.primaryHostname,
                                                    live: state.isRunning(server), selected: server.id == selected?.id) {
                                            selectedRaw = server.id.uuidString
                                        }
                                        .cardMenu {
                                            ServerMenu.items(for: server, running: state.isRunning(server), state: state,
                                                             edit: { editing = server }, delete: { deleting = server })
                                        }
                                    }
                                }
                            }
                        }
                    }
                } detail: {
                    if let server = selected {
                        ServerDetail(server: server, edit: { editing = server }, delete: { deleting = server })
                            .id(server.id)
                    }
                }
            }
        }
        .task(id: selected?.id) { await resources.watch(state, focus: selected.map { .server($0) }) }
        .sheet(isPresented: $creating) { ServerEditor(server: nil) }
        .onAppear { if Paths.testSheet == "server" { creating = true } }
        .onAppear(perform: openTestMenu)
        .sheet(item: $editing) { ServerEditor(server: $0) }
        .sheet(item: $deleting) { server in
            ConfirmSheet(
                symbol: "trash", title: "Delete this server?",
                message: "Local Hosting forgets this server. The files in its folder stay where they are.",
                confirmTitle: "Continue",
                confirmSymbol: "checkmark",
                cancel: { deleting = nil },
                confirm: {
                    state.deleteServer(server)
                    deleting = nil
                }
            )
        }
    }
}

extension ServersView {
    /// Screenshot runs only: opens the first server's right-click menu in the middle of the window.
    private func openTestMenu() {
        guard Paths.testMenu == "server", let server = state.config.servers.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let frame = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 })?.frame else { return }
            ContextMenuPresenter.shared.show(at: NSPoint(x: frame.midX - 80, y: frame.midY + 120)) {
                ServerMenu.items(for: server, running: false, state: state, edit: {}, delete: {})
            }
        }
    }
}

/// Everything about one server: its state and switch, what it can do, where it is and what it uses.
struct ServerDetail: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var resources: ResourceMonitor
    let server: Server
    let edit: () -> Void
    let delete: () -> Void

    private var running: Bool { state.isRunning(server) }
    private var busy: Bool { state.isBusy(server.id) }

    private var status: String {
        if busy { return "Updating…" }
        return running ? "On · redirects to This Mac" : "Off · redirects to the Internet"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(symbol: server.siteKind.symbol, title: server.name, status: status, live: running) {
                    Toggle("Running", isOn: Binding(get: { running }, set: { _ in state.toggle(server) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Theme.live)
                        .disabled(busy)
                        .help(running ? "Stop \(server.name)" : "Start \(server.name)")
                        .accessibilityLabel(running ? "Stop \(server.name)" : "Start \(server.name)")
                }

                HStack(spacing: 8) {
                    Button { state.openInBrowser(server) } label: {
                        Label("Open in Browser", systemImage: "safari").labelStyle(ButtonLabelStyle())
                    }
                    .buttonStyle(.secondary)
                    .disabled(!running)
                    .help(running ? "Open \(server.primaryHostname) in your browser" : "Switch the server on to open it")
                    Button { state.revealDocumentRoot(server) } label: {
                        Label("Show in Finder", systemImage: "folder").labelStyle(ButtonLabelStyle())
                    }
                    .buttonStyle(.secondary)
                    Button(action: edit) {
                        Label("Edit…", systemImage: "pencil").labelStyle(ButtonLabelStyle())
                    }
                    .buttonStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(action: delete) {
                        Label("Delete…", systemImage: "trash").labelStyle(ButtonLabelStyle()).foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.secondary)
                }

                DetailBlock(title: "Site") {
                    DetailRow(label: "Address", value: server.primaryHostname)
                    Divider()
                    if server.webServer == .nginx && state.setup.checked && !state.setup.nginx {
                        DetailRow(label: "Server", value: "Nginx (not installed)", tint: Theme.attention)
                    } else {
                        DetailRow(label: "Server", value: server.webServer.name)
                    }
                    Divider()
                    kindRows
                    DetailRow(label: "Folder", value: (server.documentRoot as NSString).abbreviatingWithTildeInPath)
                        .help(server.documentRoot)
                }

                DetailSection(title: "Usage") {
                    HStack(spacing: 12) {
                        StatTile(label: "RAM", value: Usage.memory(resources.memory[server.id]),
                                 caption: server.siteKind.isApp ? "This app and what it started"
                                                                : "Shared by every site on \(server.webServer.name)")
                        StatTile(label: "Storage", value: Usage.disk(resources.storage[server.id]), caption: "The size of the folder")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var kindRows: some View {
        switch server.siteKind {
        case .php:
            let installed = state.setup.phpVersions
            let shown = server.phpVersion ?? installed.first?.id
            if !state.setup.checked {
                DetailRow(label: "PHP Version", value: shown ?? " ")
            } else if let shown, installed.contains(where: { $0.id == shown }) {
                DetailRow(label: "PHP Version", value: shown)
            } else {
                DetailRow(label: "PHP Version", value: "\(shown ?? "PHP") (not installed)", tint: Theme.attention)
            }
            Divider()
        case .node, .python, .ruby:
            DetailRow(label: "Port", value: String(server.port ?? server.siteKind.defaultPort))
            Divider()
            DetailRow(label: "Command", value: server.command ?? server.siteKind.defaultCommand)
            Divider()
        case .staticSite:
            EmptyView()
        }
    }
}

/// The right-click menu of a server.
@MainActor
enum ServerMenu {
    @ViewBuilder
    static func items(for server: Server, running: Bool, state: AppState,
                      edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        MenuItem(title: "Open in Browser", symbol: "safari", enabled: running) { state.openInBrowser(server) }
        MenuItem(title: "Show in Finder", symbol: "folder") { state.revealDocumentRoot(server) }
        MenuItem(title: "Copy Address", symbol: "doc.on.doc") { copyToPasteboard(server.primaryHostname) }
        MenuSeparator()
        MenuItem(title: running ? "Stop Server" : "Start Server", symbol: running ? "stop.circle" : "play.circle") {
            state.toggle(server)
        }
        MenuItem(title: "Edit…", symbol: "pencil", action: edit)
        MenuSeparator()
        MenuItem(title: "Delete…", symbol: "trash", destructive: true, action: delete)
    }
}

struct ServerEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private let original: Server?
    @ViewState private var name: String
    @ViewState private var domain: String
    @ViewState private var documentRoot: String
    @ViewState private var folderChosen: Bool
    @ViewState private var phpVersion: String
    @ViewState private var web: WebServer
    @ViewState private var kind: SiteKind
    @ViewState private var command: String
    @ViewState private var portText: String

    init(server: Server?) {
        original = server
        _name = ViewState(initialValue: server?.name ?? "")
        _domain = ViewState(initialValue: server?.domain ?? "")
        _documentRoot = ViewState(initialValue: server?.documentRoot ?? "")
        _folderChosen = ViewState(initialValue: server != nil)
        _web = ViewState(initialValue: server?.webServer ?? WebServer.lastUsed)
        let kind = server?.siteKind ?? .php
        _kind = ViewState(initialValue: kind)
        _command = ViewState(initialValue: server?.command ?? kind.defaultCommand)
        _portText = ViewState(initialValue: kind.isApp ? String(server?.port ?? kind.defaultPort) : "")
        // Servers saved before PHP versions existed use the newest one.
        _phpVersion = ViewState(initialValue: server?.phpVersion ?? PHP.newest()?.id ?? "")
    }

    /// Installed versions, plus the server's current one if it has since been uninstalled.
    private var phpChoices: [String] {
        var ids = state.setup.phpVersions.map(\.id)
        if !phpVersion.isEmpty && !ids.contains(phpVersion) { ids.append(phpVersion) }
        return ids
    }

    /// Types whose software is installed, plus the server's current one if it has since been removed.
    private var kindChoices: [SiteKind] {
        SiteKind.allCases.filter { isAvailable($0) || $0 == original?.siteKind }
    }

    private func isAvailable(_ kind: SiteKind) -> Bool {
        switch kind {
        case .php: state.setup.php
        case .staticSite: true
        case .node, .python, .ruby: kind.runtime.map { state.setup.runtimes.contains($0) } ?? false
        }
    }

    private func kindLabel(_ kind: SiteKind) -> String { isAvailable(kind) ? kind.name : "\(kind.name) (not installed)" }

    /// Installed web servers, plus the server's current one if it has since been removed.
    private var webChoices: [WebServer] {
        WebServer.allCases.filter { isInstalled($0) || $0 == original?.webServer }
    }

    private func isInstalled(_ web: WebServer) -> Bool { web == .apache ? state.setup.httpd : state.setup.nginx }

    private func webLabel(_ web: WebServer) -> String { isInstalled(web) ? web.name : "\(web.name) (not installed)" }

    /// A new server starts on a type and web server that exist on This Mac, once that's known.
    private func chooseAvailable() {
        guard original == nil, state.setup.checked else { return }
        if !kindChoices.contains(kind), let first = kindChoices.first { kind = first }
        if !webChoices.contains(web), let first = webChoices.first { web = first }
    }

    private var slug: String { Server.slug(for: name) }
    private var normalizedDomain: String { Server.normalizeDomain(domain) }

    private var suggestedRoot: String {
        Paths.sites.appendingPathComponent(name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : slug).path
    }

    private var effectiveRoot: String { folderChosen ? documentRoot : suggestedRoot }

    private var validationError: String? {
        let others = state.config.servers.filter { $0.id != original?.id }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty || normalizedDomain.isEmpty { return "" }
        if others.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return "Another server is already called “\(trimmedName)”."
        }
        // Typed input that isn't valid yet just keeps Continue off; only conflicts get a message.
        if !Server.isValidDomain(normalizedDomain) { return "" }
        let candidate = Server(name: name, domain: normalizedDomain, documentRoot: "")
        if let clash = others.first(where: { !Set($0.hostnames).isDisjoint(with: candidate.hostnames) }) {
            return "“\(clash.name)” already uses this address."
        }
        if candidate.hostnames.contains(state.config.mysqlHost) { return "MySQL already uses this name." }
        if effectiveRoot.contains("\"") { return "The folder path can't contain double quotes." }
        if kind.isApp {
            if command.trimmingCharacters(in: .whitespaces).isEmpty || portText.isEmpty { return "" }
            if command.contains(where: \.isNewline) { return "" }
            guard let port = Int(portText), (1024...65535).contains(port) else { return "" }
            if port == state.config.mysqlPort { return "MySQL uses port \(port)." }
            if let clash = others.first(where: { $0.siteKind.isApp && ($0.port ?? $0.siteKind.defaultPort) == port }) {
                return "“\(clash.name)” already uses port \(port)."
            }
        }
        if web == .nginx && (effectiveRoot.contains("$") || effectiveRoot.contains("\\")) {
            return "Nginx can't serve a folder whose path contains $ or \\."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                symbol: "globe",
                title: original == nil ? "New server" : "Edit server",
                message: original == nil
                    ? "Serve a website or app from a folder on This Mac at an address you choose."
                    : "Changes apply right away if the server is running."
            )

            VStack(alignment: .leading, spacing: 16) {
                FieldGroup {
                    FieldRow(label: "Name") {
                        TextField("Name", text: $name, prompt: Text("Type the server name…"))
                            .textFieldStyle(.plain)
                    }
                    Divider()
                    FieldRow(label: "Address") {
                        TextField("Address", text: $domain, prompt: Text("madebyeduard.com"))
                            .textFieldStyle(.plain)
                    }
                }
                FieldNote("While the server is on, this address opens your local site in every browser on This Mac. If a real website exists on it, it comes back the moment you switch the server off.")

                FieldGroup {
                    FieldRow(label: "Type") {
                        OptionMenu(selection: $kind, options: kindChoices.map {
                            .init(value: $0, title: kindLabel($0), symbol: $0.symbol)
                        })
                    }
                    Divider()
                    FieldRow(label: "Server") {
                        if webChoices.isEmpty {
                            Text("Install Apache or Nginx in Settings").foregroundStyle(.secondary)
                        } else {
                            OptionMenu(selection: $web, options: webChoices.map {
                                .init(value: $0, title: webLabel($0), symbol: $0.symbol)
                            })
                        }
                    }
                    Divider()
                    if kind == .php {
                        FieldRow(label: "PHP Version") {
                            OptionMenu(selection: $phpVersion, options: phpChoices.map { id in
                                .init(value: id,
                                      title: state.setup.phpVersions.contains { $0.id == id } ? "PHP \(id)" : "PHP \(id) (not installed)",
                                      symbol: "chevron.left.forwardslash.chevron.right")
                            })
                        }
                        Divider()
                    }
                    if kind.isApp {
                        FieldRow(label: "Command") {
                            TextField("Command", text: $command, prompt: Text(kind.defaultCommand))
                                .textFieldStyle(.plain)
                                .font(Theme.data)
                        }
                        Divider()
                        FieldRow(label: "Port") {
                            TextField("Port", text: $portText, prompt: Text(String(kind.defaultPort)))
                                .textFieldStyle(.plain)
                                .font(Theme.data)
                        }
                        Divider()
                    }
                    FieldRow(label: kind.isApp ? "Project" : "Folder") {
                        HStack(spacing: 8) {
                            Spacer(minLength: 8)
                            Text(effectiveRoot.isEmpty ? "Choose a folder" : (effectiveRoot as NSString).abbreviatingWithTildeInPath)
                                .font(Theme.data)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            PillButton(title: "Choose…", symbol: "folder", action: chooseFolder)
                        }
                    }
                }
                FieldNote(kind.isApp
                    ? "Your \(kind.name) project is started with this command in its folder, with the port also given to it as $PORT. \(web.name) sends the address to that port. The output appears in the Console. Apache and Nginx can't run at the same time."
                    : "Apache and Nginx can't run at the same time: switching this server on turns off the running servers that use the other one. Install Nginx, more PHP versions, Node, Python and Ruby in Settings. Local Hosting creates the folder if it doesn't exist yet.")

                if let error = validationError, !error.isEmpty {
                    FieldProblem(text: error)
                }
            }
            .padding(20)

            SheetFooter(
                confirmTitle: original == nil ? "Continue" : "Save",
                canConfirm: validationError == nil,
                cancel: { dismiss() },
                confirm: save
            )
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        // Picking a type fills in a sensible command and port, unless they were already changed.
        .onAppear(perform: chooseAvailable)
        .onChange(of: state.setup.checked) { chooseAvailable() }
        .onChange(of: kindChoices) { chooseAvailable() }
        .onChange(of: webChoices) { chooseAvailable() }
        .onChange(of: kind) { old, new in
            if command.isEmpty || command == old.defaultCommand { command = new.defaultCommand }
            if portText.isEmpty || portText == String(old.defaultPort) { portText = new.isApp ? String(new.defaultPort) : "" }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.directoryURL = URL(fileURLWithPath: effectiveRoot).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            documentRoot = url.path
            folderChosen = true
        }
    }

    private func save() {
        var server = original ?? Server(name: "", documentRoot: "")
        server.name = name.trimmingCharacters(in: .whitespaces)
        server.domain = normalizedDomain
        server.documentRoot = effectiveRoot
        server.kind = kind
        server.web = web
        if kind == .php { server.phpVersion = phpVersion.isEmpty ? nil : phpVersion }
        server.command = kind.isApp ? command.trimmingCharacters(in: .whitespaces) : nil
        server.port = kind.isApp ? Int(portText) : nil
        if original == nil {
            state.addServer(server)
        } else {
            state.updateServer(server)
        }
        dismiss()
    }
}
