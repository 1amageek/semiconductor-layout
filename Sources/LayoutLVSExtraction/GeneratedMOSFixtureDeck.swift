import CryptoKit
import Foundation

public struct GeneratedMOSFixtureDeck: Sendable {
    public static let processID = "fixture.sample-process"
    public static let processProfileID = "fixture.generated-mos.v1"

    public init() {}

    public func makeDeck() -> LayoutExtractionDeck {
        let sourceText = Self.sourceLines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(sourceText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let sourcePath = "fixture://generated-mos/sample-process-v1"
        let rules = Self.sourceLines.enumerated().map { offset, line in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let model = tokens[1]
            let recognitionExpressions = Array(tokens[2...4])
            let parameterExpressions = Array(tokens.dropFirst(5))
            return LayoutExtractionDeviceRule(
                ruleID: "fixture.generated-mos.\(model)",
                family: "mosfet",
                model: model,
                recognitionExpressions: recognitionExpressions,
                parameterExpressions: parameterExpressions,
                sourceLocation: LayoutExtractionSourceLocation(
                    path: sourcePath,
                    startLine: offset + 1,
                    endLine: offset + 1,
                    sourceDigest: digest
                ),
                sourceText: line
            )
        }
        return LayoutExtractionDeck(
            processID: Self.processID,
            processProfileID: Self.processProfileID,
            sourcePath: sourcePath,
            sourceDigest: digest,
            qualificationScope: .fixtureOnly,
            deviceRules: rules
        )
    }

    private static let sourceLines = [
        "device nmos ACTIVE POLY NIMP w=channelWidth l=channelLength m=parallelFingerCount",
        "device pmos ACTIVE POLY PIMP w=channelWidth l=channelLength m=parallelFingerCount",
    ]
}
