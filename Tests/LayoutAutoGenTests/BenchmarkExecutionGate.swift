import Synchronization

enum BenchmarkExecutionGate {
    private static let lock = Mutex(())

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock { _ in
            try body()
        }
    }
}
