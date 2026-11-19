import Foundation
import Testing
@testable import SwiftXDS

@Suite struct QueryValueTests {
    @Test func encoding() {
        #expect(XDSQueryValue.string("O'Brien") == "'O''Brien'")
        #expect(XDSQueryValue.list(["a", "b"]) == "('a','b')")
        #expect(XDSQueryValue.code(XDSCode(code: "IMG", codingScheme: "1.2.3", displayName: "x")) == "IMG^^1.2.3")
    }

    @Test(arguments: [
        ("'a'", ["a"]), ("('a','b')", ["a", "b"]), ("( 'a' , 'b' )", ["a", "b"]), ("20261119", ["20261119"]),
        ("(1,2)", ["1", "2"]), ("'O''Brien'", ["O'Brien"]), ("('a,b','c')", ["a,b", "c"]),
        ("('urn:oasis:names:tc:ebxml-regrep:StatusType:Approved')", ["urn:oasis:names:tc:ebxml-regrep:StatusType:Approved"]),
    ])
    func parsing(text: String, values: [String]) {
        #expect(XDSQueryValue.parse(text) == values)
    }

    @Test(arguments: ["", "'a", "('a'", "('a',)", "a'b", "'a'b'", "()"])
    func malformedValues(text: String) {
        #expect(XDSQueryValue.parse(text) == nil)
    }

    @Test func codes() {
        #expect(XDSQueryValue.code("IMG^^1.2.3")?.matches(XDSCode(code: "IMG", codingScheme: "1.2.3", displayName: "")) == true)
        #expect(XDSQueryValue.code("IMG") == nil)
        #expect(XDSQueryValue.code("^^1.2") == nil)
    }
}

@Suite struct StoredQueryTests {
    let patient = CXIdentifier(id: "SYNTH-0000042", assigningAuthority: "1.2.250.1.213.1.4.8")

    @Test func findDocumentsHasTheShapeOfITI18() throws {
        var filter = XDSDocumentFilter()
        // A query carries code and scheme only, not the display name.
        filter.classCodes = [XDSCode(code: "IMG", codingScheme: "1.2.250.1.213.1.1.4.1", localizedDisplayName: [])]
        filter.creationTime = XDSTimeRange(from: XDSDateTime("20260101"))
        let q = XDSStoredQuery.findDocuments(patientId: patient, filter)
        let xml = try XMLWriter.string(q.element)
        #expect(xml.contains(#"returnType="LeafClass""#) && xml.contains(#"returnComposedObjects="true""#))
        #expect(xml.contains(#"id="urn:uuid:14d4debf-8f97-4251-9a74-a90016b0af0d""#))
        // As in the published example: patient quoted, status as a list, dates bare.
        #expect(xml.contains("'SYNTH-0000042^^^&amp;1.2.250.1.213.1.4.8&amp;ISO'"))
        #expect(xml.contains("('urn:oasis:names:tc:ebxml-regrep:StatusType:Approved')"))
        #expect(xml.contains("('IMG^^1.2.250.1.213.1.1.4.1')"))
        #expect(xml.contains(">20260101<"))
        let read = try XDSStoredQuery(element: XMLReader.parse(xml))
        #expect(read == q)
        #expect(try XDSDocumentFilter(query: read) == filter)
    }

