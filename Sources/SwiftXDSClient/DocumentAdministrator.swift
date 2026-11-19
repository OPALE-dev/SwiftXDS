import Foundation
import SwiftXDS
import SwiftXDSSOAP

extension XDSClient {
    /// Update Responsible Document Source / Document Administrator: Update Document Set (ITI-57),
    /// sent to the registry. Metadata that would be refused is reported first, as
    /// `XDSClientError.invalidMetadata`, without sending.
    public func updateDocumentSet(_ update: XDSObjectList, registry: URL) async throws -> RegistryResponse {
        if validatesMetadata {
            let issues = XDSValidator.validate(update, as: .updateDocumentSet)
            guard issues.isEmpty else { throw XDSClientError.invalidMetadata(issues) }
        }
        let response = try await call(.updateDocumentSet, to: registry, payload: update.submitObjectsRequest)
        guard let payload = response.envelope.payload, payload.name == XDSMessage.registryResponse else {
            throw XDSClientError.unexpectedResponse(response.envelope.payload?.name)
        }
        return try RegistryResponse(element: payload)
    }

    /// Withdraws documents: Approved → Deprecated (ITI-57). `set` describes the update (patient,
    /// source, author, content type); its time is set to now when missing.
    public func deprecate(_ entryUUIDs: [String], in set: XDSSubmissionSet, registry: URL) async throws -> RegistryResponse {
        try await updateDocumentSet(.statusUpdate(entryUUIDs, in: set), registry: registry)
    }
}
