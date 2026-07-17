import CryptoKit
import Foundation

public struct LayoutExtractionProcessProfileLoader: LayoutExtractionProcessProfileLoading {
    public init() {}

    public func load(
        profileURL: URL,
        extractionDeckURL: URL,
        expectedProcessProfileID: String? = nil
    ) throws -> LayoutExtractionProcessProfile {
        let profileData = try readProfileData(from: profileURL)
        let profile: LayoutExtractionProcessProfile
        do {
            profile = try JSONDecoder().decode(LayoutExtractionProcessProfile.self, from: profileData)
        } catch {
            throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                path: profileURL.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
        try validate(profile, path: profileURL.path(percentEncoded: false))
        if let expectedProcessProfileID,
           profile.processProfileID != expectedProcessProfileID {
            throw LayoutExtractionProcessProfileError.processProfileMismatch(
                expected: expectedProcessProfileID,
                actual: profile.processProfileID
            )
        }

        let deckData = try readDeckData(from: extractionDeckURL)
        let actualDigest = SHA256.hash(data: deckData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualDigest == profile.extractionDeckDigest else {
            throw LayoutExtractionProcessProfileError.extractionDeckDigestMismatch(
                expected: profile.extractionDeckDigest,
                actual: actualDigest
            )
        }
        return profile
    }

    private func readProfileData(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw LayoutExtractionProcessProfileError.missingProfileArtifact(
                path: url.path(percentEncoded: false)
            )
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LayoutExtractionProcessProfileError.unreadableProfileArtifact(
                path: url.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
    }

    private func readDeckData(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw LayoutExtractionProcessProfileError.missingExtractionDeck(
                path: url.path(percentEncoded: false)
            )
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LayoutExtractionProcessProfileError.unreadableExtractionDeck(
                path: url.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
    }

    private func validate(_ profile: LayoutExtractionProcessProfile, path: String) throws {
        guard profile.schemaVersion == LayoutExtractionProcessProfile.currentSchemaVersion else {
            throw LayoutExtractionProcessProfileError.unsupportedSchemaVersion(
                actual: profile.schemaVersion,
                supported: LayoutExtractionProcessProfile.currentSchemaVersion
            )
        }
        try requireNonEmpty(profile.processID, field: "processID", path: path)
        try requireNonEmpty(profile.processProfileID, field: "processProfileID", path: path)
        let digestCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard profile.extractionDeckDigest.count == 64,
              profile.extractionDeckDigest.unicodeScalars.allSatisfy(digestCharacters.contains) else {
            throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                path: path,
                reason: "extractionDeckDigest must be a lowercase SHA-256 digest."
            )
        }
        guard !profile.conductorLayers.names.isEmpty else {
            throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                path: path,
                reason: "conductorLayers must not be empty."
            )
        }
        guard !profile.mosRules.isEmpty else {
            throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                path: path,
                reason: "mosRules must not be empty."
            )
        }
        let ruleIDs = profile.mosRules.map(\.ruleID)
        guard Set(ruleIDs).count == ruleIDs.count else {
            throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                path: path,
                reason: "mosRules contains duplicate ruleID values."
            )
        }
        for rule in profile.mosRules {
            try requireNonEmpty(rule.ruleID, field: "mosRules.ruleID", path: path)
            try requireNonEmpty(rule.model, field: "mosRules.model", path: path)
            guard !rule.gateLayers.names.isEmpty,
                  !rule.diffusionLayers.names.isEmpty,
                  !rule.selectorLayers.names.isEmpty else {
                throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                    path: path,
                    reason: "MOS rule '\(rule.ruleID)' requires gate, diffusion, and selector layers."
                )
            }
        }
        for rule in profile.connectionRules {
            guard !rule.cutLayers.names.isEmpty,
                  !rule.lowerLayers.names.isEmpty,
                  !rule.upperLayers.names.isEmpty else {
                throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                    path: path,
                    reason: "Connection rules require cut, lower, and upper layers."
                )
            }
        }
    }

    private func requireNonEmpty(_ value: String, field: String, path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LayoutExtractionProcessProfileError.invalidProfileArtifact(
                path: path,
                reason: "\(field) must not be empty."
            )
        }
    }
}
