import Foundation

/// A single file's blaze mark, resolved for display in a navigator row.
///
/// `fraction` is the mark's normalized position within the project's hierarchy (0 = lowest level,
/// 1 = highest); it drives the saturation of the badge color. It is meaningful only when
/// `isHierarchy` is true. `canBumpUp`/`canBumpDown` reflect whether a `bump` is possible from here.
struct BlazeMark: Equatable {
    let name: String
    let abbreviation: String
    let isHierarchy: Bool
    let fraction: Double
    let canBumpUp: Bool
    let canBumpDown: Bool
}

/// Reads `.blaze/marks.toml` for the current project and exposes per-file marks for the navigator.
///
/// Reads are done directly from the TOML file (fast, no subprocess). Writes — `mark` and `bump` —
/// shell out to the `blaze` CLI, which is the only supported way to mutate blaze state. After a write
/// the model re-reads, and the navigator's FSEvents watcher also catches the `marks.toml` change, so
/// indicators refresh either way.
final class BlazeTracker: ObservableObject {
    // Whether `.blaze/` exists in the project. Drives the "not initialized" message.
    @Published private(set) var isInitialized: Bool = false

    // Resolved absolute file path → its mark. Only marked files appear.
    @Published private(set) var marks: [String: BlazeMark] = [:]

    // All mark names in the project's registry, hierarchy marks first (in level order), then the rest.
    // Used to populate the "Mark" context-menu submenu.
    @Published private(set) var markNames: [String] = []

    // Reads/writes run off the main thread; results are published back on main.
    private let queue = DispatchQueue(label: "com.blobtxt.blazetracker", qos: .userInitiated)

    // Cached from the last `refresh` so the write methods can re-resolve paths and re-read afterward.
    private var projectURL: URL?
    private var abbreviations: [String: String] = [:]

    // The pipx-installed blaze shim. Its `-E` shebang points at blaze's own venv Python, so invoking
    // it by absolute path runs correctly regardless of the GUI app's PATH.
    private static let blazeURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/blaze")

    // MARK: - Reading

