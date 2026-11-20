import Foundation
import Testing
@testable import SwiftXDS

private func fixture(_ name: String) throws -> XElement {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try XMLReader.parse(Data(contentsOf: url))
}

private func objectList() throws -> XDSObjectList {
    let request = try fixture("kos-submission.xml")
    return try XDSObjectList(registryObjectList: try #require(request.element(named: XName(Namespace.rim, "RegistryObjectList"))))
}

@Suite struct EbRIMReadTests {
    @Test func readsTheImagingManifestSubmission() throws {
        let list = try objectList()
        #expect(list.documentEntries.count == 1)
        #expect(list.submissionSets.count == 1)
        #expect(list.associations.count == 1)
        let d = list.documentEntries[0]
        #expect(d.entryUUID == "Document01")
        #expect(d.uniqueId == "1.2.250.1.999.2.1.1.99")
        #expect(d.patientId == CXIdentifier(id: "SYNTH-0000042", assigningAuthority: "1.2.250.1.213.1.4.8"))
        #expect(d.sourcePatientId?.assigningAuthority == "1.2.250.1.999.1.1")
        #expect(d.sourcePatientInfo == ["PID-3|P-0042^^^&1.2.250.1.999.1.1&ISO", "PID-5|SYNTHETIQUE^PAUL^^^", "PID-8|M"])
        #expect(d.mimeType == "application/dicom")
        #expect(d.creationTime?.value == "20261119101500")
        #expect(d.serviceStartTime?.value == "202611190930")
        #expect(d.languageCode == "fr-FR")
        #expect(d.title == "Manifeste d’examen : scanner thoracique")
        #expect(d.classCode == XDSCode(code: "IMG", codingScheme: "1.2.250.1.213.1.1.4.1", displayName: "Imagerie"))
        #expect(d.confidentialityCodes.map(\.code) == ["N"])
        #expect(d.eventCodes.map(\.code) == ["CT"])
        #expect(d.formatCode?.code == "1.2.840.10008.5.1.4.1.1.88.59")
        #expect(d.healthcareFacilityTypeCode?.displayName == "Établissement public de santé")
        #expect(d.practiceSettingCode?.code == "ETABLISSEMENT")
        #expect(d.typeCode?.code == "18748-4")
        #expect(d.referenceIds.count == 2)
        #expect(d.extraSlots == [XDSSlot(name: "urn:example:national-extension", values: ["kept"])])
        let author = try #require(d.authors.first)
        #expect(XCNPerson(try #require(author.person)).family == "RADIOLOGUE")
        #expect(XONOrganization(author.institutions[0]).identifier == "3123456789")
        #expect(author.roles == ["Radiologue"])
    }

    @Test func submissionSetIsRecognisedFromASiblingClassification() throws {
        let set = try objectList().submissionSets[0]
        #expect(set.entryUUID == "SubmissionSet01")
        #expect(set.uniqueId == "1.2.250.1.999.4.20261119.1")
        #expect(set.sourceId == "1.2.250.1.999.4")
        #expect(set.contentTypeCode?.code == "IMG-KOS")
        #expect(set.submissionTime?.value == "20261119101600")
        #expect(set.title == "Partage de l’examen")
    }

    @Test func writtenMetadataReadsBackToTheSameModel() throws {
        let list = try objectList()
        let xml = try XMLWriter.data(list.submitObjectsRequest)
        let again = try XDSObjectList(registryObjectList: try #require(try XMLReader.parse(xml).element(named: XName(Namespace.rim, "RegistryObjectList"))))
        #expect(again == list)
    }

    static let unknownScheme = "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000aa"

    static func unknownClassification(of object: String) -> XElement {
        XElement(RIM.classification, attributes: [
            XAttribute(XName("classificationScheme"), unknownScheme), XAttribute(XName("classifiedObject"), object),
            XAttribute(XName("id"), "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000ab"), XAttribute(XName("nodeRepresentation"), "X1"),
            XAttribute(XName("objectType"), XDSScheme.classificationType),
        ], elements: [
            XElement(RIM.slot, attributes: [XAttribute(XName("name"), "codingScheme")],
                     elements: [XElement(RIM.valueList, elements: [XElement(RIM.value, text: "1.2.250.1.999.9")])]),
        ])
    }

    static func unknownIdentifier(of object: String) -> XElement {
        XElement(RIM.externalIdentifier, attributes: [
            XAttribute(XName("id"), "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000ac"),
            XAttribute(XName("identificationScheme"), "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000ad"),
            XAttribute(XName("objectType"), XDSScheme.externalIdentifierType), XAttribute(XName("registryObject"), object),
            XAttribute(XName("value"), "EXT-0042"),
        ], elements: [XElement(RIM.nameElement, elements: [XElement(RIM.localizedString, attributes: [XAttribute(XName("value"), "national.id")])])])
    }

    /// Exit criterion of #231: a classification and an external identifier of unknown schemes are
    /// read, then written back identically, in the ebRIM order.
    @Test func unknownClassificationsAndIdentifiersAreRewrittenIdentically() throws {
        let known = try objectList().documentEntries[0]
        var e = known.element
        let lastClassification = try #require(e.children.lastIndex { if case .element(let c) = $0 { c.name == RIM.classification } else { false } })
        e.children.insert(.element(Self.unknownClassification(of: known.entryUUID)), at: lastClassification + 1)
        e.children.append(.element(Self.unknownIdentifier(of: known.entryUUID)))
        let original = try XMLReader.parse(XMLWriter.data(e))

        let d = try XDSDocumentEntry(element: original)
        #expect(d.extraClassifications.map { $0.attribute("nodeRepresentation") } == ["X1"])
        #expect(d.extraIdentifiers.map { $0.attribute("value") } == ["EXT-0042"])
        #expect(d.componentIDs == known.componentIDs)
        #expect(d.classCode == known.classCode && d.uniqueId == known.uniqueId)
        let a = Canonical.form(original), b = Canonical.form(try XMLReader.parse(XMLWriter.data(d.element)))
        #expect(a == b, "\(Canonical.firstDifference(a, b) ?? "")")
    }

    /// Placed next to the object, or with an unknown node, they are kept too, and follow the object
    /// when the registry gives it a UUID.
    @Test func unknownComponentsFollowTheObject() throws {
        var list = try objectList().registryObjectList
        var node = Self.unknownClassification(of: "SubmissionSet01")
        node.attributes = [XAttribute(XName("classificationNode"), "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000ae"),
                           XAttribute(XName("classifiedObject"), "SubmissionSet01"), XAttribute(XName("id"), "SubmissionSetNode"),
                           XAttribute(XName("objectType"), XDSScheme.classificationType)]
        node.children = []
        list.children += [.element(node), .element(Self.unknownIdentifier(of: "SubmissionSet01"))]
        var set = try #require(try XDSObjectList(registryObjectList: list).submissionSets.first)
        #expect(set.extraClassifications.map { $0.attribute("id") } == ["SubmissionSetNode"])
        #expect(set.extraIdentifiers.count == 1)
        #expect(set.uniqueId == "1.2.250.1.999.4.20261119.1")

        set.entryUUID = "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000af"
        let written = set.element
        #expect(written.elements(named: RIM.classification).last?.attribute("classifiedObject") == set.entryUUID)
        #expect(written.elements(named: RIM.externalIdentifier).last?.attribute("registryObject") == set.entryUUID)
        #expect(try XDSSubmissionSet(element: XMLReader.parse(XMLWriter.data(written))) == set)
    }

    @Test func writtenDocumentFollowsTheEbRIMOrder() throws {
        let e = try objectList().documentEntries[0].element
        let kinds = e.elements.map(\.name.local)
        let firstClassification = try #require(kinds.firstIndex(of: "Classification"))
        let firstIdentifier = try #require(kinds.firstIndex(of: "ExternalIdentifier"))
        #expect(kinds.lastIndex(of: "Slot")! < kinds.firstIndex(of: "Name")!)
        #expect(kinds.firstIndex(of: "Name")! < firstClassification)
        #expect(kinds.lastIndex(of: "Classification")! < firstIdentifier)
    }

    @Test func folderAndObjectRefsAreRead() throws {
        let folder = XDSFolder(entryUUID: "F1", uniqueId: "1.2.3.4", patientId: CXIdentifier(id: "p", assigningAuthority: "1.2"),
                               codeList: [XDSCode(code: "c", codingScheme: "s", displayName: "d")], title: "Dossier")
        let list = XDSObjectList(folders: [folder], objectRefs: ["urn:uuid:00000000-0000-0000-0000-000000000001"])
        let read = try XDSObjectList(registryObjectList: XMLReader.parse(XMLWriter.data(list.registryObjectList)))
        #expect(read.folders == [folder])
        #expect(read.objectRefs == list.objectRefs)
    }

    @Test func registryAttributesAreRead() throws {
        var d = XDSDocumentEntry(entryUUID: "urn:uuid:5e1f1c1a-0000-4000-8000-000000000001", uniqueId: "1.2.3", patientId: nil, mimeType: "text/plain")
        d.availabilityStatus = .approved
        d.logicalID = "urn:uuid:5e1f1c1a-0000-4000-8000-000000000001"
        d.version = "1"
        d.homeCommunityId = "urn:oid:1.2.3.4"
        d.hash = String(repeating: "a", count: 40)
        d.size = 12
        d.documentAvailability = .online
        let read = try XDSDocumentEntry(element: XMLReader.parse(XMLWriter.data(d.element)))
        #expect(read == d)
    }

    @Test func invalidSizeAndMissingIDAreRefused() throws {
        var d = XDSDocumentEntry(entryUUID: "D", uniqueId: "1.2", patientId: nil, mimeType: "x/y")
        d.extraSlots = [XDSSlot(name: "size", values: ["-1"])]
        #expect(throws: XDSMetadataError.invalidValue(attribute: "size", value: "-1")) { try XDSDocumentEntry(element: d.element) }
        #expect(throws: XDSMetadataError.missingAttribute(element: "ExtrinsicObject", attribute: "id")) {
            try XDSDocumentEntry(element: XElement(XName(Namespace.rim, "ExtrinsicObject")))
        }
    }
}

@Suite struct ValidationTests {
    @Test func theFixtureIsValidForADocumentSource() throws {
        #expect(XDSValidator.validate(try objectList(), as: .documentSource) == [])
    }

    @Test func repositoryMustAddHashSizeAndRepository() throws {
        var list = try objectList()
        let issues = XDSValidator.validate(list, as: .documentRepository)
        #expect(issues.map(\.attribute) == ["hash", "size", "repositoryUniqueId"])
        // The registry receives ITI-42: its own error code.
        #expect(issues.allSatisfy { $0.errorCode == XDSErrorCode.registryMetadataError })
        #expect(XDSValidator.validate(list, as: .documentRepository, receiver: .repository)
            .allSatisfy { $0.errorCode == XDSErrorCode.repositoryMetadataError })
        list.documentEntries[0].hash = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        list.documentEntries[0].size = 0
        list.documentEntries[0].repositoryUniqueId = "1.2.250.1.999.5"
        #expect(XDSValidator.validate(list, as: .documentRepository) == [])
    }

    @Test func missingRequiredAttributesAreNamed() throws {
        var list = try objectList()
        list.documentEntries[0].classCode = nil
        list.documentEntries[0].typeCode = nil
        list.submissionSets[0].contentTypeCode = nil
        let issues = XDSValidator.validate(list, as: .documentSource)
        #expect(Set(issues.map(\.attribute)) == ["classCode", "typeCode", "contentTypeCode"])
        #expect(issues.allSatisfy { $0.errorCode == XDSErrorCode.registryMetadataError })
    }

    @Test func limitedMetadataDoesNotRelaxAnXDSSubmission() throws {
        var list = try objectList()
        list.documentEntries[0].classCode = nil
        list.documentEntries[0].limitedMetadata = true
        #expect(XDSValidator.validate(list, as: .documentSource).map(\.attribute) == ["classCode"])
    }

    @Test func patientMismatchUsesItsErrorCode() throws {
        var list = try objectList()
        list.documentEntries[0].patientId = CXIdentifier(id: "OTHER", assigningAuthority: "1.2.250.1.213.1.4.8")
        let issue = try #require(XDSValidator.validate(list, as: .documentSource).first)
        #expect(issue.errorCode == XDSErrorCode.patientIdDoesNotMatch)
        #expect(issue.registryError.location == "Document01")
    }

    @Test func duplicateUniqueIdsInTheMessage() throws {
        var list = try objectList()
        var second = list.documentEntries[0]
        second.entryUUID = "Document02"
        list.documentEntries.append(second)
        list.associations.append(.member(of: "SubmissionSet01", document: "Document02"))
        #expect(XDSValidator.validate(list, as: .documentSource).map(\.errorCode) == [XDSErrorCode.registryDuplicateUniqueIdInMessage])
    }

    @Test func associationsMustResolveAndCoverEveryObject() throws {
        var list = try objectList()
        list.associations = [XDSAssociation(id: "as01", type: .replace, source: "Document01", target: "Elsewhere")]
        let issues = XDSValidator.validate(list, as: .documentSource)
        #expect(issues.map(\.errorCode).contains(XDSErrorCode.unresolvedReference))
        #expect(issues.contains { $0.objectID == "Document01" && $0.attribute == "HasMember" })
        // A replacement of a registry document by UUID resolves.
        list.associations = [.member(of: "SubmissionSet01", document: "Document01"),
                             XDSAssociation(type: .replace, source: "Document01", target: "urn:uuid:5e1f1c1a-0000-4000-8000-000000000009")]
        #expect(XDSValidator.validate(list, as: .documentSource) == [])
    }

    @Test func exactlyOneSubmissionSet() {
        #expect(XDSValidator.validate(XDSObjectList(), as: .documentSource).map(\.attribute) == ["count"])
    }

    @Test(arguments: [("1.2.250.1", true), ("1.02", false), ("1", false), ("1..2", false), ("a.b", false), ("0.1", true)])
    func oids(value: String, valid: Bool) {
        #expect(XDSValidator.isOID(value) == valid)
    }

    @Test func documentUniqueIdsMayHaveAnExtension() {
        #expect(XDSValidator.isDocumentUniqueId("1.2.3^ext"))
        #expect(!XDSValidator.isDocumentUniqueId("1.2.3^"))
        #expect(!XDSValidator.isDocumentUniqueId("1.2.3^" + String(repeating: "x", count: 17)))
    }
}

