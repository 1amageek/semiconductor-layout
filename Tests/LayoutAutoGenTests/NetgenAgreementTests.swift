import Foundation
import Testing
import LayoutAutoGen
import LayoutCore
import LayoutTech
import LayoutVerify

/// Agreement gate between the in-process LVS comparator and Netgen: on
/// the same netlist pair, both must point the same way. Verifies the
/// matching pair, a parameter-mutated pair, and a physically
/// gate-disconnected pair.
///
/// Enabled only where a Netgen binary exists (`NETGEN_BIN` or the
/// `~/.local/netgen/bin/netgen` install the signoff stack uses); the
/// suite shows as skipped otherwise — a visible gate, not a silent one.
private var netgenBinaryURL: URL? {
    let environment = ProcessInfo.processInfo.environment
    let path = environment["NETGEN_BIN"]
        ?? (NSHomeDirectory() + "/.local/netgen/bin/netgen")
    return FileManager.default.isExecutableFile(atPath: path)
        ? URL(fileURLWithPath: path)
        : nil
}

@Suite(
    "Netgen agreement",
    .serialized,
    .timeLimit(.minutes(5)),
    .enabled(if: netgenBinaryURL != nil)
)
struct NetgenAgreementTests {

    private let polyLayer = LayoutLayerID(name: "POLY", purpose: "drawing")

    @Test func matchingPairAgreesWithNetgen() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try Self.generatedDocument(width: 2.0, length: 0.18)
        let extracted = try DeviceExtractor().extract(document: document, tech: tech)
        #expect(extracted.issues.isEmpty)
        let reference = try SPICESubcktReader().read("""
        .subckt mos source gate drain bulk
        M1 drain gate source bulk nmos W=2u L=0.18u
        .ends
        """)

        let mine = NetlistComparator().compare(
            extracted: extracted.netlist, reference: reference
        ).passed
        let netgen = try Self.netgenMatches(extracted.netlist, reference)

