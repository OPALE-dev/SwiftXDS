import Foundation
import Testing
import SwiftXDS
import SwiftXDSClient
import SwiftXDSSOAP
import SwiftXDSTestRegistry

@Suite struct ReplaceAndDeprecateTests {
    let v1 = Data("version 1".utf8), v2 = Data("version 2".utf8)

    func updateSet(_ patientId: CXIdentifier = patient) -> XDSSubmissionSet {
        XDSSubmissionSet(entryUUID: "SubmissionSet01", uniqueId: "1.2.250.1.999.5.\(Int.random(in: 1...999_999))", sourceId: "1.2.250.1.999.4",
                         patientId: patientId, contentTypeCode: XDSCode(code: "IMG-KOS", codingScheme: "1.2.250.1.999.3", displayName: "Manifeste"))
    }

    /// A second version of the manifest of `original`, as a submission that replaces it.
    func replacement(of original: XDSDocumentEntry, uniqueId: String? = nil) -> XDSObjectList {
        var d = manifestSubmission().documentEntries[0]
        d.entryUUID = "Document02"
        d.uniqueId = uniqueId ?? original.uniqueId + ".2"
        d.patientId = original.patientId
        var set = updateSet(original.patientId!)
        set.entryUUID = "SubmissionSet02"
        return .replacement(of: original.entryUUID, by: d, in: set)
    }

    func publish(_ h: Harness) async throws -> XDSDocumentEntry {
        let submission = manifestSubmission()
        #expect(try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: v1)], to: h.server.url).isSuccess)
        return try #require(await h.registry.documentEntries.values.first { $0.uniqueId == submission.documentEntries[0].uniqueId })
    }