@Suite struct HL7TypeTests {
    @Test func cxRoundTripWithEscapes() throws {
        let cx = CXIdentifier(id: "A^B&C", assigningAuthority: "1.2.250.1.213.1.4.8", typeCode: "NH")
        #expect(cx.description == #"A\S\B\T\C^^^&1.2.250.1.213.1.4.8&ISO^NH"#)
        #expect(CXIdentifier(cx.description) == cx)
        #expect(CXIdentifier("id-only") == nil)
        #expect(CXIdentifier("id^^^&&ISO") == nil)
    }

    @Test func cxKeepsEveryComponent() throws {
        let raw = "id^4^M10^NS&1.2.3&ISO^NH^^20260101"
        let cx = try #require(CXIdentifier(raw))
        #expect(cx.description == raw)
        #expect(cx.assigningAuthorityNamespace == "NS")
        #expect(cx.otherComponents == [2: "4", 3: "M10", 7: "20260101"])
        #expect(!cx.isAffinityDomainIdentifier)
        #expect(try #require(CXIdentifier("id^^^&1.2.3&ISO")).isAffinityDomainIdentifier)
        #expect(try #require(CXIdentifier("id^^^&1.2.3&L")).isAffinityDomainIdentifier == false)
        #expect(try #require(CXIdentifier("id^^^&not-an-oid&ISO")).isAffinityDomainIdentifier == false)
    }

