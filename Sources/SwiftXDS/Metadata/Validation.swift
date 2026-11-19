import Foundation

/// A problem found in metadata, with the registry error code it maps to.
public struct XDSValidationIssue: Hashable, Sendable, CustomStringConvertible {
    public var objectID: String
    public var attribute: String
    public var errorCode: String
    public var message: String

    public init(objectID: String, attribute: String, errorCode: String = XDSErrorCode.registryMetadataError, message: String) {
        self.objectID = objectID
        self.attribute = attribute
        self.errorCode = errorCode
        self.message = message
    }

    public var description: String { "\(objectID) \(attribute): \(message)" }

    public var registryError: RegistryError { RegistryError(errorCode, description, location: objectID) }
}

/// Which submission the metadata belongs to, which decides what is required (ITI TF-3 Table
/// 4.3.1-3, XDS Document Source and Document Repository columns).
public enum XDSMetadataRole: Sendable {
    /// ITI-41 from a Document Source: `hash`, `size` and `repositoryUniqueId` are the repository's.
    case documentSource
    /// ITI-42 from a Document Repository: it has added them.
    case documentRepository
    /// ITI-57 from an Update Responsible Document Source or a Document Administrator: objects are
    /// already registered, a new DocumentEntry version carries `hash`, `size` and
    /// `repositoryUniqueId`; only this role sends `UpdateAvailabilityStatus`.
    case updateDocumentSet
}

/// Who checks the metadata, which decides the error code of generic metadata problems: a
/// registry answers `XDSRegistryMetadataError`, a repository `XDSRepositoryMetadataError`.
public enum XDSMetadataReceiver: Sendable {
    case registry
    case repository

    var metadataError: String {
        self == .registry ? XDSErrorCode.registryMetadataError : XDSErrorCode.repositoryMetadataError
    }
}

