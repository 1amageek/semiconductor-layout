enum DeviceParameterValidation {
    static let maximumFingerCount = 1024

    static func requireSupported(
        _ deviceKindID: String,
        supported: [String]
    ) throws {
        guard supported.contains(deviceKindID) else {
            throw AutoGenError.unsupportedDevice(deviceKindID)
        }
    }

    static func requireMOSKind(_ deviceKindID: String) throws -> Bool {
        if deviceKindID.hasPrefix("pmos") {
            return true
        }
        if deviceKindID.hasPrefix("nmos") {
            return false
        }
        throw AutoGenError.unsupportedDevice(deviceKindID)
    }

    static func requirePositive(
        _ parameters: [String: Double],
        _ parameter: String,
        device: String
    ) throws -> Double {
        guard let value = parameters[parameter] else {
            throw AutoGenError.missingParameter(device: device, parameter: parameter)
        }
        return try requirePositiveValue(value, parameter, device: device)
    }

    static func requirePositiveValue(
        _ value: Double,
        _ parameter: String,
        device: String
    ) throws -> Double {
        guard value.isFinite else {
            throw AutoGenError.invalidParameter(
                device: device,
                parameter: parameter,
                value: value,
                reason: "must be finite"
            )
        }
        guard value > 0 else {
            throw AutoGenError.invalidParameter(
                device: device,
                parameter: parameter,
                value: value,
                reason: "must be greater than zero"
            )
        }
        return value
    }

    static func requirePositiveInteger(
        _ parameters: [String: Double],
        _ parameter: String,
        defaultValue: Int,
        device: String
    ) throws -> Int {
        guard let rawValue = parameters[parameter] else {
            return defaultValue
        }
        let value = try requirePositiveValue(rawValue, parameter, device: device)
        guard value.rounded(.towardZero) == value else {
            throw AutoGenError.invalidParameter(
                device: device,
                parameter: parameter,
                value: value,
                reason: "must be an integer"
            )
        }
        guard value <= Double(maximumFingerCount) else {
            throw AutoGenError.invalidParameter(
                device: device,
                parameter: parameter,
                value: value,
                reason: "must be less than or equal to \(maximumFingerCount)"
            )
        }
        return Int(value)
    }
}