    @Test func xcnAndXon() {
        let p = XCNPerson(id: "801234567", family: "RADIOLOGUE", given: "ANNE", prefix: "Dr", assigningAuthority: "1.2.250.1.71.4.2.1")
        #expect(p.description == "801234567^RADIOLOGUE^ANNE^^^Dr^^^&1.2.250.1.71.4.2.1&ISO")
        #expect(XCNPerson(p.description) == p)
        let o = XONOrganization(name: "Centre d’imagerie", identifier: "3123456789", assigningAuthority: "1.2.250.1.71.4.2.2")
        #expect(XONOrganization(o.description) == o)
        #expect(XONOrganization("Name only") == XONOrganization(name: "Name only"))
    }

    @Test func dateTimes() throws {
        #expect(XDSDateTime("2026") != nil)
        #expect(XDSDateTime("202611") != nil)
        #expect(XDSDateTime("20261") == nil)
        #expect(XDSDateTime("2026111910150000") == nil)
        #expect(XDSDateTime("2026-11") == nil)
        #expect(XDSDateTime("20261399") == nil)
        #expect(XDSDateTime("20260230") == nil)
        #expect(XDSDateTime("20240229") != nil)
        #expect(XDSDateTime("20230229") == nil)
        #expect(XDSDateTime("2026111924") == nil)
        #expect(XDSDateTime("202611192360") == nil)
        let d = try #require(XDSDateTime("20261119"))
        #expect(d < XDSDateTime("20261119000001")!)
        #expect(try #require(d.date) == Date(timeIntervalSince1970: 1_795_046_400))
        #expect(XDSDateTime(Date(timeIntervalSince1970: 0)).value == "19700101000000")
    }
}

