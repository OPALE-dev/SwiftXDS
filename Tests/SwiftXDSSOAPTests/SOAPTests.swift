import Foundation
import Testing
import SwiftXDS
@testable import SwiftXDSSOAP

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct SOAPEnvelopeTests {
    @Test func readsAnITI41RequestEnvelope() throws {
        let envelope = try SOAPEnvelope(data: fixture("iti41-envelope.xml"))
        let wsa = try #require(envelope.addressing)
        #expect(wsa.action == "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b")
        #expect(wsa.messageID == "urn:uuid:9376254e-da05-41f5-9af3-ac56d63d8ebd")
        #expect(wsa.replyTo == WSAddressing.anonymous)
        #expect(wsa.to == "https://repository.example.invalid/xds/iti41")
        let payload = try #require(envelope.payload)
        #expect(payload.name == XName(Namespace.xdsb, "ProvideAndRegisterDocumentSetRequest"))
        let document = try #require(payload.element(named: XName(Namespace.xdsb, "Document")))
        #expect(document.attribute("id") == "Document01")
        #expect(XOP.contentID(in: document) == "1.urn:uuid:b1a9c4f2@example.invalid")
        let name = payload.descendants(named: XName(Namespace.rim, "LocalizedString")).first?.attribute("value")
        #expect(name == "Manifeste d’examen & images clés")
        #expect(try envelope.fault() == nil)
    }

    @Test func writtenEnvelopeReadsBackIdentically() throws {
        let envelope = try SOAPEnvelope(data: fixture("iti41-envelope.xml"))
        let again = try SOAPEnvelope(data: envelope.data())
        #expect(again == envelope)
    }

    @Test func requestHeadersFollowAppendixV() throws {
        let wsa = WSAddressing.request(action: "urn:ihe:iti:2007:RegistryStoredQuery", to: "https://registry.example.invalid/iti18")
        let envelope = SOAPEnvelope(addressing: wsa, payload: XElement(XName(Namespace.query, "AdhocQueryRequest")))
        let xml = String(decoding: try envelope.data(), as: UTF8.self)
        #expect(xml.contains("<wsa:Action soap:mustUnderstand=\"true\">urn:ihe:iti:2007:RegistryStoredQuery</wsa:Action>"))
        #expect(xml.contains("<wsa:To soap:mustUnderstand=\"true\">https://registry.example.invalid/iti18</wsa:To>"))
        let read = try #require(try SOAPEnvelope(data: Data(xml.utf8)).addressing)
        #expect(read == wsa)
        #expect(wsa.messageID?.hasPrefix("urn:uuid:") == true)
        let response = wsa.response(action: "urn:ihe:iti:2007:RegistryStoredQueryResponse")
        #expect(response.relatesTo == wsa.messageID)
        #expect(response.replyTo == nil)
    }

    @Test func extraHeadersFollowAddressing() throws {
        let assertion = XElement(XName("urn:oasis:names:tc:SAML:2.0:assertion", "Assertion"), text: "opaque")
        let envelope = SOAPEnvelope(addressing: .request(action: "a", to: nil), extraHeaders: [assertion], payload: XElement(XName("p")))
        let read = try SOAPEnvelope(data: envelope.data())
        #expect(read.headers.last == assertion)
        #expect(read.header(named: assertion.name) == assertion)
    }

    @Test func rawHeadersAndBodyAttributesAreWrittenVerbatim() throws {
        // A signed header must keep its exact bytes and prefixes (exclusive C14N).
        let signed = #"<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><saml2:Assertion xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_a1">x</saml2:Assertion></wsse:Security>"#
        let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
        let envelope = SOAPEnvelope(headers: WSAddressing.request(action: "a", to: nil).headers, rawHeaders: [signed],
                                    body: [XElement(XName("urn:x", "p"))], bodyAttributes: [XAttribute(XName(wsu, "Id"), "body-1")])
        let xml = String(decoding: try envelope.data(), as: UTF8.self)
        #expect(xml.contains(signed))
        let read = try SOAPEnvelope(data: Data(xml.utf8))
        #expect(read.bodyAttributes == [XAttribute(XName(wsu, "Id"), "body-1")])
        #expect(read.header(named: XName("http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd", "Security")) != nil)
    }

    @Test func mustUnderstandHeadersNotUnderstoodAreListed() throws {
        let other = XElement(XName("urn:x", "Policy"), attributes: [XAttribute(SOAPEnvelope.mustUnderstand, "1")])
        let envelope = SOAPEnvelope(addressing: .request(action: "a", to: "b"), extraHeaders: [other, XElement(XName("urn:x", "Optional"))],
                                    payload: XElement(XName("p")))
        let addressing = Set(["Action", "MessageID", "ReplyTo", "To"].map { XName(Namespace.addressing, $0) })
        #expect(envelope.notUnderstoodHeaders(understood: addressing) == [other])
    }

    @Test func soap11IsAVersionMismatch() {
        let xml = #"<e:Envelope xmlns:e="http://schemas.xmlsoap.org/soap/envelope/"><e:Body/></e:Envelope>"#
        #expect(throws: SOAPError.versionMismatch("http://schemas.xmlsoap.org/soap/envelope/")) {
            try SOAPEnvelope(data: Data(xml.utf8))
        }
    }

    @Test func envelopeWithoutBodyOrNotAnEnvelope() {
        let noBody = #"<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"/>"#
        #expect(throws: SOAPError.missingBody) { try SOAPEnvelope(data: Data(noBody.utf8)) }
        #expect(throws: SOAPError.notAnEnvelope(XName("html"))) { try SOAPEnvelope(data: Data("<html/>".utf8)) }
    }

    @Test func missingActionIsRefused() {
        #expect(throws: SOAPError.missingHeader(XName(Namespace.addressing, "Action"))) { try WSAddressing(headers: []) }
    }
}

