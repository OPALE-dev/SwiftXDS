/// IHE transactions and their WS-Addressing actions (ITI TF-2).
public enum XDSTransaction: String, Sendable, Hashable, CaseIterable {
    case provideAndRegister = "ITI-41"
    case register = "ITI-42"
    case registryStoredQuery = "ITI-18"
    case retrieveDocumentSet = "ITI-43"
    case updateDocumentSet = "ITI-57"

    public var requestAction: String {
        switch self {
        case .provideAndRegister: "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b"
        case .register: "urn:ihe:iti:2007:RegisterDocumentSet-b"
        case .registryStoredQuery: "urn:ihe:iti:2007:RegistryStoredQuery"
        case .retrieveDocumentSet: "urn:ihe:iti:2007:RetrieveDocumentSet"
        case .updateDocumentSet: "urn:ihe:iti:2010:UpdateDocumentSet"
        }
    }

    public var responseAction: String { requestAction + "Response" }

    /// Transactions that carry documents use MTOM in both directions (ITI-41, ITI-43); the others
    /// may use plain SOAP. SwiftXDS sends MTOM for ITI-41 and ITI-43, plain SOAP otherwise.
    public var usesMTOM: Bool { self == .provideAndRegister || self == .retrieveDocumentSet }

    public init?(requestAction: String) {
        guard let t = Self.allCases.first(where: { $0.requestAction == requestAction }) else { return nil }
        self = t
    }
}

/// Element names of the XDS.b messages.
public enum XDSMessage {
    public static let provideAndRegisterRequest = XName(Namespace.xdsb, "ProvideAndRegisterDocumentSetRequest")
    public static let document = XName(Namespace.xdsb, "Document")
    public static let retrieveRequest = XName(Namespace.xdsb, "RetrieveDocumentSetRequest")
    public static let retrieveResponse = XName(Namespace.xdsb, "RetrieveDocumentSetResponse")
    public static let documentRequest = XName(Namespace.xdsb, "DocumentRequest")
    public static let documentResponse = XName(Namespace.xdsb, "DocumentResponse")
    public static let homeCommunityId = XName(Namespace.xdsb, "HomeCommunityId")
    public static let repositoryUniqueId = XName(Namespace.xdsb, "RepositoryUniqueId")
    public static let documentUniqueId = XName(Namespace.xdsb, "DocumentUniqueId")
    public static let mimeType = XName(Namespace.xdsb, "mimeType")
    public static let submitObjectsRequest = XName(Namespace.lcm, "SubmitObjectsRequest")
    public static let registryResponse = XName(Namespace.rs, "RegistryResponse")
    public static let registryObjectList = XName(Namespace.rim, "RegistryObjectList")
}
