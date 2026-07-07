struct LayoutCommandCLIArgumentCursor: Sendable {
    private let arguments: [String]
    private var index: Int

    init(arguments: [String]) {
        self.arguments = arguments
        index = 0
    }

    mutating func next() -> String? {
        guard index < arguments.count else {
            return nil
        }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func requireValue(for option: String) throws -> String {
        guard let value = next(), !value.isEmpty, !value.hasPrefix("--") else {
            throw LayoutCommandError.missingValueAfter(option)
        }
        return value
    }
}
