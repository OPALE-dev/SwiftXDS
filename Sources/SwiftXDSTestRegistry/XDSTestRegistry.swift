import Foundation
import SwiftXDS
import SwiftXDSClient
import SwiftXDSSOAP

/// An XDS.b registry and repository in memory, for tests and simulators. It answers ITI-41 (with
/// replacement), ITI-18 (FindDocuments, GetDocuments, GetSubmissionSetAndContents), ITI-43 and
/// ITI-57 (status updates) with the checks of ITI TF-2 and TF-3 that a client can be expected to
/// meet; it is not a production registry.
public actor XDSTestRegistry {
    public struct StoredDocument: Sendable {
        public var mimeType: String
        public var data: Data
    }

    public nonisolated let repositoryUniqueId: String
    public nonisolated let homeCommunityId: String?
    /// When set, submissions for other patients are refused (`XDSUnknownPatientId`).
    public var knownPatients: Set<CXIdentifier>?

    public private(set) var documentEntries: [String: XDSDocumentEntry] = [:]
    public private(set) var submissionSets: [String: XDSSubmissionSet] = [:]
    public private(set) var folders: [String: XDSFolder] = [:]
    public private(set) var associations: [String: XDSAssociation] = [:]
    /// Documents by `DocumentEntry.uniqueId`.
    public private(set) var documents: [String: StoredDocument] = [:]
    /// Requests received, for assertions in tests (action, then the headers other than WS-Addressing).
    public private(set) var received: [(action: String, headers: [XElement])] = []
    /// Header blocks accepted with `mustUnderstand`, besides WS-Addressing.
    public nonisolated let understoodHeaders: Set<XName>

    /// `wsse:Security`, which carries the security assertion (XUA, VIHF of the French DMP).
    public static let wsSecurity = XName("http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd", "Security")

    /// `understoodHeaders`: header blocks marked `mustUnderstand` that the registry accepts (it
    /// does not check them), such as `XDSTestRegistry.wsSecurity`; others get a MustUnderstand fault.
    public init(repositoryUniqueId: String = "1.3.6.1.4.1.21367.13.70.1", homeCommunityId: String? = nil,
                knownPatients: Set<CXIdentifier>? = nil, understoodHeaders: Set<XName> = []) {
        self.repositoryUniqueId = repositoryUniqueId
        self.homeCommunityId = homeCommunityId
        self.knownPatients = knownPatients
        self.understoodHeaders = understoodHeaders
    }

    public func setKnownPatients(_ patients: Set<CXIdentifier>?) { knownPatients = patients }

    static let addressingHeaders = Set(["Action", "MessageID", "ReplyTo", "To", "RelatesTo", "FaultTo", "From"].map { XName(Namespace.addressing, $0) })

    /// Answers one SOAP request: a response, or a SOAP fault for addressing errors.
    public func handle(_ request: SOAPMessage) async -> SOAPMessage {
        let envelope = request.envelope
        guard let addressing = envelope.addressing else {
            return Self.fault(.sender, subcode: "MessageAddressingHeaderRequired", reason: "WS-Addressing Action header required", relatesTo: nil)
        }
        received.append((addressing.action, envelope.headers.filter { $0.name.namespace != Namespace.addressing }))
        let unknown = envelope.notUnderstoodHeaders(understood: Self.addressingHeaders.union(understoodHeaders))
        guard unknown.isEmpty else {
            return Self.fault(.mustUnderstand, subcode: nil, reason: "Header not understood: \(unknown[0].name)", relatesTo: addressing.messageID)
        }
        guard let transaction = XDSTransaction(requestAction: addressing.action) else {
            return Self.fault(.sender, subcode: "ActionNotSupported", reason: "Action not supported: \(addressing.action)", relatesTo: addressing.messageID)
        }
        let reply: SOAPMessage
        switch transaction {
        case .provideAndRegister:
            reply = SOAPMessage(envelope: SOAPEnvelope(body: [await provideAndRegister(request).element]))
        case .registryStoredQuery:
            reply = SOAPMessage(envelope: SOAPEnvelope(body: [query(request).element]))
        case .retrieveDocumentSet:
            reply = retrieve(request)
        case .updateDocumentSet:
            reply = SOAPMessage(envelope: SOAPEnvelope(body: [updateDocumentSet(request).element]))
        default:
            return Self.fault(.sender, subcode: "ActionNotSupported", reason: "\(transaction.rawValue) not simulated yet", relatesTo: addressing.messageID)
        }
        var out = reply
        out.envelope.headers = addressing.response(action: transaction.responseAction).headers
        return out
    }

    static func fault(_ code: SOAPFault.Code, subcode: String?, reason: String, relatesTo: String?) -> SOAPMessage {
        let fault = SOAPFault(code: code, subcodes: subcode.map { [XName(Namespace.addressing, $0)] } ?? [], reason: reason)
        let wsa = WSAddressing(action: SOAPFault.faultAction, messageID: XDSMetadata.newUUID(), relatesTo: relatesTo)
        return SOAPMessage(envelope: SOAPEnvelope(addressing: wsa, payload: fault.element))
    }

    // MARK: ITI-41

    func provideAndRegister(_ request: SOAPMessage) async -> RegistryResponse {
        guard let payload = request.envelope.payload, payload.name == XDSMessage.provideAndRegisterRequest,
              let list = payload.element(named: XDSMessage.submitObjectsRequest)?.element(named: XDSMessage.registryObjectList)
        else {
            return .failure([RegistryError(XDSErrorCode.repositoryError, "ProvideAndRegisterDocumentSetRequest with SubmitObjectsRequest expected")])
        }
        var submission: XDSObjectList
        do {
            submission = try XDSObjectList(registryObjectList: list)
        } catch {
            return .failure([RegistryError(XDSErrorCode.registryMetadataError, String(describing: error))])
        }
        var errors: [RegistryError] = []

        // Documents: each DocumentEntry has exactly one, and the other way round.
        var bodies: [String: Data] = [:]
        var reported: Set<String> = []
        for document in payload.elements(named: XDSMessage.document) {
            guard let id = document.attribute("id"), !id.isEmpty else {
                errors.append(RegistryError(XDSErrorCode.repositoryError, "xdsb:Document without id"))
                continue
            }
            guard bodies[id] == nil, !reported.contains(id) else {
                errors.append(RegistryError(XDSErrorCode.repositoryDuplicateUniqueIdInMessage, "two documents for DocumentEntry \(id)", location: id))
                continue
            }
            if document.element(named: XOP.includeName) != nil {
                guard let cid = XOP.contentID(in: document), let attachment = request.attachment(contentID: cid) else {
                    let href = document.element(named: XOP.includeName)?.attribute("href") ?? ""
                    errors.append(RegistryError(XDSErrorCode.missingDocument, "xop:Include \(href) of document \(id) names no MTOM part", location: id))
                    reported.insert(id)
                    continue
                }
                do {
                    bodies[id] = try await attachment.data()
                } catch {
                    errors.append(RegistryError(XDSErrorCode.repositoryError, "cannot read document \(id): \(error)", location: id))
                    reported.insert(id)
                }
            } else {
                let text = document.trimmedText
                guard !text.isEmpty, let inline = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
                    errors.append(RegistryError(XDSErrorCode.missingDocument, "document \(id) has neither an xop:Include nor base64 content", location: id))
                    reported.insert(id)
                    continue
                }
                bodies[id] = inline
            }
        }
        let entryIDs = Set(submission.documentEntries.map(\.entryUUID))
        for id in entryIDs.sorted() where bodies[id] == nil && !reported.contains(id) {
            errors.append(RegistryError(XDSErrorCode.missingDocument, "no document for DocumentEntry \(id)", location: id))
        }
        for id in Set(bodies.keys).union(reported).sorted() where !entryIDs.contains(id) {
            errors.append(RegistryError(XDSErrorCode.missingDocumentMetadata, "document \(id) has no DocumentEntry", location: id))
        }

        // Repository: hash, size and repositoryUniqueId (ITI-42 metadata).
        for i in submission.documentEntries.indices {
            let entry = submission.documentEntries[i]
            guard let data = bodies[entry.entryUUID] else { continue }
            let hash = XDSHash.sha1(data)
            if let given = entry.hash, given.lowercased() != hash {
                errors.append(RegistryError(XDSErrorCode.nonIdenticalHash, "hash \(given) differs from the document's \(hash)", location: entry.entryUUID))
            }
            if let given = entry.size, given != Int64(data.count) {
                errors.append(RegistryError(XDSErrorCode.nonIdenticalSize, "size \(given) differs from the document's \(data.count)", location: entry.entryUUID))
            }
            submission.documentEntries[i].hash = hash
            submission.documentEntries[i].size = Int64(data.count)
            submission.documentEntries[i].repositoryUniqueId = repositoryUniqueId
        }
        // The repository's attributes of a missing document are not reported again.
        errors += XDSValidator.validate(submission, as: .documentRepository)
            .filter { bodies[$0.objectID] != nil || !["hash", "size", "repositoryUniqueId"].contains($0.attribute) }
            .map(\.registryError)

        // Registry: known patient, unique IDs, references to existing objects.
        if let known = knownPatients, let set = submission.submissionSets.first, let patient = set.patientId, !known.contains(patient) {
            errors.append(RegistryError(XDSErrorCode.unknownPatientId, "patient \(patient) is not known in this affinity domain", location: set.entryUUID))
        }
        let existingUniqueIds = Set(documentEntries.values.map(\.uniqueId) + submissionSets.values.map(\.uniqueId) + folders.values.map(\.uniqueId))
        for (id, unique) in submission.documentEntries.map({ ($0.entryUUID, $0.uniqueId) }) + submission.submissionSets.map({ ($0.entryUUID, $0.uniqueId) })
            + submission.folders.map({ ($0.entryUUID, $0.uniqueId) }) where existingUniqueIds.contains(unique) {
            errors.append(RegistryError(XDSErrorCode.duplicateUniqueIdInRegistry, "uniqueId \(unique) already registered", location: id))
        }
        let local = Set(submission.documentEntries.map(\.entryUUID) + submission.submissionSets.map(\.entryUUID)
            + submission.folders.map(\.entryUUID) + submission.associations.map(\.id))
        // An entryUUID given by the source must be new: refused rather than renumbered.
        for id in local.sorted() where exists(id) {
            errors.append(RegistryError(XDSErrorCode.registryMetadataError, "\(id) is already in the registry; a submitted object needs a new entryUUID", location: id))
        }
        for a in submission.associations {
            for ref in [a.source, a.target] where !local.contains(ref) && !exists(ref) {
                errors.append(RegistryError(XDSErrorCode.unresolvedReference, "\(ref) is not in the registry", location: a.id))
            }
        }
        errors += relationshipErrors(submission)
        guard errors.isEmpty else { return .failure(errors) }

        // Store, atomically: symbolic IDs become UUIDs, every object is Approved.
        var ids: [String: String] = [:]
        for id in local {
            ids[id] = id.lowercased().hasPrefix("urn:uuid:") ? id : XDSMetadata.newUUID()
        }
        func map(_ id: String) -> String { ids[id] ?? id }
        for var d in submission.documentEntries {
            let data = bodies[d.entryUUID]!
            d.entryUUID = map(d.entryUUID)
            d.logicalID = d.entryUUID
            d.version = "1"
            d.availabilityStatus = .approved
            d.homeCommunityId = homeCommunityId
            documentEntries[d.entryUUID] = d
            documents[d.uniqueId] = StoredDocument(mimeType: d.mimeType, data: data)
        }
        for var s in submission.submissionSets {
            s.entryUUID = map(s.entryUUID)
            s.availabilityStatus = .approved
            s.homeCommunityId = homeCommunityId
            submissionSets[s.entryUUID] = s
        }
        for var f in submission.folders {
            f.entryUUID = map(f.entryUUID)
            f.availabilityStatus = .approved
            f.lastUpdateTime = .now()
            f.homeCommunityId = homeCommunityId
            folders[f.entryUUID] = f
        }
        for var a in submission.associations {
            a.id = map(a.id)
            a.source = map(a.source)
            a.target = map(a.target)
            a.availabilityStatus = .approved
            associations[a.id] = a
        }
        // Replacement: the original is deprecated, the replacement joins its folders (§4.2.2.2.1).
        for a in submission.associations where [.replace, .transformAndReplace].contains(a.type) {
            let original = map(a.target), replacement = map(a.source)
            documentEntries[original]?.availabilityStatus = .deprecated
            // Its transformations and addenda go with it.
            for related in associations.values where [.transform, .append].contains(related.type) && related.target == original {
                documentEntries[related.source]?.availabilityStatus = .deprecated
            }
            for link in associations.values where link.type == .hasMember && link.target == original && folders[link.source] != nil {
                var copy = XDSAssociation(type: .hasMember, source: link.source, target: replacement)
                copy.availabilityStatus = .approved
                associations[copy.id] = copy
                folders[link.source]?.lastUpdateTime = .now()
            }
        }
        return .success
    }

    /// Document relationships (RPLC, XFRM, APND, XFRM_RPLC): the original is an Approved
    /// DocumentEntry of the same patient. Status updates belong to ITI-57.
    func relationshipErrors(_ submission: XDSObjectList) -> [RegistryError] {
        var errors: [RegistryError] = []
        let replaced = Dictionary(grouping: submission.associations.filter { [.replace, .transformAndReplace].contains($0.type) }, by: \.target)
        for (target, list) in replaced where list.count > 1 {
            errors.append(RegistryError(XDSErrorCode.registryMetadataError, "\(target) is replaced twice in one submission", location: list[0].id))
        }
        for a in submission.associations {
            if a.type == .updateAvailabilityStatus {
                errors.append(RegistryError(XDSErrorCode.registryMetadataError, "UpdateAvailabilityStatus is sent with ITI-57, not ITI-41", location: a.id))
                continue
            }
            guard [.replace, .transform, .append, .transformAndReplace].contains(a.type), exists(a.target) else { continue }
            guard let original = documentEntries[a.target] else {
                errors.append(RegistryError(XDSErrorCode.registryMetadataError, "\(a.type) must point to a DocumentEntry", location: a.id))
                continue
            }
            if original.availabilityStatus != .approved {
                errors.append(RegistryError(XDSErrorCode.registryDeprecatedDocumentError, "\(a.target) is not Approved: only the current version can be \(a.type == .replace ? "replaced" : "related to")", location: a.id))
            }
            if let document = submission.documentEntries.first(where: { $0.entryUUID == a.source }), document.patientId != original.patientId {
                errors.append(RegistryError(XDSErrorCode.patientIdDoesNotMatch, "\(a.source) and the original \(a.target) are of different patients", location: a.id))
            }
        }
        return errors
    }

    // MARK: ITI-57

    /// Update Document Set: status changes of DocumentEntries and Folders. Metadata updates (a new
    /// version of an object) are not simulated and get `XDSMetadataUpdateOperationError`.
    func updateDocumentSet(_ request: SOAPMessage) -> RegistryResponse {
        guard let payload = request.envelope.payload, payload.name == XDSMessage.submitObjectsRequest,
              let list = payload.element(named: XDSMessage.registryObjectList) else {
            return .failure([RegistryError(XDSErrorCode.registryError, "SubmitObjectsRequest expected")])
        }
        let update: XDSObjectList
        do { update = try XDSObjectList(registryObjectList: list) } catch {
            return .failure([RegistryError(XDSErrorCode.registryMetadataError, String(describing: error))])
        }
        var errors = XDSValidator.validate(update, as: .updateDocumentSet).map(\.registryError)
        guard let set = update.submissionSets.first else { return .failure(errors) }
        for id in update.documentEntries.map(\.entryUUID) + update.folders.map(\.entryUUID) {
            errors.append(RegistryError(XDSErrorCode.metadataUpdateOperationError, "metadata updates (new versions) are not simulated by XDSTestRegistry", location: id))
        }
        if exists(set.entryUUID) {
            errors.append(RegistryError(XDSErrorCode.registryMetadataError, "\(set.entryUUID) is already in the registry", location: set.entryUUID))
        }
        if submissionSets.values.contains(where: { $0.uniqueId == set.uniqueId }) {
            errors.append(RegistryError(XDSErrorCode.duplicateUniqueIdInRegistry, "uniqueId \(set.uniqueId) already registered", location: set.entryUUID))
        }
        let replacedBy = Dictionary(associations.values.filter { [.replace, .transformAndReplace].contains($0.type) }.map { ($0.target, $0.source) },
                                    uniquingKeysWith: { a, _ in a })
        var changes: [(target: String, status: XDSAvailabilityStatus)] = []
        for a in update.associations where exists(a.id) {
            errors.append(RegistryError(XDSErrorCode.registryMetadataError, "\(a.id) is already in the registry; a submitted association needs a new id", location: a.id))
        }
        for a in update.associations {
            guard a.type == .updateAvailabilityStatus else {
                errors.append(RegistryError(XDSErrorCode.metadataUpdateOperationError, "\(a.type) is not simulated in ITI-57 by XDSTestRegistry", location: a.id))
                continue
            }
            guard let change = a.statusChange else { continue }  // reported by the validator
            let current: XDSAvailabilityStatus?, patient: CXIdentifier?
            if let d = documentEntries[a.target] { (current, patient) = (d.availabilityStatus, d.patientId) }
            else if let f = folders[a.target] { (current, patient) = (f.availabilityStatus, f.patientId) }
            else {
                errors.append(RegistryError(XDSErrorCode.unresolvedReference, "\(a.target) is no DocumentEntry or Folder of the registry", location: a.id))
                continue
            }
            if current != change.original {
                errors.append(RegistryError(XDSErrorCode.metadataUpdateError, "\(a.target) is \(current?.rawValue ?? "without status"), not \(change.original.rawValue)", location: a.id))
            }
            if patient != set.patientId {
                errors.append(RegistryError(XDSErrorCode.patientIdDoesNotMatch, "\(a.target) is not of the submission set's patient", location: a.id))
            }
            if change.new == .approved, let newer = replacedBy[a.target] {
                errors.append(RegistryError(XDSErrorCode.metadataUpdateError, "\(a.target) was replaced by \(newer): approving it again would leave two current versions", location: a.id))
            }
            if changes.contains(where: { $0.target == a.target }) {
                errors.append(RegistryError(XDSErrorCode.metadataUpdateError, "\(a.target) is updated twice", location: a.id))
            }
            changes.append((a.target, change.new))
        }
        guard errors.isEmpty else { return .failure(errors) }
        // A symbolic submission set ID becomes a UUID, as in ITI-41.
        let setID = set.entryUUID.lowercased().hasPrefix("urn:uuid:") ? set.entryUUID : XDSMetadata.newUUID()
        var stored = set
        stored.entryUUID = setID
        stored.availabilityStatus = .approved
        stored.homeCommunityId = homeCommunityId
        submissionSets[setID] = stored
        for var a in update.associations {
            if !a.id.lowercased().hasPrefix("urn:uuid:") { a.id = XDSMetadata.newUUID() }
            if a.source == set.entryUUID { a.source = setID }
            a.availabilityStatus = .approved
            associations[a.id] = a
        }
        for (target, status) in changes {
            if documentEntries[target] != nil { documentEntries[target]?.availabilityStatus = status }
            else { folders[target]?.availabilityStatus = status }
        }
        return .success
    }

    // MARK: ITI-18

    func query(_ request: SOAPMessage) -> XDSQueryResponse {
        guard let payload = request.envelope.payload, payload.name == XDSStoredQuery.request else {
            return XDSQueryResponse(response: .failure([RegistryError(XDSErrorCode.registryError, "AdhocQueryRequest expected")]))
        }
        do {
            let q = try XDSStoredQuery(element: payload)
            var found: XDSObjectList
            switch q.id.lowercased() {
            case XDSStoredQueryID.findDocuments:
                found = try findDocuments(q)
            case XDSStoredQueryID.getDocuments:
                found = try getDocuments(q)
            case XDSStoredQueryID.getSubmissionSetAndContents:
                found = try submissionSetAndContents(q)
            case let id where XDSStoredQueryID.all.contains(id):
                throw RegistryError(XDSErrorCode.registryError, "stored query \(q.id) is not simulated by XDSTestRegistry")
            default:
                throw RegistryError(XDSErrorCode.unknownStoredQuery, "unknown stored query \(q.id)", location: q.id)
            }
            if q.returnType == .objectRef {
                found = XDSObjectList(objectRefs: found.documentEntries.map(\.entryUUID) + found.submissionSets.map(\.entryUUID)
                                      + found.folders.map(\.entryUUID) + found.associations.map(\.id))
            }
            return XDSQueryResponse(response: .success, objects: found)
        } catch let error as RegistryError {
            return XDSQueryResponse(response: .failure([error]))
        } catch {
            return XDSQueryResponse(response: .failure([RegistryError(XDSErrorCode.registryError, "\(error)")]))
        }
    }

    /// One required parameter with one value.
    func single(_ q: XDSStoredQuery, _ name: String) throws -> String? {
        let values: [[String]]
        do { values = try q.values(name) } catch { throw RegistryError(XDSErrorCode.registryError, "\(error)", location: name) }
        guard !values.isEmpty else { return nil }
        guard values.count == 1, values[0].count == 1 else {
            throw RegistryError(XDSErrorCode.storedQueryParamNumber, "\(name) takes one value", location: name)
        }
        return values[0][0]
    }

    /// Exactly one of two parameters (ITI TF-2 §3.18.4.1.2.3.7: "shall … but not both").
    func oneOf(_ q: XDSStoredQuery, _ a: String, _ b: String) throws -> (name: String, values: [String]) {
        let va = try q.values(a).flatMap { $0 }, vb = try q.values(b).flatMap { $0 }
        switch (va.isEmpty, vb.isEmpty) {
        case (false, true): return (a, va)
        case (true, false): return (b, vb)
        case (false, false): throw RegistryError(XDSErrorCode.storedQueryParamNumber, "\(a) and \(b) are exclusive", location: a)
        case (true, true): throw RegistryError(XDSErrorCode.storedQueryMissingParam, "\(a) or \(b) required", location: a)
        }
    }

    func findDocuments(_ q: XDSStoredQuery) throws -> XDSObjectList {
        guard let raw = try single(q, "$XDSDocumentEntryPatientId") else {
            throw RegistryError(XDSErrorCode.storedQueryMissingParam, "$XDSDocumentEntryPatientId required", location: "$XDSDocumentEntryPatientId")
        }
        guard let patient = CXIdentifier(raw) else {
            throw RegistryError(XDSErrorCode.registryError, "$XDSDocumentEntryPatientId: '\(raw)' is not a CX", location: "$XDSDocumentEntryPatientId")
        }
        let filter = try XDSDocumentFilter(query: q)
        guard !filter.status.isEmpty else {
            throw RegistryError(XDSErrorCode.storedQueryMissingParam, "$XDSDocumentEntryStatus required", location: "$XDSDocumentEntryStatus")
        }
        let found = documentEntries.values.filter { $0.patientId == patient && filter.matches($0) }
        return XDSObjectList(documentEntries: found.sorted { $0.entryUUID < $1.entryUUID })
    }

    func getDocuments(_ q: XDSStoredQuery) throws -> XDSObjectList {
        let (name, values) = try oneOf(q, "$XDSDocumentEntryEntryUUID", "$XDSDocumentEntryUniqueId")
        let wanted = Set(values)
        let found = documentEntries.values.filter { wanted.contains(name == "$XDSDocumentEntryEntryUUID" ? $0.entryUUID : $0.uniqueId) }
        return XDSObjectList(documentEntries: found.sorted { $0.entryUUID < $1.entryUUID })
    }

    func submissionSetAndContents(_ q: XDSStoredQuery) throws -> XDSObjectList {
        let (name, values) = try oneOf(q, "$XDSSubmissionSetEntryUUID", "$XDSSubmissionSetUniqueId")
        guard values.count == 1 else { throw RegistryError(XDSErrorCode.storedQueryParamNumber, "\(name) takes one value", location: name) }
        guard let set = submissionSets.values.first(where: { (name == "$XDSSubmissionSetEntryUUID" ? $0.entryUUID : $0.uniqueId) == values[0] }) else {
            return XDSObjectList()
        }
        var filter = try XDSDocumentFilter(query: q)
        filter.status = XDSAvailabilityStatus.allCases
        let members = associations.values.filter { $0.type == .hasMember && $0.source == set.entryUUID }
        let documents = members.compactMap { documentEntries[$0.target] }.filter { filter.matches($0) }
        let folders = members.compactMap { self.folders[$0.target] }
        let documentIDs = Set(documents.map(\.entryUUID)), folderIDs = Set(folders.map(\.entryUUID))
        // Folder memberships submitted with the set, between objects returned.
        let folderLinks = members.compactMap { associations[$0.target] }
            .filter { $0.type == .hasMember && folderIDs.contains($0.source) && documentIDs.contains($0.target) }
        let linkIDs = Set(folderLinks.map(\.id))
        let kept = members.filter { documentIDs.contains($0.target) || folderIDs.contains($0.target) || linkIDs.contains($0.target) }
        return XDSObjectList(submissionSets: [set], documentEntries: documents.sorted { $0.entryUUID < $1.entryUUID },
                             folders: folders.sorted { $0.entryUUID < $1.entryUUID },
                             associations: (kept + folderLinks).sorted { $0.id < $1.id })
    }

    // MARK: ITI-43

    func retrieve(_ request: SOAPMessage) -> SOAPMessage {
        let requests: [XDSDocumentRequest]
        do {
            requests = try XDSRetrieve.requests(in: request.envelope.payload ?? XElement(XName("none")))
        } catch {
            return SOAPMessage(envelope: SOAPEnvelope(body: [XDSRetrieve.responseElement(.failure([RegistryError(XDSErrorCode.repositoryError, "\(error)")]), documents: [])]))
        }
        guard !requests.isEmpty else {
            return SOAPMessage(envelope: SOAPEnvelope(body: [XDSRetrieve.responseElement(.failure([RegistryError(XDSErrorCode.repositoryError, "RetrieveDocumentSetRequest without DocumentRequest")]), documents: [])]))
        }
        var errors: [RegistryError] = []
        var documents: [XElement] = []
        var attachments: [MTOMAttachment] = []
        for r in requests {
            if let home = r.homeCommunityId, let own = homeCommunityId, home != own {
                errors.append(RegistryError(XDSErrorCode.unknownCommunity, "community \(home) is not \(own)", location: r.documentUniqueId))
            } else if r.repositoryUniqueId != repositoryUniqueId {
                errors.append(RegistryError(XDSErrorCode.unknownRepositoryId, "repository \(r.repositoryUniqueId) is not \(repositoryUniqueId)", location: r.documentUniqueId))
            } else if let stored = self.documents[r.documentUniqueId] {
                let contentID = MTOMAttachment.newContentID()
                let info = XDSDocumentResponse(repositoryUniqueId: repositoryUniqueId, documentUniqueId: r.documentUniqueId,
                                               mimeType: stored.mimeType, homeCommunityId: r.homeCommunityId)
                documents.append(info.element(document: XElement(XDSRetrieve.document, elements: [XOP.include(contentID: contentID)])))
                attachments.append(MTOMAttachment(contentID: contentID, contentType: stored.mimeType, data: stored.data))
            } else {
                errors.append(RegistryError(XDSErrorCode.documentUniqueIdError, "no document \(r.documentUniqueId) in this repository", location: r.documentUniqueId))
            }
        }
        let status: RegistryResponse.Status = errors.isEmpty ? .success : documents.isEmpty ? .failure : .partialSuccess
        let response = RegistryResponse(status: status, errors: errors)
        return SOAPMessage(envelope: SOAPEnvelope(body: [XDSRetrieve.responseElement(response, documents: documents)]), attachments: attachments)
    }

    func exists(_ id: String) -> Bool {
        documentEntries[id] != nil || submissionSets[id] != nil || folders[id] != nil || associations[id] != nil
    }
}