@Suite struct RegistryResponseTests {
    @Test func successAndFailureRoundTrip() throws {
        let failure = RegistryResponse.failure([
            RegistryError(XDSErrorCode.patientIdDoesNotMatch, "patient differs", location: "Document01"),
            RegistryError(XDSErrorCode.extraMetadataNotSaved, "slot dropped", severity: .warning),
        ])
        let xml = try XMLWriter.string(failure.element)
        #expect(xml.contains("highestSeverity=\"urn:oasis:names:tc:ebxml-regrep:ErrorSeverityType:Error\""))
        #expect(try RegistryResponse(element: XMLReader.parse(xml)) == failure)
        #expect(try RegistryResponse(element: XMLReader.parse(XMLWriter.data(RegistryResponse.success.element))).isSuccess)
    }

    @Test func readsTheStatusOfOtherResponses() throws {
        let query = """
        <query:AdhocQueryResponse xmlns:query="\(Namespace.query)" xmlns:rs="\(Namespace.rs)"
            status="urn:ihe:iti:2007:ResponseStatusType:PartialSuccess">
          <rs:RegistryErrorList><rs:RegistryError errorCode="XDSTooManyResults" codeContext="too many"/></rs:RegistryErrorList>
        </query:AdhocQueryResponse>
        """
        let q = try RegistryResponse(element: XMLReader.parse(query))
        #expect(q.status == .partialSuccess)
        #expect(q.errors == [RegistryError(XDSErrorCode.tooManyResults, "too many")])
        let retrieve = """
        <xdsb:RetrieveDocumentSetResponse xmlns:xdsb="\(Namespace.xdsb)" xmlns:rs="\(Namespace.rs)">
          <rs:RegistryResponse status="urn:oasis:names:tc:ebxml-regrep:ResponseStatusType:Success"/>
        </xdsb:RetrieveDocumentSetResponse>
        """
        #expect(try RegistryResponse(element: XMLReader.parse(retrieve)).isSuccess)
        // Older registries answer with the ebRS 3.0 short form of PartialSuccess.
        let short = "<r status=\"urn:oasis:names:tc:ebxml-regrep:ResponseStatusType:PartialSuccess\"/>"
        #expect(try RegistryResponse(element: XMLReader.parse(short)).status == .partialSuccess)
    }

