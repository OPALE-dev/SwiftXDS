import AsyncHTTPClient
import Foundation
import Testing
import SwiftXDS
import SwiftXDSClient

/// The complete path of a document source and consumer against a third-party registry and repository,
/// such as a simulator of the NIST XDS Toolkit. Skipped unless the environment names one:
///
/// - `SWIFTXDS_EXTERNAL_SIMULATOR`: base address of a Toolkit registry/repository simulator
///   (`…/xdstools/sim/<user>__<id>`); the endpoints are its `rep/prb`, `reg/sq`, `rep/ret` and `reg/update`.
/// - `SWIFTXDS_EXTERNAL_PATIENT`: `id^^^&oid&ISO` of a patient the registry knows (patient identity feed).
///
/// The metadata codes are those of the Toolkit's default affinity domain (`codes.xml`), which the
/// simulator validates.
enum ExternalRegistry {
    static let environment = ProcessInfo.processInfo.environment
    static var simulator: URL? { environment["SWIFTXDS_EXTERNAL_SIMULATOR"].flatMap(URL.init(string:)) }
    static var enabled: Bool { simulator != nil && patient != nil }

    static var patient: CXIdentifier? {
        guard let value = environment["SWIFTXDS_EXTERNAL_PATIENT"] else { return nil }
        let components = value.components(separatedBy: "^")
        guard components.count >= 4 else { return nil }
        let authority = components[3].components(separatedBy: "&")
        guard authority.count >= 2, !components[0].isEmpty, !authority[1].isEmpty else { return nil }
        return CXIdentifier(id: components[0], assigningAuthority: authority[1])
    }

    static func endpoint(_ path: String) -> URL { simulator!.appendingPathComponent(path) }

    static func submissionSet(_ patient: CXIdentifier, entryUUID: String = "SubmissionSet01") -> XDSSubmissionSet {
        XDSSubmissionSet(entryUUID: entryUUID, uniqueId: "1.2.250.1.999.5.\(UInt32.random(in: 1...UInt32.max))", sourceId: "1.2.250.1.999.4",
                         patientId: patient,
                         contentTypeCode: XDSCode(code: "22232009", codingScheme: "2.16.840.1.113883.6.96", displayName: "Hospital"))
    }

    /// An imaging manifest entry coded with the Toolkit's default codes.
    static func manifest(_ patient: CXIdentifier, entryUUID: String, uniqueId: String) -> XDSDocumentEntry {
        var d = XDSDocumentEntry(entryUUID: entryUUID, uniqueId: uniqueId, patientId: patient, mimeType: "application/dicom")
        d.sourcePatientId = CXIdentifier(id: "P-0042", assigningAuthority: "1.2.250.1.999.1.1")
        d.creationTime = XDSDateTime("20261120101500")
        d.languageCode = "fr-FR"
        d.title = "Imaging manifest"
        d.classCode = XDSCode(code: "IMAGES", codingScheme: "1.3.6.1.4.1.19376.1.2.6.1", displayName: "Images")
        d.confidentialityCodes = [XDSCode(code: "N", codingScheme: "2.16.840.1.113883.5.25", displayName: "normal")]
        d.formatCode = XDSCode(code: "1.2.840.10008.5.1.4.1.1.88.59", codingScheme: "1.2.840.10008.2.6.1", displayName: "Key Object Selection Document")
        d.healthcareFacilityTypeCode = XDSCode(code: "22232009", codingScheme: "2.16.840.1.113883.6.96", displayName: "Hospital")
        d.practiceSettingCode = XDSCode(code: "309964003", codingScheme: "2.16.840.1.113883.6.96", displayName: "Radiology department (environment)")
        d.typeCode = XDSCode(code: "18748-4", codingScheme: "2.16.840.1.113883.6.1", displayName: "Diagnostic imaging study")
        d.authors = [XDSAuthor(person: XCNPerson(id: "801234567", family: "RADIOLOGUE", given: "ANNE", assigningAuthority: "1.2.250.1.71.4.2.1"))]
        return d
    }
}

@Suite(.enabled(if: ExternalRegistry.enabled, "SWIFTXDS_EXTERNAL_SIMULATOR and SWIFTXDS_EXTERNAL_PATIENT name a third-party registry"),
       .serialized)