    /// The exit criterion of #227: replaced, then withdrawn; ITI-18 returns the approved version, then none.
    @Test func replacedThenWithdrawn() async throws {
        try await withHarness { h in
            let original = try await publish(h)
            let replacing = replacement(of: original)
            #expect(try await h.client.provideAndRegister(replacing, documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url).isSuccess)

            let approved = try await h.client.findDocuments(patientId: patient, registry: h.server.url).objects.documentEntries
            #expect(approved.map(\.uniqueId) == [replacing.documentEntries[0].uniqueId])
            let deprecated = try await h.client.findDocuments(patientId: patient, XDSDocumentFilter(status: [.deprecated]), registry: h.server.url)
            #expect(deprecated.objects.documentEntries.map(\.entryUUID) == [original.entryUUID])
            let current = try #require(approved.first)
            let retrieved = try await h.client.retrieve([try #require(XDSDocumentRequest(current))], from: h.server.url)
            #expect(try await retrieved.documents.first?.data() == v2)

            #expect(try await h.client.deprecate([current.entryUUID], in: updateSet(), registry: h.server.url).isSuccess)
            #expect(try await h.client.findDocuments(patientId: patient, registry: h.server.url).objects.documentEntries.isEmpty)
            let both = try await h.client.findDocuments(patientId: patient, XDSDocumentFilter(status: [.approved, .deprecated]), registry: h.server.url)
            #expect(both.objects.documentEntries.count == 2)
            // The update is recorded: its submission set and the association with both statuses.
            let update = try #require(await h.registry.associations.values.first { $0.type == .updateAvailabilityStatus })
            #expect(update.target == current.entryUUID)
            #expect(update.statusChange?.original == .approved && update.statusChange?.new == .deprecated)
            #expect(await h.registry.submissionSets[update.source] != nil)
        }
    }

    @Test func onlyTheApprovedVersionOfTheSamePatientCanBeReplaced() async throws {
        try await withHarness { h in
            let original = try await publish(h)
            let first = replacement(of: original)
            _ = try await h.client.provideAndRegister(first, documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url)
            // Replacing the deprecated version again.
            let again = try await h.client.provideAndRegister(replacement(of: original, uniqueId: original.uniqueId + ".3"),
                                                              documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url)
            #expect(again.errors.map(\.errorCode) == [XDSErrorCode.registryDeprecatedDocumentError])
            // Another patient's document.
            var foreign = original
            foreign.patientId = CXIdentifier(id: "SYNTH-0000043", assigningAuthority: "1.2.250.1.213.1.4.8")
            let current = try #require(await h.registry.documentEntries.values.first { $0.availabilityStatus == .approved })
            foreign.entryUUID = current.entryUUID
            let other = try await h.client.provideAndRegister(replacement(of: foreign, uniqueId: original.uniqueId + ".4"),
                                                              documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url)
            #expect(other.errors.map(\.errorCode) == [XDSErrorCode.patientIdDoesNotMatch])
            // A target the registry does not have.
            foreign = original
            foreign.entryUUID = "urn:uuid:00000000-0000-4000-8000-0000000000aa"
            let unknown = try await h.client.provideAndRegister(replacement(of: foreign, uniqueId: original.uniqueId + ".5"),
                                                                documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url)
            #expect(unknown.errors.map(\.errorCode) == [XDSErrorCode.unresolvedReference])
            #expect(await h.registry.documentEntries.count == 2, "refused submissions store nothing")
        }
    }

    @Test func theReplacementJoinsTheOriginalsFolders() async throws {
        try await withHarness { h in
            var submission = manifestSubmission()
            let folder = XDSFolder(entryUUID: "Folder01", uniqueId: submission.submissionSets[0].uniqueId + ".9", patientId: patient,
                                   codeList: [XDSCode(code: "IMG", codingScheme: "1.2.3", displayName: "Imagerie")], title: "Dossier")
            submission = .submission(submission.submissionSets[0], documents: submission.documentEntries, folders: [folder],
                                     associations: [XDSAssociation(type: .hasMember, source: "Folder01", target: "Document01")])
            #expect(try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: v1)], to: h.server.url).isSuccess)
            let original = try #require(await h.registry.documentEntries.values.first)
            let replacing = replacement(of: original)
            #expect(try await h.client.provideAndRegister(replacing, documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url).isSuccess)
            let new = try #require(await h.registry.documentEntries.values.first { $0.availabilityStatus == .approved })
            let folderID = try #require(await h.registry.folders.keys.first)
            #expect(await h.registry.associations.values.contains { $0.type == .hasMember && $0.source == folderID && $0.target == new.entryUUID })
        }
    }

    @Test func statusUpdateErrors() async throws {
        try await withHarness { h in
            let original = try await publish(h)
            let wrongOriginal = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet(), from: .deprecated, to: .approved)
            #expect(try await h.client.updateDocumentSet(wrongOriginal, registry: h.server.url).errors.map(\.errorCode) == [XDSErrorCode.metadataUpdateError])
            let unknown = XDSObjectList.statusUpdate(["urn:uuid:00000000-0000-4000-8000-0000000000bb"], in: updateSet())
            #expect(try await h.client.updateDocumentSet(unknown, registry: h.server.url).errors.map(\.errorCode) == [XDSErrorCode.unresolvedReference])
            let otherPatient = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet(CXIdentifier(id: "SYNTH-0000043", assigningAuthority: "1.2.250.1.213.1.4.8")))
            #expect(try await h.client.updateDocumentSet(otherPatient, registry: h.server.url).errors.map(\.errorCode) == [XDSErrorCode.patientIdDoesNotMatch])
            #expect(await h.registry.documentEntries[original.entryUUID]?.availabilityStatus == .approved)
            // Refused by the client before sending: same status twice.
            let same = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet(), from: .approved, to: .approved)
            await #expect(throws: XDSClientError.self) { try await h.client.updateDocumentSet(same, registry: h.server.url) }
        }
    }

    @Test func aWithdrawnDocumentCanBeApprovedAgainUnlessReplaced() async throws {
        try await withHarness { h in
            let original = try await publish(h)
            #expect(try await h.client.deprecate([original.entryUUID], in: updateSet(), registry: h.server.url).isSuccess)
            let back = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet(), from: .deprecated, to: .approved)
            #expect(try await h.client.updateDocumentSet(back, registry: h.server.url).isSuccess)
            #expect(try await h.client.findDocuments(patientId: patient, registry: h.server.url).objects.documentEntries.map(\.entryUUID) == [original.entryUUID])
            // Once replaced, the original stays withdrawn.
            #expect(try await h.client.provideAndRegister(replacement(of: original), documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url).isSuccess)
            let again = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet(), from: .deprecated, to: .approved)
            #expect(try await h.client.updateDocumentSet(again, registry: h.server.url).errors.map(\.errorCode) == [XDSErrorCode.metadataUpdateError])
        }
    }

    @Test func replacingDeprecatesTransformsAndAddenda() async throws {
        try await withHarness { h in
            let original = try await publish(h)
            var addendum = replacement(of: original)
            addendum.associations = addendum.associations.map { a in
                var a = a
                if a.type == .replace { a.type = .append }
                return a
            }
            #expect(try await h.client.provideAndRegister(addendum, documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url).isSuccess)
            #expect(await h.registry.documentEntries.values.filter { $0.availabilityStatus == .approved }.count == 2)
            #expect(try await h.client.provideAndRegister(replacement(of: original, uniqueId: original.uniqueId + ".3"),
                                                         documents: [XDSDocument(entryUUID: "Document02", data: v2)], to: h.server.url).isSuccess)
            let approved = await h.registry.documentEntries.values.filter { $0.availabilityStatus == .approved }
            #expect(approved.map(\.uniqueId) == [original.uniqueId + ".3"])
        }
    }

    @Test func symbolicAssociationIDsBecomeUUIDsAndExistingOnesAreRefused() async throws {
        try await withHarness { h in
            let original = try await publish(h)
            var update = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet())
            update.associations[0].id = "Update01"
            #expect(try await h.client.updateDocumentSet(update, registry: h.server.url).isSuccess)
            let stored = try #require(await h.registry.associations.values.first { $0.type == .updateAvailabilityStatus })
            #expect(stored.id.hasPrefix("urn:uuid:"))
            var reused = XDSObjectList.statusUpdate([original.entryUUID], in: updateSet(), from: .deprecated, to: .approved)
            reused.associations[0].id = stored.id
            #expect(try await h.client.updateDocumentSet(reused, registry: h.server.url).errors.map(\.errorCode) == [XDSErrorCode.registryMetadataError])
        }
    }

    @Test func statusUpdatesAreForITI57Only() async throws {
        try await withHarness(validates: false) { h in
            let original = try await publish(h)
            var submission = manifestSubmission()
            submission.associations.append(.statusUpdate(of: original.entryUUID, by: submission.submissionSets[0].entryUUID, from: .approved, to: .deprecated))
            let response = try await h.client.provideAndRegister(submission, documents: [XDSDocument(entryUUID: "Document01", data: v1)], to: h.server.url)
            #expect(response.errors.map(\.errorCode).contains(XDSErrorCode.registryMetadataError))
            #expect(await h.registry.documentEntries[original.entryUUID]?.availabilityStatus == .approved)
        }
    }
}