    @Test func filterMatching() throws {
        var d = XDSDocumentEntry(entryUUID: "urn:uuid:5e1f1c1a-0000-4000-8000-000000000001", uniqueId: "1.2", patientId: patient, mimeType: "x/y")
        d.availabilityStatus = .approved
        d.creationTime = XDSDateTime("20261119101500")
        d.classCode = XDSCode(code: "IMG", codingScheme: "1.2.3", displayName: "Imagerie")
        d.eventCodes = [XDSCode(code: "CT", codingScheme: "DCM", displayName: ""), XDSCode(code: "CHEST", codingScheme: "SCT", displayName: "")]
        d.authors = [XDSAuthor(person: "801234567^RADIOLOGUE^ANNE")]
        var f = XDSDocumentFilter()
        #expect(f.matches(d))
        f.classCodes = [XDSCode(code: "IMG", codingScheme: "other", displayName: "")]
        #expect(!f.matches(d))
        f.classCodes = [XDSCode(code: "X", codingScheme: "1", displayName: ""), XDSCode(code: "IMG", codingScheme: "1.2.3", displayName: "autre libellé")]
        #expect(f.matches(d))
        f.eventCodes = [[XDSCode(code: "CT", codingScheme: "DCM", displayName: "")], [XDSCode(code: "CHEST", codingScheme: "SCT", displayName: "")]]
        #expect(f.matches(d))
        f.eventCodes.append([XDSCode(code: "MR", codingScheme: "DCM", displayName: "")])
        #expect(!f.matches(d))
        f.eventCodes = []
        f.creationTime = XDSTimeRange(from: XDSDateTime("20261119101500"), to: XDSDateTime("20261120"))
        #expect(f.matches(d))
        f.creationTime = XDSTimeRange(to: XDSDateTime("20261119101500"))
        #expect(!f.matches(d), "to is exclusive")
        f.creationTime = nil
        f.authorPersons = ["%^RADIOLOGUE^%"]
        #expect(f.matches(d))
        f.authorPersons = ["_RADIOLOGUE%"]
        #expect(!f.matches(d))
        f = XDSDocumentFilter(status: [.deprecated])
        #expect(!f.matches(d))
        d.objectType = XDSScheme.documentEntryOnDemand
        f = XDSDocumentFilter()
        #expect(!f.matches(d), "Stable only by default")
        f.documentEntryTypes = [XDSScheme.documentEntryOnDemand]
        #expect(f.matches(d))
    }

    @Test func invalidParametersAreRegistryErrors() throws {
        let twoPatients = XDSStoredQuery(id: XDSStoredQueryID.findDocuments, parameters: [
            XDSSlot(name: "$XDSDocumentEntryCreationTimeFrom", values: ["(20260101,20260102)"]),
        ])
        #expect(throws: RegistryError.self) { try XDSDocumentFilter(query: twoPatients) }
        let badCode = XDSStoredQuery(id: XDSStoredQueryID.findDocuments, parameters: [XDSSlot(name: "$XDSDocumentEntryClassCode", values: ["('IMG')"])])
        do {
            _ = try XDSDocumentFilter(query: badCode)
            Issue.record("accepted a code without scheme")
        } catch let e as RegistryError {
            #expect(e.location == "$XDSDocumentEntryClassCode")
        }
    }

    @Test func readsAPublishedFindDocumentsResponse() throws {
        let url = try #require(Bundle.module.url(forResource: "epr-iti18-response.xml", withExtension: nil, subdirectory: "Fixtures"))
        let response = try XDSQueryResponse(element: XMLReader.parse(Data(contentsOf: url)))
        #expect(response.response.isSuccess)
        let d = try #require(response.objects.documentEntries.first)
        #expect(d.availabilityStatus == .approved)
        #expect(d.logicalID == d.entryUUID)
        #expect(d.version == "1")
        #expect(d.homeCommunityId == "urn:oid:1.1.4567334.1.6")
        #expect(d.repositoryUniqueId == "1.1.4567332.1.75")
        #expect(d.size == 5375)
        #expect(XDSDocumentRequest(d) == XDSDocumentRequest(repositoryUniqueId: "1.1.4567332.1.75", documentUniqueId: d.uniqueId, homeCommunityId: "urn:oid:1.1.4567334.1.6"))
    }

    @Test func retrieveElementsRoundTrip() throws {
        let r = XDSDocumentRequest(repositoryUniqueId: "1.2.3", documentUniqueId: "1.2.3.4", homeCommunityId: "urn:oid:1.2")
        let xml = try XMLWriter.data(XDSRetrieve.requestElement([r]))
        #expect(try XDSRetrieve.requests(in: XMLReader.parse(xml)) == [r])
        var info = XDSDocumentResponse(repositoryUniqueId: "1.2.3", documentUniqueId: "1.2.3.4", mimeType: "application/dicom")
        info.newDocumentUniqueId = "1.2.3.5"
        let e = info.element(document: XElement(XDSRetrieve.document, text: "AAAA"))
        let names = e.elements.map(\.name.local)
        #expect(names == ["RepositoryUniqueId", "DocumentUniqueId", "NewDocumentUniqueId", "mimeType", "Document"])
        #expect(try XDSDocumentResponse(element: XMLReader.parse(XMLWriter.data(e))) == info)
    }

