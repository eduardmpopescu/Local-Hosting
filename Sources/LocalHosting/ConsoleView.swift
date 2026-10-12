import SwiftUI

/// Follows a log file as it grows, keeping the most recent lines.
@MainActor
final class LogTail: ObservableObject {
    enum Level { case error, warning, normal }

    struct Line: Identifiable {
        let id: Int
        let text: String
        let level: Level
    }

    static let maxLines = 2000
    /// How much of an existing log to show when the console opens.
    private static let initialBytes: UInt64 = 256 * 1024

    @Published private(set) var lines: [Line] = []
    /// The whole log as one coloured text. One block has an exact, stable height, which keeps
    /// following the newest line reliable, and lets a selection span several lines. It's built once per
    /// batch of new lines, not once per line.
    @Published private(set) var text = AttributedString()
    @Published private(set) var exists = false

    let url: URL
    private var offset: UInt64 = 0
    /// Identifies the file on disk, so a replaced (rotated) log is read from its start.
    private var fileNumber: Int?
    private var partial = ""
    private var nextID = 0
    private var timer: Timer?

    init(url: URL) { self.url = url }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // The common modes keep it ticking while the window is being scrolled or resized.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Empties the log file. The server keeps appending to it, so new lines show up as usual.
    func clearFile() {
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }
        offset = 0
        partial = ""
        lines.removeAll()
        text = AttributedString()
    }

    private func poll() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            exists = false
            return
        }
        exists = true
        let number = attributes[.systemFileNumber] as? Int
        if size < offset || (fileNumber != nil && number != fileNumber) {
            // The log was rotated or emptied: start over from its beginning.
            offset = 0
            partial = ""
            lines.removeAll()
            text = AttributedString()
        }
        fileNumber = number
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let firstRead = offset == 0
        let start = firstRead && size > Self.initialBytes ? size - Self.initialBytes : offset
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        offset = start + UInt64(data.count)

        var parts = (partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        partial = parts.removeLast()
        // Starting mid-file, the first line is cut off.
        if firstRead && start > 0 && !parts.isEmpty { parts.removeFirst() }

        var added: [Line] = []
        for text in parts where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            added.append(Line(id: nextID, text: text, level: Self.level(of: text)))
            nextID += 1
        }
        guard !added.isEmpty else { return }
        var all = lines + added
        if all.count > Self.maxLines { all.removeFirst(all.count - Self.maxLines) }
        lines = all
        text = Self.render(all)
    }

    /// Lines of one colour are joined first and coloured as one piece: far fewer pieces than lines.
    private static func render(_ lines: [Line]) -> AttributedString {
        var text = AttributedString()
        var run = ""
        var runLevel = Level.normal

        func flush() {
            guard !run.isEmpty else { return }
            var part = AttributedString(run)
            switch runLevel {
            case .error: part.foregroundColor = Theme.danger
            case .warning: part.foregroundColor = Theme.attention
            case .normal: break
            }
            text.append(part)
            run = ""
        }

        for (index, line) in lines.enumerated() {
            if line.level != runLevel {
                flush()
                runLevel = line.level
            }
            run += index == lines.count - 1 ? line.text : line.text + "\n"
        }
        flush()
        return text
    }

    private static func level(of line: String) -> Level {
        let lower = line.lowercased()
        if lower.contains("error]") || lower.contains("[error") || lower.contains("fatal") || lower.contains("parse error")
            || lower.contains("error:") || lower.contains("traceback") || lower.contains("exception")
            || lower.contains("\"s\":\"e\"") || lower.contains("\"s\":\"f\"") { return .error }
        if lower.contains("warn") || lower.contains("\"s\":\"w\"") { return .warning }
        return .normal
    }
}

struct ConsoleView: View {
    enum Source: String, CaseIterable, Identifiable {
        // Raw values are what's remembered between launches; "Web server" is the original.
        case web = "Web server", php = "PHP", apps = "Apps", mysql = "MySQL", postgresql = "PostgreSQL", mongodb = "MongoDB", redis = "Redis"
        var id: String { rawValue }

        /// The database engine whose log this is.
        var engine: DatabaseEngine? {
            switch self {
            case .mysql: .mysql
            case .postgresql: .postgresql
            case .mongodb: .mongodb
            case .redis: .redis
            default: nil
            }
        }

        init(_ engine: DatabaseEngine) {
            switch engine {
            case .postgresql: self = .postgresql
            case .mongodb: self = .mongodb
            case .redis: self = .redis
            default: self = .mysql
            }
        }

        var title: String {
            switch self {
            case .web: "Servers"
            case .apps: "Apps"
            default: engine?.name ?? rawValue
            }
        }

