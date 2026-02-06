import Foundation

public struct LayoutUnionFind: Sendable {
    private var parent: [Int]
    private var rank: [Int]

    public init(count: Int) {
        self.parent = Array(0..<count)
        self.rank = Array(repeating: 0, count: count)
    }

    public mutating func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])
        }
        return parent[x]
    }

    public mutating func union(_ x: Int, _ y: Int) {
        let rx = find(x)
        let ry = find(y)
        if rx == ry { return }
        if rank[rx] < rank[ry] {
            parent[rx] = ry
        } else if rank[rx] > rank[ry] {
            parent[ry] = rx
        } else {
            parent[ry] = rx
            rank[rx] += 1
        }
    }

    public mutating func components() -> [Int: [Int]] {
        var groups: [Int: [Int]] = [:]
        for i in 0..<parent.count {
            let root = find(i)
            groups[root, default: []].append(i)
        }
        return groups
    }
}
