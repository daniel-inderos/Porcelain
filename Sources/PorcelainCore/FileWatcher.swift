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
        stop()

        let box = CallbackBox(queue: queue, debounce: debounce, onChange: onChange)
        callbackBox = box

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [repositoryURL.path] as CFArray
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
}

private final class CallbackBox: @unchecked Sendable {
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private var debounceWorkItem: DispatchWorkItem?

    init(queue: DispatchQueue, debounce: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    func schedule() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [onChange] in
            onChange()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    func cancel() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }
}

private let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    box.schedule()
}
