import SwiftUI

struct DatabasesView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var resources: ResourceMonitor
    @ViewState private var creating = false
    @ViewState private var changingPassword: Database?
    @ViewState private var deleting: Database?
    @AppStorage("selectedDatabase") private var selectedRaw = ""

    /// The database whose details are open: the one picked, or the first when none is (or it's gone).
    private var selected: Database? {
        state.config.databases.first { $0.id.uuidString == selectedRaw } ?? state.config.databases.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Databases", subtitle: "Each database has its own user and password. Switch one on to use it.") {
                Button {
                    creating = true
                    // What's installed is looked up again, so software added meanwhile is offered.
                    Task { await state.refreshSetup() }
                } label: {
                    Label("New database", systemImage: "plus").labelStyle(ButtonLabelStyle())
                }
                .buttonStyle(.primary)
                .keyboardShortcut("n")
                .help("New database (⌘N)")
            }

            if state.config.databases.isEmpty {
                EmptyState(
                    symbol: "cylinder.split.1x2",
                    title: "No databases yet",
                    message: "Create a database for each project. It gets its own user and password to put in the project's settings."
                )
            } else {
                MasterDetail {
                    // A group appears for each kind of database once there's one.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(DatabaseEngine.allCases) { engine in
                            let databases = state.config.databases.filter { $0.engine == engine }
                            if !databases.isEmpty {
                                ListGroup(title: engine.name, symbol: engine.symbol, count: databases.count, key: "databases-\(engine.rawValue)") {
                                    ForEach(databases) { db in
                                        ListItemRow(symbol: engine.symbol, title: db.name, subtitle: subtitle(for: db),
                                                    live: state.isRunning(db), selected: db.id == selected?.id) {
                                            selectedRaw = db.id.uuidString
                                        }
                                        .cardMenu {
                                            DatabaseMenu.items(for: db, state: state,
                                                               changePassword: { changingPassword = db }, delete: { deleting = db })
                                        }
                                    }
                                }
                            }
                        }
                    }
                } detail: {
                    if let db = selected {
                        DatabaseDetail(db: db, changePassword: { changingPassword = db }, delete: { deleting = db })
                            .id(db.id)
                    }
                }
            }
        }
        .task(id: selected?.id) { await resources.watch(state, focus: selected.map { .database($0) }) }
        .sheet(isPresented: $creating) { DatabaseEditor() }
        .sheet(item: $changingPassword) { PasswordEditor(db: $0) }
        .onAppear { if Paths.testSheet == "database" { creating = true } }
        .sheet(item: $deleting) { db in
            ConfirmSheet(
                symbol: "trash", title: "Delete this database?",
                message: db.engine == .sqlite
                    ? "The database file and everything in it is permanently deleted. This can't be undone."
                    : "Everything in this database is permanently deleted. This can't be undone.",
                confirmTitle: "Continue",
                confirmSymbol: "checkmark",
                cancel: { deleting = nil },
                confirm: {
                    state.deleteDatabase(db)
                    deleting = nil
                }
            )
        }
    }

    /// The line under a database's name in the list.
    private func subtitle(for db: Database) -> String {
        guard db.engine.hasServer else { return "File" }
        let host = db.engine == .mysql ? state.config.mysqlHost : "127.0.0.1"
        return "\(host):\(state.config.port(for: db.engine))"
    }
}

