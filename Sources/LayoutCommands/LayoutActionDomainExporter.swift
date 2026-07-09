public struct LayoutActionDomainExporter: Sendable {
    public init() {}

    public func snapshot() -> LayoutActionDomainSnapshot {
        LayoutActionDomainSnapshot(
            domainID: "layout-edit",
            ownerPackages: ["semiconductor-layout"],
            operations: [
                replayOperation(),
                createCellOperation(),
                addNetOperation(),
                addRectOperation(),
                addShapeOperation(),
                finishNetOperation(),
                translateShapeOperation(),
                resizeShapeOperation(),
                deleteShapeOperation(),
                splitShapeOperation(),
                addLabelOperation(),
                addViaOperation(),
                addConstraintOperation(),
                addGuardRingOperation(),
                addInstanceOperation(),
                moveInstanceOperation(),
                rotateInstanceOperation(),
                mirrorInstanceOperation(),
                flattenInstanceOperation(),
                makeCellOperation(),
                fixAllViolationsOperation(),
                validateConstraintsOperation(),
            ]
        )
    }

    private func replayOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout-command-replay",
            maturity: "implemented",
            inputRefs: ["layout-command-request"],
            preconditions: ["valid-layout-command-request", "explicit-entity-identifiers"],
            effects: ["layout-document-updated", "artifact-manifest-written"],
            producedArtifacts: ["layout-document", "layout-command-result", "layout-command-manifest"],
            verificationGates: ["artifact-integrity"],
            reversible: false
        )
    }

    private func createCellOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.create-cell",
            maturity: "implemented",
            inputRefs: ["document-ref"],
            preconditions: ["unique-cell-id", "valid-cell-name"],
            effects: ["cell-created", "optional-top-cell-updated"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity"],
            reversible: true
        )
    }

    private func addNetOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-net",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref"],
            preconditions: ["cell-exists", "unique-net-id", "valid-net-name"],
            effects: ["net-created"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity"],
            reversible: true
        )
    }

    private func addRectOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-rect",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "layer-ref", "optional-net-ref"],
            preconditions: [
                "cell-exists",
                "unique-shape-id",
                "positive-rect-size",
                "net-ref-exists-when-present",
            ],
            effects: ["rect-shape-created", "optional-net-assigned"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc"],
            reversible: true
        )
    }

    private func addShapeOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-shape",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "layer-ref", "geometry", "optional-net-ref"],
            preconditions: [
                "cell-exists",
                "unique-shape-id",
                "valid-shape-geometry",
                "net-ref-exists-when-present",
            ],
            effects: ["shape-created", "optional-net-assigned"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func finishNetOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.finish-net",
            maturity: "implemented",
            inputRefs: [
                "document-ref",
                "cell-ref",
                "net-ref",
                "layer-ref",
                "route-policy",
                "route-endpoints",
                "explicit-route-shape-ids",
                "optional-technology-profile-ref",
                "optional-finish-net-report-ref",
            ],
            preconditions: [
                "cell-exists",
                "net-exists",
                "positive-route-width",
                "explicit-route-or-open-net-flyline-available",
                "orthogonal-route-materializable",
            ],
            effects: [
                "route-shapes-created",
                "net-connectivity-geometry-added",
                "optional-drc-report-produced",
                "optional-open-net-reduction-verified",
            ],
            producedArtifacts: ["layout-document", "layout-command-result", "layout-finish-net-report"],
            verificationGates: [
                "artifact-integrity",
                "native-drc",
                "native-lvs",
                "optional-finish-net-drc-report",
                "optional-open-net-auto-route-gate",
            ],
            reversible: true
        )
    }

    private func translateShapeOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.translate-shape",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "shape-ref"],
            preconditions: ["cell-exists", "shape-exists"],
            effects: ["shape-position-updated"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func resizeShapeOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.resize-shape",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "shape-ref"],
            preconditions: ["cell-exists", "shape-exists", "shape-is-resizable", "positive-resized-bounds"],
            effects: ["shape-bounds-updated"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func deleteShapeOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.delete-shape",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "shape-ref"],
            preconditions: ["cell-exists", "shape-exists", "delete-policy-approved"],
            effects: ["shape-deleted"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func splitShapeOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.split-shape",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "shape-ref"],
            preconditions: [
                "cell-exists",
                "shape-exists",
                "shape-is-splittable",
                "valid-split-coordinate",
                "explicit-child-shape-ids",
            ],
            effects: ["shape-split", "shape-deleted", "child-shapes-created"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func addLabelOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-label",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "layer-ref", "optional-net-ref"],
            preconditions: [
                "cell-exists",
                "unique-label-id",
                "valid-label-text",
                "net-ref-exists-when-present",
            ],
            effects: ["label-created", "optional-net-assigned"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-lvs"],
            reversible: true
        )
    }

    private func addViaOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-via",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "via-definition-ref", "optional-net-ref"],
            preconditions: [
                "cell-exists",
                "unique-via-id",
                "valid-via-definition-id",
                "net-ref-exists-when-present",
            ],
            effects: ["via-created", "optional-net-assigned"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func addConstraintOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-constraint",
            maturity: "implemented",
            inputRefs: [
                "document-ref",
                "cell-ref",
                "layout-constraint",
                "shape-or-instance-member-refs",
            ],
            preconditions: [
                "cell-exists",
                "constraint-structure-valid",
                "constraint-members-exist",
            ],
            effects: ["design-intent-constraint-recorded"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "layout-constraint-validation"],
            reversible: true
        )
    }

    private func addGuardRingOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-guard-ring",
            maturity: "implemented",
            inputRefs: [
                "document-ref",
                "cell-ref",
                "technology-profile-ref",
                "guard-ring-request",
                "optional-net-ref",
                "optional-guard-ring-report-ref",
            ],
            preconditions: [
                "cell-exists",
                "technology-profile-decodable",
                "guard-ring-rules-available",
                "guard-ring-fits-contact-array",
                "net-ref-exists-when-present",
                "deterministic-shape-ids-do-not-collide",
            ],
            effects: [
                "guard-ring-active-geometry-created",
                "guard-ring-implant-geometry-created",
                "guard-ring-metal-geometry-created",
                "guard-ring-contact-array-created",
                "optional-guard-ring-report-produced",
            ],
            producedArtifacts: [
                "layout-document",
                "layout-command-result",
                "layout-command-manifest",
                "layout-guard-ring-report",
            ],
            verificationGates: ["artifact-integrity", "native-drc", "layout-constraint-validation"],
            reversible: true
        )
    }

    private func addInstanceOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.add-instance",
            maturity: "implemented",
            inputRefs: [
                "document-ref",
                "parent-cell-ref",
                "referenced-cell-ref",
                "terminal-net-bindings",
            ],
            preconditions: [
                "parent-cell-exists",
                "referenced-cell-exists",
                "unique-instance-id",
                "acyclic-cell-hierarchy",
                "terminal-net-refs-exist-when-present",
            ],
            effects: ["instance-created", "cell-hierarchy-updated"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func moveInstanceOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.move-instance",
            maturity: "implemented",
            inputRefs: ["document-ref", "parent-cell-ref", "instance-ref"],
            preconditions: ["parent-cell-exists", "instance-exists"],
            effects: ["instance-translation-updated"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func rotateInstanceOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.rotate-instance",
            maturity: "implemented",
            inputRefs: ["document-ref", "parent-cell-ref", "instance-ref"],
            preconditions: ["parent-cell-exists", "instance-exists", "optional-explicit-pivot"],
            effects: ["instance-rotation-updated", "instance-translation-updated-when-pivoted"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func mirrorInstanceOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.mirror-instance",
            maturity: "implemented",
            inputRefs: ["document-ref", "parent-cell-ref", "instance-ref"],
            preconditions: ["parent-cell-exists", "instance-exists", "valid-mirror-axis", "optional-explicit-origin"],
            effects: ["instance-mirror-updated", "instance-translation-updated-when-origin-provided"],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func flattenInstanceOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.flatten-instance",
            maturity: "implemented",
            inputRefs: ["document-ref", "parent-cell-ref", "instance-ref"],
            preconditions: [
                "parent-cell-exists",
                "instance-exists",
                "referenced-cell-exists",
                "acyclic-cell-hierarchy",
            ],
            effects: [
                "instance-removed",
                "child-geometry-materialized",
                "deterministic-copy-ids-created",
            ],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func makeCellOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.make-cell",
            maturity: "implemented",
            inputRefs: ["document-ref", "parent-cell-ref", "shape-selection", "instance-selection"],
            preconditions: [
                "parent-cell-exists",
                "non-empty-selection",
                "selected-entities-exist",
                "unique-new-cell-id",
                "unique-new-instance-id",
                "acyclic-resulting-hierarchy",
            ],
            effects: [
                "cell-created",
                "selection-extracted",
                "replacement-instance-created",
            ],
            producedArtifacts: ["layout-document", "layout-command-result"],
            verificationGates: ["artifact-integrity", "native-drc", "native-lvs"],
            reversible: true
        )
    }

    private func fixAllViolationsOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.fix-all-violations",
            maturity: "implemented",
            inputRefs: ["document-ref", "cell-ref", "technology-profile-ref", "repair-report-ref"],
            preconditions: ["cell-exists", "technology-profile-decodable", "positive-repair-budget"],
            effects: ["verified-repair-deltas-applied", "residual-violations-reported"],
            producedArtifacts: [
                "layout-document",
                "layout-command-result",
                "layout-command-manifest",
                "layout-repair-sweep-report",
            ],
            verificationGates: ["artifact-integrity", "native-drc", "repair-delta-verification"],
            reversible: true
        )
    }

    private func validateConstraintsOperation() -> LayoutActionDomainOperation {
        LayoutActionDomainOperation(
            operationID: "layout.validate-constraints",
            maturity: "implemented",
            inputRefs: ["layout-document", "optional-cell-ref", "constraint-tolerance"],
            preconditions: ["layout-document-decodable", "cell-exists-when-provided"],
            effects: ["design-intent-constraints-evaluated"],
            producedArtifacts: [
                "layout-constraint-validation-result",
                "layout-command-manifest",
            ],
            verificationGates: ["artifact-integrity", "layout-constraint-validation"],
            reversible: false
        )
    }
}
