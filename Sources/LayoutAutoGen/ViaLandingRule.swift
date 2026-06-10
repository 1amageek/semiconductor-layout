import LayoutTech

/// Sizes via landing pads against metal-layer rules.
///
/// A landing pad inherits its side from the cut size plus enclosure; on
/// processes where the minimum metal area or width exceeds that footprint,
/// an isolated pad (at a route bend or trunk endpoint) is a violation the
/// router itself manufactured. Widening the enclosure to the rule-derived
/// side keeps every emitted pad legal on its own, without relying on a
/// neighbouring wire or pin pad to merge it above the threshold.
enum ViaLandingRule {

    /// Returns a copy of `viaDef` whose enclosures guarantee that both
    /// landing pads satisfy the minimum width and minimum area of their
    /// metal layers.
    static func sized(
        _ viaDef: LayoutViaDefinition,
        bottomRules: LayoutLayerRuleSet,
        topRules: LayoutLayerRuleSet
    ) -> LayoutViaDefinition {
        var adjusted = viaDef
        adjusted.enclosure.bottom = enclosureSatisfying(
            rules: bottomRules,
            cut: viaDef.cutSize.width,
            enclosure: viaDef.enclosure.bottom
        )
        adjusted.enclosure.top = enclosureSatisfying(
            rules: topRules,
            cut: viaDef.cutSize.width,
            enclosure: viaDef.enclosure.top
        )
        return adjusted
    }

    private static func enclosureSatisfying(
        rules: LayoutLayerRuleSet,
        cut: Double,
        enclosure: Double
    ) -> Double {
        let requiredSide = max(rules.minWidth, rules.minArea.squareRoot())
        return max(enclosure, (requiredSide - cut) / 2)
    }
}
