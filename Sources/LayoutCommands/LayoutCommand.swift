import Foundation
import LayoutCore

public enum LayoutCommand: Sendable, Equatable {
    case createCell(CreateCellCommand)
    case addNet(AddNetCommand)
    case addRect(AddRectCommand)
    case addShape(AddShapeCommand)
    case finishNet(FinishNetCommand)
    case translateShape(TranslateShapeCommand)
    case resizeShape(ResizeShapeCommand)
    case deleteShape(DeleteShapeCommand)
    case splitShape(SplitShapeCommand)
    case addLabel(AddLabelCommand)
    case addVia(AddViaCommand)
    case addConstraint(AddConstraintCommand)
    case addInstance(AddInstanceCommand)
    case moveInstance(MoveInstanceCommand)
    case rotateInstance(RotateInstanceCommand)
    case mirrorInstance(MirrorInstanceCommand)
    case flattenInstance(FlattenInstanceCommand)
    case makeCell(MakeCellCommand)
    case fixAllViolations(FixAllViolationsCommand)
}

extension LayoutCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case createCell
        case addNet
        case addRect
        case addShape
        case finishNet
        case translateShape
        case resizeShape
        case deleteShape
        case splitShape
        case addLabel
        case addVia
        case addConstraint
        case addInstance
        case moveInstance
        case rotateInstance
        case mirrorInstance
        case flattenInstance
        case makeCell
        case fixAllViolations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(LayoutCommandKind.self, forKey: .kind)
        switch kind {
        case .createCell:
            self = .createCell(try container.decode(CreateCellCommand.self, forKey: .createCell))
        case .addNet:
            self = .addNet(try container.decode(AddNetCommand.self, forKey: .addNet))
        case .addRect:
            self = .addRect(try container.decode(AddRectCommand.self, forKey: .addRect))
        case .addShape:
            self = .addShape(try container.decode(AddShapeCommand.self, forKey: .addShape))
        case .finishNet:
            self = .finishNet(try container.decode(FinishNetCommand.self, forKey: .finishNet))
        case .translateShape:
            self = .translateShape(try container.decode(TranslateShapeCommand.self, forKey: .translateShape))
        case .resizeShape:
            self = .resizeShape(try container.decode(ResizeShapeCommand.self, forKey: .resizeShape))
        case .deleteShape:
            self = .deleteShape(try container.decode(DeleteShapeCommand.self, forKey: .deleteShape))
        case .splitShape:
            self = .splitShape(try container.decode(SplitShapeCommand.self, forKey: .splitShape))
        case .addLabel:
            self = .addLabel(try container.decode(AddLabelCommand.self, forKey: .addLabel))
        case .addVia:
            self = .addVia(try container.decode(AddViaCommand.self, forKey: .addVia))
        case .addConstraint:
            self = .addConstraint(try container.decode(AddConstraintCommand.self, forKey: .addConstraint))
        case .addInstance:
            self = .addInstance(try container.decode(AddInstanceCommand.self, forKey: .addInstance))
        case .moveInstance:
            self = .moveInstance(try container.decode(MoveInstanceCommand.self, forKey: .moveInstance))
        case .rotateInstance:
            self = .rotateInstance(try container.decode(RotateInstanceCommand.self, forKey: .rotateInstance))
        case .mirrorInstance:
            self = .mirrorInstance(try container.decode(MirrorInstanceCommand.self, forKey: .mirrorInstance))
        case .flattenInstance:
            self = .flattenInstance(try container.decode(FlattenInstanceCommand.self, forKey: .flattenInstance))
        case .makeCell:
            self = .makeCell(try container.decode(MakeCellCommand.self, forKey: .makeCell))
        case .fixAllViolations:
            self = .fixAllViolations(try container.decode(FixAllViolationsCommand.self, forKey: .fixAllViolations))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createCell(let command):
            try container.encode(LayoutCommandKind.createCell, forKey: .kind)
            try container.encode(command, forKey: .createCell)
        case .addNet(let command):
            try container.encode(LayoutCommandKind.addNet, forKey: .kind)
            try container.encode(command, forKey: .addNet)
        case .addRect(let command):
            try container.encode(LayoutCommandKind.addRect, forKey: .kind)
            try container.encode(command, forKey: .addRect)
        case .addShape(let command):
            try container.encode(LayoutCommandKind.addShape, forKey: .kind)
            try container.encode(command, forKey: .addShape)
        case .finishNet(let command):
            try container.encode(LayoutCommandKind.finishNet, forKey: .kind)
            try container.encode(command, forKey: .finishNet)
        case .translateShape(let command):
            try container.encode(LayoutCommandKind.translateShape, forKey: .kind)
            try container.encode(command, forKey: .translateShape)
        case .resizeShape(let command):
            try container.encode(LayoutCommandKind.resizeShape, forKey: .kind)
            try container.encode(command, forKey: .resizeShape)
        case .deleteShape(let command):
            try container.encode(LayoutCommandKind.deleteShape, forKey: .kind)
            try container.encode(command, forKey: .deleteShape)
        case .splitShape(let command):
            try container.encode(LayoutCommandKind.splitShape, forKey: .kind)
            try container.encode(command, forKey: .splitShape)
        case .addLabel(let command):
            try container.encode(LayoutCommandKind.addLabel, forKey: .kind)
            try container.encode(command, forKey: .addLabel)
        case .addVia(let command):
            try container.encode(LayoutCommandKind.addVia, forKey: .kind)
            try container.encode(command, forKey: .addVia)
        case .addConstraint(let command):
            try container.encode(LayoutCommandKind.addConstraint, forKey: .kind)
            try container.encode(command, forKey: .addConstraint)
        case .addInstance(let command):
            try container.encode(LayoutCommandKind.addInstance, forKey: .kind)
            try container.encode(command, forKey: .addInstance)
        case .moveInstance(let command):
            try container.encode(LayoutCommandKind.moveInstance, forKey: .kind)
            try container.encode(command, forKey: .moveInstance)
        case .rotateInstance(let command):
            try container.encode(LayoutCommandKind.rotateInstance, forKey: .kind)
            try container.encode(command, forKey: .rotateInstance)
        case .mirrorInstance(let command):
            try container.encode(LayoutCommandKind.mirrorInstance, forKey: .kind)
            try container.encode(command, forKey: .mirrorInstance)
        case .flattenInstance(let command):
            try container.encode(LayoutCommandKind.flattenInstance, forKey: .kind)
            try container.encode(command, forKey: .flattenInstance)
        case .makeCell(let command):
            try container.encode(LayoutCommandKind.makeCell, forKey: .kind)
            try container.encode(command, forKey: .makeCell)
        case .fixAllViolations(let command):
            try container.encode(LayoutCommandKind.fixAllViolations, forKey: .kind)
            try container.encode(command, forKey: .fixAllViolations)
        }
    }

    public var kind: LayoutCommandKind {
        switch self {
        case .createCell: return .createCell
        case .addNet: return .addNet
        case .addRect: return .addRect
        case .addShape: return .addShape
        case .finishNet: return .finishNet
        case .translateShape: return .translateShape
        case .resizeShape: return .resizeShape
        case .deleteShape: return .deleteShape
        case .splitShape: return .splitShape
        case .addLabel: return .addLabel
        case .addVia: return .addVia
        case .addConstraint: return .addConstraint
        case .addInstance: return .addInstance
        case .moveInstance: return .moveInstance
        case .rotateInstance: return .rotateInstance
        case .mirrorInstance: return .mirrorInstance
        case .flattenInstance: return .flattenInstance
        case .makeCell: return .makeCell
        case .fixAllViolations: return .fixAllViolations
        }
    }
}
