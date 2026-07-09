import CryptoKit
import Foundation
import LayoutCore
import LayoutTech

public struct GuardRingRequest: Codable, Sendable, Equatable {
    public var innerRect: LayoutRect
    public var activeLayer: LayoutLayerID
    public var implantLayer: LayoutLayerID
    public var metalLayer: LayoutLayerID
    public var contactDefinitionID: String
    public var netID: UUID?
    public var clearance: Double?
    public var ringWidth: Double?
    public var idSeed: String

    public init(
        innerRect: LayoutRect,
        activeLayer: LayoutLayerID = LayoutLayerID(name: "ACTIVE", purpose: "drawing"),
        implantLayer: LayoutLayerID,
        metalLayer: LayoutLayerID = LayoutLayerID(name: "M1", purpose: "drawing"),
        contactDefinitionID: String = "CONT_ACTIVE",
        netID: UUID? = nil,
        clearance: Double? = nil,
        ringWidth: Double? = nil,
        idSeed: String
    ) {
        self.innerRect = innerRect
        self.activeLayer = activeLayer
        self.implantLayer = implantLayer
        self.metalLayer = metalLayer
        self.contactDefinitionID = contactDefinitionID
        self.netID = netID
        self.clearance = clearance
        self.ringWidth = ringWidth
        self.idSeed = idSeed
    }
}

public struct GuardRingGenerationResult: Codable, Sendable, Equatable {
    public let request: GuardRingRequest
    public let status: String
    public let innerRect: LayoutRect
    public let activeOuterRect: LayoutRect
    public let implantOuterRect: LayoutRect
    public let shapeCount: Int
    public let viaCount: Int
    public let contactCount: Int
    public let activeShapeIDs: [UUID]
    public let implantShapeIDs: [UUID]
    public let metalShapeIDs: [UUID]
    public let contactViaIDs: [UUID]
    public let shapes: [LayoutShape]
    public let vias: [LayoutVia]

    public init(
        request: GuardRingRequest,
        status: String,
        innerRect: LayoutRect,
        activeOuterRect: LayoutRect,
        implantOuterRect: LayoutRect,
        shapeCount: Int,
        viaCount: Int,
        contactCount: Int,
        activeShapeIDs: [UUID],
        implantShapeIDs: [UUID],
        metalShapeIDs: [UUID],
        contactViaIDs: [UUID],
        shapes: [LayoutShape],
        vias: [LayoutVia]
    ) {
        self.request = request
        self.status = status
        self.innerRect = innerRect
        self.activeOuterRect = activeOuterRect
        self.implantOuterRect = implantOuterRect
        self.shapeCount = shapeCount
        self.viaCount = viaCount
        self.contactCount = contactCount
        self.activeShapeIDs = activeShapeIDs
        self.implantShapeIDs = implantShapeIDs
        self.metalShapeIDs = metalShapeIDs
        self.contactViaIDs = contactViaIDs
        self.shapes = shapes
        self.vias = vias
    }
}

public struct GuardRingGenerator: Sendable {
    public init() {}

    public func generate(request: GuardRingRequest, tech: LayoutTechDatabase) throws -> GuardRingGenerationResult {
        try validate(rect: request.innerRect)
        let rules = try makeRuleContext(request: request, tech: tech)
        let dimensions = try makeDimensions(request: request, rules: rules, tech: tech)
        let activeHole = request.innerRect.expanded(by: dimensions.clearance, dimensions.clearance)
        let activeOuter = request.innerRect.expanded(
            by: dimensions.clearance + dimensions.ringWidth,
            dimensions.clearance + dimensions.ringWidth
        )
        let implantHole = activeHole.inset(by: rules.implantEnclosure, rules.implantEnclosure)
        let implantOuter = activeOuter.expanded(by: rules.implantEnclosure, rules.implantEnclosure)

        let activeRects = ringRects(outer: activeOuter, hole: activeHole)
        let implantRects = ringRects(outer: implantOuter, hole: implantHole)
        let metalRects = activeRects
        let activeShapes = makeShapes(
            rects: activeRects,
            layer: request.activeLayer,
            netID: request.netID,
            seed: request.idSeed,
            role: "active"
        )
        let implantShapes = makeShapes(
            rects: implantRects,
            layer: request.implantLayer,
            netID: nil,
            seed: request.idSeed,
            role: "implant"
        )
        let metalShapes = makeShapes(
            rects: metalRects,
            layer: request.metalLayer,
            netID: request.netID,
            seed: request.idSeed,
            role: "metal"
        )
        let contactVias = try makeContactVias(
            activeRects: activeRects,
            request: request,
            rules: rules,
            tech: tech
        )
        guard !contactVias.isEmpty else {
            throw AutoGenError.invalidParameter(
                device: "guardRing",
                parameter: "innerRect",
                value: min(request.innerRect.size.width, request.innerRect.size.height),
                reason: "guard ring cannot fit any contact cuts"
            )
        }

        let shapes = implantShapes + activeShapes + metalShapes
        return GuardRingGenerationResult(
            request: request,
            status: "generated",
            innerRect: request.innerRect,
            activeOuterRect: activeOuter,
            implantOuterRect: implantOuter,
            shapeCount: shapes.count,
            viaCount: contactVias.count,
            contactCount: contactVias.count,
            activeShapeIDs: activeShapes.map(\.id),
            implantShapeIDs: implantShapes.map(\.id),
            metalShapeIDs: metalShapes.map(\.id),
            contactViaIDs: contactVias.map(\.id),
            shapes: shapes,
            vias: contactVias
        )
    }

