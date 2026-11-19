import AsyncHTTPClient
import Foundation
import Testing
import SwiftXDS
import SwiftXDSClient
import SwiftXDSSOAP
import SwiftXDSTestRegistry

@Suite struct DocumentConsumerTests {
    let kos = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    /// The exit criterion of #226: published, found by patient, retrieved identical.
    @Test func publishedThenFoundByPatientThenRetrievedIdentical() async throws {
        try await withHarness { h in
            let submission = manifestSubmission()
            #expect(try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url).isSuccess)
            let found = try await h.client.findDocuments(patientId: patient, registry: h.server.url)
            #expect(found.response.isSuccess)
            let entry = try #require(found.objects.documentEntries.first)
            #expect(found.objects.documentEntries.count == 1)
            #expect(entry.uniqueId == submission.documentEntries[0].uniqueId)
            let request = try #require(XDSDocumentRequest(entry))
            let result = try await h.client.retrieve([request], from: h.server.url)
            #expect(result.response.isSuccess)
            let document = try #require(result.documents.first)
            let data = try await document.data()
            #expect(XDSHash.sha1(data) == entry.hash)
            #expect(Int64(data.count) == entry.size)
            #expect(data == kos)
            #expect(document.info.mimeType == "application/dicom")
        }
    }

    @Test func retrievedDocumentsCanGoToFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let submission = manifestSubmission()
        try await withHarness(transport: { XDSHTTPTransport(client: $0.client, store: MTOMFileStore(directory: directory)) }) { h in
            _ = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            let result = try await h.client.retrieve([XDSDocumentRequest(repositoryUniqueId: h.registry.repositoryUniqueId,
                                                                         documentUniqueId: submission.documentEntries[0].uniqueId)], from: h.server.url)
            let document = try #require(result.documents.first)
            guard case .file(let url) = document.attachment.body else { Issue.record("kept in memory"); return }
            // Paths, not URLs: a directory URL may end with a slash (Linux) and /var is /private/var (macOS).
            #expect(url.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
            #expect(try await document.matches(await h.registry.documentEntries.values.first!))
            #expect(try Data(contentsOf: url) == kos)
        }
    }

    @Test func partialRetrieveNamesEachMissingDocument() async throws {
        try await withHarness { h in
            let submission = manifestSubmission()
            _ = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            let repository = h.registry.repositoryUniqueId
            let result = try await h.client.retrieve([
                XDSDocumentRequest(repositoryUniqueId: repository, documentUniqueId: submission.documentEntries[0].uniqueId),
                XDSDocumentRequest(repositoryUniqueId: repository, documentUniqueId: "1.2.250.1.999.404"),
                XDSDocumentRequest(repositoryUniqueId: "1.2.250.1.999.9", documentUniqueId: "1.2.250.1.999.405"),
            ], from: h.server.url)
            #expect(result.response.status == .partialSuccess)
            #expect(result.documents.count == 1)
            #expect(result.response.errors.map(\.errorCode) == [XDSErrorCode.documentUniqueIdError, XDSErrorCode.unknownRepositoryId])
            #expect(result.response.errors.map(\.location) == ["1.2.250.1.999.404", "1.2.250.1.999.405"])
            let none = try await h.client.retrieve([XDSDocumentRequest(repositoryUniqueId: repository, documentUniqueId: "1.2.250.1.999.404")], from: h.server.url)
            #expect(none.response.status == .failure)
        }
    }

    @Test func getDocumentsAndObjectRefs() async throws {
        try await withHarness { h in
            let submission = manifestSubmission()
            _ = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            let refs = try await h.client.findDocuments(patientId: patient, returnType: .objectRef, registry: h.server.url)
            let id = try #require(refs.objects.objectRefs.first)
            #expect(refs.objects.documentEntries.isEmpty && refs.objects.objectRefs.count == 1)
            let byUUID = try await h.client.query(.getDocuments(entryUUIDs: [id]), registry: h.server.url)
            #expect(byUUID.objects.documentEntries.map(\.entryUUID) == [id])
            let byUniqueId = try await h.client.query(.getDocuments(uniqueIds: [submission.documentEntries[0].uniqueId]), registry: h.server.url)
            #expect(byUniqueId.objects.documentEntries.map(\.entryUUID) == [id])
        }
    }

    @Test func submissionSetAndContents() async throws {
        try await withHarness { h in
            let submission = manifestSubmission()
            _ = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos)], to: h.server.url)
            let result = try await h.client.query(.getSubmissionSetAndContents(submission.submissionSets[0].uniqueId, byUniqueId: true), registry: h.server.url)
            let set = try #require(result.objects.submissionSets.first)
            #expect(result.objects.documentEntries.count == 1)
            #expect(result.objects.associations.map(\.source) == [set.entryUUID])
            #expect(result.objects.associations.first?.submissionSetStatus == .original)
            // A format filter that does not match leaves the set without documents.
            let filtered = try await h.client.query(.getSubmissionSetAndContents(set.entryUUID, formatCodes: [XDSCode(code: "other", codingScheme: "1.2", displayName: "")]),
                                                    registry: h.server.url)
            #expect(filtered.objects.submissionSets.count == 1 && filtered.objects.documentEntries.isEmpty && filtered.objects.associations.isEmpty)
        }
    }

    @Test func queryErrorsUseTheirCodes() async throws {
        try await withHarness { h in
            let noPatient = XDSStoredQuery(id: XDSStoredQueryID.findDocuments, parameters: [XDSSlot(name: "$XDSDocumentEntryStatus", values: ["('urn:oasis:names:tc:ebxml-regrep:StatusType:Approved')"])])
            let r1 = try await h.client.query(noPatient, registry: h.server.url)
            #expect(r1.response.errors.map(\.errorCode) == [XDSErrorCode.storedQueryMissingParam])
            let unknown = XDSStoredQuery(id: "urn:uuid:00000000-0000-4000-8000-000000000000")
            let r2 = try await h.client.query(unknown, registry: h.server.url)
            #expect(r2.response.errors.map(\.errorCode) == [XDSErrorCode.unknownStoredQuery])
            let both = XDSStoredQuery(id: XDSStoredQueryID.getDocuments, parameters: [
                XDSSlot(name: "$XDSDocumentEntryEntryUUID", values: ["('urn:uuid:a')"]), XDSSlot(name: "$XDSDocumentEntryUniqueId", values: ["('1.2')"]),
            ])
            let r3 = try await h.client.query(both, registry: h.server.url)
            #expect(r3.response.errors.map(\.errorCode) == [XDSErrorCode.storedQueryParamNumber])
        }
    }

    @Test func folderContentsFollowTheDocumentFilter() async throws {
        try await withHarness { h in
            var submission = manifestSubmission()
            var other = submission.documentEntries[0]
            other.entryUUID = "Document02"
            other.uniqueId += ".2"
            other.formatCode = XDSCode(code: "urn:ihe:rad:PDF", codingScheme: "1.3.6.1.4.1.19376.1.2.3", displayName: "PDF")
            let folder = XDSFolder(entryUUID: "Folder01", uniqueId: submission.submissionSets[0].uniqueId + ".9", patientId: patient,
                                   codeList: [XDSCode(code: "IMG", codingScheme: "1.2.3", displayName: "Imagerie")], title: "Dossier")
            let link = XDSAssociation(type: .hasMember, source: "Folder01", target: "Document01")
            submission = .submission(submission.submissionSets[0], documents: [submission.documentEntries[0], other], folders: [folder], associations: [link])
            #expect(try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: kos),
                                                                                   XDSDocument(entryUUID: "Document02", data: kos)], to: h.server.url).isSuccess)
            let uid = submission.submissionSets[0].uniqueId
            let all = try await h.client.query(.getSubmissionSetAndContents(uid, byUniqueId: true), registry: h.server.url)
            #expect(all.objects.documentEntries.count == 2 && all.objects.folders.count == 1)
            // SS→Document01, SS→Document02, SS→Folder01, SS→(Folder01→Document01), Folder01→Document01.
            #expect(all.objects.associations.count == 5)
            let folderID = try #require(all.objects.folders.first?.entryUUID)
            #expect(all.objects.associations.contains { $0.source == folderID })
            // PDF only: Document01 leaves, and with it the folder's link to it.
            let pdf = try await h.client.query(.getSubmissionSetAndContents(uid, byUniqueId: true, formatCodes: [other.formatCode!]), registry: h.server.url)
            #expect(pdf.objects.documentEntries.map(\.uniqueId) == [other.uniqueId])
            #expect(pdf.objects.folders.count == 1)
            #expect(pdf.objects.associations.count == 2)
            #expect(!pdf.objects.associations.contains { $0.source == folderID })
        }
    }

    @Test func anEmptyRetrieveIsRefused() async throws {
        try await withHarness { h in
            let result = try await h.client.retrieve([], from: h.server.url)
            #expect(result.response.status == .failure && result.documents.isEmpty)
            #expect(result.response.errors.map(\.errorCode) == [XDSErrorCode.repositoryError])
        }
    }

    /// A peer that answers in base64 and with mistakes: each unusable response is set aside, the rest kept.
    @Test func unusableDocumentResponsesAreSetAside() async throws {
        func response(_ id: String, _ document: XElement?) -> XElement {
            let e = XDSDocumentResponse(repositoryUniqueId: "1.2.9", documentUniqueId: id, mimeType: "text/plain")
                .element(document: document ?? XElement(XName("none")))
            return document == nil ? XElement(e.name, elements: e.elements.filter { $0.name != XName("none") }) : e
        }
        let body = XDSRetrieve.responseElement(RegistryResponse(status: .success), documents: [
            response("1.1", XElement(XDSRetrieve.document, text: "aGVs\nbG8=")),
            response("1.2", XElement(XDSRetrieve.document, text: "not*base64")),
            response("1.3", nil),
            response("1.4", XElement(XDSRetrieve.document, text: "aGVsbG8=")),
        ])
        let envelope = try SOAPEnvelope(addressing: WSAddressing(action: XDSTransaction.retrieveDocumentSet.responseAction), payload: body).data()
        let server = try await XDSTestServer.start { _, _ in (.ok, "application/soap+xml; charset=UTF-8", envelope) }
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = XDSClient(transport: XDSHTTPTransport(client: http))
        let asked = ["1.1", "1.2", "1.3"].map { XDSDocumentRequest(repositoryUniqueId: "1.2.9", documentUniqueId: $0) }
        let result = await Result(catching: { try await client.retrieve(asked, from: server.url) })
        try await http.shutdown()
        await server.stop()
        let r = try result.get()
        #expect(r.documents.map(\.info.documentUniqueId) == ["1.1"])
        #expect(try await r.documents[0].data() == Data("hello".utf8))
        #expect(r.problems.map(\.documentUniqueId) == ["1.2", "1.3", "1.4"])
        #expect(!r.isComplete)
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
