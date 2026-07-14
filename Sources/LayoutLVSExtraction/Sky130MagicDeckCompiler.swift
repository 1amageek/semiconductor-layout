import CryptoKit
import Foundation

public struct Sky130MagicDeckCompiler: LayoutExtractionDeckCompiling {
    private let supportedFamilies: Set<String> = [
        "mosfet",
        "resistor",
        "ndiode",
        "pdiode",
        "bjt",
        "capacitor",
        "subcircuit",
        "msubcircuit",
        "rsubcircuit",
        "csubcircuit",
    ]

    public init() {}

    public func compile(
        sourceURL: URL,
        processID: String = "sky130A",
        processProfileID: String = "sky130.open-pdk.digital-mos.signoff"
    ) throws -> LayoutExtractionDeck {
        let data: Data
        let text: String
        do {
            data = try Data(contentsOf: sourceURL)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw LayoutExtractionDeckCompilerError.unreadableSource(
                    "Magic deck is not UTF-8."
                )
            }
            text = decoded
        } catch let error as LayoutExtractionDeckCompilerError {
            throw error
        } catch {
            throw LayoutExtractionDeckCompilerError.unreadableSource(error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let logicalLines = logicalLines(in: text)
        guard let extractIndex = logicalLines.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "extract"
        }) else {
            throw LayoutExtractionDeckCompilerError.missingExtractSection
        }

        var rules: [LayoutExtractionDeviceRule] = []
        var unsupported: [LayoutExtractionUnsupportedDirective] = []
        for line in logicalLines.dropFirst(extractIndex + 1) {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("device ") else { continue }
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 4 else {
                throw LayoutExtractionDeckCompilerError.malformedDeviceDirective(
                    line: line.startLine,
                    directive: trimmed
                )
            }
            let family = tokens[1].lowercased()
            let model = tokens[2]
            let sourceLocation = LayoutExtractionSourceLocation(
                path: sourceURL.path(percentEncoded: false),
                startLine: line.startLine,
                endLine: line.endLine,
                sourceDigest: digest
            )
            guard supportedFamilies.contains(family), model != "Ignore" else {
                unsupported.append(LayoutExtractionUnsupportedDirective(
                    reasonCode: model == "Ignore" ? "ignored-device-rule" : "unsupported-device-family",
                    family: family,
                    directive: trimmed,
                    sourceLocation: sourceLocation
                ))
                continue
            }
            let expressions = Array(tokens.dropFirst(3))
            let parameterExpressions = expressions.filter { $0.contains("=") }
            let recognitionExpressions = expressions.filter {
                !$0.contains("=") && $0 != "error"
            }
            rules.append(LayoutExtractionDeviceRule(
                ruleID: "magic-device-\(line.startLine)-\(model)",
                family: family,
                model: model,
                recognitionExpressions: recognitionExpressions,
                parameterExpressions: parameterExpressions,
                sourceLocation: sourceLocation,
                sourceText: trimmed
            ))
        }
        guard !rules.isEmpty else {
            throw LayoutExtractionDeckCompilerError.noDeviceRules
        }
        return LayoutExtractionDeck(
            processID: processID,
            processProfileID: processProfileID,
            sourcePath: sourceURL.path(percentEncoded: false),
            sourceDigest: digest,
            deviceRules: rules,
            unsupportedDirectives: unsupported
        )
    }

    private struct LogicalLine {
        let text: String
        let startLine: Int
        let endLine: Int
    }

    private func logicalLines(in text: String) -> [LogicalLine] {
        let physicalLines = text.components(separatedBy: .newlines)
        var result: [LogicalLine] = []
        var buffer = ""
        var startLine = 1
        for (offset, physicalLine) in physicalLines.enumerated() {
            let lineNumber = offset + 1
            let content = physicalLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if buffer.isEmpty { startLine = lineNumber }
            if trimmed.hasSuffix("\\") {
                buffer += String(trimmed.dropLast()) + " "
                continue
            }
            buffer += trimmed
            if !buffer.isEmpty {
                result.append(LogicalLine(text: buffer, startLine: startLine, endLine: lineNumber))
            }
            buffer = ""
        }
        if !buffer.isEmpty {
            result.append(LogicalLine(
                text: buffer,
                startLine: startLine,
                endLine: physicalLines.count
            ))
        }
        return result
    }
}