    @Test func missingStatusIsRefused() {
        #expect(throws: XDSMetadataError.missingAttribute(element: "r", attribute: "status")) {
            try RegistryResponse(element: XElement(XName("r")))
        }
    }
}

/// An ITI-41 request from another stack (eHealth Suisse, Apache CXF; see Fixtures/README.md).
@Suite struct PublishedExampleTests {
    static func request() throws -> XElement {
        try fixture("epr-iti41-request.xml")
    }

    static func list() throws -> XElement {
        let request = try request()
        return try #require(request.element(named: XName(Namespace.lcm, "SubmitObjectsRequest"))?.element(named: XName(Namespace.rim, "RegistryObjectList")))
    }

    @Test func isReadAndValid() throws {
        let list = try XDSObjectList(registryObjectList: Self.list())
        let d = try #require(list.documentEntries.first)
        #expect(d.mimeType == "application/fhir+json")
        #expect(d.patientId?.id == "CHPAM3946")
        #expect(d.localizedTitle == [XDSLocalizedString("Vaccination - FSME-Immun 0.25 ml Junior", charset: "UTF-8")])
        #expect(d.confidentialityCodes.first?.localizedDisplayName == [XDSLocalizedString("Normal", language: "en-US", charset: "UTF-8")])
        #expect(d.extraSlots.map(\.name) == ["urn:e-health-suisse:2020:originalProviderRole"])
        #expect(d.componentIDs[XDSScheme.documentEntryUniqueId] == "urn:uuid:40e565f5-bd4b-4e8a-bb08-72d2257e8762")
        #expect(list.submissionSets.first?.componentIDs[XDSScheme.submissionSet] == "urn:uuid:b855e4d0-4adb-44e4-9bd7-76f8ab15899c")
        #expect(list.associations.first?.submissionSetStatus == .original)
        #expect(XDSValidator.validate(list, as: .documentSource) == [])
    }

    @Test func isRewrittenIdenticallyInTheXMLSense() throws {
        let original = try Self.list()
        let written = try XMLReader.parse(XMLWriter.data(XDSObjectList(registryObjectList: original).registryObjectList))
        let a = Canonical.form(original), b = Canonical.form(written)
        #expect(a == b, "\(Canonical.firstDifference(a, b) ?? "")")
    }

