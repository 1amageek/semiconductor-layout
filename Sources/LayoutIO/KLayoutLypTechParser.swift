import Foundation
import LayoutCore
import LayoutTech
import TechIR

/// Builds a LayoutTechDatabase from a KLayout layer properties file (`.lyp`).
public struct KLayoutLypTechParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> LayoutTechDatabase {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML parse error"
            throw LayoutIOError.readFailed(reason)
        }

        var usedNames: Set<String> = []
        var layers: [LayoutLayerDefinition] = []

        for raw in delegate.layers {
            guard let source = raw.source,
                  let (gdsLayer, gdsDatatype) = parseSource(source) else { continue }

            let displayName = normalizedDisplayName(raw.name, gdsLayer: gdsLayer, gdsDatatype: gdsDatatype)
            let idName = uniqueIDName(from: displayName, used: &usedNames)
            let purpose = inferredPurpose(from: displayName)
            let color = parseColor(raw.fillColor) ?? parseColor(raw.frameColor) ?? fallbackColor(for: gdsLayer)
            let pattern = mapPattern(raw.ditherPattern)
            let visible = parseBool(raw.visible) ?? true

            layers.append(LayoutLayerDefinition(
                id: LayoutLayerID(name: idName, purpose: purpose),
                displayName: displayName,
                gdsLayer: gdsLayer,
                gdsDatatype: gdsDatatype,
                color: color,
                fillPattern: pattern,
                preferredDirection: .none,
                visibleByDefault: visible
            ))
        }

        layers.sort {
            if $0.gdsLayer == $1.gdsLayer { return $0.gdsDatatype < $1.gdsDatatype }
            return $0.gdsLayer < $1.gdsLayer
        }

        guard !layers.isEmpty else {
            throw LayoutIOError.readFailed("No valid layer entries found in .lyp")
        }

        return LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: layers,
            vias: [],
            layerRules: []
        )
    }

    // MARK: - IRTech Output

    /// Parses `.lyp` data into an `IRTechLibrary` intermediate representation.
    public func parseToIRTech(data: Data) throws -> IRTechLibrary {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML parse error"
            throw LayoutIOError.readFailed(reason)
        }

        var usedNames: Set<String> = []
        var layers: [IRTechLayerDef] = []

        for raw in delegate.layers {
            guard let source = raw.source,
                  let (gdsLayer, gdsDatatype) = parseSource(source) else { continue }

            let displayName = normalizedDisplayName(raw.name, gdsLayer: gdsLayer, gdsDatatype: gdsDatatype)
            let idName = uniqueIDName(from: displayName, used: &usedNames)
            let purpose = inferredPurpose(from: displayName)
            let layerType: IRTechLayerType = purpose == "cut" ? .cut : .routing
            let color = parseColorIR(raw.fillColor) ?? parseColorIR(raw.frameColor) ?? fallbackColorIR(for: gdsLayer)
            let pattern = mapPatternIR(raw.ditherPattern)
            let visible = parseBool(raw.visible) ?? true

            layers.append(IRTechLayerDef(
                name: idName,
                type: layerType,
                gdsLayer: gdsLayer,
                gdsDatatype: gdsDatatype,
                color: color,
                fillPattern: pattern,
                visibleByDefault: visible
            ))
        }

        layers.sort {
            if ($0.gdsLayer ?? 0) == ($1.gdsLayer ?? 0) { return ($0.gdsDatatype ?? 0) < ($1.gdsDatatype ?? 0) }
            return ($0.gdsLayer ?? 0) < ($1.gdsLayer ?? 0)
        }

        guard !layers.isEmpty else {
            throw LayoutIOError.readFailed("No valid layer entries found in .lyp")
        }

        return IRTechLibrary(
            name: "",
            dbuPerMicron: 1000,
            layers: layers,
            metadata: ["source.format": "lyp"]
        )
    }

    private func parseColorIR(_ hex: String?) -> IRTechColor? {
        guard let hex else { return nil }
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("#") else { return nil }
        let v = String(clean.dropFirst())

        if v.count == 6, let rgb = Int(v, radix: 16) {
            let r = Double((rgb >> 16) & 0xFF) / 255
            let g = Double((rgb >> 8) & 0xFF) / 255
            let b = Double(rgb & 0xFF) / 255
            return IRTechColor(red: r, green: g, blue: b, alpha: 1.0)
        }

        if v.count == 8, let argb = Int(v, radix: 16) {
            let a = Double((argb >> 24) & 0xFF) / 255
            let r = Double((argb >> 16) & 0xFF) / 255
            let g = Double((argb >> 8) & 0xFF) / 255
            let b = Double(argb & 0xFF) / 255
            return IRTechColor(red: r, green: g, blue: b, alpha: a)
        }

        return nil
    }

    private func fallbackColorIR(for layer: Int) -> IRTechColor {
        let hue = Double((layer * 37) % 360) / 360
        let i = Int(hue * 6)
        let f = hue * 6 - Double(i)
        let s = 0.55
        let v = 0.92
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)

        let (r, g, b): (Double, Double, Double)
        switch i % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return IRTechColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    private func mapPatternIR(_ value: String?) -> IRTechFillPattern {
        guard let value else { return .solid }
        let p = value.lowercased()
        if p.contains("dot") { return .dots }
        if p.contains("grid") { return .grid }
        if p.contains("cross") || p.contains("hatch") { return .crosshatch }
        if p.contains("horiz") { return .horizontal }
        if p.contains("vert") { return .vertical }
        if p.contains("back") { return .backwardDiagonal }
        if p.contains("diag") || p.contains("slash") { return .forwardDiagonal }
        return .solid
    }

    // MARK: - Parsing Helpers

    private func parseSource(_ source: String) -> (Int, Int)? {
        let src = source.split(separator: "@", maxSplits: 1).first.map(String.init) ?? source
        let parts = src.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let layer = Int(parts[0]), let datatype = Int(parts[1]) else { return nil }
        return (layer, datatype)
    }

    private func normalizedDisplayName(_ name: String?, gdsLayer: Int, gdsDatatype: Int) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "L\(gdsLayer)/D\(gdsDatatype)" : trimmed
    }

    private func uniqueIDName(from displayName: String, used: inout Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let raw = displayName.uppercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        var name = String(raw)
        while name.contains("__") {
            name = name.replacingOccurrences(of: "__", with: "_")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.isEmpty { name = "LAYER" }

        if !used.contains(name) {
            used.insert(name)
            return name
        }

        var index = 2
        while used.contains("\(name)_\(index)") {
            index += 1
        }
        let unique = "\(name)_\(index)"
        used.insert(unique)
        return unique
    }

    private func inferredPurpose(from displayName: String) -> String {
        let n = displayName.lowercased()
        if n.contains("via") || n.contains("cont") || n.contains("cut") {
            return "cut"
        }
        return "drawing"
    }

    private func parseColor(_ hex: String?) -> LayoutColor? {
        guard let hex else { return nil }
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("#") else { return nil }
        let v = String(clean.dropFirst())

        if v.count == 6, let rgb = Int(v, radix: 16) {
            let r = Double((rgb >> 16) & 0xFF) / 255
            let g = Double((rgb >> 8) & 0xFF) / 255
            let b = Double(rgb & 0xFF) / 255
            return LayoutColor(red: r, green: g, blue: b, alpha: 1.0)
        }

        if v.count == 8, let argb = Int(v, radix: 16) {
            let a = Double((argb >> 24) & 0xFF) / 255
            let r = Double((argb >> 16) & 0xFF) / 255
            let g = Double((argb >> 8) & 0xFF) / 255
            let b = Double(argb & 0xFF) / 255
            return LayoutColor(red: r, green: g, blue: b, alpha: a)
        }

        return nil
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    private func mapPattern(_ value: String?) -> LayoutFillPattern {
        guard let value else { return .solid }
        let p = value.lowercased()
        if p.contains("dot") { return .dots }
        if p.contains("grid") { return .grid }
        if p.contains("cross") || p.contains("hatch") { return .crosshatch }
        if p.contains("horiz") { return .horizontal }
        if p.contains("vert") { return .vertical }
        if p.contains("back") { return .backwardDiagonal }
        if p.contains("diag") || p.contains("slash") { return .forwardDiagonal }
        return .solid
    }

    private func fallbackColor(for layer: Int) -> LayoutColor {
        let hue = Double((layer * 37) % 360) / 360
        return hsvToRGB(h: hue, s: 0.55, v: 0.92)
    }

    private func hsvToRGB(h: Double, s: Double, v: Double) -> LayoutColor {
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)

        let (r, g, b): (Double, Double, Double)
        switch i % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return LayoutColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

private extension KLayoutLypTechParser {
    struct RawLayer: Sendable {
        var name: String?
        var source: String?
        var frameColor: String?
        var fillColor: String?
        var ditherPattern: String?
        var visible: String?
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var layers: [RawLayer] = []
        private var current: RawLayer?
        private var textBuffer: String = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "properties" {
                current = RawLayer()
            }
            textBuffer = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, var current {
                switch elementName {
                case "name": current.name = value
                case "source": current.source = value
                case "frame-color": current.frameColor = value
                case "fill-color": current.fillColor = value
                case "dither-pattern": current.ditherPattern = value
                case "visible": current.visible = value
                default: break
                }
                self.current = current
            }

            if elementName == "properties", let current {
                layers.append(current)
                self.current = nil
            }
            textBuffer = ""
        }
    }
}
