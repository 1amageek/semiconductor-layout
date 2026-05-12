import LayoutCore
import LayoutTech

extension LayoutTechDatabase {
    func requiredRuleSet(for id: LayoutLayerID) throws -> LayoutLayerRuleSet {
        guard let ruleSet = ruleSet(for: id) else {
            throw AutoGenError.missingLayerRule(id.name)
        }
        return ruleSet
    }

    func requiredEnclosureRule(
        outer outerID: LayoutLayerID,
        inner innerID: LayoutLayerID
    ) throws -> LayoutEnclosureRule {
        guard let rule = enclosureRule(outer: outerID, inner: innerID) else {
            throw AutoGenError.missingEnclosureRule(outer: outerID.name, inner: innerID.name)
        }
        return rule
    }
}
