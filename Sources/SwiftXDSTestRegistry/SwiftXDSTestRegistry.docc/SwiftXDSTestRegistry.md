# ``SwiftXDSTestRegistry``

An in-memory XDS.b registry and repository, with a small HTTP server, for
tests and simulators.

## Overview

``XDSTestRegistry`` answers ITI-41 (with replacements), ITI-18, ITI-43, and
the status updates of ITI-57, and keeps its documents in memory.
``XDSTestServer`` serves it over plain HTTP on the loopback interface, so that
an application can run its real client code against it:

```swift
import SwiftXDSTestRegistry

let registry = XDSTestRegistry()
let server = try await XDSTestServer.start(registry: registry)   // a free port
defer { Task { await server.stop() } }

let client = XDSClient(transport: XDSHTTPTransport(client: httpClient))
let found = try await client.findDocuments(patientId: patient, registry: server.url)
```

`setKnownPatients(_:)` restricts the patients the registry accepts, to test
the refusal of an unknown patient. `XDSTestServer.Limits` bounds the request
size and the number of connections; `errors` lists what the server refused.

The registry is strict: it applies the validation of a Document Repository
and of the registry to what it receives. It is not a reference
implementation, and passing tests against it proves no IHE conformance. It is
not meant for production use.

## Topics

### Registry

- ``XDSTestRegistry``
- ``XDSTestServer``
