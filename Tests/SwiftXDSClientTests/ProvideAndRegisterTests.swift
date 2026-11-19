import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
import SwiftXDS
import SwiftXDSClient
import SwiftXDSSOAP
import SwiftXDSTestRegistry

let patient = CXIdentifier(id: "SYNTH-0000042", assigningAuthority: "1.2.250.1.213.1.4.8")

/// A complete imaging manifest submission, as an XDS-I.b Imaging Document Source would send it.
func manifestSubmission(uniqueId: String = "1.2.250.1.999.2.1.1.\(Int.random(in: 1...999_999))") -> XDSObjectList {
    var d = XDSDocumentEntry(entryUUID: "Document01", uniqueId: uniqueId, patientId: patient, mimeType: "application/dicom")
    d.sourcePatientId = CXIdentifier(id: "P-0042", assigningAuthority: "1.2.250.1.999.1.1")
    d.creationTime = XDSDateTime("20261119101500")
    d.languageCode = "fr-FR"
    d.title = "Manifeste d’examen"
    d.classCode = XDSCode(code: "IMG", codingScheme: "1.2.250.1.213.1.1.4.1", displayName: "Imagerie")
    d.confidentialityCodes = [XDSCode(code: "N", codingScheme: "2.16.840.1.113883.5.25", displayName: "Normal")]
    d.formatCode = XDSCode(code: "1.2.840.10008.5.1.4.1.1.88.59", codingScheme: "1.2.840.10008.2.6.1", displayName: "KOS")
    d.healthcareFacilityTypeCode = XDSCode(code: "SA01", codingScheme: "1.2.250.1.71.4.2.4", displayName: "Établissement public")
    d.practiceSettingCode = XDSCode(code: "ETABLISSEMENT", codingScheme: "1.2.250.1.213.1.1.4.9", displayName: "Établissement")
    d.typeCode = XDSCode(code: "18748-4", codingScheme: "2.16.840.1.113883.6.1", displayName: "Diagnostic imaging study")
    d.authors = [XDSAuthor(person: XCNPerson(id: "801234567", family: "RADIOLOGUE", given: "ANNE", assigningAuthority: "1.2.250.1.71.4.2.1"))]
    let set = XDSSubmissionSet(entryUUID: "SubmissionSet01", uniqueId: uniqueId + ".1", sourceId: "1.2.250.1.999.4", patientId: patient,
                               contentTypeCode: XDSCode(code: "IMG-KOS", codingScheme: "1.2.250.1.999.3", displayName: "Manifeste"))
    return .submission(set, documents: [d])
}

/// One registry served over HTTP, one client; `withHarness` stops both, even on failure.
struct Harness {
    let server: XDSTestServer
    let http: HTTPClient
    let client: XDSClient
    var registry: XDSTestRegistry { server.registry! }
}

func withHarness<T>(registry: XDSTestRegistry = XDSTestRegistry(), validates: Bool = true,
                    transport: (@Sendable (XDSHTTPTransport) -> any XDSTransport)? = nil,
                    headers: @escaping @Sendable (XDSTransaction) async throws -> XDSRequestHeaders = { _ in XDSRequestHeaders() },
                    _ body: (Harness) async throws -> T) async throws -> T {
    let server = try await XDSTestServer.start(registry: registry)
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let base = XDSHTTPTransport(client: http)
    let h = Harness(server: server, http: http, client: XDSClient(transport: transport?(base) ?? base, validatesMetadata: validates, headers: headers))
    do {
        let result = try await body(h)
        try await http.shutdown()
        await server.stop()
        return result
    } catch {
        try? await http.shutdown()
        await server.stop()
        throw error
    }
}

/// Keeps the bytes the client sends.
actor Recorder {
    var bytes = Data()
    func set(_ d: Data) { bytes = d }
}

struct RecordingTransport: XDSTransport {
    let inner: XDSHTTPTransport
    let recorder: Recorder

    func send(_ request: SOAPMessage, transaction: XDSTransaction, to endpoint: URL) async throws -> SOAPMessage {
        await recorder.set(try await MTOMWriter(action: transaction.requestAction).data(request))
        return try await inner.send(request, transaction: transaction, to: endpoint)
    }
}