    private struct RuleContext {
        let activeRules: LayoutLayerRuleSet
        let implantRules: LayoutLayerRuleSet
        let metalRules: LayoutLayerRuleSet
        let contactRules: LayoutLayerRuleSet
        let contact: LayoutContactDefinition
        let implantEnclosure: Double
    }

    private struct Dimensions {
        let clearance: Double
        let ringWidth: Double
    }

    private func makeRuleContext(request: GuardRingRequest, tech: LayoutTechDatabase) throws -> RuleContext {
        guard let activeRules = tech.ruleSet(for: request.activeLayer) else {
            throw AutoGenError.missingLayerRule(request.activeLayer.name)
        }
        guard let implantRules = tech.ruleSet(for: request.implantLayer) else {
            throw AutoGenError.missingLayerRule(request.implantLayer.name)
        }
        guard let metalRules = tech.ruleSet(for: request.metalLayer) else {
            throw AutoGenError.missingLayerRule(request.metalLayer.name)
        }
        guard let contact = tech.contactDefinition(for: request.contactDefinitionID) else {
            throw AutoGenError.missingContactDefinition(request.contactDefinitionID)
        }
        guard let contactRules = tech.ruleSet(for: contact.cutLayer) else {
            throw AutoGenError.missingLayerRule(contact.cutLayer.name)
        }
        guard contact.bottomLayer == request.activeLayer, contact.topLayer == request.metalLayer else {
            throw AutoGenError.invalidParameter(
                device: "guardRing",
                parameter: "contactDefinitionID",
                value: 0,
                reason: "contact definition must connect activeLayer to metalLayer"
            )
        }
        let implantEnclosure = try tech.requiredEnclosureRule(
            outer: request.implantLayer,
            inner: request.activeLayer
        ).minEnclosure
        return RuleContext(
            activeRules: activeRules,
            implantRules: implantRules,
            metalRules: metalRules,
            contactRules: contactRules,
            contact: contact,
            implantEnclosure: implantEnclosure
        )
    }

    private func makeDimensions(
        request: GuardRingRequest,
        rules: RuleContext,
        tech: LayoutTechDatabase
    ) throws -> Dimensions {
        try validateNonNegative(request.clearance, parameter: "clearance")
        try validateNonNegative(request.ringWidth, parameter: "ringWidth")
        let contactWidth = max(rules.contact.cutSize.width, rules.contact.cutSize.height)
        let contactEnclosure = max(rules.contact.enclosure.bottom, rules.contact.enclosure.top)
        let contactLandingWidth = contactWidth + 2 * (contactEnclosure + tech.grid)
        let minimumRingWidth = max(
            rules.activeRules.minWidth,
            rules.metalRules.minWidth,
            rules.implantRules.minWidth - 2 * rules.implantEnclosure,
            contactLandingWidth
        )
        let ringWidth = snapUp(request.ringWidth ?? minimumRingWidth, grid: tech.grid)
        let clearance = snapUp(
            max(
                request.clearance ?? rules.activeRules.minSpacing,
                rules.activeRules.minSpacing,
                rules.implantEnclosure + tech.grid
            ),
            grid: tech.grid
        )
        guard ringWidth >= minimumRingWidth else {
            throw AutoGenError.invalidParameter(
                device: "guardRing",
                parameter: "ringWidth",
                value: ringWidth,
                reason: "ring width cannot fit active, metal, implant, and contact rules"
            )
        }
        return Dimensions(clearance: clearance, ringWidth: ringWidth)
    }

    private func validate(rect: LayoutRect) throws {
        guard rect.size.width > 0, rect.size.height > 0 else {
            throw AutoGenError.invalidParameter(
                device: "guardRing",
                parameter: "innerRect",
                value: min(rect.size.width, rect.size.height),
                reason: "inner rectangle must have positive width and height"
            )
        }
    }

