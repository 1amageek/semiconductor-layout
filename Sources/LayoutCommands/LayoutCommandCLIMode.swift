public enum LayoutCommandCLIMode: Sendable, Equatable {
    case runRequest(String)
    case emitActionDomain
    case convertDocument(LayoutDocumentConversionRequest)
    case inspectDocument(LayoutDocumentInspectionRequest)
    case diagnoseConnectivity(LayoutConnectivityDiagnosisRequest)
}
