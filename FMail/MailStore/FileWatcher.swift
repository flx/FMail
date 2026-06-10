import Foundation
import CoreServices

/// Wraps an `FSEventStream` rooted at `~/Library/Mail/V*/`. Coalesces with a
/// 2 s latency. Persists the last `FSEventStreamEventId` to UserDefaults so a
/// relaunch only sees changes since the previous session.
///
/// Filters at receive time: events for `*.emlx`, `*.partial.emlx`, and
/// `Envelope Index*` are forwarded. Everything else (BiomeStream churn,
/// interaction logs, etc.) is dropped.
final class FileWatcher: @unchecked Sendable {
    static let lastEventIdKey = "FMail.FSEventStream.lastEventId"

    private let path: String
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private var coalescer: DispatchWorkItem?

    init(rootPath: String, onChange: @Sendable @escaping () -> Void) {
        self.path = rootPath
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.felixmatschke.FMail.fsevents", qos: .utility)
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        let pathsToWatch = [path] as CFArray
        let lastEvent: FSEventStreamEventId
        if let stored = UserDefaults.standard.object(forKey: Self.lastEventIdKey) as? UInt64 {
            lastEvent = FSEventStreamEventId(stored)
        } else {
            lastEvent = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }

        // The FSEventStream retains a heap `WatcherBox` (NOT the FileWatcher)
        // via the context's retain/release callbacks. The box holds only a
        // WEAK reference back to us, so the stream can never resurrect a
        // half-deinitialized FileWatcher: if a queued callback fires while we're
        // being deallocated, `box.watcher` reads nil and the callback is a
        // no-op. FileWatcher therefore deinits normally; deinit→stop()
        // invalidates+releases the stream, which runs the `release` callback and
        // frees the box.
        //
        // Ownership: we hand the box to FSEventStreamCreate via `passRetained`
        // (+1). On success the stream takes its own +1 through the `retain`
        // callback. We then balance OUR +1 with `boxRef.release()` below — in
        // every exit path — so the only remaining strong ref is the stream's,
        // which is dropped exactly once by FSEventStreamRelease. No leak, no
        // double-release.
        let box = WatcherBox(watcher: self)
        let boxRef = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: boxRef.toOpaque(),
            retain: { rawBox in
                guard let rawBox else { return rawBox }
                _ = Unmanaged<WatcherBox>.fromOpaque(rawBox).retain()
                return rawBox
            },
            release: { rawBox in
                guard let rawBox else { return }
                Unmanaged<WatcherBox>.fromOpaque(rawBox).release()
            },
            copyDescription: nil
        )

        let flags: UInt32 =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot)

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, _, eventIds) in
                guard let info else { return }
                // `info` is the retained WatcherBox (unretained read — the
                // stream holds a +1 for the duration of the callback).
                let box = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
                // Weak resolve: nil means the FileWatcher is being/has been
                // deallocated, so drop the event rather than resurrect it.
                guard let watcher = box.watcher else { return }
                // Without kFSEventStreamCreateFlagUseCFTypes, eventPaths is a
                // C array of (const char *).
                let pathsBuf = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                var paths: [String] = []
                paths.reserveCapacity(numEvents)
                for i in 0..<numEvents {
                    if let cstr = pathsBuf[i] {
                        paths.append(String(cString: cstr))
                    }
                }
                let lastId = (0..<numEvents).map { eventIds[$0] }.max() ?? 0
                watcher.handle(paths: paths, lastEventId: lastId)
            },
            &context,
            pathsToWatch,
            lastEvent,
            2.0,
            flags
        ) else {
            // Create failed: the stream never ran the `retain` callback, so our
            // `passRetained` +1 is the only ref — release it so the box (and
            // thus our retain on it via the weak ref's storage) doesn't leak.
            boxRef.release()
            Log.fileWatcher.error("FSEventStreamCreate returned nil — real-time updates disabled.")
            return
        }
        // Create succeeded and took its own +1 via the `retain` callback; drop
        // the +1 we created so the stream is the sole strong owner of the box.
        boxRef.release()

        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) {
            self.stream = s
        } else {
            Log.fileWatcher.error("FSEventStreamStart returned false — real-time updates disabled.")
            // Releasing the stream runs the `release` callback, freeing the box.
            FSEventStreamRelease(s)
        }
    }

    func stop() {
        // Tear down on the stream's own dispatch queue so we can't race a
        // callback in flight there, and cancel any pending coalescer.
        // Idempotent: the `guard let s = stream` early-returns if already
        // stopped, so a deinit after an explicit stop() is a no-op and the
        // stream is released exactly once (no double-release). `queue.sync` is
        // safe because neither caller (SyncCoordinator on the main actor, or
        // deinit) runs on `queue`.
        //
        // Even if a callback is already mid-flight on `queue` when we tear down,
        // it resolves the FileWatcher through the box's WEAK reference, so once
        // we're deallocating it reads nil and no-ops — no use-after-free.
        queue.sync {
            coalescer?.cancel()
            coalescer = nil
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func handle(paths: [String], lastEventId: FSEventStreamEventId) {
        // Filter to interesting paths.
        let interesting = paths.contains { p in
            p.hasSuffix(".emlx") ||
            p.hasSuffix(".partial.emlx") ||
            p.contains("/Envelope Index")
        }
        // Persist lastEventId regardless so we don't replay.
        UserDefaults.standard.set(UInt64(lastEventId), forKey: Self.lastEventIdKey)

        guard interesting else { return }

        // Debounce: wait 2 s of quiet, then fire.
        coalescer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        coalescer = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}

/// Heap box retained by the FSEventStream (via the context's retain/release
/// callbacks) in place of the FileWatcher itself. Holds a WEAK reference to the
/// FileWatcher so the stream can never resurrect a deallocating FileWatcher: an
/// in-flight callback reads `watcher` as nil once the owner is gone and no-ops.
///
/// `@unchecked Sendable`: the only stored property is a `weak var` set once at
/// init and never reassigned (weak references must be `var`, but we only ever
/// read it after construction). Reading a `weak` reference is internally
/// synchronized by the runtime, so concurrent reads from the FSEvents callback
/// queue and the owner thread are safe. There is no mutable state we race on.
private final class WatcherBox: @unchecked Sendable {
    weak var watcher: FileWatcher?
    init(watcher: FileWatcher) {
        self.watcher = watcher
    }
}
