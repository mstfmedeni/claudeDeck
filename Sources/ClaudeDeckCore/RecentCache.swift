import Foundation

/// A dictionary that keeps only the `limit` most recently used entries (reading one counts as
/// using it). For caches a long-running host would otherwise grow without end, like the parsed
/// transcripts it keeps for phones.
public struct RecentCache<Key: Hashable, Value> {
    public let limit: Int
    private var values: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var count: Int { values.count }
    public var keys: [Key] { order }

    public subscript(key: Key) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
        set {
            guard let newValue else {
                values[key] = nil
                order.removeAll { $0 == key }
                return
            }
            values[key] = newValue
            touch(key)
            while order.count > limit { values[order.removeFirst()] = nil }
        }
    }

    /// Without counting as a use.
    public func peek(_ key: Key) -> Value? { values[key] }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
