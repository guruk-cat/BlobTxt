import Foundation

// A git status category, each mapped to one of the three dedicated tracking colors in `AppColors`.
enum GitStatusKind: Hashable {
    case untracked
    case unstaged
    case staged
}

// A single letter badge shown at the trailing end of a navigator row in git mode.
// A file can carry two (e.g. a green "M" plus a yellow "M" when it is staged and then edited again).
struct GitBadge: Hashable {
    let letter: String
    let kind: GitStatusKind
}

// Runs `git status` for the current project and exposes a per-file status map the navigator can read.
// Status is keyed by symlink-resolved absolute path so it matches `FileNode.url.resolvingSymlinksInPath()`.
// Paths are resolved against the repository's top level (not the project folder) so a project nested
// inside a larger repository still maps correctly; files outside the project simply match no tree node.
final class GitTracker: ObservableObject {
    @Published private(set) var isRepository: Bool = false
    // file path → its badges (one, or two for the staged-and-edited-again case).
    @Published private(set) var statuses: [String: [GitBadge]] = [:]
    // git work is done off the main thread; results are published back on main.
    private let queue = DispatchQueue(label: "com.blobtxt.gittracker", qos: .userInitiated)
    private static let gitPath = "/usr/bin/git"

    // Recomputes status for `projectURL`. A nil URL (no open project) clears everything.
    func refresh(projectURL: URL?) {
        guard let projectURL = projectURL else {
            isRepository = false
            statuses = [:]
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }

            // `--show-toplevel` doubles as the repo check: it exits non-zero outside a work tree.
            guard let top = self.runGit(["rev-parse", "--show-toplevel"], in: projectURL),
                  top.status == 0 else {
                DispatchQueue.main.async {
                    self.isRepository = false
                    self.statuses = [:]
                }
                return
            }
            let repoRoot = top.output.trimmingCharacters(in: .whitespacesAndNewlines)

            let map: [String: [GitBadge]]
            if let result = self.runGit(["status", "--porcelain"], in: projectURL), result.status == 0 {
                map = Self.parse(porcelain: result.output, repoRoot: repoRoot)
            } else {
                map = [:]
            }

            DispatchQueue.main.async {
                self.isRepository = true
                self.statuses = map
            }
        }
    }

    // MARK: - Lookups used by the navigator rows

    func badges(forFileAt resolvedPath: String) -> [GitBadge] {
        statuses[resolvedPath] ?? []
    }

    // Aggregate status for a folder: the single highest-priority kind among any file inside it,
    // or nil when nothing within has changed.
    func aggregateKind(forFolderAt resolvedPath: String) -> GitStatusKind? {
        let prefix = resolvedPath + "/"
        var kinds: Set<GitStatusKind> = []
        for (path, badges) in statuses where path.hasPrefix(prefix) {
            for badge in badges { kinds.insert(badge.kind) }
        }
        if kinds.contains(.untracked) { return .untracked }
        if kinds.contains(.unstaged) { return .unstaged }
        if kinds.contains(.staged) { return .staged }
        return nil
    }

    // MARK: - Parsing

    // Parses `git status --porcelain` (v1) output into per-file badges.
    // Each line is `XY <path>`, where X is the index (staged) column and Y the working-tree
    // (unstaged) column. `??` marks an untracked file. A rename line carries `old -> new`.
    private static func parse(porcelain: String, repoRoot: String) -> [String: [GitBadge]] {
        var map: [String: [GitBadge]] = [:]

        for rawLine in porcelain.components(separatedBy: "\n") where rawLine.count >= 4 {
            let chars = Array(rawLine)
            let x = chars[0]
            let y = chars[1]
            var path = String(rawLine.dropFirst(3))
            if let range = path.range(of: " -> ") {
                path = String(path[range.upperBound...])
            }

            let absolute = (repoRoot as NSString).appendingPathComponent(path)
            let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path

            var badges: [GitBadge] = []
            if x == "?" && y == "?" {
                badges.append(GitBadge(letter: "U", kind: .untracked))
            } else {
                // Staged column first (rendered green), then the unstaged column (yellow).
                if x != " " { badges.append(GitBadge(letter: String(x), kind: .staged)) }
                if y != " " { badges.append(GitBadge(letter: String(y), kind: .unstaged)) }
            }
            if !badges.isEmpty { map[resolved] = badges }
        }
        return map
    }

    // MARK: - Process

    // Runs git with `args` in `dir`, returning its exit status and stdout, or nil if it failed to launch.
    private func runGit(_ args: [String], in dir: URL) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = args
        process.currentDirectoryURL = dir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
