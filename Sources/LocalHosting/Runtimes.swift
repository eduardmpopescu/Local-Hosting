import Foundation

/// The languages behind Node, Python and Ruby servers, installed with Homebrew.
enum Runtime: String, CaseIterable, Identifiable {
    case node, python, ruby
    var id: String { rawValue }

    var name: String { kind.name }

    /// The kind of server that needs it.
    var kind: SiteKind {
        switch self {
        case .node: .node
        case .python: .python
        case .ruby: .ruby
        }
    }

    /// What `brew install` is given. Python's is an alias for whichever 3.x Homebrew currently recommends.
    var formula: String { self == .python ? "python3" : rawValue }

    /// The program that runs the language.
    var executableName: String { self == .python ? "python3" : rawValue }

    var executable: String { "\(Paths.brewPrefix)/bin/\(executableName)" }

    var symbol: String {
        switch self {
        case .node: "hexagon"
        case .python: "curlybraces"
        case .ruby: "diamond"
        }
    }

    var detail: String {
        switch self {
        case .node: "Runs your Node servers, with npm to install their packages"
        case .python: "Runs your Python servers (Django, Flask), with pip to install their packages"
        case .ruby: "Runs your Ruby servers (Rails), with gem to install their packages"
        }
    }

    /// Installed means Homebrew's own copy is there; nvm, pyenv and the like don't count.
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    /// The Homebrew formula behind the installed program, e.g. "python@3.15". Updates are looked up by it.
    /// Read from where the link in Homebrew's bin folder leads: `…/Cellar/python@3.15/3.15.0/bin/python3`.
    var installedFormula: String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: executable) else { return nil }
        let parts = target.split(separator: "/")
        guard let cellar = parts.firstIndex(of: "Cellar"), parts.indices.contains(cellar + 1) else { return nil }
        return String(parts[cellar + 1])
    }

    /// Asks the program for its version: "v26.11.1", "Python 3.15.0", "ruby 4.0.7 (2026-…)".
    func version() async -> String? {
        let result = await Shell.run(executable, ["--version"])
        guard result.ok else { return nil }
        let first = result.output.split(whereSeparator: { $0 == " " || $0 == "\n" })
        let word = self == .node ? first.first : first.dropFirst().first
        return word.map { $0.hasPrefix("v") ? String($0.dropFirst()) : String($0) }
    }

    /// Part of the setup fingerprint: changes when the program is installed, removed or upgraded.
    var fingerprint: String {
        guard isInstalled else { return "0" }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: executable)) ?? "1"
    }

    /// Shell lines that put Homebrew's copy first when the login shell would only find macOS's own
    /// (`/usr/bin/python3`, `/usr/bin/ruby`) or nothing. Tools from nvm, pyenv or rbenv keep winning.
    static var pathSetup: String {
        let bin = shellQuote("\(Paths.brewPrefix)/bin")
        let names = allCases.map(\.executableName).joined(separator: " ")
        return """
        for tool in \(names); do
          case "$(command -v $tool 2>/dev/null)" in
            ""|/usr/bin/*) [ -x \(bin)/$tool ] && PATH=\(bin):$PATH ;;
          esac
        done
        export PATH
        """
    }
}

extension SiteKind {
    /// The language a Node, Python or Ruby server needs installed.
    var runtime: Runtime? { Runtime.allCases.first { $0.kind == self } }
}