    @Test func derivedIDsDoNotCollideAcrossSubmissions() throws {
        // Symbolic objects get symbolic component IDs, replaced by the registry like the object's.
        let symbolic = RIM.derivedID(object: "Document01", key: XDSScheme.documentEntryUniqueId)
        #expect(symbolic.hasPrefix("Document01_"))
        #expect(!symbolic.hasPrefix("urn:uuid:"))
        #expect(symbolic != RIM.derivedID(object: "Document01", key: XDSScheme.documentEntryPatientId))
        // UUID objects get UUIDs, distinct per object.
        let a = RIM.derivedID(object: "urn:uuid:5e1f1c1a-0000-4000-8000-000000000001", key: XDSScheme.documentEntryUniqueId)
        let b = RIM.derivedID(object: "urn:uuid:5e1f1c1a-0000-4000-8000-000000000002", key: XDSScheme.documentEntryUniqueId)
        #expect(a.hasPrefix("urn:uuid:") && a.count == 45 && a != b)
        let ids = try objectList().registryObjectList.descendants(named: XName(Namespace.rim, "Classification")).compactMap { $0.attribute("id") }
        #expect(Set(ids).count == ids.count)
    }

    @Test func writingIsDeterministic() throws {
        let list = try objectList()
        #expect(try XMLWriter.data(list.registryObjectList) == XMLWriter.data(list.registryObjectList))
        let set = list.submissionSets[0]
        // A new object gets the same derived IDs on every write, and they read back as derived.
        #expect(set.element == set.element)
        #expect(try XDSSubmissionSet(element: XMLReader.parse(XMLWriter.data(set.element))) == set)
    }
}

/// Canonical form for comparing ebRIM documents: classifications and external identifiers moved
/// into their object, children sorted by kind then by name or ID, attributes sorted, whitespace-only
/// text dropped, default `objectType` values dropped. These differences carry no meaning in ebRIM.
enum Canonical {
    static let defaults: [String: String] = [
        "Classification": XDSScheme.classificationType, "ExternalIdentifier": XDSScheme.externalIdentifierType,
        "Association": XDSScheme.associationType, "RegistryPackage": XDSScheme.registryPackageType,
    ]
    static let rank = ["Slot": 0, "Name": 1, "Description": 2, "VersionInfo": 3, "Classification": 4, "ExternalIdentifier": 5]
    static let objects: Set<String> = ["ExtrinsicObject", "RegistryPackage", "Classification", "ExternalIdentifier", "Association"]

    static func form(_ list: XElement) -> XElement {
        var top = list.elements
        var moved: Set<Int> = []
        for (i, e) in top.enumerated() where e.name.local == "Classification" || e.name.local == "ExternalIdentifier" {
            let owner = e.attribute("classifiedObject") ?? e.attribute("registryObject")
            if let j = top.firstIndex(where: { $0.attribute("id") == owner && $0.name.local != e.name.local }) {
                top[j].append(e)
                moved.insert(i)
            }
        }
        let kept = top.enumerated().filter { !moved.contains($0.offset) }.map(\.element)
        return normalize(XElement(list.name, attributes: list.attributes, elements: kept))
    }

    static func normalize(_ e: XElement) -> XElement {
        var attributes = e.attributes
        if let d = defaults[e.name.local] { attributes.removeAll { $0.name == XName("objectType") && $0.value == d } }
        attributes.sort { ($0.name.namespace ?? "", $0.name.local) < ($1.name.namespace ?? "", $1.name.local) }
        var children: [XNode] = e.children.compactMap { node in
            switch node {
            case .element(let c): .element(normalize(c))
            case .text(let t): t.allSatisfy(\.isWhitespace) ? nil : .text(t)
            default: node
            }
        }
        if objects.contains(e.name.local) {
            func key(_ n: XNode) -> (Int, String) {
                guard case .element(let c) = n else { return (9, "") }
                return (rank[c.name.local] ?? 8, c.attribute("name") ?? c.attribute("id") ?? "")
            }
            children = children.enumerated().sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
        }
        return XElement(e.name, attributes: attributes, children: children)
    }

    static func firstDifference(_ a: XElement, _ b: XElement, path: String = "") -> String? {
        let here = path + "/" + a.name.local + (a.attribute("id").map { "[\($0)]" } ?? a.attribute("name").map { "[\($0)]" } ?? "")
        if a.name != b.name { return "\(here): \(a.name) vs \(b.name)" }
        if a.attributes != b.attributes { return "\(here): \(a.attributes) vs \(b.attributes)" }
        let ea = a.elements, eb = b.elements
        for (x, y) in zip(ea, eb) { if let d = firstDifference(x, y, path: here) { return d } }
        if ea.count != eb.count { return "\(here): \(ea.count) vs \(eb.count) children" }
        if a.text != b.text { return "\(here): text '\(a.text)' vs '\(b.text)'" }
        return nil
    }
}

