import Foundation

public struct LayoutDocumentValidator: Sendable {
    public init() {}

    public func validate(
        _ document: LayoutDocument
    ) -> LayoutDocumentValidationReport {
        var findings: [LayoutDocumentValidationFinding] = []
        if !document.name.contains(where: { !$0.isWhitespace }) {
            findings.append(error(
                "layout.document.name-missing",
                "The layout document name must not be empty.",
                document.id
            ))
        }

        var cellIDs = Set<UUID>()
        var cellNames = Set<String>()
        for cell in document.cells {
            if !cellIDs.insert(cell.id).inserted {
                findings.append(error(
                    "layout.cell.duplicate-id",
                    "Cell identifiers must be unique.",
                    cell.id
                ))
            }
            if !cell.name.contains(where: { !$0.isWhitespace }) {
                findings.append(error(
                    "layout.cell.name-missing",
                    "Cell names must not be empty.",
                    cell.id
                ))
            } else if !cellNames.insert(cell.name).inserted {
                findings.append(error(
                    "layout.cell.duplicate-name",
                    "Cell names must be unique.",
                    cell.id
                ))
            }
        }
        if let topCellID = document.topCellID, !cellIDs.contains(topCellID) {
            findings.append(error(
                "layout.document.top-cell-missing",
                "The top-cell reference does not resolve in the document.",
                topCellID
            ))
        }

        for cell in document.cells {
            validate(
                cell,
                knownCellIDs: cellIDs,
                findings: &findings
            )
        }
        validateHierarchy(document, findings: &findings)
        return LayoutDocumentValidationReport(findings: findings)
    }

    private func validate(
        _ cell: LayoutCell,
        knownCellIDs: Set<UUID>,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        var netIDs = Set<UUID>()
        var netNames = Set<String>()
        for net in cell.nets {
            if !netIDs.insert(net.id).inserted {
                findings.append(error(
                    "layout.net.duplicate-id",
                    "Net identifiers must be unique within a cell.",
                    net.id
                ))
            }
            if !net.name.contains(where: { !$0.isWhitespace }) {
                findings.append(error(
                    "layout.net.name-missing",
                    "Net names must not be empty.",
                    net.id
                ))
            } else if !netNames.insert(net.name).inserted {
                findings.append(error(
                    "layout.net.duplicate-name",
                    "Net names must be unique within a cell.",
                    net.id
                ))
            }
            if let current = net.currentSpec,
               !current.isFinite || current < 0 {
                findings.append(error(
                    "layout.net.current-invalid",
                    "A net current specification must be finite and nonnegative.",
                    net.id
                ))
            }
        }

        var shapeIDs = Set<UUID>()
        for shape in cell.shapes {
            if !shapeIDs.insert(shape.id).inserted {
                findings.append(error(
                    "layout.shape.duplicate-id",
                    "Shape identifiers must be unique within a cell.",
                    shape.id
                ))
            }
            validate(shape.layer, entityID: shape.id, findings: &findings)
            validate(shape.geometry, entityID: shape.id, findings: &findings)
            validate(
                shape.netID,
                knownNetIDs: netIDs,
                code: "layout.shape.net-missing",
                entityID: shape.id,
                findings: &findings
            )
        }

        var viaIDs = Set<UUID>()
        for via in cell.vias {
            if !viaIDs.insert(via.id).inserted {
                findings.append(error(
                    "layout.via.duplicate-id",
                    "Via identifiers must be unique within a cell.",
                    via.id
                ))
            }
            if !via.viaDefinitionID.contains(where: { !$0.isWhitespace }) {
                findings.append(error(
                    "layout.via.definition-missing",
                    "A via must reference a nonempty definition identifier.",
                    via.id
                ))
            }
            validate(via.position, entityID: via.id, findings: &findings)
            validate(
                via.netID,
                knownNetIDs: netIDs,
                code: "layout.via.net-missing",
                entityID: via.id,
                findings: &findings
            )
        }

        var labelIDs = Set<UUID>()
        for label in cell.labels {
            if !labelIDs.insert(label.id).inserted {
                findings.append(error(
                    "layout.label.duplicate-id",
                    "Label identifiers must be unique within a cell.",
                    label.id
                ))
            }
            if !label.text.contains(where: { !$0.isWhitespace }) {
                findings.append(error(
                    "layout.label.text-missing",
                    "Label text must not be empty.",
                    label.id
                ))
            }
            validate(label.position, entityID: label.id, findings: &findings)
            validate(label.layer, entityID: label.id, findings: &findings)
            validate(
                label.netID,
                knownNetIDs: netIDs,
                code: "layout.label.net-missing",
                entityID: label.id,
                findings: &findings
            )
        }

        var pinIDs = Set<UUID>()
        var pinNames = Set<String>()
        for pin in cell.pins {
            if !pinIDs.insert(pin.id).inserted {
                findings.append(error(
                    "layout.pin.duplicate-id",
                    "Pin identifiers must be unique within a cell.",
                    pin.id
                ))
            }
            if !pin.name.contains(where: { !$0.isWhitespace }) {
                findings.append(error(
                    "layout.pin.name-missing",
                    "Pin names must not be empty.",
                    pin.id
                ))
            } else if !pinNames.insert(pin.name).inserted {
                findings.append(error(
                    "layout.pin.duplicate-name",
                    "Pin names must be unique within a cell.",
                    pin.id
                ))
            }
            validate(pin.position, entityID: pin.id, findings: &findings)
            validate(pin.size, entityID: pin.id, findings: &findings)
            validate(pin.layer, entityID: pin.id, findings: &findings)
            validate(
                pin.netID,
                knownNetIDs: netIDs,
                code: "layout.pin.net-missing",
                entityID: pin.id,
                findings: &findings
            )
        }

        var instanceIDs = Set<UUID>()
        var instanceNames = Set<String>()
        for instance in cell.instances {
            if !instanceIDs.insert(instance.id).inserted {
                findings.append(error(
                    "layout.instance.duplicate-id",
                    "Instance identifiers must be unique within a cell.",
                    instance.id
                ))
            }
            if !instance.name.contains(where: { !$0.isWhitespace }) {
                findings.append(error(
                    "layout.instance.name-missing",
                    "Instance names must not be empty.",
                    instance.id
                ))
            } else if !instanceNames.insert(instance.name).inserted {
                findings.append(error(
                    "layout.instance.duplicate-name",
                    "Instance names must be unique within a cell.",
                    instance.id
                ))
            }
            if !knownCellIDs.contains(instance.cellID) {
                findings.append(error(
                    "layout.instance.cell-missing",
                    "The referenced child cell does not exist.",
                    instance.id
                ))
            }
            validate(instance.transform, entityID: instance.id, findings: &findings)
            if let repetition = instance.repetition {
                validate(repetition, entityID: instance.id, findings: &findings)
            }
            for (terminal, netID) in instance.terminalNetIDs {
                if !terminal.contains(where: { !$0.isWhitespace }) {
                    findings.append(error(
                        "layout.instance.terminal-name-missing",
                        "Terminal binding names must not be empty.",
                        instance.id
                    ))
                }
                if !netIDs.contains(netID) {
                    findings.append(error(
                        "layout.instance.terminal-net-missing",
                        "An instance terminal references a missing parent-cell net.",
                        instance.id
                    ))
                }
            }
        }

        for constraint in cell.constraints {
            validate(
                constraint,
                knownInstanceIDs: instanceIDs,
                cellID: cell.id,
                findings: &findings
            )
        }
    }

