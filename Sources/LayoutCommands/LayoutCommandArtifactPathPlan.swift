import Foundation

struct LayoutCommandArtifactPathPlan: Sendable, Equatable {
    let inputURL: URL
    let outputURL: URL?
    let resultURL: URL?
    let manifestURL: URL?

    static func conversion(_ request: LayoutDocumentConversionRequest) throws -> LayoutCommandArtifactPathPlan {
        let plan = LayoutCommandArtifactPathPlan(
            inputURL: URL(fileURLWithPath: request.inputPath),
            outputURL: URL(fileURLWithPath: request.outputPath),
            resultURL: request.resultPath.map { URL(fileURLWithPath: $0) },
            manifestURL: request.artifactManifestPath.map { URL(fileURLWithPath: $0) }
        )
        try validateDistinctPaths([
            ("input", plan.inputURL),
            ("output", plan.outputURL),
            ("result", plan.resultURL),
            ("artifact-manifest", plan.manifestURL),
        ])
        return plan
    }

    static func inspection(_ request: LayoutDocumentInspectionRequest) throws -> LayoutCommandArtifactPathPlan {
        let plan = LayoutCommandArtifactPathPlan(
            inputURL: URL(fileURLWithPath: request.inputPath),
            outputURL: nil,
            resultURL: request.resultPath.map { URL(fileURLWithPath: $0) },
            manifestURL: request.artifactManifestPath.map { URL(fileURLWithPath: $0) }
        )
        try validateDistinctPaths([
            ("input", plan.inputURL),
            ("result", plan.resultURL),
            ("artifact-manifest", plan.manifestURL),
        ])
        return plan
    }

    static func constraintValidation(_ request: LayoutConstraintValidationRequest) throws -> LayoutCommandArtifactPathPlan {
        let plan = LayoutCommandArtifactPathPlan(
            inputURL: URL(fileURLWithPath: request.inputPath),
            outputURL: nil,
            resultURL: request.resultPath.map { URL(fileURLWithPath: $0) },
            manifestURL: request.artifactManifestPath.map { URL(fileURLWithPath: $0) }
        )
        try validateDistinctPaths([
            ("input", plan.inputURL),
            ("result", plan.resultURL),
            ("artifact-manifest", plan.manifestURL),
        ])
        return plan
    }

    private static func validateDistinctPaths(_ entries: [(role: String, url: URL?)]) throws {
        var roleByPath: [String: String] = [:]
        for entry in entries {
            guard let url = entry.url else {
                continue
            }
            let path = normalizedPath(url)
            if let existingRole = roleByPath[path] {
                throw LayoutCommandError.conflictingArtifactPath("\(existingRole) and \(entry.role)", url.path)
            }
            roleByPath[path] = entry.role
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