@Suite struct SOAPFaultTests {
    @Test func faultRoundTrip() throws {
        let fault = SOAPFault(code: .sender, subcodes: [XName(Namespace.addressing, "ActionNotSupported"), XName("urn:example:dmp", "Refus")], reason: "Unknown action",
                              detail: [XElement(XName("urn:x", "Info"), text: "d")])
        let envelope = SOAPEnvelope(addressing: WSAddressing(action: SOAPFault.faultAction), payload: fault.element)
        let xml = String(decoding: try envelope.data(), as: UTF8.self)
        #expect(xml.contains("<soap:Value>soap:Sender</soap:Value>"))
        #expect(xml.contains("<soap:Value>wsa:ActionNotSupported</soap:Value>"))
        #expect(xml.contains("xmlns:ns1=\"urn:example:dmp\"") && xml.contains("<soap:Value>ns1:Refus</soap:Value>"))
        #expect(try envelope.fault() == fault)
        #expect(xml.contains("<soap:Text xml:lang=\"en\">Unknown action</soap:Text>"))
        let read = try #require(try SOAPEnvelope(data: Data(xml.utf8)).fault())
        #expect(read == fault)
    }

    @Test func readsAFaultFromAnotherStack() throws {
        let xml = """
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"><env:Body><env:Fault>
          <env:Code><env:Value>env:Receiver</env:Value></env:Code>
          <env:Reason><env:Text xml:lang="fr">Registre indisponible</env:Text><env:Text xml:lang="en">Registry down</env:Text></env:Reason>
        </env:Fault></env:Body></env:Envelope>
        """
        let fault = try #require(try SOAPEnvelope(data: Data(xml.utf8)).fault())
        #expect(fault.code == .receiver)
        #expect(fault.reason == "Registre indisponible")
        #expect(fault.reasonLanguage == "fr")
        #expect(fault.subcodes.isEmpty)
    }

