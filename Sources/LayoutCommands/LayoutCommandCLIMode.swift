public enum LayoutCommandCLIMode: Sendable, Equatable {
    case runRequest(String)
    case emitActionDomain
    case convertDocument(LayoutDocumentConversionRequest)
    case inspectDocument(LayoutDocumentInspectionRequest)
    case validateConstraints(LayoutConstraintValidationRequest)
    case diagnoseConnectivity(LayoutConnectivityDiagnosisRequest)
}
