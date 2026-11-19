# ``SwiftXDSClient``

Publish, find, retrieve, replace, and withdraw documents in an XDS.b affinity
domain, over HTTP.

## Overview

``XDSClient`` runs the transactions of the Document Source, the Document
Consumer, and status updates, over a transport: ``XDSHTTPTransport`` uses
AsyncHTTPClient, and its `HTTPClient` carries the TLS configuration.
Documents are streamed in both directions.

| Transaction | Actor | Method |
| --- | --- | --- |
| ITI-41 Provide and Register Document Set-b, with RPLC | Document Source | `provideAndRegister(_:documents:to:)` |
| ITI-18 Registry Stored Query | Document Consumer | `query(_:registry:)`, `findDocuments(patientId:_:returnType:registry:)` |
| ITI-43 Retrieve Document Set | Document Consumer | `retrieve(_:from:)` |
| ITI-57 Update Document Set, status updates | Document Administrator | `deprecate(_:in:registry:)`, `updateDocumentSet(_:registry:)` |

Metadata updates that create a new version of an object (ITI-57), XDR, and
XCA are not implemented yet.

## Topics

### Essentials

- <doc:PublishingDocuments>
- <doc:FindingAndRetrievingDocuments>
- <doc:ReplacingAndWithdrawingDocuments>
- ``XDSClient``
- ``XDSHTTPTransport``
- ``XDSTransport``
- ``XDSClientError``

### Documents

- ``XDSDocument``
- ``XDSRetrieveResult``
- ``XDSRetrievedDocument``
