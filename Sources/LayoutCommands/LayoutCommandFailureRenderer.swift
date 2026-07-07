import Foundation

public struct LayoutCommandFailureRenderer: Sendable {
    public init() {}

    public func output(for error: any Error) -> LayoutCommandFailureOutput {
        let errorCode = errorCode(for: error)
        return LayoutCommandFailureOutput(
            errorCode: errorCode,
            reason: reason(for: error),
            message: error.localizedDescription,
            suggestedActions: suggestedActions(for: error)
        )
    }

    public func jsonString(for error: any Error) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output(for: error))
        return String(decoding: data, as: UTF8.self)
    }

    private func errorCode(for error: any Error) -> String {
        guard let error = error as? LayoutCommandError else {
            return "layout_command_failed"
        }
        switch error {
        case .unsupportedSchemaVersion:
            return "unsupported_schema_version"
        case .missingDocumentIDForNewDocument:
            return "missing_document_id_for_new_document"
        case .duplicateCellID:
            return "duplicate_cell_id"
        case .duplicateNetID:
            return "duplicate_net_id"
        case .netNotFound:
            return "net_not_found"
        case .duplicateShapeID:
            return "duplicate_shape_id"
        case .duplicateLabelID:
            return "duplicate_label_id"
        case .duplicateViaID:
            return "duplicate_via_id"
        case .duplicateInstanceID:
            return "duplicate_instance_id"
        case .cellNotFound:
            return "cell_not_found"
        case .shapeNotFound:
            return "shape_not_found"
        case .viaNotFound:
            return "via_not_found"
        case .instanceNotFound:
            return "instance_not_found"
        case .invalidInstanceHierarchy:
            return "invalid_instance_hierarchy"
        case .emptySelection:
            return "empty_selection"
        case .duplicateSelectionID:
            return "duplicate_selection_id"
        case .deterministicIDCollision:
            return "deterministic_id_collision"
        case .invalidRectSize:
            return "invalid_rect_size"
        case .invalidShapeGeometry:
            return "invalid_shape_geometry"
        case .missingRouteShapeID:
            return "missing_route_shape_id"
        case .unsupportedResizeGeometry:
            return "unsupported_resize_geometry"
        case .invalidResizeResult:
            return "invalid_resize_result"
        case .unsupportedSplitGeometry:
            return "unsupported_split_geometry"
        case .invalidSplitCoordinate:
            return "invalid_split_coordinate"
        case .invalidRepairBudget:
            return "invalid_repair_budget"
        case .missingRequiredArgument:
            return "missing_required_argument"
        case .missingValueAfter:
            return "missing_value_after"
        case .duplicateArgument:
            return "duplicate_argument"
        case .unknownArgument:
            return "unknown_argument"
        case .invalidFormat:
            return "invalid_format"
        case .conflictingArguments:
            return "conflicting_arguments"
        case .conflictingArtifactPath:
            return "conflicting_artifact_path"
        case .missingCommandMode:
            return "missing_command_mode"
        }
    }

    private func reason(for error: any Error) -> String {
        guard let error = error as? LayoutCommandError else {
            return "layout_command_execution_failed"
        }
        switch error {
        case .unsupportedSchemaVersion:
            return "unsupported_schema"
        case .missingDocumentIDForNewDocument,
             .missingRequiredArgument,
             .missingValueAfter,
             .missingCommandMode:
            return "missing_input"
        case .duplicateCellID,
             .duplicateNetID,
             .duplicateShapeID,
             .duplicateLabelID,
             .duplicateViaID,
             .duplicateInstanceID,
             .duplicateSelectionID,
             .deterministicIDCollision,
             .duplicateArgument:
            return "duplicate_identifier"
        case .netNotFound,
             .cellNotFound,
             .shapeNotFound,
             .viaNotFound,
             .instanceNotFound,
             .missingRouteShapeID:
            return "missing_reference"
        case .invalidRectSize,
             .invalidShapeGeometry,
             .invalidResizeResult,
             .invalidSplitCoordinate:
            return "invalid_geometry"
        case .invalidInstanceHierarchy:
            return "invalid_hierarchy"
        case .emptySelection:
            return "invalid_selection"
        case .unsupportedResizeGeometry,
             .unsupportedSplitGeometry:
            return "unsupported_geometry"
        case .invalidRepairBudget:
            return "invalid_budget"
        case .unknownArgument,
             .invalidFormat,
             .conflictingArguments:
            return "invalid_cli_argument"
        case .conflictingArtifactPath:
            return "artifact_path_conflict"
        }
    }

    private func suggestedActions(for error: any Error) -> [String] {
        guard let error = error as? LayoutCommandError else {
            return [
                "inspect-layout-command-input",
                "check-layout-command-logs",
                "rerun-layout-command-after-fix",
            ]
        }
        switch error {
        case .unsupportedSchemaVersion:
            return [
                "upgrade-layout-command-request-schema",
                "regenerate-layout-command-request",
            ]
        case .missingDocumentIDForNewDocument:
            return [
                "provide-document-id",
                "provide-input-document-path",
            ]
        case .missingRequiredArgument,
             .missingValueAfter,
             .missingCommandMode:
            return [
                "provide-required-layout-command-argument",
                "inspect-layout-command-help",
            ]
        case .duplicateCellID,
             .duplicateNetID,
             .duplicateShapeID,
             .duplicateLabelID,
             .duplicateViaID,
             .duplicateInstanceID,
             .duplicateSelectionID,
             .deterministicIDCollision:
            return [
                "inspect-existing-layout-ids",
                "generate-unique-deterministic-id",
                "retry-command-with-new-id",
            ]
        case .netNotFound:
            return [
                "inspect-cell-nets",
                "use-existing-net-id",
                "create-net-before-reference",
            ]
        case .cellNotFound:
            return [
                "inspect-layout-cells",
                "use-existing-cell-id",
                "create-cell-before-reference",
            ]
        case .shapeNotFound:
            return [
                "inspect-cell-shapes",
                "use-existing-shape-id",
                "create-shape-before-reference",
            ]
        case .viaNotFound:
            return [
                "inspect-cell-vias",
                "use-existing-via-id",
                "create-via-before-reference",
            ]
        case .instanceNotFound:
            return [
                "inspect-cell-instances",
                "use-existing-instance-id",
                "create-instance-before-reference",
            ]
        case .missingRouteShapeID:
            return [
                "provide-route-shape-id",
                "generate-route-segment-ids",
            ]
        case .invalidRectSize:
            return [
                "use-positive-rectangle-size",
                "inspect-layout-command-geometry",
            ]
        case .invalidShapeGeometry:
            return [
                "repair-shape-geometry",
                "use-positive-area-polygon-or-length-path",
                "inspect-layout-command-geometry",
            ]
        case .invalidResizeResult:
            return [
                "adjust-resize-delta",
                "use-positive-rectangle-size",
            ]
        case .invalidSplitCoordinate:
            return [
                "choose-split-coordinate-inside-shape",
                "inspect-shape-bounds",
            ]
        case .invalidInstanceHierarchy:
            return [
                "select-non-recursive-reference-cell",
                "inspect-instance-hierarchy",
            ]
        case .emptySelection:
            return [
                "select-shapes-or-instances",
                "inspect-selection-payload",
            ]
        case .unsupportedResizeGeometry:
            return [
                "select-rectangle-shape",
                "convert-geometry-before-resize",
            ]
        case .unsupportedSplitGeometry:
            return [
                "select-rectangle-shape",
                "convert-geometry-before-split",
            ]
        case .invalidRepairBudget:
            return [
                "use-positive-repair-budget",
                "inspect-repair-policy",
            ]
        case .duplicateArgument:
            return [
                "remove-duplicate-cli-argument",
                "inspect-layout-command-help",
            ]
        case .unknownArgument:
            return [
                "remove-unknown-cli-argument",
                "inspect-layout-command-help",
            ]
        case .invalidFormat:
            return [
                "select-supported-layout-format",
                "inspect-layout-command-help",
            ]
        case .conflictingArguments:
            return [
                "choose-one-layout-command-mode",
                "remove-conflicting-cli-argument",
            ]
        case .conflictingArtifactPath:
            return [
                "choose-distinct-artifact-paths",
                "inspect-layout-command-artifact-plan",
            ]
        }
    }
}