@Suite struct StrictReadingTests {
    static func entry(_ change: (inout XElement) -> Void) throws -> XElement {
        var e = try objectList().documentEntries[0].element
        change(&e)
        return e
    }

    static func setSlot(_ e: inout XElement, _ name: String, _ value: String) {
        e.children.removeAll { if case .element(let c) = $0 { c.name.local == "Slot" && c.attribute("name") == name } else { false } }
        e.children.insert(.element(XElement(XName(Namespace.rim, "Slot"), attributes: [XAttribute(XName("name"), name)],
                                            elements: [XElement(XName(Namespace.rim, "ValueList"), elements: [XElement(XName(Namespace.rim, "Value"), text: value)])])), at: 0)
    }

    @Test(arguments: [("creationTime", "20261119101500+0100"), ("sourcePatientId", "no-authority"),
                      ("documentAvailability", "urn:example:Maybe"), ("serviceStartTime", "20261399")])
    func invalidSlotValuesAreErrors(slot: String, value: String) throws {
        let e = try Self.entry { Self.setSlot(&$0, slot, value) }
        #expect(throws: XDSMetadataError.invalidValue(attribute: slot, value: value)) { try XDSDocumentEntry(element: e) }
    }

    @Test func invalidStatusAndPatientAreErrors() throws {
        let e = try Self.entry { $0.setAttribute(XName("status"), "urn:example:Unknown") }
        #expect(throws: XDSMetadataError.invalidValue(attribute: "status", value: "urn:example:Unknown")) { try XDSDocumentEntry(element: e) }
        var list = try objectList()
        list.documentEntries[0].patientId = nil
        var element = list.documentEntries[0].element
        element.append(XElement(XName(Namespace.rim, "ExternalIdentifier"), attributes: [
            XAttribute(XName("identificationScheme"), XDSScheme.documentEntryPatientId), XAttribute(XName("value"), "bad"),
        ]))
        #expect(throws: XDSMetadataError.invalidValue(attribute: "patientId", value: "bad")) { try XDSDocumentEntry(element: element) }
    }

    @Test func unknownSubmissionSetStatusIsAnError() throws {
        var a = XDSAssociation.member(of: "SS", document: "D").element
        a.children = [.element(XElement(XName(Namespace.rim, "Slot"), attributes: [XAttribute(XName("name"), "SubmissionSetStatus")],
                                        elements: [XElement(XName(Namespace.rim, "ValueList"), elements: [XElement(XName(Namespace.rim, "Value"), text: "Maybe")])]))]
        #expect(throws: XDSMetadataError.invalidValue(attribute: "SubmissionSetStatus", value: "Maybe")) { try XDSAssociation(element: a) }
    }

    @Test func unclassifiedRegistryPackageIsAnError() throws {
        let list = XElement(XName(Namespace.rim, "RegistryObjectList"), elements: [
            XElement(XName(Namespace.rim, "RegistryPackage"), attributes: [XAttribute(XName("id"), "P1")]),
        ])
        #expect(throws: XDSMetadataError.unclassifiedRegistryPackage(id: "P1")) { try XDSObjectList(registryObjectList: list) }
    }

    @Test func upperCaseUUIDsAndSiblingIdentifiersAreRead() throws {
        var set = try objectList().submissionSets[0]
        set.patientId = nil
        set.authors = [XDSAuthor(person: "^RADIOLOGUE^ANNE")]
        var e = set.element
        // Upper-case scheme UUIDs, as some stacks write them.
        e.children = e.children.map { node in
            guard case .element(var c) = node, let s = c.attribute("classificationScheme") else { return node }
            c.setAttribute(XName("classificationScheme"), s.uppercased().replacingOccurrences(of: "URN:UUID:", with: "urn:uuid:"))
            return .element(c)
        }
        let patient = XElement(XName(Namespace.rim, "ExternalIdentifier"), attributes: [
            XAttribute(XName("id"), "ei-p"), XAttribute(XName("identificationScheme"), XDSScheme.submissionSetPatientId.uppercased()),
            XAttribute(XName("registryObject"), set.entryUUID), XAttribute(XName("value"), "SYNTH-1^^^&1.2.3&ISO"),
        ])
        let read = try XDSObjectList(registryObjectList: XElement(XName(Namespace.rim, "RegistryObjectList"), elements: [e, patient]))
        let s = try #require(read.submissionSets.first)
        #expect(s.contentTypeCode?.code == "IMG-KOS")
        #expect(s.authors.count == 1)
        #expect(s.patientId?.id == "SYNTH-1")
        #expect(s.componentIDs[XDSScheme.submissionSetPatientId] == "ei-p")
    }

