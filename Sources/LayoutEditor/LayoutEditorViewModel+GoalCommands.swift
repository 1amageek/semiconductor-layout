import LayoutCore

extension LayoutEditorViewModel {
    // MARK: - Goal commands (N5)

    /// Executes one goal command through the same implementations the
    /// keymap uses — the human/agent parity surface.
    @discardableResult
    public func execute(_ command: LayoutGoalCommand) -> Bool {
        let violationsBefore = violations.count
        let opensBefore = connectivityAnalysis?.opens.count ?? 0
        let lvsBefore = lvsComparison?.matchedReferenceDeviceCount ?? 0

        let succeeded: Bool
        switch command {
        case .fixAllViolations:
            let sweep = fixAllViolations()
            succeeded = sweep?.reachedFixedPoint ?? false
        case .finishNet(let netID):
            succeeded = finishNet(netID)
        case .finishAllNets:
            succeeded = finishAllNets() > 0 || connectivityAnalysis?.flylines.isEmpty == true
        case .annotateNetsFromLabels:
            succeeded = annotateNetsFromLabels() != nil
        case .placeIntentDevice(let deviceID, let point):
            if let device = unplacedIntentDevices.first(where: { $0.id == deviceID }) {
                armIntentPlacement(device)
                succeeded = placeArmedIntentDevice(at: point, bindTerminals: false)
            } else {
                handleError(LayoutEditorError.intentDeviceNotFound(deviceID))
                succeeded = false
            }
        case .bindIntentTerminals:
            succeeded = (bindIntentTerminals() ?? 0) > 0
        case .setActiveLayer(let layer):
            activeLayer = layer
            succeeded = true
        }

        goalLog.append(LayoutGoalRecord(
            command: command,
            succeeded: succeeded,
            violationsBefore: violationsBefore,
            violationsAfter: violations.count,
            opensBefore: opensBefore,
            opensAfter: connectivityAnalysis?.opens.count ?? 0,
            lvsMatchedBefore: lvsBefore,
            lvsMatchedAfter: lvsComparison?.matchedReferenceDeviceCount ?? 0
        ))
        return succeeded
    }

    /// Replays a command sequence in order; stops at the first failure
    /// and reports whether every command succeeded.
    @discardableResult
    public func replay(_ commands: [LayoutGoalCommand]) -> Bool {
        for command in commands {
            guard execute(command) else { return false }
        }
        return true
    }

}