        var symbol: String {
            switch self {
            case .web: "globe"
            case .php: "chevron.left.forwardslash.chevron.right"
            case .apps: "bolt.horizontal"
            default: engine?.symbol ?? "terminal"
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @AppStorage("consoleSource") private var stored: Source = .web
    @StateObject private var apache = LogTail(url: Paths.apacheErrorLog)
    @StateObject private var nginx = LogTail(url: Paths.nginxErrorLog)
    @StateObject private var php = LogTail(url: Paths.phpLog)
    @StateObject private var apps = LogTail(url: Paths.appsLog)
    @StateObject private var mysql = LogTail(url: Paths.mysqlErrorLog)
    @StateObject private var postgres = LogTail(url: Paths.postgresLog)
    @StateObject private var mongo = LogTail(url: Paths.mongoLog)
    @StateObject private var redis = LogTail(url: Paths.redisLog)
    @ViewState private var following = true

    /// The logs of what's installed: there's nothing to read for software that isn't there.
    private var visible: [Source] {
        var sources: [Source] = []
        if state.setup.httpd || state.setup.nginx { sources.append(.web) }
        if state.setup.php { sources.append(.php) }
        if !state.setup.runtimes.isEmpty || state.config.servers.contains(where: { $0.siteKind.isApp }) { sources.append(.apps) }
        for engine in DatabaseEngine.allCases where engine.hasServer && state.setup.engines.contains(engine) {
            sources.append(Source(engine))
        }
        return sources
    }

    /// What's open: the remembered tab, or the first one when that software is gone.
    private var source: Source { visible.contains(stored) ? stored : (visible.first ?? stored) }

    private var subtitle: String {
        let names = visible.map { source -> String in
            switch source {
            case .web: "your servers"
            case .apps: "apps"
            default: source.title
            }
        }
        guard let last = names.last else { return "Live logs from what you install in Settings." }
        return "Live logs from " + (names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last) + "."
    }

    private var emptyMessage: String {
        switch source {
        case .web: "Apache or Nginx writes here while a server is on."
        case .php: "Your sites' PHP errors, warnings and error_log() messages show up here."
        case .apps: "Output from your Node, Python and Ruby servers shows up here, each line starting with the server's name."
        default: "\(source.title) writes here when it starts and stops, and when something goes wrong."
        }
    }

    private var tail: LogTail { tail(for: source) }

    private func tail(for source: Source) -> LogTail {
        switch source {
        case .web: state.lastWebServer == .nginx ? nginx : apache
        case .php: php
        case .apps: apps
        case .mysql: mysql
        case .postgresql: postgres
        case .mongodb: mongo
        case .redis: redis
        }
    }

    private var allTails: [LogTail] { [apache, nginx, php, apps, mysql, postgres, mongo, redis] }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Console", subtitle: subtitle) {
                if !visible.isEmpty {
                    HStack(spacing: 10) {
                        OptionMenu(selection: Binding(get: { source }, set: { stored = $0 }),
                                   options: visible.map { .init(value: $0, title: $0.title, symbol: $0.symbol) })
                        ShortcutButton(symbol: "eraser", shortcut: "⌘K", help: "Empty this log file (⌘K)") { tail.clearFile() }
                            .keyboardShortcut("k")
                            .disabled(!tail.exists)
                    }
                }
            }

            if visible.isEmpty {
                EmptyState(symbol: "terminal", title: "Nothing to show yet",
                           message: "Install software in Settings, and its log shows up here.")
            } else {
                LogView(tail: tail, following: $following, emptyMessage: emptyMessage)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, Theme.pagePadding)
            }
        }
        // Each log opens at its newest line.
        .onChange(of: source) { old, new in
            following = true
            // Only the log on screen is followed.
            tail(for: old).stop()
            tail(for: new).start()
        }
        .onAppear { tail.start() }
        .onDisappear { allTails.forEach { $0.stop() } }
    }
}

private struct LogView: View {
    @ObservedObject var tail: LogTail
    /// True while the view sits at the newest line. Scrolling up turns it off; scrolling back
    /// to the bottom turns it on again.
    @Binding var following: Bool
    let emptyMessage: String

    /// Where the scroll view is, and how tall its content is.
    private struct Position: Equatable {
        var atBottom: Bool
        var contentHeight: CGFloat
    }

    var body: some View {
        if tail.lines.isEmpty {
            EmptyState(symbol: "text.alignleft", title: "Nothing logged yet", message: emptyMessage)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tail.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .onScrollGeometryChange(for: Position.self) { geometry in
                    Position(atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24,
                             contentHeight: geometry.contentSize.height)
                } action: { old, new in
                    // Only a scroll (same content, new position) changes following;
                    // new lines arriving don't.
                    if old.contentHeight == new.contentHeight { following = new.atBottom }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: tail.lines.last?.id) { _, _ in
                    if following { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: following) { _, follow in
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .id(tail.url)
        }
    }
}