/// Checks a submission before it is sent, or when a registry or a repository receives it.
///
/// The `limitedMetadata` flag of the Metadata-Limited Document Source (XDR, XDM) does not relax
/// these requirements: they are those of an XDS submission.
public enum XDSValidator {
    public static func validate(_ list: XDSObjectList, as role: XDSMetadataRole,
                                receiver: XDSMetadataReceiver = .registry) -> [XDSValidationIssue] {
        var issues: [XDSValidationIssue] = []
        let metadataError = receiver.metadataError
        func issue(_ id: String, _ attribute: String, _ message: String, _ code: String? = nil) {
            issues.append(XDSValidationIssue(objectID: id, attribute: attribute, errorCode: code ?? metadataError, message: message))
        }
        func patient(_ id: String, _ value: CXIdentifier?) {
            guard let value else { return issue(id, "patientId", "required") }
            if !value.isAffinityDomainIdentifier {
                issue(id, "patientId", "must be id^^^&OID&ISO with no other component (ITI TF-3 §4.2.3.1.7), found '\(value)'")
            }
        }
        func authors(_ id: String, _ list: [XDSAuthor]) {
            for a in list where a.person == nil && a.institutions.isEmpty && a.telecommunications.isEmpty {
                issue(id, "author", "needs authorPerson, authorInstitution or authorTelecommunication")
            }
        }
        guard list.submissionSets.count == 1, let set = list.submissionSets.first else {
            issue("SubmissionSet", "count", "a submission carries exactly one submission set, found \(list.submissionSets.count)")
            return issues
        }

        // Submission set.
        if !isOID(set.uniqueId) { issue(set.entryUUID, "uniqueId", "must be an OID, found '\(set.uniqueId)'") }
        if !isOID(set.sourceId) { issue(set.entryUUID, "sourceId", "must be an OID, found '\(set.sourceId)'") }
        patient(set.entryUUID, set.patientId)
        if set.submissionTime == nil { issue(set.entryUUID, "submissionTime", "required") }
        if set.contentTypeCode == nil { issue(set.entryUUID, "contentTypeCode", "required") }
        authors(set.entryUUID, set.authors)

        // Documents.
        for d in list.documentEntries {
            let id = d.entryUUID
            if !isDocumentUniqueId(d.uniqueId) {
                issue(id, "uniqueId", "must be an OID, optionally followed by ^extension (at most 128 characters), found '\(d.uniqueId)'")
            }
            patient(id, d.patientId)
            if d.mimeType.isEmpty { issue(id, "mimeType", "required") }
            if d.objectType == XDSScheme.documentEntryOnDemand {
                issue(id, "objectType", "an On-Demand DocumentEntry is registered with ITI-61, not ITI-41 or ITI-42 (ITI TF-2 §3.42.4.1.2)")
            } else if d.objectType != XDSScheme.documentEntryStable {
                issue(id, "objectType", "unknown DocumentEntry type \(d.objectType)")
            }
            if d.classCode == nil { issue(id, "classCode", "required") }
            if d.confidentialityCodes.isEmpty { issue(id, "confidentialityCode", "required") }
            if d.creationTime == nil { issue(id, "creationTime", "required") }
            if d.formatCode == nil { issue(id, "formatCode", "required") }
            if d.healthcareFacilityTypeCode == nil { issue(id, "healthcareFacilityTypeCode", "required") }
            if d.languageCode == nil { issue(id, "languageCode", "required") }
            if d.practiceSettingCode == nil { issue(id, "practiceSettingCode", "required") }
            if d.sourcePatientId == nil { issue(id, "sourcePatientId", "required") }
            if d.typeCode == nil { issue(id, "typeCode", "required") }
            authors(id, d.authors)
            if role != .documentSource {
                if d.hash.map(isSHA1) != true { issue(id, "hash", "required: SHA-1 of the document in hexadecimal") }
                if d.size == nil { issue(id, "size", "required") }
                if d.repositoryUniqueId.map(isOID) != true { issue(id, "repositoryUniqueId", "required: an OID") }
            }
            if let start = d.serviceStartTime, let stop = d.serviceStopTime, stop < start {
                issue(id, "serviceStopTime", "precedes serviceStartTime")
            }
            if let p = d.patientId, let s = set.patientId, p != s {
                issue(id, "patientId", "differs from the submission set's", XDSErrorCode.patientIdDoesNotMatch)
            }
        }

        // Folders.
        for f in list.folders {
            if !isOID(f.uniqueId) { issue(f.entryUUID, "uniqueId", "must be an OID, found '\(f.uniqueId)'") }
            patient(f.entryUUID, f.patientId)
            if f.codeList.isEmpty { issue(f.entryUUID, "codeList", "required") }
            if f.title == nil { issue(f.entryUUID, "title", "required") }
            if let p = f.patientId, let s = set.patientId, p != s {
                issue(f.entryUUID, "patientId", "differs from the submission set's", XDSErrorCode.patientIdDoesNotMatch)
            }
        }

        // Unique IDs within the message.
        var uniqueIds: [String: String] = [:]
        for (id, unique) in [(set.entryUUID, set.uniqueId)] + list.documentEntries.map({ ($0.entryUUID, $0.uniqueId) })
            + list.folders.map({ ($0.entryUUID, $0.uniqueId) }) where !unique.isEmpty {
            if let other = uniqueIds[unique] {
                issue(id, "uniqueId", "\(unique) also used by \(other)", XDSErrorCode.registryDuplicateUniqueIdInMessage)
            }
            uniqueIds[unique] = id
        }

        // Associations (ITI TF-3 §4.2.2).
        let documents = Set(list.documentEntries.map(\.entryUUID))
        let folders = Set(list.folders.map(\.entryUUID))
        let associations = Set(list.associations.map(\.id))
        let local = documents.union(folders).union(associations).union([set.entryUUID])
        for a in list.associations {
            for ref in [a.source, a.target] where !local.contains(ref) && !ref.lowercased().hasPrefix("urn:uuid:") {
                issue(a.id, "reference", "\(ref) is neither in the submission nor a registry UUID", XDSErrorCode.unresolvedReference)
            }
            let fromSet = a.type == .hasMember && a.source == set.entryUUID
            if fromSet, !folders.contains(a.target), !associations.contains(a.target), a.submissionSetStatus == nil {
                issue(a.id, "SubmissionSetStatus", "required on a HasMember from the submission set to a document")
            }
            if a.submissionSetStatus != nil, !fromSet || folders.contains(a.target) || associations.contains(a.target) {
                issue(a.id, "SubmissionSetStatus", "only a HasMember from the submission set to a document has one")
            }
            switch a.type {
            case .replace, .append, .transform, .transformAndReplace:
                if !documents.contains(a.source) { issue(a.id, "sourceObject", "\(a.type) must start from a document of the submission") }
                if local.contains(a.target) { issue(a.id, "targetObject", "\(a.type) must point to a document already in the registry") }
            case .signs:
                if !documents.contains(a.source) { issue(a.id, "sourceObject", "signs must start from a document of the submission") }
            case .isSnapshotOf:
                if !documents.contains(a.source) { issue(a.id, "sourceObject", "IsSnapshotOf must start from a Stable document of the submission") }
                if local.contains(a.target) { issue(a.id, "targetObject", "IsSnapshotOf must point to an On-Demand document already in the registry") }
            case .updateAvailabilityStatus:
                if role != .updateDocumentSet { issue(a.id, "associationType", "UpdateAvailabilityStatus is sent with ITI-57 only") }
                if a.source != set.entryUUID { issue(a.id, "sourceObject", "UpdateAvailabilityStatus must start from the submission set", XDSErrorCode.metadataUpdateError) }
                if local.contains(a.target) || !a.target.lowercased().hasPrefix("urn:uuid:") {
                    issue(a.id, "targetObject", "UpdateAvailabilityStatus must point to an object already in the registry", XDSErrorCode.metadataUpdateError)
                }
                if let change = a.statusChange {
                    let allowed: Set<XDSAvailabilityStatus> = [.approved, .deprecated]
                    if !allowed.contains(change.original) || !allowed.contains(change.new) || change.original == change.new {
                        issue(a.id, "NewStatus", "moves between Approved and Deprecated only", XDSErrorCode.metadataUpdateError)
                    }
                } else {
                    issue(a.id, "OriginalStatus", "OriginalStatus and NewStatus required, one status each", XDSErrorCode.metadataUpdateError)
                }
            default:
                break
            }
        }
        let members = Set(list.associations.filter { $0.type == .hasMember && $0.source == set.entryUUID }.map(\.target))
        for id in list.documentEntries.map(\.entryUUID) + list.folders.map(\.entryUUID) where !members.contains(id) {
            issue(id, "HasMember", "not a member of the submission set")
        }
        // A HasMember from a folder of the submission, or from a folder already in the registry.
        for a in list.associations where a.type == .hasMember && a.source != set.entryUUID
            && (folders.contains(a.source) || !local.contains(a.source)) && !members.contains(a.id) {
            issue(a.id, "HasMember", "a folder's HasMember needs its own HasMember from the submission set (ITI TF-3 §4.2.2.1.3)")
        }
        return issues
    }

    /// Dotted decimal OID (ITU-T X.660), at most 64 characters, no leading zeros.
    public static func isOID(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        let arcs = s.split(separator: ".", omittingEmptySubsequences: false)
        guard arcs.count >= 2 else { return false }
        return arcs.allSatisfy { arc in
            !arc.isEmpty && arc.allSatisfy { $0.isASCII && $0.isNumber } && (arc == "0" || arc.first != "0")
        }
    }

    /// `DocumentEntry.uniqueId`: an OID, or `OID^extension`, at most 128 characters.
    public static func isDocumentUniqueId(_ s: String) -> Bool {
        guard s.count <= 128 else { return false }
        let parts = s.split(separator: "^", maxSplits: 1, omittingEmptySubsequences: false)
        guard isOID(String(parts[0])) else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 16)
    }

    static func isSHA1(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }
}
