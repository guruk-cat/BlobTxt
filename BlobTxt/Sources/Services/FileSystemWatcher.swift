import Foundation
import CoreServices

// Watches a directory tree for changes using the macOS FSEvents API and invokes `onChange` on the main queue. The FSEvents latency coalesces rapid bursts into one call.
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    // FSEvents delivers callbacks on this private queue; we hop to main before notifying.
    private let queue = DispatchQueue(label: "com.blobtxt.fswatcher")

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(path: url.path)
    }

    deinit { stop() }

    private func start(path: String) {
        // `info` carries a pointer back to self so the C callback can reach this instance.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onChange() }
        }

        // 0.3s latency coalesces bursts; FileEvents reports per-file granularity;
        // NoDefer fires the first event promptly rather than waiting out the latency.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
