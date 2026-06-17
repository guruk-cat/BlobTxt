import Foundation
import AppKit

// Renders a blob to PDF by shelling out to pandoc with the weasyprint engine. This is the basic
// wiring for the Page Layout feature; for now it always uses the built-in "default" profile (vanilla
// pandoc output plus auto-numbered figure captions). Custom profiles and a configuring UI come later.
enum PrintService {
    // A GUI app launched from Finder does not inherit the shell PATH, so the executables and the
    // directories pandoc itself searches for weasyprint must be located explicitly.
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    // The default profile, injected into the HTML <head>: numbers each figure's caption ("Figure 1.",
    // "Figure 2.", …). Pandoc promotes a standalone image's alt-text into a <figcaption>, which this
    // counter then prefixes.
    private static let defaultHeaderCSS = """
    <style>
    body { counter-reset: figure; }
    figure { break-inside: avoid; }
    figcaption::before {
      counter-increment: figure;
      content: "Figure " counter(figure) ". ";
      font-weight: bold;
    }
    </style>
    """

    struct PrintError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Renders the blob at `input` to a PDF at `output`. The subprocess runs off the main thread;
    // `completion` is delivered on the main thread.
    static func printBlob(at input: URL, to output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try run(input: input, output: output) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(input: URL, output outputURL: URL) throws -> URL {
        guard let pandoc = resolve("pandoc") else {
            throw PrintError(message: "Could not find the `pandoc` executable. Install it with Homebrew: brew install pandoc.")
        }

        let headerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobtxt-print-header-\(UUID().uuidString).html")
        try defaultHeaderCSS.write(to: headerURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: headerURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandoc)
        process.arguments = [
            input.path,
            "--from", "markdown",
            "--pdf-engine=weasyprint",
            "--include-in-header", headerURL.path,
            "--output", outputURL.path,
        ]
        // pandoc invokes weasyprint by name, so it must be on the child's PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env
        // Resolve the blob's relative image paths against its own directory.
        process.currentDirectoryURL = input.deletingLastPathComponent()

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        // Drain stderr before waiting so a large error message can't fill the pipe and deadlock.
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? "Unknown error."
            throw PrintError(message: message.isEmpty ? "pandoc exited with status \(process.terminationStatus)." : message)
        }
        return outputURL
    }

    private static func resolve(_ name: String) -> String? {
        for dir in searchPaths {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
