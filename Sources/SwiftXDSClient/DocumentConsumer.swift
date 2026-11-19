import Foundation
import SwiftXDS
import SwiftXDSSOAP

/// A retrieved document: its description and its content. With `XDSHTTPTransport.store` set to an
/// `MTOMFileStore`, an MTOM part is a file written while it arrived; base64 content sent in the
/// element (peers without MTOM) is decoded in memory.
public struct XDSRetrievedDocument: Sendable {
    public var info: XDSDocumentResponse
    public var attachment: MTOMAttachment

    public init(info: XDSDocumentResponse, attachment: MTOMAttachment) {
        self.info = info
        self.attachment = attachment
    }

    public func data() async throws -> Data { try await attachment.data() }

    /// Whether the content has the `hash` and `size` of its DocumentEntry, read in chunks.
    public func matches(_ entry: XDSDocumentEntry) async throws -> Bool {
        let d = try await XDSHash.digest(of: attachment.body)
        return entry.hash?.lowercased() == d.hash && entry.size == d.size
    }
}

/// A `DocumentResponse` the client could not use, with the reason.
public struct XDSRetrieveProblem: Hashable, Sendable, CustomStringConvertible {
    public var documentUniqueId: String
    public var reason: String

    public init(documentUniqueId: String, reason: String) {
        self.documentUniqueId = documentUniqueId
        self.reason = reason
    }

    public var description: String { "\(documentUniqueId): \(reason)" }
}

/// The answer to a Retrieve Document Set: the repository's status and errors (`partialSuccess`
/// when some documents were not returned), the documents returned, and the responses the client
/// set aside (content missing or invalid, document not asked for).
public struct XDSRetrieveResult: Sendable {
    public var response: RegistryResponse
    public var documents: [XDSRetrievedDocument]
    public var problems: [XDSRetrieveProblem]

    public init(response: RegistryResponse, documents: [XDSRetrievedDocument], problems: [XDSRetrieveProblem] = []) {
        self.response = response
        self.documents = documents
        self.problems = problems
    }

    /// Every document asked for was returned and usable.
    public var isComplete: Bool { response.isSuccess && problems.isEmpty }
}

extension XDSClient {
    /// Document Consumer: Registry Stored Query (ITI-18). A failure of the registry is returned in
    /// `response`, not thrown.
    public func query(_ query: XDSStoredQuery, registry: URL) async throws -> XDSQueryResponse {
        let reply = try await call(.registryStoredQuery, to: registry, payload: query.element)
        guard let payload = reply.envelope.payload, payload.name == XDSQueryResponse.name else {
            throw XDSClientError.unexpectedResponse(reply.envelope.payload?.name)
        }
        return try XDSQueryResponse(element: payload)
    }

    /// FindDocuments for a patient (Approved documents by default).
    public func findDocuments(patientId: CXIdentifier, _ filter: XDSDocumentFilter = XDSDocumentFilter(),
                              returnType: XDSReturnType = .leafClass, registry: URL) async throws -> XDSQueryResponse {
        try await query(.findDocuments(patientId: patientId, filter, returnType: returnType), registry: registry)
    }

    /// Document Consumer: Retrieve Document Set (ITI-43). One unusable `DocumentResponse` does not
    /// discard the others: it is listed in `problems`.
    public func retrieve(_ requests: [XDSDocumentRequest], from repository: URL) async throws -> XDSRetrieveResult {
        let reply = try await call(.retrieveDocumentSet, to: repository, payload: XDSRetrieve.requestElement(requests))
        guard let payload = reply.envelope.payload, payload.name == XDSRetrieve.response else {
            throw XDSClientError.unexpectedResponse(reply.envelope.payload?.name)
        }
        let response = try RegistryResponse(element: payload)
        let asked = Set(requests.map { [$0.repositoryUniqueId, $0.documentUniqueId] })
        var documents: [XDSRetrievedDocument] = []
        var problems: [XDSRetrieveProblem] = []
        for e in payload.elements(named: XDSRetrieve.documentResponse) {
            let info: XDSDocumentResponse
            do { info = try XDSDocumentResponse(element: e) } catch {
                problems.append(XDSRetrieveProblem(documentUniqueId: e.element(named: XDSRetrieve.documentUniqueId)?.trimmedText ?? "", reason: "\(error)"))
                continue
            }
            func problem(_ reason: String) { problems.append(XDSRetrieveProblem(documentUniqueId: info.documentUniqueId, reason: reason)) }
            guard asked.contains([info.repositoryUniqueId, info.documentUniqueId]) else {
                problem("not asked for (repository \(info.repositoryUniqueId))")
                continue
            }
            guard let document = e.element(named: XDSRetrieve.document) else {
                problem("no Document element")
                continue
            }
            if document.element(named: XOP.includeName) != nil {
                guard let attachment = reply.attachment(referencedBy: document) else {
                    problem("xop:Include names no MTOM part")
                    continue
                }
                documents.append(XDSRetrievedDocument(info: info, attachment: attachment))
            } else {
                // Base64 in the element, from a peer that does not use MTOM: whitespace only allowed.
                let text = document.text.filter { !$0.isWhitespace }
                guard !text.isEmpty, let data = Data(base64Encoded: text) else {
                    problem(text.isEmpty ? "empty content" : "content is not valid base64")
                    continue
                }
                documents.append(XDSRetrievedDocument(info: info, attachment: MTOMAttachment(contentID: "inline", contentType: info.mimeType, data: data)))
            }
        }
        return XDSRetrieveResult(response: response, documents: documents, problems: problems)
    }
}