    private func validateNonNegative(_ value: Double?, parameter: String) throws {
        guard let value else {
            return
        }
        guard value.isFinite, value >= 0 else {
            throw AutoGenError.invalidParameter(
                device: "guardRing",
                parameter: parameter,
                value: value,
                reason: "value must be finite and non-negative"
            )
        }
    }

    private func makeShapes(
        rects: [LayoutRect],
        layer: LayoutLayerID,
        netID: UUID?,
        seed: String,
        role: String
    ) -> [LayoutShape] {
        rects.enumerated().map { index, rect in
            LayoutShape(
                id: deterministicUUID(seed: seed, role: role, index: index),
                layer: layer,
                netID: netID,
                geometry: .rect(rect),
                properties: [
                    "analogRole": "guardRing",
                    "guardRingRole": role,
                    "guardRingSide": sideName(index),
                ]
            )
        }
    }

    private func ringRects(outer: LayoutRect, hole: LayoutRect) -> [LayoutRect] {
        [
            LayoutRect(
                origin: outer.origin,
                size: LayoutSize(width: outer.size.width, height: hole.minY - outer.minY)
            ),
            LayoutRect(
                origin: LayoutPoint(x: outer.minX, y: hole.maxY),
                size: LayoutSize(width: outer.size.width, height: outer.maxY - hole.maxY)
            ),
            LayoutRect(
                origin: LayoutPoint(x: outer.minX, y: outer.minY),
                size: LayoutSize(width: hole.minX - outer.minX, height: outer.size.height)
            ),
            LayoutRect(
                origin: LayoutPoint(x: hole.maxX, y: outer.minY),
                size: LayoutSize(width: outer.maxX - hole.maxX, height: outer.size.height)
            ),
        ]
    }

    private func makeContactVias(
        activeRects: [LayoutRect],
        request: GuardRingRequest,
        rules: RuleContext,
        tech: LayoutTechDatabase
    ) throws -> [LayoutVia] {
        var contacts: [LayoutVia] = []
        for (index, rect) in activeRects.enumerated() {
            let side = sideName(index)
            let region = contactRegion(
                for: rect,
                side: side,
                contact: rules.contact,
                grid: tech.grid
            )
            guard region.size.width >= rules.contact.cutSize.width,
                  region.size.height >= rules.contact.cutSize.height else {
                continue
            }
            let generated = ContactArrayHelper.generateContacts2D(
                regionX: region.minX,
                regionY: region.minY,
                regionWidth: region.size.width,
                regionHeight: region.size.height,
                contSize: max(rules.contact.cutSize.width, rules.contact.cutSize.height),
                contSpacing: max(rules.contact.cutSpacing, rules.contactRules.minSpacing),
                contLayer: rules.contact.cutLayer,
                grid: tech.grid
            )
            for generatedShape in generated {
                let contactIndex = contacts.count
                let contactRect = LayoutGeometryAnalysis.boundingBox(for: generatedShape.geometry)
                contacts.append(LayoutVia(
                    id: deterministicUUID(seed: request.idSeed, role: "contact", index: contactIndex),
                    viaDefinitionID: request.contactDefinitionID,
                    position: contactRect.center,
                    netID: request.netID
                ))
            }
        }
        return contacts
    }

    private func contactRegion(
        for rect: LayoutRect,
        side: String,
        contact: LayoutContactDefinition,
        grid: Double
    ) -> LayoutRect {
        let enclosure = max(contact.enclosure.bottom, contact.enclosure.top) + grid
        let cornerKeepout = contact.cutSpacing + max(contact.cutSize.width, contact.cutSize.height)
        switch side {
        case "bottom", "top":
            return LayoutRect(
                origin: LayoutPoint(x: rect.minX + enclosure + cornerKeepout, y: rect.minY + enclosure),
                size: LayoutSize(
                    width: rect.size.width - 2 * (enclosure + cornerKeepout),
                    height: rect.size.height - 2 * enclosure
                )
            )
        default:
            return LayoutRect(
                origin: LayoutPoint(x: rect.minX + enclosure, y: rect.minY + enclosure + cornerKeepout),
                size: LayoutSize(
                    width: rect.size.width - 2 * enclosure,
                    height: rect.size.height - 2 * (enclosure + cornerKeepout)
                )
            )
        }
    }

    private func sideName(_ index: Int) -> String {
        switch index {
        case 0: return "bottom"
        case 1: return "top"
        case 2: return "left"
        default: return "right"
        }
    }

    private func snapUp(_ value: Double, grid: Double) -> Double {
        ContactArrayHelper.snapUp(value, grid: grid)
    }

    private func deterministicUUID(seed: String, role: String, index: Int) -> UUID {
        let input = ["guard-ring", seed, role, String(index)].joined(separator: "|")
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