/// Everything about one database: its state and switch, what it can do, how to connect and what it uses.
struct DatabaseDetail: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var resources: ResourceMonitor
    let db: Database
    let changePassword: () -> Void
    let delete: () -> Void

    private var engine: DatabaseEngine { db.engine }
    private var on: Bool { state.isRunning(db) }
    private var busy: Bool { state.isBusy(db.id) }

    private var status: String {
        if !engine.hasServer { return "A file on This Mac" }
        if busy { return "Updating…" }
        return on ? "On · accepting connections" : "Off · not accepting connections"
    }

    private var host: String { engine == .mysql ? state.config.mysqlHost : "127.0.0.1" }

    private var serverText: String {
        engine.hasServer ? [engine.name, state.setup.engineVersions[engine]].compactMap { $0 }.joined(separator: " ") : "SQLite"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(symbol: engine.symbol, title: db.name, status: status, live: on) {
                    if engine.hasServer {
                        Toggle("On", isOn: Binding(get: { on }, set: { _ in state.toggle(db) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Theme.live)
                            .disabled(busy || !state.setup.isInstalled(engine))
                            .help(on ? "Switch \(db.name) off" : "Switch \(db.name) on")
                            .accessibilityLabel(on ? "Switch \(db.name) off" : "Switch \(db.name) on")
                    }
                }

                HStack(spacing: 8) {
                    Button { state.browse(db.name) } label: {
                        Label(engine.browseTitle, systemImage: "tablecells").labelStyle(ButtonLabelStyle())
                    }
                    .buttonStyle(.secondary)
                    if engine.hasAccounts {
                        Button(action: changePassword) {
                            Label("Change Password…", systemImage: "key.horizontal").labelStyle(ButtonLabelStyle())
                        }
                        .buttonStyle(.secondary)
                    }
                    if !engine.hasServer {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([db.file]) } label: {
                            Label("Show in Finder", systemImage: "folder").labelStyle(ButtonLabelStyle())
                        }
                        .buttonStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: delete) {
                        Label("Delete…", systemImage: "trash").labelStyle(ButtonLabelStyle()).foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.secondary)
                }

                DetailBlock(title: "Connection") { connectionRows }

                DetailSection(title: "Usage") {
                    HStack(spacing: 12) {
                        if engine.hasServer {
                            StatTile(label: "RAM", value: Usage.memory(resources.memory[db.id]),
                                     caption: "Shared by all databases")
                        }
                        StatTile(label: "Storage", value: Usage.disk(resources.storage[db.id]),
                                 caption: engine == .redis ? "Saved data, shared by all" : "This database on disk")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var connectionRows: some View {
        DetailRow(label: "Server", value: serverText)
        Divider()
        if engine.hasServer {
            DetailRow(label: "Address", value: host)
            Divider()
            DetailRow(label: "Port", value: String(state.config.port(for: engine)))
            Divider()
        } else {
            DetailRow(label: "File", value: (db.file.path as NSString).abbreviatingWithTildeInPath).help(db.file.path)
        }
        switch engine {
        case .mysql, .postgresql, .mongodb:
            DetailRow(label: "User", value: db.username, copy: db.username)
            Divider()
            DetailRow(label: "Password", value: db.password, copy: db.password)
        case .redis:
            DetailRow(label: "Database", value: String(db.index ?? 0))
            Divider()
            DetailRow(label: "Password", value: db.password, copy: db.password)
        case .sqlite:
            EmptyView()
        }
    }
}

/// The right-click menu of a database.
@MainActor
enum DatabaseMenu {
    @ViewBuilder
    static func items(for db: Database, state: AppState, changePassword: @escaping () -> Void,
                      delete: @escaping () -> Void) -> some View {
        let engine = db.engine
        let on = state.isRunning(db)
        MenuItem(title: engine.browseTitle, symbol: "tablecells") { state.browse(db.name) }
        if engine.hasServer {
            MenuItem(title: on ? "Switch Off" : "Switch On", symbol: on ? "stop.circle" : "play.circle") { state.toggle(db) }
        } else {
            MenuItem(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([db.file]) }
        }
        MenuSeparator()
        if engine.hasServer {
            MenuItem(title: "Copy Port", symbol: "number") { copyToPasteboard(String(state.config.port(for: engine))) }
        }
        switch engine {
        case .mysql, .postgresql, .mongodb:
            MenuItem(title: "Copy User", symbol: "person") { copyToPasteboard(db.username) }
            MenuItem(title: "Copy Password", symbol: "key") { copyToPasteboard(db.password) }
            MenuItem(title: "Change Password…", symbol: "key.horizontal", action: changePassword)
        case .redis:
            MenuItem(title: "Copy Password", symbol: "key") { copyToPasteboard(db.password) }
        case .sqlite:
            MenuItem(title: "Copy File Path", symbol: "doc.on.doc") { copyToPasteboard(db.file.path) }
        }
        MenuSeparator()
        MenuItem(title: "Delete…", symbol: "trash", destructive: true, action: delete)
    }
}

struct DatabaseEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var engine = DatabaseEngine.mysql

    /// The software that's installed on This Mac. SQLite always is.
    private var engineChoices: [DatabaseEngine] { DatabaseEngine.allCases.filter { state.setup.isInstalled($0) } }

    private var existingUser: Database? {
        guard engine.hasAccounts else { return nil }
        return state.config.databases.first { $0.engine == engine && $0.username == username }
    }

    /// The number the next Redis database gets, if any is left.
    private var nextRedisNumber: Int? {
        let taken = Set(state.config.databases.compactMap { $0.engine == .redis ? $0.index : nil })
        return (0..<RedisService.databaseCount).first { !taken.contains($0) }
    }

    private var validationError: String? {
        if name.isEmpty { return "" }
        if engine.hasAccounts && (username.isEmpty || password.isEmpty) { return "" }
        // Typed input that isn't valid yet just keeps Continue off; only conflicts and reserved names get a message.
        if !Database.isValidName(name) { return "" }
        if engine.reservedNames.contains(name.lowercased()) { return "“\(name)” is reserved by \(engine.name)." }
        if state.config.databases.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            return "A database named “\(name)” already exists."
        }
        if engine.hasAccounts {
            if !Database.isValidUsername(username) { return "" }
            let admin = engine == .mysql ? MySQL.adminUser : ""
            if engine.reservedUsers.contains(username.lowercased()) || username == admin {
                return "“\(username)” is reserved. Choose another user."
            }
            if password.contains(where: \.isNewline) { return "" }
        }
        if engine == .redis && nextRedisNumber == nil { return "All \(RedisService.databaseCount) Redis databases are in use." }
        if engine == .sqlite && FileManager.default.fileExists(atPath: Paths.sqliteFile(named: name).path) {
            return "A file for “\(name)” already exists in the SQLite folder."
        }
        return nil
    }

    /// What the name, user and password are for, under the first group.
    private var identityNote: String {
        switch engine {
        case .mysql, .postgresql, .mongodb:
            "Your project connects with these. Names and users can use letters, numbers and _."
        case .redis:
            "Only how Local Hosting lists it. A project connects with the number below and the server's password."
        case .sqlite:
            "The name of the file, and of this database in Local Hosting. It can use letters, numbers and _."
        }
    }

    /// What the engine means for this database, under the second group.
    private var note: String {
        switch engine {
        case .mysql, .postgresql, .mongodb:
            "\(engine.name) starts when a database of it is switched on."
        case .redis:
            "Redis has no separate users: every database uses the server's one password, shown on each row. A database is a number, from 0 to \(RedisService.databaseCount - 1)."
        case .sqlite:
            "SQLite keeps the whole database in one file, with no server and no user or password."
        }
    }

    /// A new database starts on a software that's installed, once that's known.
    private func chooseAvailable() {
        guard state.setup.checked, !engineChoices.contains(engine), let first = engineChoices.first else { return }
        engine = first
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                symbol: "cylinder.split.1x2",
                title: "New database",
                message: "An empty database for a project, in the software you choose."
            )

            VStack(alignment: .leading, spacing: 16) {
                FieldGroup {
                    FieldRow(label: "Name") {
                        TextField("Name", text: $name, prompt: Text("Type the name of the database…"))
                            .textFieldStyle(.plain)
                    }
                    if engine.hasAccounts {
                        Divider()
                        FieldRow(label: "User") {
                            TextField("User", text: $username, prompt: Text("Type the user of the database…"))
                                .textFieldStyle(.plain)
                        }
                        Divider()
                        FieldRow(label: "Password") {
                            TextField("Password", text: $password, prompt: Text("Type the password of the database…"))
                                .textFieldStyle(.plain)
                        }
                    }
                }
                FieldNote(identityNote)
                if let existing = existingUser {
                    FieldNote("\(username) already has access to \(existing.name). A user has one password, so this one replaces it for both databases.")
                }

                FieldGroup {
                    FieldRow(label: "Engine") {
                        OptionMenu(selection: $engine, options: engineChoices.map {
                            .init(value: $0, title: $0.name, symbol: $0.symbol)
                        })
                    }
                    if engine == .redis, let number = nextRedisNumber {
                        Divider()
                        FieldRow(label: "Database") {
                            Text("Number \(number)").font(Theme.data).foregroundStyle(.secondary)
                        }
                    }
                    if engine == .sqlite {
                        Divider()
                        FieldRow(label: "File") {
                            Text((Paths.sqliteFile(named: name.isEmpty ? "name" : name).path as NSString).abbreviatingWithTildeInPath)
                                .font(Theme.data)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                FieldNote(note)

                if let error = validationError, !error.isEmpty {
                    FieldProblem(text: error)
                }
            }
            .padding(20)

            SheetFooter(canConfirm: validationError == nil, cancel: { dismiss() }) {
                state.addDatabase(Database(name: name, username: engine.hasAccounts ? username : "",
                                           password: engine.hasAccounts ? password : "", kind: engine))
                dismiss()
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: chooseAvailable)
        .onChange(of: state.setup.checked) { chooseAvailable() }
        .onChange(of: engineChoices) { chooseAvailable() }
    }
}

struct PasswordEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let db: Database
    @ViewState private var password = ""

    /// An empty or unusable password only keeps the button off; there's nothing to explain.
    private var problem: String? { password.isEmpty || state.validatePassword(password) != nil ? "" : nil }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(symbol: "key.horizontal", title: "Change password",
                        message: "Update it in your project's settings too.")
            VStack(alignment: .leading, spacing: 16) {
                FieldGroup {
                    FieldRow(label: "Password") {
                        TextField("Password", text: $password, prompt: Text("Type the new password…"))
                            .textFieldStyle(.plain)
                    }
                }
            }
            .padding(20)
            SheetFooter(confirmTitle: "Save", canConfirm: problem == nil, cancel: { dismiss() }) {
                state.changePassword(db, to: password)
                dismiss()
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
