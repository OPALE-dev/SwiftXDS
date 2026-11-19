import Foundation
import SwiftXDS
import SwiftXDSSOAP

/// A document to publish, linked to its DocumentEntry by `entryUUID`.
public struct XDSDocument: Sendable {
    public var entryUUID: String
    public var body: MTOMAttachment.Body

    public init(entryUUID: String, body: MTOMAttachment.Body) {
        self.entryUUID = entryUUID
        self.body = body
    }

    public init(entryUUID: String, data: Data) {
        self.init(entryUUID: entryUUID, body: .data(data))
    }
}

extension XDSClient {
    /// Document Source: Provide and Register Document Set-b (ITI-41).
    ///
    /// Sends the submission with its documents as MTOM parts to the repository. The registry's
    /// answer is returned as is: check `isSuccess`, `errors` hold the reasons of a failure. Metadata
    /// that would be refused is reported first, as `XDSClientError.invalidMetadata`, without sending.
    public func provideAndRegister(_ submission: XDSObjectList, documents: [XDSDocument],
                                   to repository: URL) async throws -> RegistryResponse {
        let request = try Self.provideAndRegisterRequest(submission, documents: documents, validate: validatesMetadata)
        let response = try await call(.provideAndRegister, to: repository, payload: request.payload, attachments: request.attachments)
        guard let payload = response.envelope.payload, payload.name == XDSMessage.registryResponse else {
            throw XDSClientError.unexpectedResponse(response.envelope.payload?.name)
        }
        return try RegistryResponse(element: payload)
    }

    /// The ITI-41 request body and its MTOM parts.
    public static func provideAndRegisterRequest(_ submission: XDSObjectList, documents: [XDSDocument],
                                                 validate: Bool = true) throws -> (payload: XElement, attachments: [MTOMAttachment]) {
        if validate {
            let issues = XDSValidator.validate(submission, as: .documentSource)
            guard issues.isEmpty else { throw XDSClientError.invalidMetadata(issues) }
        }
        let entries = Dictionary(submission.documentEntries.map { ($0.entryUUID, $0) }, uniquingKeysWith: { a, _ in a })
        var given: Set<String> = []
        for d in documents where !given.insert(d.entryUUID).inserted { throw XDSClientError.duplicateDocument(entryUUID: d.entryUUID) }
        for id in entries.keys.sorted() where !given.contains(id) { throw XDSClientError.missingDocument(entryUUID: id) }
        var payload = XElement(XDSMessage.provideAndRegisterRequest, elements: [submission.submitObjectsRequest])
        var attachments: [MTOMAttachment] = []
        for document in documents {
            guard let entry = entries[document.entryUUID] else { throw XDSClientError.unknownDocument(entryUUID: document.entryUUID) }
            let contentID = MTOMAttachment.newContentID()
            payload.append(XElement(XDSMessage.document, attributes: [XAttribute(XName("id"), document.entryUUID)],
                                    elements: [XOP.include(contentID: contentID)]))
            attachments.append(MTOMAttachment(contentID: contentID, contentType: entry.mimeType, body: document.body))
        }
        return (payload, attachments)
    }
}
