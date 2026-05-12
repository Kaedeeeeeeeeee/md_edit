import Foundation
import CoreServices

/// Watches a folder (recursively) and fires `onChange` when files change.
/// Uses FSEventStream — the macOS-native API used by Finder, mds, Dropbox.
/// Coalesces bursts via a small debounce so we don't thrash the UI when an
/// editor saves many files at once.
///
/// Lifecycle: owned by `DocumentStore`. We don't bother cleaning up in
/// `deinit` — the watcher lives for the duration of the process and the
/// kernel reclaims FSEventStream resources on app exit. Explicit `stop()`
/// is invoked when switching folders.
@MainActor
final class FolderWatcher {
    var onChange: (@MainActor () -> Void)?

    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var debounceTask: Task<Void, Never>?

    /// Begin watching `url`. If already watching another path, stop that one first.
    func start(watching url: URL) {
        if watchedPath == url.path { return }
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    watcher.scheduleRefresh()
                }
            }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            /* latency: */ 0.3,
            flags
        ) else {
            print("FSEventStreamCreate failed for", url.path)
            return
        }

        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        watchedPath = url.path
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        watchedPath = nil
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
            guard !Task.isCancelled, let self else { return }
            self.onChange?()
        }
    }
}