    private func validateHierarchy(
        _ document: LayoutDocument,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        let knownCellIDs = Set(document.cells.map(\.id))
        var edges: [UUID: [UUID]] = [:]
        for cell in document.cells where edges[cell.id] == nil {
            edges[cell.id] = cell.instances
                .map(\.cellID)
                .filter(knownCellIDs.contains)
        }
        var states: [UUID: Int] = [:]

        func visit(_ cellID: UUID) {
            if states[cellID] == 2 { return }
            if states[cellID] == 1 {
                findings.append(error(
                    "layout.hierarchy.cycle",
                    "The cell-instance hierarchy contains a cycle.",
                    cellID
                ))
                return
            }
            states[cellID] = 1
            for childID in edges[cellID] ?? [] {
                visit(childID)
            }
            states[cellID] = 2
        }

        for cellID in knownCellIDs.sorted(by: uuidOrder) {
            visit(cellID)
        }
    }

    private func validate(
        _ geometry: LayoutGeometry,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        switch geometry {
        case .rect(let rect):
            validate(rect.origin, entityID: entityID, findings: &findings)
            validate(rect.size, entityID: entityID, findings: &findings)
        case .polygon(let polygon):
            if !polygon.isValid {
                findings.append(error(
                    "layout.geometry.polygon-invalid",
                    "A polygon must contain at least three points.",
                    entityID
                ))
            }
            for point in polygon.points {
                validate(point, entityID: entityID, findings: &findings)
            }
        case .path(let path):
            if !path.isValid || !path.width.isFinite {
                findings.append(error(
                    "layout.geometry.path-invalid",
                    "A path needs at least two points and a finite positive width.",
                    entityID
                ))
            }
            for point in path.points {
                validate(point, entityID: entityID, findings: &findings)
            }
        }
    }

    private func validate(
        _ transform: LayoutTransform,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        validate(transform.translation, entityID: entityID, findings: &findings)
        if !transform.rotationDegrees.isFinite
            || !transform.magnification.isFinite
            || transform.magnification <= 0 {
            findings.append(error(
                "layout.instance.transform-invalid",
                "Instance rotation and positive magnification must be finite.",
                entityID
            ))
        }
    }

