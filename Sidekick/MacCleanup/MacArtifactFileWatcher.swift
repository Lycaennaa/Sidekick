import CoreServices
import Foundation

struct MacArtifactFileEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
}

@MainActor
final class MacArtifactFileWatcher {
    var onEvents: (([MacArtifactFileEvent]) -> Void)?
    private var stream: FSEventStreamRef?
    private var started = false

    func start(watching roots: [URL]) {
        stop()
        let paths = roots.map(\.standardizedFileURL.path)
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<MacArtifactFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let events = (0..<count).map { index in
                MacArtifactFileEvent(path: String(cString: paths[index]), flags: eventFlags[index])
            }
            Task { @MainActor [weak watcher] in
                watcher?.onEvents?(events)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        started = FSEventStreamStart(stream)
        if !started {
            FSEventStreamSetDispatchQueue(stream, nil)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func stop() {
        guard let stream else { return }
        if started { FSEventStreamStop(stream) }
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        started = false
    }
}