    @Test func folderVersionAndLocalizedTitlesRoundTrip() throws {
        var folder = XDSFolder(entryUUID: "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000f1", uniqueId: "1.2.3.4",
                               patientId: CXIdentifier(id: "p", assigningAuthority: "1.2"),
                               codeList: [XDSCode(code: "c", codingScheme: "s", displayName: "d")], title: nil)
        folder.logicalID = "urn:uuid:5e1f1c1a-0000-4000-8000-0000000000f0"
        folder.version = "2"
        folder.localizedTitle = [XDSLocalizedString("Imagerie", language: "fr-FR"), XDSLocalizedString("Imaging", language: "en-US")]
        let read = try XDSFolder(element: XMLReader.parse(XMLWriter.data(folder.element)))
        #expect(read == folder)
        #expect(read.title == "Imagerie")
    }
}

@Suite struct ValidationRuleTests {
    @Test func patientIdMustBeTheRestrictedCX() throws {
        var list = try objectList()
        let local = try #require(CXIdentifier("SYNTH-0000042^^^&1.2.250.1.213.1.4.8&L^NH"))
        list.submissionSets[0].patientId = local
        list.documentEntries[0].patientId = local
        let issues = XDSValidator.validate(list, as: .documentSource).filter { $0.attribute == "patientId" }
        #expect(issues.map(\.objectID) == ["SubmissionSet01", "Document01"])
        // sourcePatientId may carry a type code.
        list = try objectList()
        list.documentEntries[0].sourcePatientId = local
        #expect(XDSValidator.validate(list, as: .documentSource) == [])
    }

    @Test func onDemandEntriesAreNotSubmittedWithITI41() throws {
        var list = try objectList()
        list.documentEntries[0].objectType = XDSScheme.documentEntryOnDemand
        #expect(XDSValidator.validate(list, as: .documentSource).map(\.attribute) == ["objectType"])
    }

    @Test func documentAuthorsNeedAPersonAnInstitutionOrATelecom() throws {
        var list = try objectList()
        list.documentEntries[0].authors = [XDSAuthor(roles: ["Radiologue"])]
        #expect(XDSValidator.validate(list, as: .documentSource).map(\.attribute) == ["author"])
    }

    @Test func folderMembership() throws {
        let base = try objectList()
        var set = base.submissionSets[0]
        set.submissionTime = nil
        let folder = XDSFolder(entryUUID: "Folder01", uniqueId: "1.2.250.1.999.6.1", patientId: base.submissionSets[0].patientId,
                               codeList: [XDSCode(code: "IMG", codingScheme: "1.2.250.1.999.7", displayName: "Imagerie")], title: "Dossier")
        let inFolder = XDSAssociation(id: "FolderMember01", type: .hasMember, source: "Folder01", target: "Document01")
        let list = XDSObjectList.submission(set, documents: base.documentEntries, folders: [folder], associations: [inFolder])
        // The factory sets the time, the statuses and the membership of the folder's association.
        #expect(list.submissionSets[0].submissionTime != nil)
        #expect(list.associations.filter { $0.submissionSetStatus != nil }.map(\.target) == ["Document01"])
        #expect(XDSValidator.validate(list, as: .documentSource) == [])
        var missing = list
        missing.associations.removeAll { $0.target == "FolderMember01" }
        #expect(XDSValidator.validate(missing, as: .documentSource).map(\.objectID) == ["FolderMember01"])
        var statusOnFolder = list
        statusOnFolder.associations = statusOnFolder.associations.map { a in
            var a = a
            if a.target == "Folder01" { a.submissionSetStatus = .original }
            return a
        }
        #expect(XDSValidator.validate(statusOnFolder, as: .documentSource).map(\.attribute) == ["SubmissionSetStatus"])
    }

    @Test func replacementMustTargetARegistryDocument() throws {
        var list = try objectList()
        var second = list.documentEntries[0]
        second.entryUUID = "Document02"
        second.uniqueId = "1.2.250.1.999.2.1.1.100"
        list.documentEntries.append(second)
        list.associations += [.member(of: "SubmissionSet01", document: "Document02"),
                              XDSAssociation(id: "rplc", type: .replace, source: "Document02", target: "Document01")]
        #expect(XDSValidator.validate(list, as: .documentSource).map(\.attribute) == ["targetObject"])
    }
}
