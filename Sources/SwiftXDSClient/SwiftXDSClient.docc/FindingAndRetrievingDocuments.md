# Finding and Retrieving Documents

Query a registry (ITI-18), then retrieve documents from their repositories
(ITI-43).

## Overview

`findDocuments(patientId:_:returnType:registry:)` runs the FindDocuments
stored query; `query(_:registry:)` runs any stored query by its identifier,
such as GetDocuments or GetSubmissionSetAndContents:

```swift
let found = try await client.findDocuments(patientId: patientId, registry: registryURL)
let requests = found.objects.documentEntries.compactMap(XDSDocumentRequest.init)
let result = try await client.retrieve(requests, from: repositoryURL)
for document in result.documents { try await store(document.info, document.data()) }
```

An `XDSDocumentFilter` narrows FindDocuments: values within one slot are
combined with OR, slots with AND; time ranges include their lower bound and
exclude their upper bound; `%` and `_` are wildcards in LIKE values. Only
entries with the Approved status are returned unless the filter asks for
others. Answers are LeafClass (full metadata) or ObjectRef (identifiers
only).

### Partial retrievals

A retrieval may succeed partially: ``XDSRetrieveResult`` holds the documents
received, the registry's errors, and the `problems` found by the client, such
as a document whose hash or size does not match its entry; `isComplete` tells
whether every requested document arrived intact. `matches(_:)` checks one
``XDSRetrievedDocument`` against its document entry.

With `XDSHTTPTransport(client:store:)` and an `MTOMFileStore`, retrieved
documents are written to files as they arrive.
