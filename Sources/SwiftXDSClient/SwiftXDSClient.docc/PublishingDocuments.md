# Publishing Documents

Send documents and their metadata to a repository (ITI-41).

## Overview

A submission is an `XDSObjectList` with a submission set and its document
entries. Each document is an ``XDSDocument`` sent as an MTOM part, from memory
or from a file:

```swift
import SwiftXDSClient

let client = XDSClient(transport: XDSHTTPTransport(client: httpClient))
let response = try await client.provideAndRegister(
    .submission(submissionSet, documents: [documentEntry]),
    documents: [XDSDocument(entryUUID: documentEntry.entryUUID, body: .file(kosURL))],
    to: repositoryURL)
guard response.isSuccess else { throw RegistryRefusal(response.errors) }
```

By default, the client validates the metadata of a Document Source before it
sends anything (`validatesMetadata`), with `XDSValidator`. The registry's
answer is a `RegistryResponse`: a refusal is an answer, not an error, and
its `errors` carry the registry's error codes.

### Security headers and TLS

National profiles, such as the French DMP, are left to the application.
Security assertions (for example a VIHF) come from the `headers` function of
``XDSClient``, called for each transaction: its `XDSRequestHeaders` hold
elements, or raw blocks written verbatim in the SOAP header, which keeps a
signature valid. Extra documents, such as signatures, are added to the
submission. TLS, including client certificates,
is the configuration of the `HTTPClient` given to ``XDSHTTPTransport``.
