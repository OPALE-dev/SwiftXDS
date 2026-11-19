# SwiftXDS

[![CI](https://github.com/OPALE-dev/SwiftXDS/actions/workflows/ci.yml/badge.svg)](https://github.com/OPALE-dev/SwiftXDS/actions/workflows/ci.yml)
[![CodeQL](https://github.com/OPALE-dev/SwiftXDS/actions/workflows/codeql.yml/badge.svg)](https://github.com/OPALE-dev/SwiftXDS/actions/workflows/codeql.yml)
[![Documentation](https://github.com/OPALE-dev/SwiftXDS/actions/workflows/documentation.yml/badge.svg)](https://opale-dev.github.io/SwiftXDS/documentation/)
[![Release](https://img.shields.io/github/v/release/OPALE-dev/SwiftXDS)](https://github.com/OPALE-dev/SwiftXDS/releases/latest)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

IHE **XDS.b** cross-enterprise document sharing in Swift, for macOS, iOS, and Linux.

SwiftXDS gives a Swift application the pieces it needs to publish, find, retrieve and update
documents in an XDS.b affinity domain:

- **SOAP 1.2** envelopes, **WS-Addressing** headers and SOAP faults, following IHE ITI TF-2
  Appendix V;
- **MTOM/XOP** packaging (`multipart/related`), streamed in both directions so that large documents
  never have to sit in memory;
- a hardened XML reader (no DTD, no entity expansion, bounded size and depth) and a namespace-aware
  writer, with no dependency beyond Foundation;
- the **XDS metadata model** (DocumentEntry, SubmissionSet, Folder, associations, codes, authors,
  CX/XCN/XON values), read from and written to **ebRIM 3.0**, with `RegistryResponse` and
  validation of what a Document Source or a Document Repository must provide;
- the **Document Source** (ITI-41 Provide and Register Document Set-b) and **Document Consumer**
  (ITI-18 Registry Stored Query, ITI-43 Retrieve Document Set) transactions over HTTP, with
  documents streamed in both directions;
- **replacement** of a document (RPLC in ITI-41) and **withdrawal** by status update (ITI-57
  Update Document Set);
- an **in-memory registry and repository** with an HTTP server, for tests and simulators.

Not yet: metadata updates that create a new version of an object (ITI-57), XDR, XCA.

National profiles such as the French DMP are left to the application. Extension points let it add
SOAP headers (security assertions), extra documents (signatures) and its own TLS configuration.

SwiftXDS is developed by [OPALE](https://www.opale.fr) for its PACS, and is meant to be useful to
any Swift healthcare application. It makes no claim of IHE conformance until it has been tested
against third-party actors, such as the NIST XDS Toolkit or Gazelle. Before 1.0, minor versions may
change the API.

> **Disclaimer.** SwiftXDS is not a medical device. The authors cannot be held responsible for its
> misuse or malfunction, as stated in the [license](LICENSE).

## Status

| Part | State |
|---|---|
| XML reader and writer | Done |
| SOAP 1.2, WS-Addressing, faults | Done |
| MTOM/XOP writer and streaming reader | Done |
| XDS metadata, ebRIM 3.0, registry responses, validation by actor | Done |
| ITI-41 Provide and Register (Document Source) over HTTP | Done |
| ITI-18 Registry Stored Query (FindDocuments, GetDocuments, GetSubmissionSetAndContents; any query by ID) and ITI-43 Retrieve Document Set (Document Consumer) | Done |
| Replacement (RPLC) and ITI-57 status updates (Approved ↔ Deprecated) | Done |
| ITI-57 metadata updates (new versions) | Planned |
| Test registry and repository, HTTP test server (ITI-41 with RPLC, ITI-18, ITI-43, ITI-57 status updates) | Done |

## Requirements

- Swift 6.2 or later;
- macOS 13, iOS 16, or Linux (tested with the official `swift` images).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/OPALE-dev/SwiftXDS.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SwiftXDSClient", package: "SwiftXDS"),
    ]),
]
```

## Use

The [documentation](https://opale-dev.github.io/SwiftXDS/documentation/) has a guide for each
transaction.

The products are `SwiftXDS` (XML and metadata, no network), `SwiftXDSSOAP` (envelope and MTOM,
no HTTP), `SwiftXDSClient` (transactions over AsyncHTTPClient) and `SwiftXDSTestRegistry`
(in-memory registry and repository with an HTTP server, for tests and simulators).

```swift
import SwiftXDSClient

let client = XDSClient(transport: XDSHTTPTransport(client: httpClient)) // TLS: the HTTPClient's configuration
let response = try await client.provideAndRegister(
    .submission(submissionSet, documents: [documentEntry]),
    documents: [XDSDocument(entryUUID: documentEntry.entryUUID, body: .file(kosURL))],
    to: repositoryURL)
guard response.isSuccess else { throw RegistryRefusal(response.errors) }
```

Finding and retrieving:

```swift
let found = try await client.findDocuments(patientId: patientId, registry: registryURL)
let requests = found.objects.documentEntries.compactMap(XDSDocumentRequest.init)
let result = try await client.retrieve(requests, from: repositoryURL)   // partialSuccess: see result.response.errors
for document in result.documents { try await store(document.info, document.data()) }
```

Replacing and withdrawing:

```swift
let v2 = XDSObjectList.replacement(of: current.entryUUID, by: newEntry, in: submissionSet)
_ = try await client.provideAndRegister(v2, documents: [XDSDocument(entryUUID: newEntry.entryUUID, data: kos)], to: repositoryURL)
_ = try await client.deprecate([v2EntryUUID], in: updateSet, registry: registryURL)   // ITI-57
```

With `XDSHTTPTransport(client:store: MTOMFileStore(directory:))`, retrieved documents are written to
files as they arrive.

Security assertions (for example the French DMP's VIHF) come from the `headers` function of
`XDSClient`, called for each transaction; raw blocks are written verbatim, which keeps a signature
valid.

```swift
import SwiftXDS
import SwiftXDSSOAP

// A request with one document sent as an MTOM part.
let id = MTOMAttachment.newContentID()
let document = XElement(XName(Namespace.xdsb, "Document"),
                        attributes: [XAttribute(XName("id"), "Document01")],
                        elements: [XOP.include(contentID: id)])
let envelope = SOAPEnvelope(
    addressing: .request(action: "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b",
                         to: "https://repository.example/xds/iti41"),
    payload: XElement(XName(Namespace.xdsb, "ProvideAndRegisterDocumentSetRequest"), elements: [document]))
let message = SOAPMessage(envelope: envelope, attachments: [
    MTOMAttachment(contentID: id, contentType: "application/dicom", body: .file(kosURL)),
])

let writer = MTOMWriter(action: "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b")
// HTTP Content-Type: writer.contentType.description
try await writer.write(message) { chunk in try await send(chunk) }

// Reading a response as it arrives, attachments written to files:
let response = try await MTOMReader().read(chunks: body, contentType: contentType,
                                           store: MTOMFileStore(directory: spool))
if let fault = try response.envelope.fault() { throw fault }
```

## Limits applied to received messages

`XMLReader.Limits` bounds the size (64 MiB) and nesting depth (256) of envelopes, and document type
declarations are always refused. `MultipartLimits` bounds:
- the number of parts (10,000);
- the header size of a part (16 KiB);
- the size of each part (4 GiB);
- the size of the whole message (16 GiB).

All of these can be configured. Only `binary`, `8bit` and `7bit` transfer encodings are accepted, as
MTOM requires.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md):

```sh
swift build --build-tests && swift test --skip-build
```

The CI runs the tests on Linux (`swift:6.2-jammy`), macOS, and iOS. Report vulnerabilities as
described in [SECURITY.md](SECURITY.md). Changes are listed in the [changelog](CHANGELOG.md).

## License

SwiftXDS is released under the [MIT License](LICENSE). Copyright (c) 2026 OPALE,
https://www.opale.fr.