func registryResponse(_ m: SOAPMessage) throws -> RegistryResponse {
    try RegistryResponse(element: try #require(m.envelope.payload))
}

/// An ITI-41 request built by hand, to send malformed ones to the registry.
func iti41(_ payload: XElement, attachments: [MTOMAttachment]) -> SOAPMessage {
    let wsa = WSAddressing.request(action: XDSTransaction.provideAndRegister.requestAction, to: "http://localhost/xds")
    return SOAPMessage(envelope: SOAPEnvelope(headers: wsa.headers, body: [payload]), attachments: attachments)
}

@Suite struct ProvideAndRegisterTests {
    let kos = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    @Test func publishesADocumentThatTheRegistryStores() async throws {
        try await withHarness { h in
            let response = try await h.client.provideAndRegister(manifestSubmission(), documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            #expect(response.isSuccess, "\(response.errors)")
            let entries = await h.registry.documentEntries
            let stored = try #require(entries.values.first)
            #expect(entries.count == 1)
            #expect(stored.entryUUID.hasPrefix("urn:uuid:"))
            #expect(stored.availabilityStatus == .approved)
            #expect(stored.hash == XDSHash.sha1(kos))
            #expect(stored.size == Int64(kos.count))
            #expect(stored.repositoryUniqueId == h.registry.repositoryUniqueId)
            #expect(await h.registry.documents[stored.uniqueId]?.data == kos)
            let association = try #require(await h.registry.associations.values.first)
            #expect(association.target == stored.entryUUID)
            #expect(await h.registry.submissionSets[association.source] != nil)
        }
    }

    @Test func publishesABatchOfTwoDocuments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = Data("Compte rendu synthétique".utf8)
        let file = directory.appendingPathComponent("report.txt")
        try report.write(to: file)
        var submission = manifestSubmission()
        var second = submission.documentEntries[0]
        second.entryUUID = "Document02"
        second.uniqueId = submission.documentEntries[0].uniqueId + ".2"
        second.mimeType = "text/plain"
        submission.documentEntries.append(second)
        submission.associations.append(.member(of: "SubmissionSet01", document: "Document02"))
        let request = try XDSClient.provideAndRegisterRequest(submission, documents: [
            XDSDocument(entryUUID: "Document01", data: kos), XDSDocument(entryUUID: "Document02", body: .file(file)),
        ])
        #expect(request.payload.elements(named: XDSMessage.document).map { $0.attribute("id") } == ["Document01", "Document02"])
        #expect(Set(request.attachments.map(\.contentID)).count == 2)
        #expect(request.attachments.map(\.contentType) == ["application/dicom", "text/plain"])

        try await withHarness { h in
            let response = try await h.client.provideAndRegister(submission, documents: [
                XDSDocument(entryUUID: "Document02", body: .file(file)), XDSDocument(entryUUID: "Document01", data: kos),
            ], to: h.server.url)
            #expect(response.isSuccess, "\(response.errors)")
            // Each document is stored under its own entry: no swap.
            #expect(await h.registry.documents[submission.documentEntries[0].uniqueId]?.data == kos)
            #expect(await h.registry.documents[second.uniqueId]?.data == report)
            #expect(await h.registry.documents[second.uniqueId]?.mimeType == "text/plain")
            let set = try #require(await h.registry.submissionSets.values.first)
            let members = await h.registry.associations.values.filter { $0.source == set.entryUUID && $0.type == .hasMember }
            #expect(members.count == 2)
            #expect(Set(members.map(\.target)) == Set(await h.registry.documentEntries.keys))
        }
    }

    @Test func aLargeFileIsStreamedWithAKnownLength() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.dcm")
        let large = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try large.write(to: file)
        var submission = manifestSubmission()
        try await submission.documentEntries[0].setHashAndSize(of: .file(file))
        try await withHarness { h in
            let response = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", body: .file(file))], to: h.server.url)
            #expect(response.isSuccess, "\(response.errors)")
            #expect(await h.registry.documents[submission.documentEntries[0].uniqueId]?.data == large)
        }
    }

    @Test func aDuplicateUniqueIdIsRefusedByTheRegistry() async throws {
        try await withHarness { h in
            let submission = manifestSubmission(uniqueId: "1.2.250.1.999.2.1.1.7")
            _ = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            let again = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            #expect(again.status == .failure)
            #expect(again.errors.map(\.errorCode).contains(XDSErrorCode.duplicateUniqueIdInRegistry))
            #expect(await h.registry.documentEntries.count == 1)
        }
    }

    @Test func invalidMetadataIsRefusedBeforeSending() async throws {
        try await withHarness { h in
            var submission = manifestSubmission()
            submission.documentEntries[0].typeCode = nil
            await #expect(throws: XDSClientError.self) {
                try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            }
            #expect(await h.registry.received.isEmpty)
        }
    }

    @Test func theRegistryChecksWhatTheClientDoesNot() async throws {
        // Without local validation, the registry's own checks answer.
        try await withHarness(registry: XDSTestRegistry(knownPatients: []), validates: false) { h in
            var submission = manifestSubmission()
            submission.documentEntries[0].hash = String(repeating: "0", count: 40)
            submission.documentEntries[0].typeCode = nil
            let response = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            #expect(response.status == .failure)
            #expect(Set(response.errors.map(\.errorCode)) == [XDSErrorCode.nonIdenticalHash, XDSErrorCode.registryMetadataError, XDSErrorCode.unknownPatientId])
            #expect(await h.registry.documentEntries.isEmpty)
        }
    }

    @Test func everyEntryNeedsExactlyOneDocument() async throws {
        let submission = manifestSubmission()
        #expect(throws: XDSClientError.self) { try XDSClient.provideAndRegisterRequest(submission, documents: []) }
        #expect(throws: XDSClientError.self) {
            try XDSClient.provideAndRegisterRequest(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos), XDSDocument(entryUUID: "Other", data: kos)])
        }
        do {
            _ = try XDSClient.provideAndRegisterRequest(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos), XDSDocument(entryUUID: "Document01", data: kos)])
            Issue.record("two documents for one entry accepted")
        } catch XDSClientError.duplicateDocument(let id) {
            #expect(id == "Document01")
        }
    }

    @Test func securityHeadersAreSentVerbatim() async throws {
        let assertion = #"<saml2:Assertion xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="_vihf"><ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#">c2lnbmVk</ds:Signature></saml2:Assertion>"#
        let recorder = Recorder()
        try await withHarness(transport: { RecordingTransport(inner: $0, recorder: recorder) }, headers: { _ in XDSRequestHeaders(raw: [assertion]) }) { h in
            _ = try await h.client.provideAndRegister(manifestSubmission(), documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            // Byte for byte in what is sent, so a signature stays valid.
            #expect(await recorder.bytes.range(of: Data(assertion.utf8)) != nil)
            let received = try #require(await h.registry.received.first)
            #expect(received.action == XDSTransaction.provideAndRegister.requestAction)
            #expect(received.headers.map(\.name) == [XName("urn:oasis:names:tc:SAML:2.0:assertion", "Assertion")])
        }
    }

    @Test func mustUnderstandSecurityHeadersAreAcceptedWhenDeclared() async throws {
        let security = #"<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:soap="http://www.w3.org/2003/05/soap-envelope" soap:mustUnderstand="true"><x/></wsse:Security>"#
        let headers: @Sendable (XDSTransaction) async throws -> XDSRequestHeaders = { _ in XDSRequestHeaders(raw: [security]) }
        try await withHarness(headers: headers) { h in
            do {
                _ = try await h.client.provideAndRegister(manifestSubmission(), documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
                Issue.record("Security accepted without being declared")
            } catch XDSClientError.fault(let fault) {
                #expect(fault.code == .mustUnderstand)
            }
        }
        try await withHarness(registry: XDSTestRegistry(understoodHeaders: [XDSTestRegistry.wsSecurity]), headers: headers) { h in
            let response = try await h.client.provideAndRegister(manifestSubmission(), documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            #expect(response.isSuccess)
        }
    }

    @Test func aFaultIsRaisedWithHTTP400() async throws {
        try await withHarness { h in
            do {
                _ = try await h.client.call(.register, to: h.server.url, payload: XElement(XName(Namespace.lcm, "SubmitObjectsRequest")))
                Issue.record("no fault")
            } catch XDSClientError.fault(let fault) {
                #expect(fault.code == .sender)
                #expect(fault.subcodes == [XName(Namespace.addressing, "ActionNotSupported")])
            }
            // SOAP 1.2 HTTP binding: a Sender fault is a 400, a GET a 405.
            var post = HTTPClientRequest(url: h.server.url.absoluteString)
            post.method = .POST
            post.headers.add(name: "Content-Type", value: "application/soap+xml; charset=UTF-8")
            post.body = .bytes(ByteBuffer(data: try SOAPEnvelope(addressing: .request(action: "urn:example:unknown", to: nil), payload: XElement(XName("x"))).data()))
            #expect(try await h.http.execute(post, timeout: .seconds(10)).status == .badRequest)
            #expect(try await h.http.execute(HTTPClientRequest(url: h.server.url.absoluteString), timeout: .seconds(10)).status == .methodNotAllowed)
        }
    }
}

@Suite struct TestRegistryTests {
    let kos = Data("kos".utf8)

    func request(_ change: (inout XElement, inout [MTOMAttachment]) -> Void) throws -> SOAPMessage {
        var (payload, attachments) = try XDSClient.provideAndRegisterRequest(manifestSubmission(), documents: [XDSDocument(entryUUID: "Document01", data: kos)])
        change(&payload, &attachments)
        return iti41(payload, attachments: attachments)
    }

    static func documents(_ payload: inout XElement, _ change: (inout XElement) -> Void) {
        payload.children = payload.children.map { node in
            guard case .element(var e) = node, e.name == XDSMessage.document else { return node }
            change(&e)
            return .element(e)
        }
    }

    @Test func aBrokenXOPReferenceIsAMissingDocument() async throws {
        let registry = XDSTestRegistry()
        let response = try registryResponse(await registry.handle(try request { _, attachments in attachments = [] }))
        #expect(response.errors.map(\.errorCode) == [XDSErrorCode.missingDocument])
        #expect(response.errors.first?.location == "Document01")
        #expect(await registry.documents.isEmpty)
    }

    @Test func anUnreadableDocumentIsARepositoryError() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-absent-" + UUID().uuidString)
        let message = try request { _, attachments in
            attachments = attachments.map { MTOMAttachment(contentID: $0.contentID, contentType: $0.contentType, body: .file(missing)) }
        }
        let response = try registryResponse(await XDSTestRegistry().handle(message))
        #expect(response.errors.map(\.errorCode) == [XDSErrorCode.repositoryError])
    }

    @Test func documentsWithoutIDOrTwiceAreRefused() async throws {
        let noID = try request { payload, _ in Self.documents(&payload) { $0.attributes.removeAll { $0.name == XName("id") } } }
        let r1 = try registryResponse(await XDSTestRegistry().handle(noID))
        #expect(r1.errors.map(\.errorCode) == [XDSErrorCode.repositoryError, XDSErrorCode.missingDocument])
        let twice = try request { payload, _ in
            let document = payload.elements(named: XDSMessage.document)[0]
            payload.append(document)
        }
        let r2 = try registryResponse(await XDSTestRegistry().handle(twice))
        #expect(r2.errors.map(\.errorCode) == [XDSErrorCode.repositoryDuplicateUniqueIdInMessage])
    }

    @Test func emptyInlineContentIsNotADocument() async throws {
        let message = try request { payload, attachments in
            attachments = []
            Self.documents(&payload) { $0.children = [] }
        }
        let response = try registryResponse(await XDSTestRegistry().handle(message))
        #expect(response.errors.map(\.errorCode) == [XDSErrorCode.missingDocument])
    }

    @Test func symbolicIDsAreRenumberedAndUUIDsKept() async throws {
        let registry = XDSTestRegistry()
        var submission = manifestSubmission()
        let given = "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000d1"
        submission.documentEntries[0].entryUUID = given
        let folder = XDSFolder(entryUUID: "Folder01", uniqueId: "1.2.250.1.999.6.\(Int.random(in: 1...999_999))", patientId: patient,
                               codeList: [XDSCode(code: "IMG", codingScheme: "1.2.250.1.999.7", displayName: "Imagerie")], title: "Dossier")
        let inFolder = XDSAssociation(id: "FolderMember01", type: .hasMember, source: "Folder01", target: given)
        submission = .submission(submission.submissionSets[0], documents: submission.documentEntries, folders: [folder], associations: [inFolder])
        let (payload, attachments) = try XDSClient.provideAndRegisterRequest(submission, documents: [XDSDocument(entryUUID: given, data: kos)])
        let response = try registryResponse(await registry.handle(iti41(payload, attachments: attachments)))
        #expect(response.isSuccess, "\(response.errors)")
        #expect(await registry.documentEntries[given] != nil)
        let storedFolder = try #require(await registry.folders.values.first)
        #expect(storedFolder.entryUUID.hasPrefix("urn:uuid:"))
        let associations = await registry.associations.values
        #expect(associations.allSatisfy { $0.id.hasPrefix("urn:uuid:") && $0.source.hasPrefix("urn:uuid:") && $0.target.hasPrefix("urn:uuid:") })
        let folderLink = try #require(associations.first { $0.source == storedFolder.entryUUID })
        #expect(folderLink.target == given)
        // The membership of the folder's association points to its new ID.
        #expect(associations.contains { $0.target == folderLink.id })

        // The same entryUUID again: refused, not renumbered.
        var again = manifestSubmission()
        again.documentEntries[0].entryUUID = given
        again = .submission(again.submissionSets[0], documents: again.documentEntries)
        let second = try XDSClient.provideAndRegisterRequest(again, documents: [XDSDocument(entryUUID: given, data: kos)])
        let refused = try registryResponse(await registry.handle(iti41(second.payload, attachments: second.attachments)))
        #expect(refused.status == .failure)
        #expect(refused.errors.contains { $0.location == given && $0.errorCode == XDSErrorCode.registryMetadataError })
        #expect(await registry.documentEntries.count == 1)
    }
}

@Suite struct HTTPErrorTests {
    func call(_ responder: @escaping XDSTestServer.Responder) async throws -> Error? {
        let server = try await XDSTestServer.start(responder: responder)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = XDSClient(transport: XDSHTTPTransport(client: http))
        var caught: Error?
        do {
            _ = try await client.call(.registryStoredQuery, to: server.url, payload: XElement(XName("q")))
        } catch {
            caught = error
        }
        try await http.shutdown()
        await server.stop()
        return caught
    }

    @Test func anHTMLErrorPageIsAnHTTPError() async throws {
        let error = try await call { _, _ in (.badGateway, "text/html", Data("<html><body>\n<h1>502 Bad Gateway</h1></body></html>".utf8)) }
        guard case .http(let status, let body)? = error as? XDSClientError else { Issue.record("\(String(describing: error))"); return }
        #expect(status == 502)
        #expect(body.contains("502 Bad Gateway") && !body.contains("\n"))
    }

    @Test func aSuccessThatIsNotSOAPIsUnexpected() async throws {
        let error = try await call { _, _ in (.ok, "text/plain", Data("hello".utf8)) }
        guard case .unexpectedContentType(let type)? = error as? XDSClientError else { Issue.record("\(String(describing: error))"); return }
        #expect(type == "text/plain")
    }

    @Test func aFaultWithHTTP500IsAFault() async throws {
        let fault = SOAPFault(code: .receiver, reason: "registry down")
        let body = try SOAPEnvelope(addressing: WSAddressing(action: SOAPFault.faultAction), payload: fault.element).data()
        let error = try await call { _, _ in (.internalServerError, "application/soap+xml; charset=UTF-8", body) }
        guard case .fault(let received)? = error as? XDSClientError else { Issue.record("\(String(describing: error))"); return }
        #expect(received.code == .receiver)
        #expect(received.reason == "registry down")
    }

    @Test func aTooLargeRequestIs413() async throws {
        let server = try await XDSTestServer.start(registry: XDSTestRegistry(), limits: .init(maxRequestBytes: 1024))
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        var post = HTTPClientRequest(url: server.url.absoluteString)
        post.method = .POST
        post.body = .bytes(ByteBuffer(repeating: 0x41, count: 4096))
        let status = try await http.execute(post, timeout: .seconds(10)).status
        try await http.shutdown()
        await server.stop()
        #expect(status == .payloadTooLarge)
    }

    @Test func stopClosesKeepAliveConnections() async throws {
        let server = try await XDSTestServer.start(registry: XDSTestRegistry())
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        // One request leaves a keep-alive connection open in the client's pool.
        _ = try await http.execute(HTTPClientRequest(url: server.url.absoluteString), timeout: .seconds(10))
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await server.stop(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        try await http.shutdown()
        #expect(stopped, "stop() waited for the open connection")
    }
}
