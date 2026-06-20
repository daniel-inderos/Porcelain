import CoreServices
import Foundation

public final class RepositoryFileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.porcelain.filewatcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    public init() {}

    deinit {
        stop()
    }

    public func startWatching(repositoryURL: URL, debounce: TimeInterval = 0.45, onChange: @escaping @Sendable () -> Void) {
        startWatching(repositoryURLs: [repositoryURL], debounce: debounce) { _ in
            onChange()
        }
    }

    public func startWatching(repositoryURLs: [URL], debounce: TimeInterval = 0.45, onChange: @escaping @Sendable ([URL]) -> Void) {
        stop()

        let repositoryURLs = uniqueURLs(repositoryURLs)
        guard !repositoryURLs.isEmpty else { return }

        let box = CallbackBox(queue: queue, debounce: debounce, onChange: onChange)
        callbackBox = box

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = repositoryURLs.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)

        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(createdStream, queue)
        FSEventStreamStart(createdStream)
        stream = createdStream
    }

    public func stop() {
        guard let stream else {
            callbackBox = nil
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox?.cancel()
        callbackBox = nil
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        var uniqueURLs: [URL] = []
        for url in urls {
            let path = FileWatchPathMatcher.normalizedPath(url)
            guard seenPaths.insert(path).inserted else { continue }
            uniqueURLs.append(url)
        }
        return uniqueURLs
    }
}

public enum FileWatchPathMatcher {
    public static func watchedURLs(matching changedURLs: [URL], in watchedURLs: [URL]) -> Set<URL> {
        var watchedByPath: [String: URL] = [:]
        for watchedURL in watchedURLs {
            watchedByPath[normalizedPath(watchedURL)] = watchedURL
        }

        let changedPaths = changedURLs.map(normalizedPath)
        var matches: Set<URL> = []
        for (watchedPath, watchedURL) in watchedByPath where changedPaths.contains(where: { isPath($0, insideOrEqualTo: watchedPath) }) {
            matches.insert(watchedURL)
        }
        return matches
    }

    public static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func isPath(_ path: String, insideOrEqualTo watchedPath: String) -> Bool {
        if path == watchedPath {
            return true
        }

        let prefix = watchedPath.hasSuffix("/") ? watchedPath : "\(watchedPath)/"
        return path.hasPrefix(prefix)
    }
}

private final class CallbackBox: @unchecked Sendable {
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: @Sendable ([URL]) -> Void
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingChangedPaths: Set<String> = []

    init(queue: DispatchQueue, debounce: TimeInterval, onChange: @escaping @Sendable ([URL]) -> Void) {
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    func schedule(changedPaths: [String]) {
        debounceWorkItem?.cancel()
        pendingChangedPaths.formUnion(changedPaths)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changedURLs = pendingChangedPaths
                .sorted()
                .map { URL(fileURLWithPath: $0) }
            pendingChangedPaths.removeAll()
            onChange(changedURLs)
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    func cancel() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingChangedPaths.removeAll()
    }
}

private let eventCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self)
    let paths = pathsArray.compactMap { $0 as? String }
    box.schedule(changedPaths: paths)
}
