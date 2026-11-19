import Foundation

/// One document asked for in a Retrieve Document Set (ITI-43).
public struct XDSDocumentRequest: Hashable, Sendable {
    public var homeCommunityId: String?
    public var repositoryUniqueId: String
    public var documentUniqueId: String

    public init(repositoryUniqueId: String, documentUniqueId: String, homeCommunityId: String? = nil) {
        self.repositoryUniqueId = repositoryUniqueId
        self.documentUniqueId = documentUniqueId
        self.homeCommunityId = homeCommunityId
    }

    /// The request for a DocumentEntry found by a query.
    public init?(_ entry: XDSDocumentEntry) {
        guard let repository = entry.repositoryUniqueId else { return nil }
        self.init(repositoryUniqueId: repository, documentUniqueId: entry.uniqueId, homeCommunityId: entry.homeCommunityId)
    }

    public var element: XElement {
        var children: [XElement] = []
        if let homeCommunityId { children.append(XElement(XDSRetrieve.homeCommunityId, text: homeCommunityId)) }
        children.append(XElement(XDSRetrieve.repositoryUniqueId, text: repositoryUniqueId))
        children.append(XElement(XDSRetrieve.documentUniqueId, text: documentUniqueId))
        return XElement(XDSRetrieve.documentRequest, elements: children)
    }

    public init(element e: XElement) throws {
        guard let repository = e.element(named: XDSRetrieve.repositoryUniqueId)?.trimmedText, !repository.isEmpty else {
            throw XDSMetadataError.missingAttribute(element: "DocumentRequest", attribute: "RepositoryUniqueId")
        }
        guard let document = e.element(named: XDSRetrieve.documentUniqueId)?.trimmedText, !document.isEmpty else {
            throw XDSMetadataError.missingAttribute(element: "DocumentRequest", attribute: "DocumentUniqueId")
        }
        self.init(repositoryUniqueId: repository, documentUniqueId: document,
                  homeCommunityId: e.element(named: XDSRetrieve.homeCommunityId)?.trimmedText)
    }
}

/// The description of one returned document; the document itself is the `Document` child, an
/// MTOM part (`xop:Include`) or base64 text.
public struct XDSDocumentResponse: Hashable, Sendable {
    public var homeCommunityId: String?
    public var repositoryUniqueId: String
    public var documentUniqueId: String
    /// Set when the repository returns another document than the one asked (On-Demand).
    public var newRepositoryUniqueId: String?
    public var newDocumentUniqueId: String?
    public var mimeType: String

    public init(repositoryUniqueId: String, documentUniqueId: String, mimeType: String, homeCommunityId: String? = nil) {
        self.repositoryUniqueId = repositoryUniqueId
        self.documentUniqueId = documentUniqueId
        self.mimeType = mimeType
        self.homeCommunityId = homeCommunityId
    }

    /// The `DocumentResponse` element, the document given as its `Document` child.
    public func element(document: XElement) -> XElement {
        var children: [XElement] = []
        if let homeCommunityId { children.append(XElement(XDSRetrieve.homeCommunityId, text: homeCommunityId)) }
        children.append(XElement(XDSRetrieve.repositoryUniqueId, text: repositoryUniqueId))
        children.append(XElement(XDSRetrieve.documentUniqueId, text: documentUniqueId))
        if let newRepositoryUniqueId { children.append(XElement(XDSRetrieve.newRepositoryUniqueId, text: newRepositoryUniqueId)) }
        if let newDocumentUniqueId { children.append(XElement(XDSRetrieve.newDocumentUniqueId, text: newDocumentUniqueId)) }
        children.append(XElement(XDSRetrieve.mimeType, text: mimeType))
        children.append(document)
        return XElement(XDSRetrieve.documentResponse, elements: children)
    }

    public init(element e: XElement) throws {
        func text(_ n: XName) -> String? { e.element(named: n)?.trimmedText }
        guard let repository = text(XDSRetrieve.repositoryUniqueId), let document = text(XDSRetrieve.documentUniqueId) else {
            throw XDSMetadataError.missingAttribute(element: "DocumentResponse", attribute: "RepositoryUniqueId and DocumentUniqueId")
        }
        guard let mimeType = text(XDSRetrieve.mimeType) else {
            throw XDSMetadataError.missingAttribute(element: "DocumentResponse", attribute: "mimeType")
        }
        self.init(repositoryUniqueId: repository, documentUniqueId: document, mimeType: mimeType, homeCommunityId: text(XDSRetrieve.homeCommunityId))
        newRepositoryUniqueId = text(XDSRetrieve.newRepositoryUniqueId)
        newDocumentUniqueId = text(XDSRetrieve.newDocumentUniqueId)
    }
}

/// Element names of ITI-43.
public enum XDSRetrieve {
    public static let request = XName(Namespace.xdsb, "RetrieveDocumentSetRequest")
    public static let response = XName(Namespace.xdsb, "RetrieveDocumentSetResponse")
    public static let documentRequest = XName(Namespace.xdsb, "DocumentRequest")
    public static let documentResponse = XName(Namespace.xdsb, "DocumentResponse")
    public static let document = XName(Namespace.xdsb, "Document")
    public static let homeCommunityId = XName(Namespace.xdsb, "HomeCommunityId")
    public static let repositoryUniqueId = XName(Namespace.xdsb, "RepositoryUniqueId")
    public static let documentUniqueId = XName(Namespace.xdsb, "DocumentUniqueId")
    public static let newRepositoryUniqueId = XName(Namespace.xdsb, "NewRepositoryUniqueId")
    public static let newDocumentUniqueId = XName(Namespace.xdsb, "NewDocumentUniqueId")
    public static let mimeType = XName(Namespace.xdsb, "mimeType")

    public static func requestElement(_ requests: [XDSDocumentRequest]) -> XElement {
        XElement(request, elements: requests.map(\.element))
    }

    public static func requests(in e: XElement) throws -> [XDSDocumentRequest] {
        guard e.name == request else { throw XDSMetadataError.unexpectedElement(e.name) }
        return try e.elements(named: documentRequest).map(XDSDocumentRequest.init(element:))
    }

    /// The response element: the registry response, then one `DocumentResponse` per document.
    public static func responseElement(_ response: RegistryResponse, documents: [XElement]) -> XElement {
        XElement(Self.response, elements: [response.element] + documents)
    }
}
