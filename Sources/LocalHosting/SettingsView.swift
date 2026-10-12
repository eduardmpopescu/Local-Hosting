import SwiftUI

/// What Local Hosting needs on this Mac, laid out like System Settings: grouped rows with
/// a status on the right of each.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ViewState private var removingPHP: String?
    @ViewState private var confirmingMongo = false

    private var subtitle: String {
        if !state.setup.checked { return "Checking This Mac…" }
        if state.setup.complete {
            return state.everythingInstalled
                ? "Everything Local Hosting needs is installed and ready."
                : "Everything servers need is ready. Install the rest below if you need it."
        }
        return "\(state.setup.readyCount) of 3 ready. Finish the rest once, and every server starts with one switch."
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", subtitle: subtitle) {
                EmptyView()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    software
                    security
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, Theme.pagePadding)
            }
            .defaultScrollAnchor(.top)
        }
        .task { await state.watchSetup() }
        .confirmationDialog("Install MongoDB?", isPresented: $confirmingMongo, titleVisibility: .visible) {
            Button("Install MongoDB") { state.installEngine(.mongodb) }
        } message: {
            Text("""
            MongoDB's server isn't in Homebrew's own list. It comes from MongoDB's official Homebrew tap, mongodb/brew. \
            Homebrew adds that tap to This Mac and, because it's not Homebrew's own, is told to trust three of its packages by name: MongoDB's server, its database tools, and MongoDB's enterprise edition, which the server checks for conflicts. \
            Nothing else from the tap is trusted.
            """)
        }
        .confirmationDialog(
            "Remove PHP \(removingPHP ?? "")?",
            isPresented: Binding(get: { removingPHP != nil }, set: { if !$0 { removingPHP = nil } }),
            titleVisibility: .visible,
            presenting: removingPHP
        ) { id in
            Button("Remove PHP \(id)", role: .destructive) {
                if let version = state.setup.phpVersions.first(where: { $0.id == id }) { state.uninstallPHP(version) }
            }
        } message: { id in
            let using = state.servers(usingPHP: id).map(\.name)
            Text(using.isEmpty
                 ? "PHP \(id) no longer gets security fixes. No server uses it."
                 : "PHP \(id) no longer gets security fixes. \(using.joined(separator: ", ")) uses it and will need another PHP version before it can start.")
        }
    }

    // MARK: Sections

    private var software: some View {
        SectionPanel(title: "Software",
                        footer: "Installed with Homebrew. Local Hosting runs them with its own settings and data; Node, Python and Ruby are only needed for servers of those kinds. Updates are looked up when this page opens, and PHP versions that no longer get fixes from php.net stop being offered.") {
            SystemRow(symbol: "shippingbox", title: "Homebrew",
                      detail: "Installs the software below. Asks for your password, and may install Apple's command line tools first") {
                softwareStatus(installed: state.setup.brew, version: state.setup.brewVersion,
                               key: "brew", install: state.installHomebrew)
            }
            Divider()
            SystemRow(symbol: "globe", title: "Apache", detail: "Serves your sites over HTTP and HTTPS") {
                softwareStatus(installed: state.setup.httpd, version: state.setup.httpdVersion, key: "httpd",
                               formula: "httpd", blockedBy: webServerBlock, install: state.installApache)
            }
            Divider()
            SystemRow(symbol: "network", title: "Nginx",
                      detail: "Another web server to choose per site. It runs instead of Apache, never together with it") {
                softwareStatus(installed: state.setup.nginx, version: state.setup.nginxVersion, key: "nginx",
                               formula: "nginx", blockedBy: webServerBlock, install: state.installNginx)
            }
            Divider()
            ForEach(phpRows, id: \.self) { id in
                phpRow(id)
                Divider()
            }
            ForEach(DatabaseEngine.allCases.filter(\.hasServer)) { engine in
                if engine != .mysql { Divider() }
                engineRow(engine)
            }
            ForEach(Runtime.allCases) { runtime in
                Divider()
                runtimeRow(runtime)
            }
        }
    }

    private func engineRow(_ engine: DatabaseEngine) -> some View {
        SystemRow(symbol: engine.symbol, title: engine.name, detail: engine.detail) {
            softwareStatus(installed: state.setup.engines.contains(engine), version: state.setup.engineVersions[engine],
                           key: engine.rawValue, formula: state.setup.engineFormulae[engine],
                           blockedBy: state.isRunning(engine) ? "Switch your databases off first" : nil) {
                if engine == .mongodb { confirmingMongo = true } else { state.installEngine(engine) }
            }
        }
    }

    private func runtimeRow(_ runtime: Runtime) -> some View {
        let running = state.runningServers(of: runtime)
        return SystemRow(symbol: runtime.symbol, title: runtime.name, detail: runtime.detail) {
            softwareStatus(installed: state.setup.runtimes.contains(runtime), version: state.setup.runtimeVersions[runtime],
                           key: runtime.rawValue, formula: state.setup.runtimeFormulae[runtime],
                           blockedBy: running.isEmpty ? nil : "Switch your \(runtime.name) servers off first") {
                state.installRuntime(runtime)
            }
        }
    }

    /// Versions PHP still supports, plus any installed ones that it no longer does, newest first.
    private var phpRows: [String] {
        Set(state.supportedPHP).union(state.setup.phpVersions.map(\.id))
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Updating swaps the program a running server uses, so it waits until the servers are off.
    private var webServerBlock: String? { state.webServerRunning ? "Switch your servers off first" : nil }

    private func phpRow(_ id: String) -> some View {
        let installed = state.setup.phpVersions.first { $0.id == id }
        let supported = state.supportedPHP.contains(id)
        let full = state.setup.phpFullVersions[id]
        let detail = !supported
            ? "PHP no longer fixes security problems in this version. Move your servers to a newer one"
            : id == state.supportedPHP.first ? "Runs your sites' code. Each server picks its version." : "Another version to choose per server"
        return SystemRow(symbol: "chevron.left.forwardslash.chevron.right", title: "PHP \(id)", detail: detail) {
            if let installed, !supported {
                unsupportedPHP(installed, full: full)
            } else {
                // A newer minor version (8.5 to 8.6) is a different row; only fixes within this one are updates.
                let update = installed.flatMap { state.updates[$0.formula] }.flatMap { $0.hasPrefix(id + ".") ? $0 : nil }
                softwareStatus(installed: installed != nil, version: full, key: "php@\(id)", formula: installed?.formula,
                               update: update, blockedBy: webServerBlock) { state.installPHP(id) }
            }
        }
    }

    /// A version PHP has dropped: still usable, flagged, and can be removed.
    @ViewBuilder
    private func unsupportedPHP(_ version: PHP.Version, full: String?) -> some View {
        if state.isBusy("install:php@\(version.id)") {
            ProgressView().controlSize(.small)
        } else {
            let using = state.servers(usingPHP: version.id)
            let inUse = using.contains { state.isRunning($0) }
            HStack(spacing: 10) {
                Button("Remove") { removingPHP = version.id }
                    .buttonStyle(.secondary)
                    .disabled(inUse || state.isInstalling)
                    .help(inUse ? "A running server uses it. Switch it off first" : "")
                StatusPill(text: full.map { "\($0) · unsupported" } ?? "Unsupported", ok: false)
            }
        }
    }

    /// Its version when installed (with an Update button if there's a newer one), otherwise its own Install
    /// button. A spinner while either is running.
    @ViewBuilder
    private func softwareStatus(installed: Bool, version: String?, key: String, formula: String? = nil,
                                update: String? = nil, blockedBy: String? = nil,
                                install: @escaping () -> Void) -> some View {
        let latest = update ?? formula.flatMap { state.updates[$0] }
        if !state.setup.checked {
            EmptyView()
        } else if state.isBusy("install:\(key)") {
            ProgressView().controlSize(.small)
        } else if installed {
            HStack(spacing: 10) {
                if let formula, let latest {
                    Button("Update") { state.updateSoftware(formula: formula, key: key) }
                        .buttonStyle(.secondary)
                        .disabled(blockedBy != nil || state.isInstalling)
                        .help(blockedBy ?? "Update to \(latest)")
                }
                StatusPill(text: version ?? "Installed", ok: true)
            }
        } else {
            Button("Install", action: install)
                .buttonStyle(.secondary)
                .disabled(state.isInstalling || (key != "brew" && !state.setup.brew))
                .help(key != "brew" && !state.setup.brew ? "Install Homebrew first" : "")
        }
    }

    private var security: some View {
        SectionPanel(title: "Security",
                        footer: "Using Firefox? In about:config, set security.enterprise_roots.enabled to true so it trusts the certificates too.") {
            SystemRow(symbol: "lock.shield", title: "HTTPS certificates",
                      detail: "Lets https:// addresses open without warnings, from a certificate authority that exists only on This Mac") {
                if state.isBusy("ca") {
                    ProgressView().controlSize(.small)
                } else if state.setup.caTrusted {
                    StatusPill(text: "Installed", ok: true)
                } else {
                    Button("Install", action: state.trustCertificateAuthority)
                        .buttonStyle(.secondary)
                }
            }
            Divider()
            SystemRow(symbol: "point.3.connected.trianglepath.dotted", title: "Address helper",
                      detail: "Points your servers' addresses at This Mac without asking for your password each time") {
                if state.isBusy("helper") {
                    ProgressView().controlSize(.small)
                } else if state.setup.helperInstalled {
                    StatusPill(text: "Installed", ok: true)
                } else {
                    Button("Install", action: state.installHelper)
                        .buttonStyle(.secondary)
                }
            }
        }
    }
}

private struct SystemRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
