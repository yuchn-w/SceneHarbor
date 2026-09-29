import AppKit

@main enum VerifyMemoryCache {
    static func main() {
        let cache = HarborMemoryCache<String, NSData>(costLimit: 10, countLimit: 2, observeLifecycle: false)
        let value = NSData(bytes: [UInt8](repeating: 1, count: 6), length: 6)
        cache.setObject(value, forKey: "a", cost: 4)
        cache.setObject(value, forKey: "b", cost: 4)
        precondition(cache.object(forKey: "a") != nil)
        cache.setObject(value, forKey: "c", cost: 6)
        precondition(cache.object(forKey: "b") == nil && cache.totalCost == 10)
        cache.setObject(value, forKey: "a", cost: 2)
        precondition(cache.totalCost == 8 && cache.count == 2)
        cache.setObject(value, forKey: "huge", cost: 11)
        precondition(cache.object(forKey: "huge") == nil && cache.totalCost == 8)
        cache.setMemoryConstrained(true)
        precondition(cache.totalCost == 0)
        cache.setObject(value, forKey: "a", cost: 2)
        precondition(cache.count == 0)
        cache.setMemoryConstrained(false)
        cache.setObject(value, forKey: "a", cost: 2)
        precondition(cache.object(forKey: "a") != nil)
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            cache.setObject(value, forKey: String(i % 8), cost: i % 7)
            _ = cache.object(forKey: String((i + 1) % 8))
            if i % 17 == 0 { cache.removeAllObjects() }
            precondition(cache.totalCost <= 10 && cache.count <= 2)
        }
        let observed = HarborMemoryCache<String, NSData>(costLimit: 10)
        observed.setObject(value, forKey: "a", cost: 4)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        precondition(observed.totalCost == 0)
        precondition(value.length == 6) // Eviction never invalidates displayed values.
        print("PASS: byte/count bounds, LRU, replacement, oversized admission, pressure recovery, concurrent access, inactive purge")
    }
}