struct ExternalRegistryTests {
    let v1 = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let v2 = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 11) })

    /// ITI-41 publish, ITI-18 find, ITI-43 retrieve, ITI-41 replace (RPLC), ITI-57 deprecate.
    @Test func publishFindRetrieveReplaceAndWithdraw() async throws {
        let patient = try #require(ExternalRegistry.patient)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            try await run(XDSClient(transport: XDSHTTPTransport(client: http)), patient: patient)
            try await http.shutdown()
        } catch {
            try? await http.shutdown()
            throw error
        }
    }

    func run(_ client: XDSClient, patient: CXIdentifier) async throws {
        let pnr = ExternalRegistry.endpoint("rep/prb"), sq = ExternalRegistry.endpoint("reg/sq")
        let ret = ExternalRegistry.endpoint("rep/ret"), update = ExternalRegistry.endpoint("reg/update")
        let base = "1.2.250.1.999.2.1.\(UInt32.random(in: 1...UInt32.max))"

        // ITI-41: publish the first version.
        let first = XDSObjectList.submission(ExternalRegistry.submissionSet(patient),
                                             documents: [ExternalRegistry.manifest(patient, entryUUID: "Document01", uniqueId: base + ".1")])
        let published = try await client.provideAndRegister(first, documents: [XDSDocument(entryUUID: "Document01", data: v1)], to: pnr)
        #expect(published.isSuccess, "ITI-41: \(published.errors)")

        // ITI-18: the registry returns it, approved, with the repository's hash and size.
        let found = try await client.findDocuments(patientId: patient, registry: sq)
        #expect(found.response.isSuccess, "ITI-18: \(found.response.errors)")
        let original = try #require(found.objects.documentEntries.first { $0.uniqueId == base + ".1" }, "ITI-18 does not return the published entry")
        #expect(original.availabilityStatus == .approved)
        #expect(original.hash == XDSHash.sha1(v1))
        #expect(original.size == Int64(v1.count))

        // ITI-43: the repository returns the same bytes, which match the entry.
        let retrieved = try await client.retrieve([try #require(XDSDocumentRequest(original))], from: ret)
        #expect(retrieved.response.isSuccess, "ITI-43: \(retrieved.response.errors)")
        let document = try #require(retrieved.documents.first)
        #expect(try await document.data() == v1)
        #expect(try await document.matches(original))

        // ITI-41 with RPLC: the second version replaces the first, which becomes deprecated.
        let replacing = XDSObjectList.replacement(of: original.entryUUID,
                                                  by: ExternalRegistry.manifest(patient, entryUUID: "Document02", uniqueId: base + ".2"),
                                                  in: ExternalRegistry.submissionSet(patient, entryUUID: "SubmissionSet02"))
        let replaced = try await client.provideAndRegister(replacing, documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: pnr)
        #expect(replaced.isSuccess, "ITI-41 RPLC: \(replaced.errors)")
        let approved = try await client.findDocuments(patientId: patient, registry: sq).objects.documentEntries.filter { $0.uniqueId.hasPrefix(base) }
        #expect(approved.map(\.uniqueId) == [base + ".2"])
        let deprecated = try await client.findDocuments(patientId: patient, XDSDocumentFilter(status: [.deprecated]), registry: sq)
            .objects.documentEntries.filter { $0.uniqueId.hasPrefix(base) }
        #expect(deprecated.map(\.entryUUID) == [original.entryUUID])

        // ITI-57: withdraw the current version; no approved version remains.
        let current = try #require(approved.first)
        let withdrawn = try await client.deprecate([current.entryUUID], in: ExternalRegistry.submissionSet(patient), registry: update)
        #expect(withdrawn.isSuccess, "ITI-57: \(withdrawn.errors)")
        let remaining = try await client.findDocuments(patientId: patient, registry: sq).objects.documentEntries.filter { $0.uniqueId.hasPrefix(base) }
        #expect(remaining.isEmpty)
        let both = try await client.findDocuments(patientId: patient, XDSDocumentFilter(status: [.approved, .deprecated]), registry: sq)
            .objects.documentEntries.filter { $0.uniqueId.hasPrefix(base) }
        #expect(Set(both.map(\.uniqueId)) == [base + ".1", base + ".2"])
    }
}
