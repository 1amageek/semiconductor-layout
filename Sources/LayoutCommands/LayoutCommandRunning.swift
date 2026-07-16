import Foundation

public protocol LayoutCommandRunning: Sendable {
    func run(request: LayoutCommandRequest, baseURL: URL) throws -> LayoutCommandResult
}
