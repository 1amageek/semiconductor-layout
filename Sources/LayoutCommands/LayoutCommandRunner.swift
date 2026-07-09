import CryptoKit
import Foundation
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify

public struct LayoutCommandRunner: Sendable {
    private let serializer: LayoutDocumentSerializer
    private let encoder: JSONEncoder

    struct PendingCommandArtifact: Sendable {
        var id: String
        var kind: String
        var format: String
        var url: URL
        var data: Data
        var status: String?
    }

    public init(serializer: LayoutDocumentSerializer = LayoutDocumentSerializer()) {
        self.serializer = serializer
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    public func run(request: LayoutCommandRequest, baseURL: URL) throws -> LayoutCommandResult {
        try validateSchemaVersion(request.schemaVersion)
        let execution = try execute(request: request, baseURL: baseURL)
        return try persistResult(
            for: request,
            editor: execution.editor,
            appliedCommands: execution.appliedCommands,
            pendingArtifacts: execution.pendingArtifacts,
            baseURL: baseURL
        )
    }

    private struct CommandExecution {
        var editor: LayoutDocumentEditor
        var appliedCommands: [LayoutAppliedCommand]
        var pendingArtifacts: [PendingCommandArtifact]
    }

    private struct WrittenDocument {
        var url: URL
        var data: Data
        var digest: String
    }

    private struct ArtifactPathEntry {
        var role: String
        var url: URL
    }

    private func validateSchemaVersion(_ schemaVersion: Int) throws {
        guard schemaVersion == 1 else {
            throw LayoutCommandError.unsupportedSchemaVersion(schemaVersion)
        }
    }

    private func execute(request: LayoutCommandRequest, baseURL: URL) throws -> CommandExecution {
        var editor = LayoutDocumentEditor(document: try loadDocument(from: request, baseURL: baseURL))
        var appliedCommands: [LayoutAppliedCommand] = []
        var pendingArtifacts: [PendingCommandArtifact] = []

        for (index, command) in request.commands.enumerated() {
            let applied = try apply(
                command,
                index: index,
                editor: &editor,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
            appliedCommands.append(applied)
        }

        return CommandExecution(
            editor: editor,
            appliedCommands: appliedCommands,
            pendingArtifacts: pendingArtifacts
        )
    }

    private func persistResult(
        for request: LayoutCommandRequest,
        editor: LayoutDocumentEditor,
        appliedCommands: [LayoutAppliedCommand],
        pendingArtifacts: [PendingCommandArtifact],
        baseURL: URL
    ) throws -> LayoutCommandResult {
        let outputURL = resolve(path: request.outputDocumentPath, baseURL: baseURL)
        let manifestURL = request.artifactManifestPath.map { resolve(path: $0, baseURL: baseURL) }
            ?? outputURL.deletingLastPathComponent().appendingPathComponent("layout-command-artifact-manifest.json")
        let resultURL = request.resultPath.map { resolve(path: $0, baseURL: baseURL) }
        try validateDistinctArtifactPaths(
            outputURL: outputURL,
            manifestURL: manifestURL,
            resultURL: resultURL,
            pendingArtifacts: pendingArtifacts
        )
        let output = try writeOutputDocument(editor.document, to: outputURL)
        let result = makeResult(
            request: request,
            appliedCommands: appliedCommands,
            pendingArtifacts: pendingArtifacts,
            output: output,
            manifestURL: manifestURL,
            document: editor.document
        )
        let artifacts = try persistArtifacts(
            output: output,
            result: result,
            resultURL: resultURL,
            pendingArtifacts: pendingArtifacts
        )
        try writeArtifactManifest(artifacts, to: manifestURL)
        return result
    }

    private func writeOutputDocument(
        _ document: LayoutDocument,
        to outputURL: URL
    ) throws -> WrittenDocument {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outputData = try serializer.encodeDocument(document)
        try outputData.write(to: outputURL, options: [.atomic])
        return WrittenDocument(url: outputURL, data: outputData, digest: Self.sha256Hex(outputData))
    }

    private func makeResult(
        request: LayoutCommandRequest,
        appliedCommands: [LayoutAppliedCommand],
        pendingArtifacts: [PendingCommandArtifact],
        output: WrittenDocument,
        manifestURL: URL,
        document: LayoutDocument
    ) -> LayoutCommandResult {
        let counts = countElements(in: document)
        return LayoutCommandResult(
            status: resultStatus(for: pendingArtifacts),
            commandCount: request.commands.count,
            appliedCommands: appliedCommands,
            outputDocumentPath: output.url.path,
            outputDocumentSHA256: output.digest,
            outputDocumentByteCount: output.data.count,
            artifactManifestPath: manifestURL.path,
            cellCount: counts.cells,
            shapeCount: counts.shapes,
            viaCount: counts.vias,
            labelCount: counts.labels,
            netCount: counts.nets
        )
    }

    private func persistArtifacts(
        output: WrittenDocument,
        result: LayoutCommandResult,
        resultURL: URL?,
        pendingArtifacts: [PendingCommandArtifact]
    ) throws -> [LayoutCommandArtifact] {
        var artifacts = [
            LayoutCommandArtifact(
                id: "output-layout-document",
                kind: "layout",
                format: "LayoutDocumentJSON",
                path: output.url.path,
                sha256: output.digest,
                byteCount: output.data.count
            )
        ]
        for pending in pendingArtifacts {
            artifacts.append(try writePendingArtifact(pending))
        }
        if let resultURL {
            artifacts.append(try writeResultArtifact(result, to: resultURL))
        }
        return artifacts
    }

    private func writePendingArtifact(_ pending: PendingCommandArtifact) throws -> LayoutCommandArtifact {
        try FileManager.default.createDirectory(
            at: pending.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pending.data.write(to: pending.url, options: [.atomic])
        return LayoutCommandArtifact(
            id: pending.id,
            kind: pending.kind,
            format: pending.format,
            path: pending.url.path,
            sha256: Self.sha256Hex(pending.data),
            byteCount: pending.data.count
        )
    }

    private func writeResultArtifact(
        _ result: LayoutCommandResult,
        to resultURL: URL
    ) throws -> LayoutCommandArtifact {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let resultData = try encoder.encode(result)
        try resultData.write(to: resultURL, options: [.atomic])
        return LayoutCommandArtifact(
            id: "layout-command-result",
            kind: "result",
            format: "LayoutCommandResultJSON",
            path: resultURL.path,
            sha256: Self.sha256Hex(resultData),
            byteCount: resultData.count
        )
    }

    private func writeArtifactManifest(_ artifacts: [LayoutCommandArtifact], to manifestURL: URL) throws {
        let manifest = LayoutCommandArtifactManifest(artifacts: artifacts)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: [.atomic])
    }

    private func validateDistinctArtifactPaths(
        outputURL: URL,
        manifestURL: URL,
        resultURL: URL?,
        pendingArtifacts: [PendingCommandArtifact]
    ) throws {
        var entries = [
            ArtifactPathEntry(role: "output", url: outputURL),
            ArtifactPathEntry(role: "artifact-manifest", url: manifestURL),
        ]
        if let resultURL {
            entries.append(ArtifactPathEntry(role: "result", url: resultURL))
        }
        entries.append(contentsOf: pendingArtifacts.map { pending in
            ArtifactPathEntry(role: "pending-artifact:\(pending.id)", url: pending.url)
        })
        try validateDistinctArtifactPaths(entries)
    }

    private func validateDistinctArtifactPaths(_ entries: [ArtifactPathEntry]) throws {
        var roleByPath: [String: String] = [:]
        for entry in entries {
            let path = entry.url.standardizedFileURL.path
            if let existingRole = roleByPath[path] {
                throw LayoutCommandError.conflictingArtifactPath("\(existingRole) and \(entry.role)", entry.url.path)
            }
            roleByPath[path] = entry.role
        }
    }

    private func loadDocument(from request: LayoutCommandRequest, baseURL: URL) throws -> LayoutDocument {
        if let path = request.inputDocumentPath {
            let url = resolve(path: path, baseURL: baseURL)
            let data = try Data(contentsOf: url)
            let document = try serializer.decodeDocument(data)
            try validateInputDocument(document)
            return document
        }

        guard let documentID = request.documentID else {
            throw LayoutCommandError.missingDocumentIDForNewDocument
        }
        return LayoutDocument(id: documentID, name: request.documentName ?? "layout")
    }

    private func validateInputDocument(_ document: LayoutDocument) throws {
        var cellIDs: Set<UUID> = []
        for cell in document.cells {
            guard !cellIDs.contains(cell.id) else {
                throw LayoutCommandError.duplicateCellID(cell.id)
            }
            cellIDs.insert(cell.id)
        }

        if let topCellID = document.topCellID, !cellIDs.contains(topCellID) {
            throw LayoutCommandError.cellNotFound(topCellID)
        }
    }

    private func apply(
        _ command: LayoutCommand,
        index: Int,
        editor: inout LayoutDocumentEditor,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws -> LayoutAppliedCommand {
        switch command {
        case .createCell(let payload):
            return try applyCreateCell(payload, index: index, kind: command.kind, editor: &editor)
        case .addNet(let payload):
            return try applyAddNet(payload, index: index, kind: command.kind, editor: &editor)
        case .addRect(let payload):
            return try applyAddRect(payload, index: index, kind: command.kind, editor: &editor)
        case .addShape(let payload):
            return try applyAddShape(payload, index: index, kind: command.kind, editor: &editor)
        case .finishNet(let payload):
            return try applyFinishNet(
                payload,
                index: index,
                kind: command.kind,
                editor: &editor,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
        case .translateShape(let payload):
            return try applyTranslateShape(payload, index: index, kind: command.kind, editor: &editor)
        case .resizeShape(let payload):
            return try applyResizeShape(payload, index: index, kind: command.kind, editor: &editor)
        case .deleteShape(let payload):
            try editor.removeShape(id: payload.shapeID, from: payload.cellID)
            return LayoutAppliedCommand(index: index, kind: command.kind, cellID: payload.cellID, entityID: payload.shapeID)
        case .splitShape(let payload):
            return try applySplitShape(payload, index: index, kind: command.kind, editor: &editor)
        case .addLabel(let payload):
            return try applyAddLabel(payload, index: index, kind: command.kind, editor: &editor)
        case .addVia(let payload):
            return try applyAddVia(payload, index: index, kind: command.kind, editor: &editor)
        case .addConstraint(let payload):
            return try applyAddConstraint(payload, index: index, kind: command.kind, editor: &editor)
        case .addInstance(let payload):
            return try applyAddInstance(payload, index: index, kind: command.kind, editor: &editor)
        case .moveInstance(let payload):
            return try applyMoveInstance(payload, index: index, kind: command.kind, editor: &editor)
        case .rotateInstance(let payload):
            return try applyRotateInstance(payload, index: index, kind: command.kind, editor: &editor)
        case .mirrorInstance(let payload):
            return try applyMirrorInstance(payload, index: index, kind: command.kind, editor: &editor)
        case .flattenInstance(let payload):
            try flattenInstance(payload, editor: &editor)
            return LayoutAppliedCommand(index: index, kind: command.kind, cellID: payload.cellID, entityID: payload.instanceID)
        case .makeCell(let payload):
            try makeCell(payload, editor: &editor)
            return LayoutAppliedCommand(index: index, kind: command.kind, cellID: payload.cellID, entityID: payload.newCellID)
        case .fixAllViolations(let payload):
            try fixAllViolations(
                payload,
                index: index,
                editor: &editor,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
            return LayoutAppliedCommand(index: index, kind: command.kind, cellID: payload.cellID, entityID: nil)
        }
    }

    private func applyCreateCell(
        _ payload: CreateCellCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        try ensureCellMissing(payload.cellID, in: editor.document)
        var cell = LayoutCell(id: payload.cellID, name: payload.name)
        editor.addCell(cell)
        if payload.makeTop {
            editor.perform { document in
                document.topCellID = cell.id
            }
        }
        cell = editor.document.cell(withID: payload.cellID) ?? cell
        return LayoutAppliedCommand(index: index, kind: kind, cellID: cell.id, entityID: cell.id)
    }

    private func applyAddNet(
        _ payload: AddNetCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        try ensureNetMissing(payload.netID, cellID: payload.cellID, in: editor.document)
        try editor.addNet(LayoutNet(id: payload.netID, name: payload.name, currentSpec: payload.currentSpec), to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.netID)
    }

    private func applyAddRect(
        _ payload: AddRectCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        guard payload.size.width > 0, payload.size.height > 0 else {
            throw LayoutCommandError.invalidRectSize(width: payload.size.width, height: payload.size.height)
        }
        try ensureShapeMissing(payload.shapeID, cellID: payload.cellID, in: editor.document)
        try ensureNetExistsIfPresent(payload.netID, cellID: payload.cellID, in: editor.document)
        let shape = LayoutShape(
            id: payload.shapeID,
            layer: payload.layer,
            netID: payload.netID,
            geometry: .rect(LayoutRect(origin: payload.origin, size: payload.size)),
            properties: payload.properties
        )
        try editor.addShape(shape, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.shapeID)
    }

    private func applyAddShape(
        _ payload: AddShapeCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        try validateGeometry(payload.geometry)
        try ensureShapeMissing(payload.shapeID, cellID: payload.cellID, in: editor.document)
        try ensureNetExistsIfPresent(payload.netID, cellID: payload.cellID, in: editor.document)
        let shape = LayoutShape(
            id: payload.shapeID,
            layer: payload.layer,
            netID: payload.netID,
            geometry: payload.geometry,
            properties: payload.properties
        )
        try editor.addShape(shape, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.shapeID)
    }

    private func applyFinishNet(
        _ payload: FinishNetCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws -> LayoutAppliedCommand {
        guard payload.width > 0 else {
            throw LayoutCommandError.invalidRectSize(width: payload.width, height: payload.width)
        }
        try ensureNetExists(payload.netID, cellID: payload.cellID, in: editor.document)
        switch payload.routePolicy ?? .explicitSegment {
        case .explicitSegment:
            try applyExplicitFinishNet(
                payload,
                index: index,
                editor: &editor,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
        case .openNetAutoRoute:
            try applyOpenNetAutoRoute(
                payload,
                index: index,
                editor: &editor,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
        }
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.netID)
    }

    private func applyExplicitFinishNet(
        _ payload: FinishNetCommand,
        index: Int,
        editor: inout LayoutDocumentEditor,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws {
        try validateFinishNetShapeIDs(payload, document: editor.document)
        let routeShapes = try finishNetShapes(payload)
        for shape in routeShapes {
            try editor.addShape(shape, to: payload.cellID)
        }
        if payload.technologyPath != nil || payload.reportPath != nil {
            try recordFinishNetReport(
                payload,
                index: index,
                routeShapeIDs: routeShapes.map(\.id),
                document: editor.document,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
        }
    }

    private func validateFinishNetShapeIDs(
        _ payload: FinishNetCommand,
        document: LayoutDocument
    ) throws {
        guard let firstShapeID = payload.firstShapeID else {
            throw LayoutCommandError.missingRequiredArgument("finishNet.firstShapeID")
        }
        try ensureShapeMissing(firstShapeID, cellID: payload.cellID, in: document)
        if let secondShapeID = payload.secondShapeID {
            guard secondShapeID != firstShapeID else {
                throw LayoutCommandError.duplicateShapeID(secondShapeID)
            }
            try ensureShapeMissing(secondShapeID, cellID: payload.cellID, in: document)
        }
    }

    private func applyOpenNetAutoRoute(
        _ payload: FinishNetCommand,
        index: Int,
        editor: inout LayoutDocumentEditor,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws {
        guard let technologyPath = payload.technologyPath else {
            throw LayoutCommandError.missingRequiredArgument("finishNet.technologyPath")
        }
        let tech = try loadTechnology(path: technologyPath, baseURL: baseURL)
        let plan = try HeadlessFinishNetPlanner().plan(
            document: editor.document,
            tech: tech,
            cellID: payload.cellID,
            netID: payload.netID,
            layer: payload.layer,
            width: payload.width,
            shapeIDSeed: "finish-net-\(index)-\(payload.netID.uuidString)"
        )
        try applyRepairDelta(plan.delta, to: &editor, cellID: payload.cellID)
        if payload.reportPath != nil {
            try recordFinishNetPlanReport(
                payload,
                index: index,
                plan: plan,
                baseURL: baseURL,
                pendingArtifacts: &pendingArtifacts
            )
        }
    }

    private func applyTranslateShape(
        _ payload: TranslateShapeCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let shape = try findShape(payload.shapeID, cellID: payload.cellID, in: editor.document)
        var translated = shape
        translated.geometry = translatedGeometry(shape.geometry, by: payload.delta)
        try editor.updateShape(translated, in: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.shapeID)
    }

    private func applyResizeShape(
        _ payload: ResizeShapeCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let shape = try findShape(payload.shapeID, cellID: payload.cellID, in: editor.document)
        let originalBounds = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
        let resizedBounds = try validatedResizedBounds(payload, originalBounds: originalBounds)
        var resized = shape
        resized.geometry = try resizedGeometry(
            shape.geometry,
            originalBounds: originalBounds,
            resizedBounds: resizedBounds,
            shapeID: payload.shapeID
        )
        try editor.updateShape(resized, in: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.shapeID)
    }

    private func validatedResizedBounds(
        _ payload: ResizeShapeCommand,
        originalBounds: LayoutRect
    ) throws -> LayoutRect {
        let bounds = resizedBounds(
            from: originalBounds,
            deltaMinX: payload.deltaMinX,
            deltaMinY: payload.deltaMinY,
            deltaMaxX: payload.deltaMaxX,
            deltaMaxY: payload.deltaMaxY
        )
        guard bounds.size.width > 0, bounds.size.height > 0 else {
            throw LayoutCommandError.invalidResizeResult(
                shapeID: payload.shapeID,
                width: bounds.size.width,
                height: bounds.size.height
            )
        }
        return bounds
    }

    private func applySplitShape(
        _ payload: SplitShapeCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let source = try splitSource(payload, document: editor.document)
        let replacements = try splitReplacementShapes(payload, source: source)
        try editor.removeShape(id: payload.shapeID, from: payload.cellID)
        try editor.addShape(replacements.first, to: payload.cellID)
        try editor.addShape(replacements.second, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.shapeID)
    }

    private func splitSource(
        _ payload: SplitShapeCommand,
        document: LayoutDocument
    ) throws -> LayoutShape {
        let shape = try findShape(payload.shapeID, cellID: payload.cellID, in: document)
        guard payload.firstShapeID != payload.secondShapeID else {
            throw LayoutCommandError.duplicateShapeID(payload.secondShapeID)
        }
        try ensureShapeMissing(payload.firstShapeID, cellID: payload.cellID, in: document)
        try ensureShapeMissing(payload.secondShapeID, cellID: payload.cellID, in: document)
        return shape
    }

    private func splitReplacementShapes(
        _ payload: SplitShapeCommand,
        source shape: LayoutShape
    ) throws -> (first: LayoutShape, second: LayoutShape) {
        guard let (firstGeometry, secondGeometry) = try splitGeometry(
            shape.geometry,
            axis: payload.axis,
            coordinate: payload.coordinate,
            shapeID: payload.shapeID
        ) else {
            throw LayoutCommandError.invalidSplitCoordinate(
                shapeID: payload.shapeID,
                axis: payload.axis,
                coordinate: payload.coordinate
            )
        }
        let firstProperties = splitProperties(from: shape, part: "first")
        let secondProperties = splitProperties(from: shape, part: "second")
        return (
            LayoutShape(id: payload.firstShapeID, layer: shape.layer, netID: shape.netID, geometry: firstGeometry, properties: firstProperties),
            LayoutShape(id: payload.secondShapeID, layer: shape.layer, netID: shape.netID, geometry: secondGeometry, properties: secondProperties)
        )
    }

    private func splitProperties(from shape: LayoutShape, part: String) -> [String: String] {
        var properties = shape.properties
        properties["splitParentShapeID"] = shape.id.uuidString
        properties["splitPart"] = part
        return properties
    }

    private func applyAddLabel(
        _ payload: AddLabelCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        try ensureLabelMissing(payload.labelID, cellID: payload.cellID, in: editor.document)
        try ensureNetExistsIfPresent(payload.netID, cellID: payload.cellID, in: editor.document)
        let label = LayoutLabel(
            id: payload.labelID,
            text: payload.text,
            position: payload.position,
            layer: payload.layer,
            netID: payload.netID
        )
        try editor.addLabel(label, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.labelID)
    }

    private func applyAddVia(
        _ payload: AddViaCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        try ensureViaMissing(payload.viaID, cellID: payload.cellID, in: editor.document)
        try ensureNetExistsIfPresent(payload.netID, cellID: payload.cellID, in: editor.document)
        let via = LayoutVia(
            id: payload.viaID,
            viaDefinitionID: payload.viaDefinitionID,
            position: payload.position,
            netID: payload.netID
        )
        try editor.addVia(via, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.viaID)
    }

    private func applyAddConstraint(
        _ payload: AddConstraintCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let cell = try findCell(payload.cellID, in: editor.document)
        try validateDeclarableConstraint(payload.constraint, in: cell)
        try editor.addConstraint(payload.constraint, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: nil)
    }

    private func applyAddInstance(
        _ payload: AddInstanceCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        try ensureInstanceMissing(payload.instanceID, cellID: payload.cellID, in: editor.document)
        try ensureInstantiableHierarchy(
            parentCellID: payload.cellID,
            referencedCellID: payload.referencedCellID,
            in: editor.document
        )
        try ensureTerminalNetIDsExist(payload.terminalNetIDs, cellID: payload.cellID, in: editor.document)
        let instance = LayoutInstance(
            id: payload.instanceID,
            cellID: payload.referencedCellID,
            name: payload.name,
            transform: payload.transform,
            terminalNetIDs: payload.terminalNetIDs,
            repetition: payload.repetition
        )
        try editor.addInstance(instance, to: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.instanceID)
    }

    private func findCell(_ cellID: UUID, in document: LayoutDocument) throws -> LayoutCell {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        return cell
    }

    private func validateDeclarableConstraint(_ constraint: LayoutConstraint, in cell: LayoutCell) throws {
        try validateConstraintStructure(constraint)
        let knownMemberIDs = Set(cell.shapes.map(\.id)).union(cell.instances.map(\.id))
        for memberID in constraintMemberIDs(constraint) where !knownMemberIDs.contains(memberID) {
            throw LayoutCommandError.constraintMemberNotFound(memberID)
        }
    }

    private func validateConstraintStructure(_ constraint: LayoutConstraint) throws {
        switch constraint {
        case .symmetry(let symmetry):
            guard !symmetry.members.isEmpty, symmetry.members.count.isMultiple(of: 2) else {
                throw LayoutCommandError.invalidConstraint("symmetry requires a non-empty even member list")
            }
            try ensureUniqueMembers(symmetry.members + symmetry.selfSymmetricMembers)
        case .matching(let matching):
            guard matching.members.count >= 2 else {
                throw LayoutCommandError.invalidConstraint("matching requires at least two members")
            }
            try ensureNonNegative(matching.maxLengthMismatch, field: "maxLengthMismatch")
            try ensureNonNegative(matching.maxWidthMismatch, field: "maxWidthMismatch")
            try ensureUniqueMembers(matching.members)
        case .commonCentroid(let centroid):
            guard centroid.members.count >= 2, !centroid.pattern.isEmpty else {
                throw LayoutCommandError.invalidConstraint("commonCentroid requires at least two members and a non-empty pattern")
            }
            guard Set(centroid.pattern).count >= 2 else {
                throw LayoutCommandError.invalidConstraint("commonCentroid pattern requires at least two groups")
            }
            try ensureUniqueMembers(centroid.members)
        case .interdigitated(let interdigitated):
            guard interdigitated.members.count >= 2, !interdigitated.pattern.isEmpty else {
                throw LayoutCommandError.invalidConstraint("interdigitated requires at least two members and a non-empty pattern")
            }
            guard Set(interdigitated.pattern).count >= 2 else {
                throw LayoutCommandError.invalidConstraint("interdigitated pattern requires at least two groups")
            }
            try ensureUniqueMembers(interdigitated.members)
        case .alignment(let alignment):
            guard alignment.members.count >= 2 else {
                throw LayoutCommandError.invalidConstraint("alignment requires at least two members")
            }
            guard alignment.tolerance >= 0 else {
                throw LayoutCommandError.invalidConstraint("alignment tolerance must be non-negative")
            }
            try ensureUniqueMembers(alignment.members)
        }
    }

    private func ensureNonNegative(_ value: Double?, field: String) throws {
        guard let value else {
            return
        }
        guard value >= 0 else {
            throw LayoutCommandError.invalidConstraint("\(field) must be non-negative")
        }
    }

    private func ensureUniqueMembers(_ memberIDs: [UUID]) throws {
        var seen: Set<UUID> = []
        for memberID in memberIDs where !seen.insert(memberID).inserted {
            throw LayoutCommandError.invalidConstraint("duplicate member ID \(memberID)")
        }
    }

    private func constraintMemberIDs(_ constraint: LayoutConstraint) -> [UUID] {
        switch constraint {
        case .symmetry(let symmetry):
            return symmetry.members + symmetry.selfSymmetricMembers
        case .matching(let matching):
            return matching.members
        case .commonCentroid(let centroid):
            return centroid.members
        case .interdigitated(let interdigitated):
            return interdigitated.members
        case .alignment(let alignment):
            return alignment.members
        }
    }

    private func applyMoveInstance(
        _ payload: MoveInstanceCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let instance = try findInstance(payload.instanceID, cellID: payload.cellID, in: editor.document)
        var moved = instance
        moved.transform.translation = moved.transform.translation.translated(by: payload.delta)
        try editor.updateInstance(moved, in: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.instanceID)
    }

    private func applyRotateInstance(
        _ payload: RotateInstanceCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let instance = try findInstance(payload.instanceID, cellID: payload.cellID, in: editor.document)
        var rotated = instance
        if let pivot = payload.pivot {
            rotated.transform.translation = rotatedPoint(
                rotated.transform.translation,
                around: pivot,
                degrees: payload.deltaDegrees
            )
        }
        rotated.transform.rotationDegrees = normalizedDegrees(rotated.transform.rotationDegrees + payload.deltaDegrees)
        try editor.updateInstance(rotated, in: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.instanceID)
    }

    private func applyMirrorInstance(
        _ payload: MirrorInstanceCommand,
        index: Int,
        kind: LayoutCommandKind,
        editor: inout LayoutDocumentEditor
    ) throws -> LayoutAppliedCommand {
        let instance = try findInstance(payload.instanceID, cellID: payload.cellID, in: editor.document)
        let mirrored = mirroredInstance(instance, payload: payload)
        try editor.updateInstance(mirrored, in: payload.cellID)
        return LayoutAppliedCommand(index: index, kind: kind, cellID: payload.cellID, entityID: payload.instanceID)
    }

    private func mirroredInstance(_ instance: LayoutInstance, payload: MirrorInstanceCommand) -> LayoutInstance {
        var mirrored = instance
        if let origin = payload.origin {
            mirrored.transform.translation = mirroredPoint(mirrored.transform.translation, axis: payload.axis, origin: origin)
            mirrored.transform.rotationDegrees = normalizedDegrees(-mirrored.transform.rotationDegrees)
        }
        toggleMirror(axis: payload.axis, instance: &mirrored)
        return mirrored
    }

    private func toggleMirror(axis: InstanceMirrorAxis, instance: inout LayoutInstance) {
        switch axis.normalized {
        case .vertical:
            instance.transform.mirrorX.toggle()
        case .horizontal:
            instance.transform.mirrorY.toggle()
        }
    }

    private func findShape(_ shapeID: UUID, cellID: UUID, in document: LayoutDocument) throws -> LayoutShape {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        guard let shape = cell.shapes.first(where: { $0.id == shapeID }) else {
            throw LayoutCommandError.shapeNotFound(shapeID)
        }
        return shape
    }

    private struct FlattenedCommandContent: Sendable {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var labels: [LayoutLabel] = []
        var pins: [LayoutPin] = []
    }

    private struct FlattenInstanceContext {
        var host: LayoutCell
        var instance: LayoutInstance
        var child: LayoutCell
    }

    private func flattenInstance(
        _ payload: FlattenInstanceCommand,
        editor: inout LayoutDocumentEditor
    ) throws {
        let context = try flattenContext(payload, document: editor.document)
        let content = try flattenedContent(payload, context: context, document: editor.document)
        try ensureFlattenedContentDoesNotCollide(content, host: context.host)
        try mergeFlattenedContent(content, payload: payload, editor: &editor)
    }

    private func flattenContext(
        _ payload: FlattenInstanceCommand,
        document: LayoutDocument
    ) throws -> FlattenInstanceContext {
        guard let host = document.cell(withID: payload.cellID) else {
            throw LayoutCommandError.cellNotFound(payload.cellID)
        }
        guard let instanceIndex = host.instances.firstIndex(where: { $0.id == payload.instanceID }) else {
            throw LayoutCommandError.instanceNotFound(payload.instanceID)
        }
        let instance = host.instances[instanceIndex]
        guard let child = document.cell(withID: instance.cellID) else {
            throw LayoutCommandError.cellNotFound(instance.cellID)
        }
        return FlattenInstanceContext(host: host, instance: instance, child: child)
    }

    private func flattenedContent(
        _ payload: FlattenInstanceCommand,
        context: FlattenInstanceContext,
        document: LayoutDocument
    ) throws -> FlattenedCommandContent {
        var content = FlattenedCommandContent()
        for (occurrenceIndex, transform) in context.instance.occurrenceTransforms().enumerated() {
            var visiting: Set<UUID> = [payload.cellID]
            try collectFlattenedContent(
                of: context.child,
                document: document,
                transforms: [transform],
                terminalNetIDs: context.instance.terminalNetIDs,
                idPath: [
                    payload.cellID.uuidString,
                    payload.instanceID.uuidString,
                    String(occurrenceIndex),
                ],
                visiting: &visiting,
                into: &content
            )
        }
        return content
    }

    private func mergeFlattenedContent(
        _ content: FlattenedCommandContent,
        payload: FlattenInstanceCommand,
        editor: inout LayoutDocumentEditor
    ) throws {
        try editor.perform { document in
            guard var mutableHost = document.cell(withID: payload.cellID) else {
                throw LayoutCommandError.cellNotFound(payload.cellID)
            }
            guard let mutableInstanceIndex = mutableHost.instances.firstIndex(where: { $0.id == payload.instanceID }) else {
                throw LayoutCommandError.instanceNotFound(payload.instanceID)
            }
            mutableHost.shapes.append(contentsOf: content.shapes)
            mutableHost.vias.append(contentsOf: content.vias)
            mutableHost.labels.append(contentsOf: content.labels)
            mutableHost.pins.append(contentsOf: content.pins)
            mutableHost.instances.remove(at: mutableInstanceIndex)
            document.updateCell(mutableHost)
        }
    }

    private func makeCell(
        _ payload: MakeCellCommand,
        editor: inout LayoutDocumentEditor
    ) throws {
        guard let host = editor.document.cell(withID: payload.cellID) else {
            throw LayoutCommandError.cellNotFound(payload.cellID)
        }
        try validateMakeCellRequest(payload, document: editor.document)
        let selection = try selectedCellContent(payload, host: host, document: editor.document)
        let newCell = LayoutCell(
            id: payload.newCellID,
            name: payload.name,
            shapes: selection.shapes,
            instances: selection.instances
        )
        let newInstance = LayoutInstance(
            id: payload.newInstanceID,
            cellID: payload.newCellID,
            name: payload.instanceName
        )
        try replaceSelectionWithCell(
            payload,
            selection: selection,
            newCell: newCell,
            newInstance: newInstance,
            editor: &editor
        )
    }

    private struct MakeCellSelection {
        var shapeIDs: Set<UUID>
        var instanceIDs: Set<UUID>
        var shapes: [LayoutShape]
        var instances: [LayoutInstance]
    }

    private func validateMakeCellRequest(_ payload: MakeCellCommand, document: LayoutDocument) throws {
        try ensureCellMissing(payload.newCellID, in: document)
        try ensureInstanceMissing(payload.newInstanceID, cellID: payload.cellID, in: document)
        try ensureUniqueSelectionIDs(payload.shapeIDs)
        try ensureUniqueSelectionIDs(payload.instanceIDs)
        guard !payload.shapeIDs.isEmpty || !payload.instanceIDs.isEmpty else {
            throw LayoutCommandError.emptySelection
        }
    }

    private func selectedCellContent(
        _ payload: MakeCellCommand,
        host: LayoutCell,
        document: LayoutDocument
    ) throws -> MakeCellSelection {
        let selectedShapeIDs = Set(payload.shapeIDs)
        let selectedInstanceIDs = Set(payload.instanceIDs)
        return MakeCellSelection(
            shapeIDs: selectedShapeIDs,
            instanceIDs: selectedInstanceIDs,
            shapes: try selectedShapes(payload.shapeIDs, host: host),
            instances: try selectedInstances(payload, host: host, document: document)
        )
    }

    private func selectedShapes(_ shapeIDs: [UUID], host: LayoutCell) throws -> [LayoutShape] {
        try shapeIDs.map { shapeID in
            guard let shape = host.shapes.first(where: { $0.id == shapeID }) else {
                throw LayoutCommandError.shapeNotFound(shapeID)
            }
            return shape
        }
    }

    private func selectedInstances(
        _ payload: MakeCellCommand,
        host: LayoutCell,
        document: LayoutDocument
    ) throws -> [LayoutInstance] {
        try payload.instanceIDs.map { instanceID in
            guard let instance = host.instances.first(where: { $0.id == instanceID }) else {
                throw LayoutCommandError.instanceNotFound(instanceID)
            }
            try validateSelectedInstance(instance, payload: payload, document: document)
            return instance
        }
    }

    private func validateSelectedInstance(
        _ instance: LayoutInstance,
        payload: MakeCellCommand,
        document: LayoutDocument
    ) throws {
        if instance.cellID == payload.cellID
            || cellHierarchyContains(payload.cellID, startingAt: instance.cellID, in: document, visited: []) {
            throw LayoutCommandError.invalidInstanceHierarchy(
                parentCellID: payload.newCellID,
                referencedCellID: instance.cellID
            )
        }
    }

    private func replaceSelectionWithCell(
        _ payload: MakeCellCommand,
        selection: MakeCellSelection,
        newCell: LayoutCell,
        newInstance: LayoutInstance,
        editor: inout LayoutDocumentEditor
    ) throws {
        try editor.perform { document in
            guard var mutableHost = document.cell(withID: payload.cellID) else {
                throw LayoutCommandError.cellNotFound(payload.cellID)
            }
            mutableHost.shapes.removeAll { selection.shapeIDs.contains($0.id) }
            mutableHost.instances.removeAll { selection.instanceIDs.contains($0.id) }
            mutableHost.instances.append(newInstance)
            document.updateCell(newCell)
            document.updateCell(mutableHost)
        }
    }

    private func fixAllViolations(
        _ payload: FixAllViolationsCommand,
        index: Int,
        editor: inout LayoutDocumentEditor,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws {
        guard payload.budget > 0 else {
            throw LayoutCommandError.invalidRepairBudget(payload.budget)
        }
        guard editor.document.cell(withID: payload.cellID) != nil else {
            throw LayoutCommandError.cellNotFound(payload.cellID)
        }

        let tech = try loadTechnology(path: payload.technologyPath, baseURL: baseURL)
        let engine = LayoutRepairEngine(document: editor.document, tech: tech, cellID: payload.cellID)
        let result = try engine.sweep(budget: payload.budget)
        for repair in result.repairs {
            try applyRepairDelta(repair.delta, to: &editor, cellID: payload.cellID)
        }

        let report = LayoutRepairSweepReport(
            commandIndex: index,
            command: payload,
            repairs: result.repairs,
            sweep: result.sweep
        )
        let reportData = try encoder.encode(report)
        let reportURL = resolve(path: payload.reportPath, baseURL: baseURL)
        pendingArtifacts.append(PendingCommandArtifact(
            id: "layout-repair-sweep-\(index)",
            kind: "layout-repair-sweep",
            format: "LayoutRepairSweepReportJSON",
            url: reportURL,
            data: reportData,
            status: report.status
        ))
    }

    private func loadTechnology(path: String, baseURL: URL) throws -> LayoutTechDatabase {
        let url = resolve(path: path, baseURL: baseURL)
        let data = try Data(contentsOf: url)
        return try serializer.decodeTech(data)
    }

    private func recordFinishNetReport(
        _ payload: FinishNetCommand,
        index: Int,
        routeShapeIDs: [UUID],
        document: LayoutDocument,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws {
        guard let technologyPath = payload.technologyPath else {
            throw LayoutCommandError.missingRequiredArgument("finishNet.technologyPath")
        }
        guard let reportPath = payload.reportPath else {
            throw LayoutCommandError.missingRequiredArgument("finishNet.reportPath")
        }
        let tech = try loadTechnology(path: technologyPath, baseURL: baseURL)
        let result = LayoutDRCService().run(document: document, tech: tech, cellID: payload.cellID)
        let routeShapeIDSet = Set(routeShapeIDs)
        let routeViolations = result.violations.filter { violation in
            !routeShapeIDSet.isDisjoint(with: violation.shapeIDs)
        }
        let status = finishNetExplicitStatus(routeViolations: routeViolations)
        let report = LayoutFinishNetReport(
            commandIndex: index,
            command: payload,
            status: status,
            routeShapeIDs: routeShapeIDs,
            violationCount: result.violations.count,
            errorCount: result.violations.filter { $0.severity == .error }.count,
            warningCount: result.violations.filter { $0.severity == .warning }.count,
            routeViolationCount: routeViolations.count,
            violations: result.violations,
            verificationStatus: status == "passed" ? "route-drc-verified" : "route-drc-failed"
        )
        let reportData = try encoder.encode(report)
        let reportURL = resolve(path: reportPath, baseURL: baseURL)
        pendingArtifacts.append(PendingCommandArtifact(
            id: "layout-finish-net-\(index)",
            kind: "layout-finish-net-report",
            format: "LayoutFinishNetReportJSON",
            url: reportURL,
            data: reportData,
            status: report.status
        ))
    }

    private func recordFinishNetPlanReport(
        _ payload: FinishNetCommand,
        index: Int,
        plan: HeadlessFinishNetPlan,
        baseURL: URL,
        pendingArtifacts: inout [PendingCommandArtifact]
    ) throws {
        guard let reportPath = payload.reportPath else {
            throw LayoutCommandError.missingRequiredArgument("finishNet.reportPath")
        }
        let routeShapeIDSet = Set(plan.routeShapeIDs)
        let routeViolations = plan.violationsAfter.filter { violation in
            !routeShapeIDSet.isDisjoint(with: violation.shapeIDs)
        }
        let status = finishNetPlanStatus(plan: plan, routeViolations: routeViolations)
        let report = LayoutFinishNetReport(
            commandIndex: index,
            command: payload,
            status: status,
            routeShapeIDs: plan.routeShapeIDs,
            violationCount: plan.violationCountAfter,
            errorCount: plan.errorCountAfter,
            warningCount: plan.warningCountAfter,
            routeViolationCount: routeViolations.count,
            violations: plan.violationsAfter,
            opensBefore: plan.opensBefore,
            opensAfter: plan.opensAfter,
            shortsBefore: plan.shortsBefore,
            shortsAfter: plan.shortsAfter,
            verificationStatus: finishNetPlanVerificationStatus(status)
        )
        let reportData = try encoder.encode(report)
        let reportURL = resolve(path: reportPath, baseURL: baseURL)
        pendingArtifacts.append(PendingCommandArtifact(
            id: "layout-finish-net-\(index)",
            kind: "layout-finish-net-report",
            format: "LayoutFinishNetReportJSON",
            url: reportURL,
            data: reportData,
            status: report.status
        ))
    }

    private func applyRepairDelta(
        _ delta: LayoutEditDelta,
        to editor: inout LayoutDocumentEditor,
        cellID: UUID
    ) throws {
        try editor.perform { document in
            guard var cell = document.cell(withID: cellID) else {
                throw LayoutCommandError.cellNotFound(cellID)
            }
            try applyShapeDelta(delta, to: &cell)
            try applyViaDelta(delta, to: &cell)
            document.updateCell(cell)
        }
    }

    private func applyShapeDelta(_ delta: LayoutEditDelta, to cell: inout LayoutCell) throws {
        try updateShapes(delta.updatedShapes, in: &cell)
        try removeShapes(delta.removedShapeIDs, from: &cell)
        try appendShapes(delta.addedShapes, to: &cell)
    }

    private func updateShapes(_ shapes: [LayoutShape], in cell: inout LayoutCell) throws {
        for shape in shapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw LayoutCommandError.shapeNotFound(shape.id)
            }
            cell.shapes[index] = shape
        }
    }

    private func removeShapes(_ shapeIDs: [UUID], from cell: inout LayoutCell) throws {
        guard !shapeIDs.isEmpty else { return }
        let removed = Set(shapeIDs)
        for shapeID in removed where !cell.shapes.contains(where: { $0.id == shapeID }) {
            throw LayoutCommandError.shapeNotFound(shapeID)
        }
        cell.shapes.removeAll { removed.contains($0.id) }
    }

    private func appendShapes(_ shapes: [LayoutShape], to cell: inout LayoutCell) throws {
        for shape in shapes where cell.shapes.contains(where: { $0.id == shape.id }) {
            throw LayoutCommandError.duplicateShapeID(shape.id)
        }
        cell.shapes.append(contentsOf: shapes)
    }

    private func applyViaDelta(_ delta: LayoutEditDelta, to cell: inout LayoutCell) throws {
        try updateVias(delta.updatedVias, in: &cell)
        try removeVias(delta.removedViaIDs, from: &cell)
        try appendVias(delta.addedVias, to: &cell)
    }

    private func updateVias(_ vias: [LayoutVia], in cell: inout LayoutCell) throws {
        for via in vias {
            guard let index = cell.vias.firstIndex(where: { $0.id == via.id }) else {
                throw LayoutCommandError.viaNotFound(via.id)
            }
            cell.vias[index] = via
        }
    }

    private func removeVias(_ viaIDs: [UUID], from cell: inout LayoutCell) throws {
        guard !viaIDs.isEmpty else { return }
        let removed = Set(viaIDs)
        for viaID in removed where !cell.vias.contains(where: { $0.id == viaID }) {
            throw LayoutCommandError.viaNotFound(viaID)
        }
        cell.vias.removeAll { removed.contains($0.id) }
    }

    private func appendVias(_ vias: [LayoutVia], to cell: inout LayoutCell) throws {
        for via in vias where cell.vias.contains(where: { $0.id == via.id }) {
            throw LayoutCommandError.duplicateViaID(via.id)
        }
        cell.vias.append(contentsOf: vias)
    }

    private func collectFlattenedContent(
        of cell: LayoutCell,
        document: LayoutDocument,
        transforms: [LayoutTransform],
        terminalNetIDs: [String: UUID],
        idPath: [String],
        visiting: inout Set<UUID>,
        into content: inout FlattenedCommandContent
    ) throws {
        guard !visiting.contains(cell.id) else {
            throw LayoutCommandError.invalidInstanceHierarchy(parentCellID: cell.id, referencedCellID: cell.id)
        }
        visiting.insert(cell.id)
        defer {
            visiting.remove(cell.id)
        }
        let netBindings = localTerminalNetBindings(in: cell, terminalNetIDs: terminalNetIDs)

        for shape in cell.shapes {
            content.shapes.append(LayoutShape(
                id: deterministicUUID(kind: "shape", parts: idPath + [cell.id.uuidString, shape.id.uuidString]),
                layer: shape.layer,
                netID: mappedNetID(shape.netID, bindings: netBindings),
                geometry: transformedGeometry(shape.geometry, transforms: transforms),
                properties: shape.properties
            ))
        }
        for via in cell.vias {
            content.vias.append(LayoutVia(
                id: deterministicUUID(kind: "via", parts: idPath + [cell.id.uuidString, via.id.uuidString]),
                viaDefinitionID: via.viaDefinitionID,
                position: transformedPoint(via.position, transforms: transforms),
                netID: mappedNetID(via.netID, bindings: netBindings)
            ))
        }
        for label in cell.labels {
            content.labels.append(LayoutLabel(
                id: deterministicUUID(kind: "label", parts: idPath + [cell.id.uuidString, label.id.uuidString]),
                text: label.text,
                position: transformedPoint(label.position, transforms: transforms),
                layer: label.layer,
                netID: mappedNetID(label.netID, bindings: netBindings)
            ))
        }
        for pin in cell.pins {
            content.pins.append(LayoutPin(
                id: deterministicUUID(kind: "pin", parts: idPath + [cell.id.uuidString, pin.id.uuidString]),
                name: pin.name,
                position: transformedPoint(pin.position, transforms: transforms),
                size: pin.size,
                layer: pin.layer,
                netID: terminalNetIDs[pin.name] ?? mappedNetID(pin.netID, bindings: netBindings),
                role: pin.role
            ))
        }

        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else {
                throw LayoutCommandError.cellNotFound(instance.cellID)
            }
            for (occurrenceIndex, occurrenceTransform) in instance.occurrenceTransforms().enumerated() {
                try collectFlattenedContent(
                    of: child,
                    document: document,
                    transforms: transforms + [occurrenceTransform],
                    terminalNetIDs: propagatedTerminalNetIDs(
                        for: instance,
                        through: netBindings
                    ),
                    idPath: idPath + [cell.id.uuidString, instance.id.uuidString, String(occurrenceIndex)],
                    visiting: &visiting,
                    into: &content
                )
            }
        }
    }

    private func propagatedTerminalNetIDs(
        for instance: LayoutInstance,
        through bindings: [UUID: UUID]
    ) -> [String: UUID] {
        instance.terminalNetIDs.mapValues { netID in
            bindings[netID] ?? netID
        }
    }

    private func mappedNetID(_ netID: UUID?, bindings: [UUID: UUID]) -> UUID? {
        guard let netID else { return nil }
        return bindings[netID] ?? netID
    }

    private func localTerminalNetBindings(
        in cell: LayoutCell,
        terminalNetIDs: [String: UUID]
    ) -> [UUID: UUID] {
        var candidates: [UUID: Set<UUID>] = [:]
        for pin in cell.pins {
            guard let localNetID = pin.netID,
                  let boundNetID = terminalNetIDs[pin.name] else {
                continue
            }
            candidates[localNetID, default: []].insert(boundNetID)
        }

        var bindings: [UUID: UUID] = [:]
        for (localNetID, boundNetIDs) in candidates where boundNetIDs.count == 1 {
            bindings[localNetID] = boundNetIDs.first
        }
        return bindings
    }

    private func ensureFlattenedContentDoesNotCollide(
        _ content: FlattenedCommandContent,
        host: LayoutCell
    ) throws {
        let existingShapeIDs = Set(host.shapes.map(\.id))
        let existingViaIDs = Set(host.vias.map(\.id))
        let existingLabelIDs = Set(host.labels.map(\.id))
        let existingPinIDs = Set(host.pins.map(\.id))

        try ensureNoCollision(ids: content.shapes.map(\.id), existing: existingShapeIDs, kind: "shape")
        try ensureNoCollision(ids: content.vias.map(\.id), existing: existingViaIDs, kind: "via")
        try ensureNoCollision(ids: content.labels.map(\.id), existing: existingLabelIDs, kind: "label")
        try ensureNoCollision(ids: content.pins.map(\.id), existing: existingPinIDs, kind: "pin")
    }

    private func normalizedDegrees(_ value: Double) -> Double {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    private func rotatedPoint(
        _ point: LayoutPoint,
        around pivot: LayoutPoint,
        degrees: Double
    ) -> LayoutPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        return LayoutPoint(
            x: normalizedCoordinate(pivot.x + dx * cos(radians) - dy * sin(radians)),
            y: normalizedCoordinate(pivot.y + dx * sin(radians) + dy * cos(radians))
        )
    }

    private func mirroredPoint(
        _ point: LayoutPoint,
        axis: InstanceMirrorAxis,
        origin: LayoutPoint
    ) -> LayoutPoint {
        switch axis.normalized {
        case .vertical:
            return LayoutPoint(
                x: normalizedCoordinate(2 * origin.x - point.x),
                y: normalizedCoordinate(point.y)
            )
        case .horizontal:
            return LayoutPoint(
                x: normalizedCoordinate(point.x),
                y: normalizedCoordinate(2 * origin.y - point.y)
            )
        }
    }

    private func transformedPoint(_ point: LayoutPoint, transforms: [LayoutTransform]) -> LayoutPoint {
        var current = point
        for transform in transforms.reversed() {
            current = transform.apply(to: current)
        }
        return current
    }

    private func transformedGeometry(_ geometry: LayoutGeometry, transforms: [LayoutTransform]) -> LayoutGeometry {
        var current = geometry
        for transform in transforms.reversed() {
            current = current.transformed(by: transform)
        }
        return current
    }

    private func deterministicUUID(kind: String, parts: [String]) -> UUID {
        let input = (["layout-command", kind] + parts).joined(separator: "|")
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

    private func normalizedCoordinate(_ value: Double) -> Double {
        abs(value) < 1e-12 ? 0 : value
    }

    private func translatedGeometry(_ geometry: LayoutGeometry, by delta: LayoutPoint) -> LayoutGeometry {
        switch geometry {
        case .rect(let rect):
            return .rect(LayoutRect(
                origin: rect.origin.translated(by: delta),
                size: rect.size
            ))
        case .polygon(let polygon):
            return .polygon(LayoutPolygon(points: polygon.points.map { $0.translated(by: delta) }))
        case .path(let path):
            return .path(LayoutPath(
                points: path.points.map { $0.translated(by: delta) },
                width: path.width,
                endCap: path.endCap
            ))
        }
    }

    private func resizedBounds(
        from bounds: LayoutRect,
        deltaMinX: Double,
        deltaMinY: Double,
        deltaMaxX: Double,
        deltaMaxY: Double
    ) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(
                x: bounds.minX + deltaMinX,
                y: bounds.minY + deltaMinY
            ),
            size: LayoutSize(
                width: bounds.size.width + deltaMaxX - deltaMinX,
                height: bounds.size.height + deltaMaxY - deltaMinY
            )
        )
    }

    private func resizedGeometry(
        _ geometry: LayoutGeometry,
        originalBounds: LayoutRect,
        resizedBounds: LayoutRect,
        shapeID: UUID
    ) throws -> LayoutGeometry {
        switch geometry {
        case .rect:
            return .rect(resizedBounds)
        case .polygon(let polygon):
            guard originalBounds.size.width > 0, originalBounds.size.height > 0 else {
                throw LayoutCommandError.unsupportedResizeGeometry(shapeID)
            }
            let resizedPoints = polygon.points.map {
                resizedPoint($0, originalBounds: originalBounds, resizedBounds: resizedBounds)
            }
            let resizedPolygon = LayoutPolygon(points: resizedPoints)
            guard resizedPolygon.isValid else {
                throw LayoutCommandError.unsupportedResizeGeometry(shapeID)
            }
            return .polygon(resizedPolygon)
        case .path(let path):
            guard originalBounds.size.width > 0, originalBounds.size.height > 0 else {
                throw LayoutCommandError.unsupportedResizeGeometry(shapeID)
            }
            let resizedPoints = path.points.map {
                resizedPoint($0, originalBounds: originalBounds, resizedBounds: resizedBounds)
            }
            return .path(LayoutPath(points: resizedPoints, width: path.width, endCap: path.endCap))
        }
    }

    private func resizedPoint(
        _ point: LayoutPoint,
        originalBounds: LayoutRect,
        resizedBounds: LayoutRect
    ) -> LayoutPoint {
        let normalizedX = (point.x - originalBounds.minX) / originalBounds.size.width
        let normalizedY = (point.y - originalBounds.minY) / originalBounds.size.height
        return LayoutPoint(
            x: resizedBounds.minX + normalizedX * resizedBounds.size.width,
            y: resizedBounds.minY + normalizedY * resizedBounds.size.height
        )
    }

    private func splitGeometry(
        _ geometry: LayoutGeometry,
        axis: SplitShapeAxis,
        coordinate: Double,
        shapeID: UUID
    ) throws -> (LayoutGeometry, LayoutGeometry)? {
        switch geometry {
        case .rect(let rect):
            let splitRects: (LayoutRect, LayoutRect)?
            switch axis {
            case .vertical:
                splitRects = rect.splitVertically(at: coordinate)
            case .horizontal:
                splitRects = rect.splitHorizontally(at: coordinate)
            }
            guard let (first, second) = splitRects else { return nil }
            return (.rect(first), .rect(second))
        case .polygon(let polygon):
            guard isConvexPolygon(polygon) else {
                throw LayoutCommandError.unsupportedSplitGeometry(shapeID)
            }
            let splitPolygons: (LayoutPolygon, LayoutPolygon)?
            switch axis {
            case .vertical:
                splitPolygons = polygon.splitVertically(at: coordinate)
            case .horizontal:
                splitPolygons = polygon.splitHorizontally(at: coordinate)
            }
            guard let (first, second) = splitPolygons else { return nil }
            return (.polygon(first), .polygon(second))
        case .path(let path):
            guard let (first, second) = splitPath(path, axis: axis, coordinate: coordinate) else {
                return nil
            }
            return (.path(first), .path(second))
        }
    }

    private func isConvexPolygon(_ polygon: LayoutPolygon) -> Bool {
        let points = normalizedPolygonPoints(polygon.points)
        guard points.count >= 3 else { return false }

        var windingSign = 0
        for index in points.indices {
            let previous = points[index]
            let current = points[(index + 1) % points.count]
            let next = points[(index + 2) % points.count]
            let cross = crossProduct(previous: previous, current: current, next: next)
            guard abs(cross) > 1.0e-9 else { continue }
            let sign = cross > 0 ? 1 : -1
            if windingSign == 0 {
                windingSign = sign
            } else if windingSign != sign {
                return false
            }
        }
        return windingSign != 0
    }

    private func normalizedPolygonPoints(_ points: [LayoutPoint]) -> [LayoutPoint] {
        guard let first = points.first, points.last == first else { return points }
        return Array(points.dropLast())
    }

    private func crossProduct(
        previous: LayoutPoint,
        current: LayoutPoint,
        next: LayoutPoint
    ) -> Double {
        let firstX = current.x - previous.x
        let firstY = current.y - previous.y
        let secondX = next.x - current.x
        let secondY = next.y - current.y
        return firstX * secondY - firstY * secondX
    }

    private func splitPath(
        _ path: LayoutPath,
        axis: SplitShapeAxis,
        coordinate: Double
    ) -> (LayoutPath, LayoutPath)? {
        guard path.points.count >= 2 else { return nil }

        var firstPoints: [LayoutPoint] = [path.points[0]]
        for index in 0..<(path.points.count - 1) {
            let start = path.points[index]
            let end = path.points[index + 1]

            if index > 0, isPointOnSplit(start, axis: axis, coordinate: coordinate) {
                return makeSplitPaths(
                    firstPoints: firstPoints,
                    splitPoint: start,
                    secondTail: Array(path.points.dropFirst(index + 1)),
                    width: path.width,
                    endCap: path.endCap
                )
            }

            if let splitPoint = splitPoint(onSegmentFrom: start, to: end, axis: axis, coordinate: coordinate) {
                return makeSplitPaths(
                    firstPoints: firstPoints,
                    splitPoint: splitPoint,
                    secondTail: Array(path.points.dropFirst(index + 1)),
                    width: path.width,
                    endCap: path.endCap
                )
            }

            firstPoints.append(end)
        }

        return nil
    }

    private func splitPoint(
        onSegmentFrom start: LayoutPoint,
        to end: LayoutPoint,
        axis: SplitShapeAxis,
        coordinate: Double
    ) -> LayoutPoint? {
        switch axis {
        case .vertical:
            let minX = min(start.x, end.x)
            let maxX = max(start.x, end.x)
            guard coordinate > minX, coordinate < maxX else { return nil }
            let t = (coordinate - start.x) / (end.x - start.x)
            return LayoutPoint(x: coordinate, y: start.y + t * (end.y - start.y))
        case .horizontal:
            let minY = min(start.y, end.y)
            let maxY = max(start.y, end.y)
            guard coordinate > minY, coordinate < maxY else { return nil }
            let t = (coordinate - start.y) / (end.y - start.y)
            return LayoutPoint(x: start.x + t * (end.x - start.x), y: coordinate)
        }
    }

    private func isPointOnSplit(_ point: LayoutPoint, axis: SplitShapeAxis, coordinate: Double) -> Bool {
        switch axis {
        case .vertical:
            return abs(point.x - coordinate) < 1e-12
        case .horizontal:
            return abs(point.y - coordinate) < 1e-12
        }
    }

    private func makeSplitPaths(
        firstPoints: [LayoutPoint],
        splitPoint: LayoutPoint,
        secondTail: [LayoutPoint],
        width: Double,
        endCap: LayoutPathEndCap
    ) -> (LayoutPath, LayoutPath)? {
        var first = firstPoints
        appendPoint(splitPoint, to: &first)

        var second = [splitPoint]
        for point in secondTail {
            appendPoint(point, to: &second)
        }

        let firstPath = LayoutPath(points: first, width: width, endCap: endCap)
        let secondPath = LayoutPath(points: second, width: width, endCap: endCap)
        guard firstPath.isValid, secondPath.isValid else { return nil }
        return (firstPath, secondPath)
    }

    private func appendPoint(_ point: LayoutPoint, to points: inout [LayoutPoint]) {
        if points.last != point {
            points.append(point)
        }
    }

    private func resolve(path: String, baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return baseURL.appendingPathComponent(path)
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum NormalizedInstanceMirrorAxis {
    case vertical
    case horizontal
}

private extension InstanceMirrorAxis {
    var normalized: NormalizedInstanceMirrorAxis {
        switch self {
        case .x, .vertical:
            return .vertical
        case .y, .horizontal:
            return .horizontal
        }
    }
}