    @Test func returnTypeIsRequired() throws {
        let xml = #"<query:AdhocQueryRequest xmlns:query="urn:oasis:names:tc:ebxml-regrep:xsd:query:3.0" xmlns:rim="urn:oasis:names:tc:ebxml-regrep:xsd:rim:3.0"><query:ResponseOption returnComposedObjects="true"/><rim:AdhocQuery id="urn:uuid:14d4debf-8f97-4251-9a74-a90016b0af0d"/></query:AdhocQueryRequest>"#
        #expect(throws: XDSMetadataError.self) { try XDSStoredQuery(element: XMLReader.parse(xml)) }
    }

    @Test func likeIsLinearOnLongValues() {
        let long = String(repeating: "a", count: 20_000)
        #expect(!XDSDocumentFilter.like(long, String(repeating: "%a", count: 50) + "%b"))
        #expect(XDSDocumentFilter.like(long + "b", "%a%b"))
        #expect(XDSDocumentFilter.like("", "%") && !XDSDocumentFilter.like("", "_"))
    }
}

@Suite struct UpdateModelTests {
    let set = XDSSubmissionSet(entryUUID: "SubmissionSet01", uniqueId: "1.2.250.1.999.5.1", sourceId: "1.2.250.1.999.4",
                               patientId: CXIdentifier(id: "SYNTH-0000042", assigningAuthority: "1.2.250.1.213.1.4.8"),
                               contentTypeCode: XDSCode(code: "IMG-KOS", codingScheme: "1.2.250.1.999.3", displayName: "Manifeste"))
    let target = "urn:uuid:5e1f1c1a-0000-4000-8000-000000000001"

    @Test func statusUpdateHasTheShapeOfITI57() throws {
        let update = XDSObjectList.statusUpdate([target], in: set)
        let xml = try XMLWriter.string(update.submitObjectsRequest)
        #expect(xml.contains(#"associationType="urn:ihe:iti:2010:AssociationType:UpdateAvailabilityStatus""#))
        #expect(xml.contains(#"sourceObject="SubmissionSet01""#) && xml.contains(#"targetObject="\#(target)""#))
        #expect(xml.contains(#"name="OriginalStatus""#) && xml.contains(#"name="NewStatus""#))
        let read = try XDSObjectList(registryObjectList: XMLReader.parse(xml).element(named: XDSMessage.registryObjectList)!)
        #expect(read.associations.first?.statusChange?.new == .deprecated)
        #expect(XDSValidator.validate(update, as: .updateDocumentSet).isEmpty)
        #expect(XDSValidator.validate(update, as: .documentSource).map(\.attribute) == ["associationType"])
    }

    @Test func malformedStatusUpdatesAreRefused() {
        var update = XDSObjectList.statusUpdate([target], in: set)
        update.associations[0].extraSlots.removeLast()
        #expect(XDSValidator.validate(update, as: .updateDocumentSet).map(\.errorCode) == [XDSErrorCode.metadataUpdateError])
        update = XDSObjectList.statusUpdate(["Document01"], in: set)
        #expect(XDSValidator.validate(update, as: .updateDocumentSet).map(\.attribute).contains("targetObject"))
        update = XDSObjectList.statusUpdate([target], in: set, from: .approved, to: .submitted)
        #expect(XDSValidator.validate(update, as: .updateDocumentSet).map(\.attribute) == ["NewStatus"])
    }

    @Test func replacementPointsFromTheNewDocument() {
        let d = XDSDocumentEntry(entryUUID: "Document02", uniqueId: "1.2.3", patientId: set.patientId, mimeType: "x/y")
        let list = XDSObjectList.replacement(of: target, by: d, in: set)
        let rplc = list.associations.filter { $0.type == .replace }
        #expect(rplc.count == 1 && rplc[0].source == "Document02" && rplc[0].target == target)
        #expect(list.associations.contains { $0.type == .hasMember && $0.target == "Document02" })
    }
}
