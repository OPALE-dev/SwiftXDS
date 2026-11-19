# ``SwiftXDSSOAP``

Write and read SOAP 1.2 envelopes with WS-Addressing, and stream MTOM/XOP
messages in both directions.

## Overview

`SwiftXDSSOAP` follows IHE ITI TF-2 Appendix V: ``SOAPEnvelope`` carries the
WS-Addressing headers and the payload, ``SOAPFault`` the faults, and
``MTOMWriter`` and ``MTOMReader`` the `multipart/related` packaging, streamed
so that large documents never have to sit in memory. It sends nothing over
HTTP: `SwiftXDSClient` does.

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

### Limits on received messages

``MultipartLimits`` bounds the number of parts (10,000), the header size of a
part (16 KiB), the size of each part (4 GiB), and the size of the whole
message (16 GiB). All of them can be configured. Only the `binary`, `8bit`,
and `7bit` transfer encodings are accepted, as MTOM requires.

The tests read messages in the shape that Apache Axis2, Apache CXF, and .NET
WCF produce, byte for byte.

## Topics

### Envelopes

- ``SOAPEnvelope``
- ``SOAPFault``
- ``SOAPMessage``

### MTOM/XOP

- ``MTOMWriter``
- ``MTOMReader``
- ``MTOMAttachment``
- ``MTOMFileStore``
- ``MultipartLimits``