        #expect(mine == true)
        #expect(netgen == true, "Netgen must agree the pair matches")
    }

    @Test func widthMutationFailsBothWays() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try Self.generatedDocument(width: 2.0, length: 0.18)
        let extracted = try DeviceExtractor().extract(document: document, tech: tech)
        let mutated = try SPICESubcktReader().read("""
        .subckt mos source gate drain bulk
        M1 drain gate source bulk nmos W=3u L=0.18u
        .ends
        """)

        let mine = NetlistComparator().compare(
            extracted: extracted.netlist, reference: mutated
        ).passed
        let netgen = try Self.netgenMatches(extracted.netlist, mutated)

        #expect(mine == false)
        #expect(netgen == false, "Netgen must reject the mutated width too")
    }

    /// A geometric MIS-WIRE (gate strapped to the drain bar through a
    /// poly bridge and contact) changes the topology, which both engines
    /// must reject. A pure OPEN (floating gate) is deliberately not the
    /// netgen case here: without port-correspondence setup netgen matches
    /// dangling-pin topologies, while the in-process comparator catches
    /// opens via island naming — that direction is covered by the LVS
    /// unit tests.
    @Test func miswiredGateFailsBothWays() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        var document = try Self.generatedDocument(width: 2.0, length: 0.18)
        let reference = try SPICESubcktReader().read("""
        .subckt mos source gate drain bulk
        M1 drain gate source bulk nmos W=2u L=0.18u
        .ends
        """)

        // Strap the gate M1 bus to the drain M1 bar with one M1 rect
        // covering both pins: a pure metal mis-wire, no device-layer side
        // effects.
        var cell = try #require(document.cells.first)
        let gatePin = try #require(cell.pins.first { $0.name == "gate" })
        let drainPin = try #require(cell.pins.first { $0.name == "drain" })
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let strapBox = LayoutRect(
            origin: LayoutPoint(
                x: min(gatePin.position.x, drainPin.position.x) - 0.1,
                y: min(gatePin.position.y, drainPin.position.y) - 0.1
            ),
            size: LayoutSize(
                width: abs(gatePin.position.x - drainPin.position.x) + 0.2,
                height: abs(gatePin.position.y - drainPin.position.y) + 0.2
            )
        )
        cell.shapes.append(LayoutShape(layer: m1, geometry: .rect(strapBox)))
        document.updateCell(cell)

        let miswired = try DeviceExtractor().extract(document: document, tech: tech)
        let mine = NetlistComparator().compare(
            extracted: miswired.netlist, reference: reference
        ).passed
        let netgen = try Self.netgenMatches(miswired.netlist, reference)

        #expect(mine == false)
        #expect(netgen == false, "a gate strapped to the drain must fail in both engines")
    }

    // MARK: - Helpers

    private static func generatedDocument(width: Double, length: Double) throws -> LayoutDocument {
        let tech = LayoutTechDatabase.sampleProcess()
        let cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": width, "l": length],
            tech: tech
        )
        return LayoutDocument(name: "mos", cells: [cell], topCellID: cell.id)
    }

    private enum NetgenHarnessError: Error {
        case binaryUnavailable
        case timedOut
        case unreadableReport
    }

    private struct NetgenRunFiles {
        var directory: URL
        var extractedURL: URL
        var referenceURL: URL
        var reportURL: URL
        var scriptURL: URL
        var setupURL: URL
    }

    /// Runs `netgen -batch lvs` on the pair and returns whether Netgen
    /// declares a match. Bounded by a hard timeout — a hung tool is a
    /// failure, not a wait.
    private static func netgenMatches(
        _ extracted: ComparisonNetlist,
        _ reference: ComparisonNetlist
    ) throws -> Bool {
        guard let netgenURL = netgenBinaryURL else { throw NetgenHarnessError.binaryUnavailable }
        let files = try makeNetgenRunFiles()
        defer { removeTemporaryDirectory(files.directory) }
        try writeNetgenInputs(extracted: extracted, reference: reference, files: files)
        try runNetgen(netgenURL: netgenURL, files: files)
        let report = try readNetgenReport(files.reportURL)
        return try netgenReportIndicatesMatch(report)
    }

    private static func makeNetgenRunFiles() throws -> NetgenRunFiles {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netgen-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return NetgenRunFiles(
            directory: directory,
            extractedURL: directory.appendingPathComponent("extracted.spice"),
            referenceURL: directory.appendingPathComponent("reference.spice"),
            reportURL: directory.appendingPathComponent("compare.out"),
            scriptURL: directory.appendingPathComponent("lvs.tcl"),
            setupURL: directory.appendingPathComponent("setup.tcl")
        )
    }

    private static func writeNetgenInputs(
        extracted: ComparisonNetlist,
        reference: ComparisonNetlist,
        files: NetgenRunFiles
    ) throws {
        let writer = ComparisonNetlistSPICEWriter()
        try writer.write(extracted, name: "top")
            .write(to: files.extractedURL, atomically: true, encoding: .utf8)
        try writer.write(reference, name: "top")
            .write(to: files.referenceURL, atomically: true, encoding: .utf8)
        // Netgen compares topology only unless told which device
        // properties matter; W/L/M is exactly what the comparator checks.
        try """
        property "-circuit1 nmos" w l m
        property "-circuit2 nmos" w l m
        property "-circuit1 pmos" w l m
        property "-circuit2 pmos" w l m
        permute default
        """.write(to: files.setupURL, atomically: true, encoding: .utf8)
        try """
        lvs "\(files.extractedURL.path) top" "\(files.referenceURL.path) top" "\(files.setupURL.path)" "\(files.reportURL.path)"
        quit
        """.write(to: files.scriptURL, atomically: true, encoding: .utf8)
    }

    private static func runNetgen(netgenURL: URL, files: NetgenRunFiles) throws {
        let process = Process()
        process.executableURL = netgenURL
        process.arguments = ["-batch", "source", files.scriptURL.path]
        process.currentDirectoryURL = files.directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw NetgenHarnessError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func readNetgenReport(_ reportURL: URL) throws -> String {
        do {
            return try String(contentsOf: reportURL, encoding: .utf8)
        } catch {
            throw NetgenHarnessError.unreadableReport
        }
    }

    private static func netgenReportIndicatesMatch(_ report: String) throws -> Bool {
        // Netgen reports topology and properties separately: a unique
        // topological match WITH property errors is still an LVS failure.
        let propertyErrors = report.contains("Property errors were found")
        if report.contains("match uniquely") { return !propertyErrors }
        if report.contains("do not match") { return false }
        throw NetgenHarnessError.unreadableReport
    }

    private static func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary directory: \(error)")
        }
    }
}