    private func validate(
        _ repetition: LayoutRepetition,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        if repetition.columns <= 0 || repetition.rows <= 0 {
            findings.append(error(
                "layout.instance.repetition-invalid",
                "Repetition rows and columns must be positive.",
                entityID
            ))
        }
        validate(repetition.columnStep, entityID: entityID, findings: &findings)
        validate(repetition.rowStep, entityID: entityID, findings: &findings)
    }

    private func validate(
        _ constraint: LayoutConstraint,
        knownInstanceIDs: Set<UUID>,
        cellID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        let members: [UUID]
        switch constraint {
        case .symmetry(let value):
            members = value.members + value.selfSymmetricMembers
            if value.members.count % 2 != 0 {
                findings.append(error(
                    "layout.constraint.symmetry-pairs-invalid",
                    "Symmetry pair members must have an even count.",
                    cellID
                ))
            }
            if let axis = value.axisPosition, !axis.isFinite {
                findings.append(error(
                    "layout.constraint.axis-invalid",
                    "A fixed symmetry axis must be finite.",
                    cellID
                ))
            }
        case .matching(let value):
            members = value.members
            validateNonnegative(
                value.maxLengthMismatch,
                code: "layout.constraint.length-mismatch-invalid",
                cellID: cellID,
                findings: &findings
            )
            validateNonnegative(
                value.maxWidthMismatch,
                code: "layout.constraint.width-mismatch-invalid",
                cellID: cellID,
                findings: &findings
            )
        case .commonCentroid(let value):
            members = value.members
            if value.pattern.isEmpty {
                findings.append(error(
                    "layout.constraint.pattern-missing",
                    "A common-centroid pattern must not be empty.",
                    cellID
                ))
            }
        case .interdigitated(let value):
            members = value.members
            if value.pattern.isEmpty {
                findings.append(error(
                    "layout.constraint.pattern-missing",
                    "An interdigitated pattern must not be empty.",
                    cellID
                ))
            }
        case .alignment(let value):
            members = value.members
            if !value.tolerance.isFinite || value.tolerance < 0 {
                findings.append(error(
                    "layout.constraint.tolerance-invalid",
                    "Alignment tolerance must be finite and nonnegative.",
                    cellID
                ))
            }
        }
        if members.count < 2 {
            findings.append(error(
                "layout.constraint.members-insufficient",
                "A placement constraint must reference at least two members.",
                cellID
            ))
        }
        var uniqueMembers = Set<UUID>()
        for memberID in members {
            if !knownInstanceIDs.contains(memberID) {
                findings.append(error(
                    "layout.constraint.member-missing",
                    "A placement constraint references a missing instance.",
                    memberID
                ))
            }
            if !uniqueMembers.insert(memberID).inserted {
                findings.append(error(
                    "layout.constraint.member-duplicate",
                    "A placement constraint repeats an instance identifier.",
                    memberID
                ))
            }
        }
    }

    private func validate(
        _ point: LayoutPoint,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        if !point.x.isFinite || !point.y.isFinite {
            findings.append(error(
                "layout.geometry.coordinate-invalid",
                "Layout coordinates must be finite.",
                entityID
            ))
        }
    }

    private func validate(
        _ size: LayoutSize,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        if !size.width.isFinite || !size.height.isFinite
            || size.width <= 0 || size.height <= 0 {
            findings.append(error(
                "layout.geometry.size-invalid",
                "Layout width and height must be finite and positive.",
                entityID
            ))
        }
    }

    private func validate(
        _ layer: LayoutLayerID,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        if !layer.name.contains(where: { !$0.isWhitespace })
            || !layer.purpose.contains(where: { !$0.isWhitespace }) {
            findings.append(error(
                "layout.layer.identity-invalid",
                "Layer name and purpose must not be empty.",
                entityID
            ))
        }
    }

    private func validate(
        _ netID: UUID?,
        knownNetIDs: Set<UUID>,
        code: String,
        entityID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        if let netID, !knownNetIDs.contains(netID) {
            findings.append(error(
                code,
                "The referenced net does not exist in the owning cell.",
                entityID
            ))
        }
    }

    private func validateNonnegative(
        _ value: Double?,
        code: String,
        cellID: UUID,
        findings: inout [LayoutDocumentValidationFinding]
    ) {
        if let value, !value.isFinite || value < 0 {
            findings.append(error(
                code,
                "Constraint mismatch bounds must be finite and nonnegative.",
                cellID
            ))
        }
    }

    private func error(
        _ code: String,
        _ summary: String,
        _ entityID: UUID
    ) -> LayoutDocumentValidationFinding {
        LayoutDocumentValidationFinding(
            severity: .error,
            code: code,
            summary: summary,
            entityID: entityID.uuidString.lowercased()
        )
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}
