import DEF
import Foundation

struct DEFViaDefinitionPropertyDecoder: Sendable {
    private static let viaDefCountPropertyKey = "def.viaDef.count"
    private static let viaDefPropertyPrefix = "def.viaDef"

    func viaDefinitions(from properties: [String: String]) throws -> [DEFViaDef] {
        guard let countValue = properties[Self.viaDefCountPropertyKey] else {
            return []
        }
        guard let count = Int(countValue), count >= 0 else {
            throw LayoutIOError.conversionFailed(
                "Invalid DEF via definition count '\(countValue)'"
            )
        }

        var viaDefs: [DEFViaDef] = []
        viaDefs.reserveCapacity(count)
        for index in 0..<count {
            let key = "\(Self.viaDefPropertyPrefix).\(index).json"
            guard let rawValue = properties[key] else {
                throw LayoutIOError.conversionFailed(
                    "Missing DEF via definition payload '\(key)'"
                )
            }
            guard let data = Data(base64Encoded: rawValue) else {
                throw LayoutIOError.conversionFailed(
                    "Invalid base64 DEF via definition payload '\(key)'"
                )
            }
            do {
                let viaDef = try JSONDecoder().decode(DEFViaDef.self, from: data)
                viaDefs.append(viaDef)
            } catch {
                throw LayoutIOError.conversionFailed(
                    "Invalid DEF via definition payload '\(key)': \(error)"
                )
            }
        }
        return viaDefs
    }
}
