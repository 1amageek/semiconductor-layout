import Foundation
import Testing
import LayoutCore
import LayoutVerify

/// Contract of the M5 constraint checker: every persisted design-intent
/// constraint (symmetry, matching, alignment, common centroid,
/// interdigitation) is evaluated against current geometry with the same
/// semantics the SA placement engine optimizes, and every degenerate
/// input (odd pairs, unresolved members, single-group patterns) is
/// reported as a violation — never skipped silently.
///
/// All fixtures use integer coordinates so geometric expectations are
/// exact in float arithmetic.
@Suite("LayoutConstraintChecker", .timeLimit(.minutes(1)))
struct LayoutConstraintCheckerTests {

    private static let layer = LayoutLayerID(name: "M1", purpose: "drawing")

    /// A shape whose bounding box is exactly `rect`.
    private static func shape(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutShape {
        LayoutShape(
            layer: layer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: w, height: h)
            ))
        )
    }

    private static func document(
        shapes: [LayoutShape],
        instances: [LayoutInstance] = [],
        constraints: [LayoutConstraint],
        extraCells: [LayoutCell] = []
    ) -> (document: LayoutDocument, cellID: UUID) {
        let top = LayoutCell(
            name: "TOP",
            shapes: shapes,
            instances: instances,
            constraints: constraints
        )
        let document = LayoutDocument(
            name: "constraint-fixture",
            cells: [top] + extraCells,
            topCellID: top.id
        )
        return (document, top.id)
    }

    private func check(
        _ fixture: (document: LayoutDocument, cellID: UUID),
        tolerance: Double = 1e-9
    ) throws -> [LayoutConstraintViolation] {
        try LayoutConstraintChecker(tolerance: tolerance)
            .check(document: fixture.document, cellID: fixture.cellID)
    }

    // MARK: - Symmetry

    @Test func symmetryExplicitAxisSatisfiedAndBroken() throws {
        // Centers x = 2 and x = 8 mirror across the vertical line x = 5.
        let a = Self.shape(1, 0, 2, 2)
        let b = Self.shape(7, 0, 2, 2)
        let constraint = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .vertical,
            members: [a.id, b.id],
            axisPosition: 5
        ))
        #expect(try check(Self.document(shapes: [a, b], constraints: [constraint])).isEmpty)

        // Shifting b right by 1 leaves a mirror error of exactly 1.
        let bShifted = Self.shape(8, 0, 2, 2)
        let broken = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .vertical,
            members: [a.id, bShifted.id],
            axisPosition: 5
        ))
        let violations = try check(Self.document(shapes: [a, bShifted], constraints: [broken]))
        let violation = try #require(violations.first)
        #expect(violations.count == 1)
        #expect(violation.kind == .symmetryPairMismatch)
        #expect(violation.constraintIndex == 0)
        #expect(violation.severity == .error)
        #expect(violation.memberIDs == [a.id, bShifted.id])
        #expect(violation.measured == 1)
        #expect(violation.region == LayoutRect(
            origin: LayoutPoint(x: 1, y: 0),
            size: LayoutSize(width: 9, height: 2)
        ))
    }

    @Test func symmetryDerivedAxisIsTheMeanOfMemberCenters() throws {
        // Two pairs, no explicit axis: centers 2, 8, 4, 6 derive x = 5
        // and both pairs mirror across it.
        let a = Self.shape(1, 0, 2, 2)
        let b = Self.shape(7, 0, 2, 2)
        let c = Self.shape(3, 4, 2, 2)
        let d = Self.shape(5, 4, 2, 2)
        let constraint = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .vertical,
            members: [a.id, b.id, c.id, d.id]
        ))
        #expect(try check(Self.document(shapes: [a, b, c, d], constraints: [constraint])).isEmpty)
    }

    @Test func symmetryPairsMustShareTheAlongCoordinate() throws {
        // Horizontal axis: pairs mirror in y and must share x. Centers
        // (1, 2) and (3, 8) mirror across y = 5 but differ in x by 2.
        let a = Self.shape(0, 1, 2, 2)
        let b = Self.shape(2, 7, 2, 2)
        let constraint = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .horizontal,
            members: [a.id, b.id],
            axisPosition: 5
        ))
        let violations = try check(Self.document(shapes: [a, b], constraints: [constraint]))
        let violation = try #require(violations.first)
        #expect(violation.kind == .symmetryPairMismatch)
        #expect(violation.measured == 2)
    }

    @Test func selfSymmetricMemberMustSitOnTheAxis() throws {
        let a = Self.shape(1, 0, 2, 2)
        let b = Self.shape(7, 0, 2, 2)
        // Center x = 6 sits 1 off the explicit axis at x = 5.
        let tail = Self.shape(5, 4, 2, 2)
        let constraint = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .vertical,
            members: [a.id, b.id],
            axisPosition: 5,
            selfSymmetricMembers: [tail.id]
        ))
        let violations = try check(Self.document(shapes: [a, b, tail], constraints: [constraint]))
        let violation = try #require(violations.first)
        #expect(violations.count == 1)
        #expect(violation.kind == .symmetryAxisMemberOffAxis)
        #expect(violation.memberIDs == [tail.id])
        #expect(violation.measured == 1)
    }

    @Test func symmetryOddMemberCountIsMalformedNotSkipped() throws {
        let a = Self.shape(1, 0, 2, 2)
        let b = Self.shape(7, 0, 2, 2)
        let c = Self.shape(4, 4, 2, 2)
        let constraint = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .vertical,
            members: [a.id, b.id, c.id]
        ))
        let violations = try check(Self.document(shapes: [a, b, c], constraints: [constraint]))
        let violation = try #require(violations.first)
        #expect(violations.count == 1)
        #expect(violation.kind == .malformedConstraint)
    }

    @Test func unresolvedMembersAreReportedAndBlockTheGeometricVerdict() throws {
        let a = Self.shape(1, 0, 2, 2)
        let ghost = UUID()
        let constraint = LayoutConstraint.symmetry(LayoutSymmetryConstraint(
            axis: .vertical,
            members: [a.id, ghost]
        ))
        let violations = try check(Self.document(shapes: [a], constraints: [constraint]))
        let violation = try #require(violations.first)
        #expect(
            violations.count == 1,
            "one unresolved-member violation and no partial geometric verdict"
        )
        #expect(violation.kind == .unresolvedMember)
        #expect(violation.memberIDs == [ghost])
    }

    // MARK: - Matching

    @Test func matchingNilBudgetMeansExactAndBudgetsRelax() throws {
        let reference = Self.shape(0, 0, 2, 4)
        let same = Self.shape(4, 0, 2, 4)
        let wider = Self.shape(8, 0, 3, 4)
        let taller = Self.shape(12, 0, 2, 6)

        // Exact twins pass with nil budgets.
        #expect(try check(Self.document(
            shapes: [reference, same],
            constraints: [.matching(LayoutMatchingConstraint(members: [reference.id, same.id]))]
        )).isEmpty)

        // Width off by 1, height off by 2 against the first member.
        let strict = try check(Self.document(
            shapes: [reference, wider, taller],
            constraints: [.matching(LayoutMatchingConstraint(
                members: [reference.id, wider.id, taller.id]
            ))]
        ))
        #expect(strict.count == 2)
        let widthViolation = try #require(strict.first { $0.kind == .matchingWidthMismatch })
        #expect(widthViolation.measured == 1)
        #expect(widthViolation.memberIDs == [reference.id, wider.id])
        let lengthViolation = try #require(strict.first { $0.kind == .matchingLengthMismatch })
        #expect(lengthViolation.measured == 2)
        #expect(lengthViolation.memberIDs == [reference.id, taller.id])

        // Budgets exactly as large as the mismatch absorb it.
        #expect(try check(Self.document(
            shapes: [reference, wider, taller],
            constraints: [.matching(LayoutMatchingConstraint(
                members: [reference.id, wider.id, taller.id],
                maxLengthMismatch: 2,
                maxWidthMismatch: 1
            ))]
        )).isEmpty)
    }

    @Test func matchingNeedsAtLeastTwoMembers() throws {
        let lone = Self.shape(0, 0, 2, 4)
        let violations = try check(Self.document(
            shapes: [lone],
            constraints: [.matching(LayoutMatchingConstraint(members: [lone.id]))]
        ))
        let violation = try #require(violations.first)
        #expect(violations.count == 1)
        #expect(violation.kind == .malformedConstraint)
    }

    // MARK: - Alignment

    @Test func alignmentModesCompareTheRightCoordinate() throws {
        // Same minY = 0, different heights: minY aligned, maxY off by 2,
        // centerY off by 1.
        let a = Self.shape(0, 0, 2, 4)
        let b = Self.shape(4, 0, 2, 6)

        #expect(try check(Self.document(
            shapes: [a, b],
            constraints: [.alignment(LayoutAlignmentConstraint(mode: .minY, members: [a.id, b.id]))]
        )).isEmpty)

        let maxY = try check(Self.document(
            shapes: [a, b],
            constraints: [.alignment(LayoutAlignmentConstraint(mode: .maxY, members: [a.id, b.id]))]
        ))
        let maxYViolation = try #require(maxY.first)
        #expect(maxYViolation.kind == .alignmentMismatch)
        #expect(maxYViolation.measured == 2)

        let centerY = try check(Self.document(
            shapes: [a, b],
            constraints: [.alignment(LayoutAlignmentConstraint(mode: .centerY, members: [a.id, b.id]))]
        ))
        #expect(try #require(centerY.first).measured == 1)

        // X-family analogue: same maxX, different widths.
        let c = Self.shape(0, 0, 4, 2)
        let d = Self.shape(2, 4, 2, 2)
        #expect(try check(Self.document(
            shapes: [c, d],
            constraints: [.alignment(LayoutAlignmentConstraint(mode: .maxX, members: [c.id, d.id]))]
        )).isEmpty)
        let minX = try check(Self.document(
            shapes: [c, d],
            constraints: [.alignment(LayoutAlignmentConstraint(mode: .minX, members: [c.id, d.id]))]
        ))
        #expect(try #require(minX.first).measured == 2)
    }

    @Test func alignmentToleranceAndSoftnessAreHonored() throws {
        let a = Self.shape(0, 0, 2, 2)
        let b = Self.shape(4, 1, 2, 2)

        // Deviation 1 within tolerance 1 passes.
        #expect(try check(Self.document(
            shapes: [a, b],
            constraints: [.alignment(LayoutAlignmentConstraint(
                mode: .minY, members: [a.id, b.id], tolerance: 1
            ))]
        )).isEmpty)

        // A soft constraint downgrades the verdict to a warning.
        let soft = try check(Self.document(
            shapes: [a, b],
            constraints: [.alignment(LayoutAlignmentConstraint(
                mode: .minY, members: [a.id, b.id], isHard: false
            ))]
        ))
        let violation = try #require(soft.first)
        #expect(violation.severity == .warning)
        #expect(
            violation.required == 1e-9,
            "a zero constraint tolerance falls back to the checker floor"
        )
    }

    // MARK: - Common centroid

    @Test func commonCentroidABBASatisfiedAndAABBBroken() throws {
        // Fingers at centers x = 1, 3, 5, 7 on one row.
        let fingers = [
            Self.shape(0, 0, 2, 2),
            Self.shape(2, 0, 2, 2),
            Self.shape(4, 0, 2, 2),
            Self.shape(6, 0, 2, 2),
        ]
        let ids = fingers.map(\.id)

        // ABBA: both groups centroid at x = 4 — the overall centroid.
        #expect(try check(Self.document(
            shapes: fingers,
            constraints: [.commonCentroid(LayoutCommonCentroidConstraint(
                members: ids, pattern: [0, 1, 1, 0]
            ))]
        )).isEmpty)

        // AABB: group A centroid x = 2, group B at 6 — both 2 off.
        let violations = try check(Self.document(
            shapes: fingers,
            constraints: [.commonCentroid(LayoutCommonCentroidConstraint(
                members: ids, pattern: [0, 0, 1, 1]
            ))]
        ))
        #expect(violations.count == 2)
        #expect(violations.allSatisfy { $0.kind == .centroidMismatch })
        #expect(violations.allSatisfy { $0.measured == 2 })
    }

    @Test func commonCentroidPatternRepeatsModulo() throws {
        // Pattern [0, 1] over four members labels them 0, 1, 0, 1; with
        // declared geometry order 1, 3, 7, 5 both groups centroid at 4.
        let fingers = [
            Self.shape(0, 0, 2, 2),
            Self.shape(2, 0, 2, 2),
            Self.shape(6, 0, 2, 2),
            Self.shape(4, 0, 2, 2),
        ]
        #expect(try check(Self.document(
            shapes: fingers,
            constraints: [.commonCentroid(LayoutCommonCentroidConstraint(
                members: fingers.map(\.id), pattern: [0, 1]
            ))]
        )).isEmpty)
    }

    @Test func commonCentroidSingleGroupIsMalformed() throws {
        let a = Self.shape(0, 0, 2, 2)
        let b = Self.shape(4, 0, 2, 2)
        let violations = try check(Self.document(
            shapes: [a, b],
            constraints: [.commonCentroid(LayoutCommonCentroidConstraint(
                members: [a.id, b.id], pattern: [0]
            ))]
        ))
        let violation = try #require(violations.first)
        #expect(violations.count == 1)
        #expect(violation.kind == .malformedConstraint)
    }

    // MARK: - Interdigitation

    @Test func interdigitationChecksPatternOrderAlongX() throws {
        // Declared order matches x order: labels 0, 1, 0, 1 left to right.
        let ordered = [
            Self.shape(0, 0, 2, 2),
            Self.shape(2, 0, 2, 2),
            Self.shape(4, 0, 2, 2),
            Self.shape(6, 0, 2, 2),
        ]
        #expect(try check(Self.document(
            shapes: ordered,
            constraints: [.interdigitated(LayoutInterdigitatedConstraint(
                members: ordered.map(\.id), pattern: [0, 1, 0, 1]
            ))]
        )).isEmpty)

        // Swapping the middle two geometries puts labels 0, 0, 1, 1 on
        // the x axis: positions 1 and 2 both mismatch.
        let swapped = [
            Self.shape(0, 0, 2, 2),
            Self.shape(4, 0, 2, 2),
            Self.shape(2, 0, 2, 2),
            Self.shape(6, 0, 2, 2),
        ]
        let violations = try check(Self.document(
            shapes: swapped,
            constraints: [.interdigitated(LayoutInterdigitatedConstraint(
                members: swapped.map(\.id), pattern: [0, 1, 0, 1]
            ))]
        ))
        #expect(violations.count == 2)
        #expect(violations.allSatisfy { $0.kind == .interdigitationOrderMismatch })
        #expect(Set(violations.flatMap(\.memberIDs)) == [swapped[1].id, swapped[2].id])
    }

    @Test func interdigitationSingleGroupIsMalformed() throws {
        let a = Self.shape(0, 0, 2, 2)
        let b = Self.shape(4, 0, 2, 2)
        let violations = try check(Self.document(
            shapes: [a, b],
            constraints: [.interdigitated(LayoutInterdigitatedConstraint(
                members: [a.id, b.id], pattern: [0]
            ))]
        ))
        let violation = try #require(violations.first)
        #expect(violations.count == 1)
        #expect(violation.kind == .malformedConstraint)
    }

    // MARK: - Instance members

    @Test func instanceMembersResolveToTransformedHierarchyBounds() throws {
        // Child UNIT spans (0,0)-(2,2); the instance translates it to
        // (8,0)-(10,2), center (9,1), mirroring the direct shape's center
        // (1,1) across the vertical line x = 5.
        let child = LayoutCell(name: "UNIT", shapes: [Self.shape(0, 0, 2, 2)])
        let instance = LayoutInstance(
            cellID: child.id,
            name: "u1",
            transform: LayoutTransform(translation: LayoutPoint(x: 8, y: 0))
        )
        let direct = Self.shape(0, 0, 2, 2)
        let fixture = Self.document(
            shapes: [direct],
            instances: [instance],
            constraints: [.symmetry(LayoutSymmetryConstraint(
                axis: .vertical,
                members: [direct.id, instance.id],
                axisPosition: 5
            ))],
            extraCells: [child]
        )
        #expect(try check(fixture).isEmpty)
    }

    // MARK: - Severity and constraint indexing

    @Test func softSymmetryReportsWarningsAndIndicesTrackTheArray() throws {
        let a = Self.shape(0, 0, 2, 2)
        let b = Self.shape(3, 0, 2, 2)
        let fixture = Self.document(
            shapes: [a, b],
            constraints: [
                .alignment(LayoutAlignmentConstraint(mode: .minX, members: [a.id, b.id])),
                .symmetry(LayoutSymmetryConstraint(
                    axis: .vertical,
                    members: [a.id, b.id],
                    axisPosition: 10,
                    isHard: false
                )),
            ]
        )
        let violations = try check(fixture)
        #expect(violations.count == 2)
        let alignment = try #require(violations.first { $0.kind == .alignmentMismatch })
        #expect(alignment.constraintIndex == 0)
        #expect(alignment.severity == .error)
        let symmetry = try #require(violations.first { $0.kind == .symmetryPairMismatch })
        #expect(symmetry.constraintIndex == 1)
        #expect(symmetry.severity == .warning)
    }

    @Test func unknownCellThrowsInsteadOfReportingClean() {
        let fixture = Self.document(shapes: [], constraints: [])
        #expect(throws: LayoutCoreError.self) {
            try LayoutConstraintChecker().check(document: fixture.document, cellID: UUID())
        }
    }

    // MARK: - Persistence

    @Test func alignmentConstraintRoundTripsThroughJSON() throws {
        let a = Self.shape(0, 0, 2, 2)
        let b = Self.shape(4, 0, 2, 2)
        let fixture = Self.document(
            shapes: [a, b],
            constraints: [
                .alignment(LayoutAlignmentConstraint(
                    mode: .centerY,
                    members: [a.id, b.id],
                    tolerance: 1,
                    isHard: false
                )),
                .symmetry(LayoutSymmetryConstraint(
                    axis: .vertical,
                    members: [a.id, b.id],
                    axisPosition: 3
                )),
            ]
        )
        let data = try JSONEncoder().encode(fixture.document)
        let decoded = try JSONDecoder().decode(LayoutDocument.self, from: data)
        let cell = try #require(decoded.cell(withID: fixture.cellID))
        #expect(cell.constraints == fixture.document.cell(withID: fixture.cellID)?.constraints)

        // The decoded document yields the same verdict.
        let original = try check(fixture)
        let reloaded = try LayoutConstraintChecker()
            .check(document: decoded, cellID: fixture.cellID)
        #expect(reloaded.count == original.count)
        #expect(reloaded.map(\.kind) == original.map(\.kind))
    }
}
