import Foundation
import Testing
import LayoutAutoGen
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("SPICE subckt reader", .timeLimit(.minutes(1)))
struct SPICESubcktReaderTests {

    @Test func readsMOSCardsWithUnitsAndPorts() throws {
        let text = """
        * reference inverter
        .subckt inv in out vdd vss
        M1 out in vdd vdd pmos W=3u L=180n
        M2 out in vss vss nmos W=2u L=180n M=2
        .ends
        """
        let netlist = try SPICESubcktReader().read(text)

        #expect(netlist.devices.count == 2)
        let pmos = try #require(netlist.devices.first { $0.kind == .pmos })
        #expect(abs(pmos.parameters.width - 3.0) < 1e-9)
        #expect(abs(pmos.parameters.length - 0.18) < 1e-9)
        #expect(pmos.terminals[.gate] == ComparisonNetID("pin:in"))
        #expect(pmos.terminals[.drain] == ComparisonNetID("pin:out"))
        let nmos = try #require(netlist.devices.first { $0.kind == .nmos })
        #expect(nmos.parameters.multiplier == 2)
        #expect(netlist.ports["vdd"] == ComparisonNetID("pin:vdd"))
    }

    @Test func expandsSubcircuitInstancesWithPathQualifiedInternalNets() throws {
        let text = """
        .subckt stage in out vss
        M1 mid in vss vss nmos W=1u L=100n
        M2 out mid vss vss nmos W=1u L=100n
        .ends
        .subckt top a y vss
        X1 a m vss stage
        X2 m y vss stage
        .ends
        """
        let netlist = try SPICESubcktReader().read(text, subcircuit: "top")

        #expect(netlist.devices.count == 4)
        let gates = Set(netlist.devices.compactMap { $0.terminals[.gate]?.rawValue })
        #expect(gates.contains("pin:a"))
        #expect(gates.contains("pin:m"), "the shared boundary net keeps one name")
        // Internal nets of the two stages must NOT merge.
        let mids = netlist.devices.compactMap { $0.terminals[.drain]?.rawValue }
            .filter { $0.contains("mid") }
        #expect(Set(mids).count == 2)
    }

    @Test func unknownModelAndForeignCardsAreTypedErrors() {
        #expect(throws: SPICESubcktReaderError.unknownModel("bjt123")) {
            _ = try SPICESubcktReader().read("""
            .subckt t a b
            M1 a b b b bjt123 W=1u L=1u
            .ends
            """)
        }
        #expect(throws: SPICESubcktReaderError.self) {
            _ = try SPICESubcktReader().read("""
            .subckt t a b
            R1 a b 100
            .ends
            """)
        }
        #expect(throws: SPICESubcktReaderError.unterminatedSubcircuit("t")) {
            _ = try SPICESubcktReader().read(".subckt t a b\nM1 a b b b nmos W=1u L=1u\n")
        }
    }

    /// The real currency test: a hand-written reference for the generated
    /// MOSFET cell must compare clean against the geometric extraction.
    @Test func referenceFromSubcktMatchesGeometricExtraction() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18],
            tech: tech
        )
        let document = LayoutDocument(name: "mos", cells: [cell], topCellID: cell.id)
        let extracted = try DeviceExtractor().extract(document: document, tech: tech)
        #expect(extracted.issues.isEmpty)

        let reference = try SPICESubcktReader().read("""
        .subckt mos source gate drain bulk
        M1 drain gate source bulk nmos W=2u L=0.18u
        .ends
        """)

        let comparison = NetlistComparator().compare(
            extracted: extracted.netlist,
            reference: reference
        )
        #expect(comparison.passed, "\(comparison)")
    }
}
