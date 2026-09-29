import AppKit

/// A byte-bounded LRU for disposable artwork. NSCache's cost limit is advisory;
/// these independent caches must not collectively retain hundreds of MB beyond
/// their budgets. Visible views keep their own references when entries evict.
final class HarborMemoryCache<Key: Hashable, Value: AnyObject>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
    }
    let costLimit: Int
    let countLimit: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var sequence: UInt64 = 0
    private var constrained = false
    private var observers: [NSObjectProtocol] = []
    private var pressure: DispatchSourceMemoryPressure?

    init(costLimit: Int, countLimit: Int = 128, observeLifecycle: Bool = true) {
        precondition(costLimit > 0 && countLimit > 0)
        self.costLimit = costLimit; self.countLimit = countLimit
        guard observeLifecycle else { return }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.removeAllObjects()
            })
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            self?.setMemoryConstrained(!source.data.contains(.normal))
        }
        pressure = source
        source.resume()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        pressure?.cancel()
    }

    var totalCost: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func object(forKey key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        sequence &+= 1; entry.access = sequence; entries[key] = entry
        return entry.value
    }

    func setObject(_ value: Value, forKey key: Key, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
        // An oversized object can still be displayed by its caller; retaining
        // it here would violate the cache budget and evict an entire page.
        guard !constrained, cost >= 0, cost <= costLimit else { return }
        while bytes > costLimit - cost || entries.count >= countLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            bytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
        sequence &+= 1
        entries[key] = Entry(value: value, cost: cost, access: sequence)
        bytes += cost
    }

    func removeAllObjects() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false); bytes = 0
    }

    func setMemoryConstrained(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        constrained = value
        if value { entries.removeAll(keepingCapacity: false); bytes = 0 }
    }
}
