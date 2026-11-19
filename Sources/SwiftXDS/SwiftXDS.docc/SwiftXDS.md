# ``SwiftXDS``

Read, write, and validate IHE XDS.b metadata, with a hardened XML reader and
no network.

## Overview

`SwiftXDS` holds what every XDS.b actor shares:

- a hardened XML reader, ``XMLReader``, that refuses document type
  declarations and entity expansion and bounds size and depth, and a
  namespace-aware ``XMLWriter``, with no dependency beyond Foundation;
- the XDS metadata model: ``XDSObjectList`` with its ``XDSDocumentEntry``,
  ``XDSSubmissionSet``, and ``XDSFolder`` objects, associations, codes,
  authors, and CX, XCN, and XON values, read from and written to ebRIM 3.0;
- ``RegistryResponse``, with its status and errors;
- ``XDSValidator``, which checks what an actor must provide for its
  ``XDSMetadataRole``: a Document Source, a Document Repository, or an update;
- the stored queries of ITI-18 (``XDSStoredQuery``, ``XDSDocumentFilter``,
  ``XDSQueryResponse``) and the requests of ITI-43 (``XDSDocumentRequest``).

`SwiftXDSSOAP` adds the SOAP 1.2 envelope and MTOM/XOP packaging, and
`SwiftXDSClient` the transactions over HTTP.

### Limits on received XML

`XMLReader.Limits` bounds the size (64 MiB) and nesting depth (256) of a
document; document type declarations are always refused. Both bounds can be
configured.

### Conformance

SwiftXDS makes no claim of IHE conformance until it has been tested against
third-party actors, such as the NIST XDS Toolkit or Gazelle.

## Topics

### Metadata

- ``XDSObjectList``
- ``XDSDocumentEntry``
- ``XDSSubmissionSet``
- ``XDSFolder``
- ``CXIdentifier``
- ``RegistryResponse``

### Validation

- ``XDSValidator``
- ``XDSMetadataRole``

### Queries and retrieval

- ``XDSStoredQuery``
- ``XDSDocumentFilter``
- ``XDSQueryResponse``
- ``XDSDocumentRequest``

### XML

- ``XMLReader``
- ``XMLWriter``
- ``XElement``

### Transactions

- ``XDSTransaction``