    // Recomputes marks for `projectURL`, using `abbreviations` (from `.blobtxt`) for badge letters.
    // A nil URL (no open project) clears everything.
    func refresh(projectURL: URL?, abbreviations: [String: String]) {
        guard let projectURL = projectURL else {
            self.projectURL = nil
            isInitialized = false
            marks = [:]
            markNames = []
            return
        }
        self.projectURL = projectURL
        self.abbreviations = abbreviations

        queue.async { [weak self] in
            guard let self = self else { return }

            let blazeDir = projectURL.appendingPathComponent(".blaze")
            let marksURL = blazeDir.appendingPathComponent("marks.toml")
            guard FileManager.default.fileExists(atPath: blazeDir.path),
                  let text = try? String(contentsOf: marksURL, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.isInitialized = false
                    self.marks = [:]
                    self.markNames = []
                }
                return
            }

            let (map, names) = Self.build(
                from: text,
                repoRoot: projectURL.resolvingSymlinksInPath().path,
                abbreviations: abbreviations
            )
            DispatchQueue.main.async {
                self.isInitialized = true
                self.marks = map
                self.markNames = names
            }
        }
    }

    // MARK: - Lookups used by the navigator rows

    func mark(forFileAt resolvedPath: String) -> BlazeMark? {
        marks[resolvedPath]
    }

    // MARK: - Writing (shell out to the blaze CLI)

    func applyMark(fileAt resolvedPath: String, as markName: String) {
        runBlaze(["mark", markName, relativePath(resolvedPath)])
    }

    func bumpUp(fileAt resolvedPath: String) {
        runBlaze(["bump", "up", relativePath(resolvedPath)])
    }

    func bumpDown(fileAt resolvedPath: String) {
        runBlaze(["bump", "down", relativePath(resolvedPath)])
    }

    // MARK: - Parsing

    /// Builds the mark map and the menu name list from `marks.toml` text.
    ///
    /// Reads three sections: `[marks]` (the registry, used for the menu and to know which marks are
    /// flat), `[hierarchy]` (mark → level, defines color/saturation and bump bounds), and `[files]`
    /// (path → mark). File paths are relative to the repo root and may be quoted.
    private static func build(
        from text: String,
        repoRoot: String,
        abbreviations: [String: String]
    ) -> (map: [String: BlazeMark], names: [String]) {
        let sections = parseTOML(text)

        let registry = sections["marks"] ?? [:]
        let hierarchy = (sections["hierarchy"] ?? [:]).compactMapValues { Int($0) }
        let files = sections["files"] ?? [:]

        let minLevel = hierarchy.values.min()
        let maxLevel = hierarchy.values.max()

        // Menu order: hierarchy marks in level order, then the remaining registry marks alphabetically.
        let hierarchyNames = hierarchy.sorted { $0.value < $1.value }.map { $0.key }
        let flatNames = registry.keys.filter { hierarchy[$0] == nil }.sorted()
        let names = hierarchyNames + flatNames

        func abbreviate(_ markName: String) -> String {
            abbreviations[markName] ?? String(markName.prefix(2)).uppercased()
        }

        var map: [String: BlazeMark] = [:]
        for (relPath, markName) in files {
            let absolute = (repoRoot as NSString).appendingPathComponent(relPath)
            let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path

            if let level = hierarchy[markName], let minLevel = minLevel, let maxLevel = maxLevel {
                let range = maxLevel - minLevel
                let fraction = range == 0 ? 1.0 : Double(level - minLevel) / Double(range)
                map[resolved] = BlazeMark(
                    name: markName,
                    abbreviation: abbreviate(markName),
                    isHierarchy: true,
                    fraction: fraction,
                    canBumpUp: level < maxLevel,
                    canBumpDown: level > minLevel
                )
            } else {
                map[resolved] = BlazeMark(
                    name: markName,
                    abbreviation: abbreviate(markName),
                    isHierarchy: false,
                    fraction: 1,
                    canBumpUp: false,
                    canBumpDown: false
                )
            }
        }
        return (map, names)
    }

    // A minimal TOML reader: `[section]` headers and `key = value` lines, with surrounding quotes
    // stripped from both key and value. Sufficient for the flat sections blaze writes; ignores
    // comments and anything fancier (arrays, nested tables), which marks.toml does not use.
    private static func parseTOML(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if let current = current, sections[current] == nil { sections[current] = [:] }
                continue
            }

            guard let eq = line.firstIndex(of: "="), let section = current else { continue }
            let key = stripQuotes(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let value = stripQuotes(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            if !key.isEmpty { sections[section, default: [:]][key] = value }
        }
        return sections
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!, last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Process

    // The path blaze records in `[files]` is relative to the repo root, so its commands expect the
    // same. Strip the resolved project root from the resolved absolute path.
    private func relativePath(_ resolved: String) -> String {
        guard let root = projectURL?.resolvingSymlinksInPath().path else { return resolved }
        if resolved.hasPrefix(root + "/") { return String(resolved.dropFirst(root.count + 1)) }
        return resolved
    }

    // Runs `blaze args` in the project directory, then re-reads so the change shows immediately.
    // No-ops (without error) if blaze is not installed at the expected path or no project is open.
    private func runBlaze(_ args: [String]) {
        guard let projectURL = projectURL,
              FileManager.default.fileExists(atPath: Self.blazeURL.path) else { return }
        let abbreviations = self.abbreviations

        queue.async { [weak self] in
            let process = Process()
            process.executableURL = Self.blazeURL
            process.arguments = args
            process.currentDirectoryURL = projectURL
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }
            // Re-read on the main actor's behalf via refresh, which re-dispatches to this queue.
            DispatchQueue.main.async {
                self?.refresh(projectURL: projectURL, abbreviations: abbreviations)
            }
        }
    }
}