    @Test func codeOutsideTheSOAPNamespaceIsInvalid() throws {
        let xml = """
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:x="urn:x"><env:Body><env:Fault>
          <env:Code><env:Value>x:Sender</env:Value></env:Code><env:Reason><env:Text xml:lang="en">r</env:Text></env:Reason>
        </env:Fault></env:Body></env:Envelope>
        """
        #expect(throws: SOAPError.invalidFault("unknown code x:Sender")) { try SOAPEnvelope(data: Data(xml.utf8)).fault() }
    }

    @Test func unknownCodeIsInvalid() {
        let e = XElement(SOAPFault.faultName, elements: [
            XElement(XName(Namespace.soapEnvelope, "Code"), elements: [XElement(XName(Namespace.soapEnvelope, "Value"), text: "x:Other")]),
        ])
        #expect(throws: SOAPError.invalidFault("unknown code x:Other")) { try SOAPFault(element: e) }
    }
}

@Suite struct MIMETests {
    @Test func parsesMTOMContentType() throws {
        let value = #"Multipart/Related; boundary="MIMEBoundary_abc"; type="application/xop+xml"; start="<root@x>"; start-info="application/soap+xml"; action="urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b""#
        let type = try #require(MIMEContentType(parsing: value))
        #expect(type.mediaType == "multipart/related")
        #expect(type["BOUNDARY"] == "MIMEBoundary_abc")
        #expect(type["start"] == "<root@x>")
        #expect(type["action"] == "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b")
        #expect(MIMEContentType(parsing: type.description) == type)
    }

    @Test func parsesUnquotedAndEscapedValues() throws {
        let type = try #require(MIMEContentType(parsing: #"application/soap+xml;charset=UTF-8; action="a\"b""#))
        #expect(type["charset"] == "UTF-8")
        #expect(type["action"] == "a\"b")
        #expect(MIMEContentType(parsing: "nonsense") == nil)
        #expect(MIMEContentType(parsing: "/x") == nil)
    }

    @Test func headerNamesAreCaseInsensitive() {
        let h = MIMEHeaders([("content-id", "<a@b>"), ("CONTENT-TYPE", "text/plain")])
        #expect(h.contentID == "a@b")
        #expect(h.contentType?.mediaType == "text/plain")
    }
}

/// Messages in the shape other SOAP stacks produce (Apache Axis2, Apache CXF, .NET WCF), byte for byte.
@Suite struct ForeignStackTests {
    func read(_ name: String) async throws -> SOAPMessage {
        let contentType = String(decoding: try fixture(name + ".content-type"), as: UTF8.self)
        return try await MTOMReader().read(try fixture(name + ".mime"), contentType: contentType)
    }

    @Test func axis2RegistryResponse() async throws {
        let message = try await read("axis2-iti41-response")
        #expect(message.envelope.addressing?.action == "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-bResponse")
        #expect(message.envelope.addressing?.relatesTo == "urn:uuid:9376254e-da05-41f5-9af3-ac56d63d8ebd")
        #expect(message.envelope.payload?.name == XName(Namespace.rs, "RegistryResponse"))
        #expect(message.attachments.isEmpty)
    }

    @Test func cxfRetrieveResponseWithADocument() async throws {
        let message = try await read("cxf-iti43-response")
        // Addressing headers in the default namespace.
        #expect(message.envelope.addressing?.action == "urn:ihe:iti:2007:RetrieveDocumentSetResponse")
        let response = try #require(message.envelope.payload)
        let document = try #require(response.descendants(named: XName(Namespace.xdsb, "Document")).first)
        let attachment = try #require(message.attachment(referencedBy: document))
        #expect(attachment.contentType == "application/dicom")
        #expect(try await attachment.data() == fixture("cxf-iti43-document.bin"))
    }

    @Test func wcfFaultWithAnAddressingSubcode() async throws {
        let message = try await read("wcf-fault")
        let fault = try #require(try message.envelope.fault())
        #expect(fault.code == .sender)
        #expect(fault.subcodes == [XName(Namespace.addressing, "ActionNotSupported")])
        #expect(fault.reasonLanguage == "en-US")
    }
}
