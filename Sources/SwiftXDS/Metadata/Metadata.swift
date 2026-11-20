import Foundation

/// One `rim:LocalizedString`: a value with its language (`xml:lang`) and character set, as received.
public struct XDSLocalizedString: Hashable, Sendable {
    public var value: String
    public var language: String?
    public var charset: String?

    public init(_ value: String, language: String? = nil, charset: String? = nil) {
        self.value = value
        self.language = language
        self.charset = charset
    }
}

extension [XDSLocalizedString] {
    /// The first value, or replaces the list with one value.
    var firstValue: String? {
        get { first?.value }
        set { self = newValue.map { [XDSLocalizedString($0)] } ?? [] }
    }
}

/// A coded value (`classCode`, `typeCode`, `eventCodeList`…): code, coding scheme and display name.
public struct XDSCode: Hashable, Sendable {
    public var code: String
    public var codingScheme: String
    /// The `Name` of the classification, every localized value.
    public var localizedDisplayName: [XDSLocalizedString]

    public var displayName: String {
        get { localizedDisplayName.first?.value ?? "" }
        set { localizedDisplayName = [XDSLocalizedString(newValue)] }
    }

    public init(code: String, codingScheme: String, displayName: String) {
        self.code = code
        self.codingScheme = codingScheme
        localizedDisplayName = [XDSLocalizedString(displayName)]
    }

    public init(code: String, codingScheme: String, localizedDisplayName: [XDSLocalizedString]) {
        self.code = code
        self.codingScheme = codingScheme
        self.localizedDisplayName = localizedDisplayName
    }

    /// Same code in the same coding scheme, whatever the display name.
    public func matches(_ other: XDSCode) -> Bool { code == other.code && codingScheme == other.codingScheme }
}

/// IDs of the `Classification` and `ExternalIdentifier` objects of a registry object, as read. A
/// registry assigns them, and Metadata Update refers to them, so rewriting an object keeps them.
/// Missing ones are derived from the object's ID and the classification, the same on each write.
public struct XDSComponentIDs: Hashable, Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }
}

/// An author of a document or a submission set (ITI TF-3 §4.2.3.1.4).
public struct XDSAuthor: Hashable, Sendable {
    /// `authorPerson`, an XCN value.
    public var person: String?
    /// `authorInstitution`, XON values.
    public var institutions: [String]
    public var roles: [String]
    public var specialties: [String]
    /// `authorTelecommunication`, XTN values.
    public var telecommunications: [String]

    public init(person: String? = nil, institutions: [String] = [], roles: [String] = [], specialties: [String] = [],
                telecommunications: [String] = []) {
        self.person = person
        self.institutions = institutions
        self.roles = roles
        self.specialties = specialties
        self.telecommunications = telecommunications
    }

    public init(person: XCNPerson?, institutions: [XONOrganization] = [], roles: [String] = [], specialties: [String] = []) {
        self.init(person: person?.description, institutions: institutions.map(\.description), roles: roles, specialties: specialties)
    }
}

/// An ebRIM slot: a named list of values.
public struct XDSSlot: Hashable, Sendable {
    public var name: String
    public var values: [String]

    public init(name: String, values: [String]) {
        self.name = name
        self.values = values
    }
}

/// Metadata of one document (ITI TF-3 §4.2.3.2), an ebRIM `ExtrinsicObject`.
public struct XDSDocumentEntry: Hashable, Sendable {
    /// `entryUUID`: the object's `id`, a `urn:uuid:` or a symbolic ID in a submission.
    public var entryUUID: String
    public var uniqueId: String
    public var patientId: CXIdentifier?
    public var sourcePatientId: CXIdentifier?
    /// `sourcePatientInfo` values, PID fields such as `PID-5|Doe^John`.
    public var sourcePatientInfo: [String]
    public var availabilityStatus: XDSAvailabilityStatus?
    /// Stable (`XDSScheme.documentEntryStable`) or On-Demand.
    public var objectType: String
    public var mimeType: String
    public var hash: String?
    public var size: Int64?
    public var repositoryUniqueId: String?
    public var homeCommunityId: String?
    public var creationTime: XDSDateTime?
    public var serviceStartTime: XDSDateTime?
    public var serviceStopTime: XDSDateTime?
    public var languageCode: String?
    /// XCN value.
    public var legalAuthenticator: String?
    /// `Name` and `Description`, every localized value; `title` and `comments` read the first.
    public var localizedTitle: [XDSLocalizedString]
    public var localizedComments: [XDSLocalizedString]
    public var title: String? { get { localizedTitle.firstValue } set { localizedTitle.firstValue = newValue } }
    public var comments: String? { get { localizedComments.firstValue } set { localizedComments.firstValue = newValue } }
    public var classCode: XDSCode?
    public var confidentialityCodes: [XDSCode]
    public var eventCodes: [XDSCode]
    public var formatCode: XDSCode?
    public var healthcareFacilityTypeCode: XDSCode?
    public var practiceSettingCode: XDSCode?
    public var typeCode: XDSCode?
    public var authors: [XDSAuthor]
    /// `referenceIdList` values (CXi), such as the accession number of an imaging study.
    public var referenceIds: [String]
    public var uri: String?
    public var documentAvailability: XDSDocumentAvailability?
    /// `lid` and `VersionInfo`, set by the registry.
    public var logicalID: String?
    public var version: String?
    public var limitedMetadata: Bool
    /// Slots this model does not interpret, kept on output (national extensions).
    public var extraSlots: [XDSSlot]
    /// Classifications and external identifiers of schemes this model does not know (national
    /// extensions), kept as read but for their `classifiedObject` or `registryObject`, and written
    /// back after the known ones, attached to the object's current ID.
    public var extraClassifications: [XElement] = []
    public var extraIdentifiers: [XElement] = []
    public var componentIDs: XDSComponentIDs

    public init(entryUUID: String, uniqueId: String, patientId: CXIdentifier?, mimeType: String,
                objectType: String = XDSScheme.documentEntryStable) {
        self.entryUUID = entryUUID
        self.uniqueId = uniqueId
        self.patientId = patientId
        self.mimeType = mimeType
        self.objectType = objectType
        localizedTitle = []
        localizedComments = []
        componentIDs = XDSComponentIDs()
        sourcePatientInfo = []
        confidentialityCodes = []
        eventCodes = []
        authors = []
        referenceIds = []
        limitedMetadata = false
        extraSlots = []
    }
}

/// A submission set (ITI TF-3 §4.2.3.3), an ebRIM `RegistryPackage` classified as such.
public struct XDSSubmissionSet: Hashable, Sendable {
    public var entryUUID: String
    public var uniqueId: String
    public var sourceId: String
    public var patientId: CXIdentifier?
    public var submissionTime: XDSDateTime?
    public var contentTypeCode: XDSCode?
    public var authors: [XDSAuthor]
    public var localizedTitle: [XDSLocalizedString]
    public var localizedComments: [XDSLocalizedString]
    public var title: String? { get { localizedTitle.firstValue } set { localizedTitle.firstValue = newValue } }
    public var comments: String? { get { localizedComments.firstValue } set { localizedComments.firstValue = newValue } }
    /// XON|XCN|XTN values.
    public var intendedRecipients: [String]
    public var homeCommunityId: String?
    public var availabilityStatus: XDSAvailabilityStatus?
    /// `lid` and `VersionInfo`, set by the registry.
    public var logicalID: String?
    public var version: String?
    public var limitedMetadata: Bool
    public var extraSlots: [XDSSlot]
    /// Classifications and external identifiers of schemes this model does not know (national
    /// extensions), kept as read but for their `classifiedObject` or `registryObject`, and written
    /// back after the known ones, attached to the object's current ID.
    public var extraClassifications: [XElement] = []
    public var extraIdentifiers: [XElement] = []
    public var componentIDs: XDSComponentIDs

    /// `submissionTime` is set by `XDSObjectList.submission` when left out.
    public init(entryUUID: String, uniqueId: String, sourceId: String, patientId: CXIdentifier?,
                submissionTime: XDSDateTime? = nil, contentTypeCode: XDSCode? = nil) {
        self.entryUUID = entryUUID
        self.uniqueId = uniqueId
        self.sourceId = sourceId
        self.patientId = patientId
        self.submissionTime = submissionTime
        self.contentTypeCode = contentTypeCode
        localizedTitle = []
        localizedComments = []
        componentIDs = XDSComponentIDs()
        authors = []
        intendedRecipients = []
        limitedMetadata = false
        extraSlots = []
    }
}

/// A folder (ITI TF-3 §4.2.3.4).
public struct XDSFolder: Hashable, Sendable {
    public var entryUUID: String
    public var uniqueId: String
    public var patientId: CXIdentifier?
    public var codeList: [XDSCode]
    public var localizedTitle: [XDSLocalizedString]
    public var localizedComments: [XDSLocalizedString]
    public var title: String? { get { localizedTitle.firstValue } set { localizedTitle.firstValue = newValue } }
    public var comments: String? { get { localizedComments.firstValue } set { localizedComments.firstValue = newValue } }
    public var lastUpdateTime: XDSDateTime?
    public var homeCommunityId: String?
    public var availabilityStatus: XDSAvailabilityStatus?
    /// `lid` and `VersionInfo`, set by the registry (folders are versioned by Metadata Update).
    public var logicalID: String?
    public var version: String?
    public var limitedMetadata: Bool
    public var extraSlots: [XDSSlot]
    /// Classifications and external identifiers of schemes this model does not know (national
    /// extensions), kept as read but for their `classifiedObject` or `registryObject`, and written
    /// back after the known ones, attached to the object's current ID.
    public var extraClassifications: [XElement] = []
    public var extraIdentifiers: [XElement] = []
    public var componentIDs: XDSComponentIDs

    public init(entryUUID: String, uniqueId: String, patientId: CXIdentifier?, codeList: [XDSCode], title: String?) {
        self.entryUUID = entryUUID
        self.uniqueId = uniqueId
        self.patientId = patientId
        self.codeList = codeList
        localizedTitle = title.map { [XDSLocalizedString($0)] } ?? []
        localizedComments = []
        componentIDs = XDSComponentIDs()
        limitedMetadata = false
        extraSlots = []
    }
}

/// `SubmissionSetStatus` of a `HasMember` from a submission set to a document (ITI TF-3 §4.2.2.1.1).
public enum XDSSubmissionSetStatus: String, Hashable, Sendable {
    /// The document is submitted with this submission set.
    case original = "Original"
    /// The document was registered before; the submission set refers to it.
    case reference = "Reference"
}

/// An association between two registry objects (ITI TF-3 §4.2.2).
public struct XDSAssociation: Hashable, Sendable {
    public var id: String
    public var type: XDSAssociationType
    public var source: String
    public var target: String
    /// `SubmissionSetStatus`, only on a `HasMember` from a submission set to a document.
    public var submissionSetStatus: XDSSubmissionSetStatus?
    public var availabilityStatus: XDSAvailabilityStatus?
    public var extraSlots: [XDSSlot]

    public init(id: String = XDSMetadata.newUUID(), type: XDSAssociationType, source: String, target: String,
                submissionSetStatus: XDSSubmissionSetStatus? = nil) {
        self.id = id
        self.type = type
        self.source = source
        self.target = target
        self.submissionSetStatus = submissionSetStatus
        extraSlots = []
    }

    /// Membership of a document in a submission set, submitted with it (`Original`) by default.
    public static func member(of submissionSet: String, document: String, status: XDSSubmissionSetStatus = .original) -> XDSAssociation {
        XDSAssociation(type: .hasMember, source: submissionSet, target: document, submissionSetStatus: status)
    }

    /// Membership of a folder, or of another association (a folder's `HasMember`), in a submission
    /// set: no `SubmissionSetStatus` (§4.2.2.1.2, §4.2.2.1.3).
    public static func member(of submissionSet: String, object: String) -> XDSAssociation {
        XDSAssociation(type: .hasMember, source: submissionSet, target: object)
    }
}

/// Registry objects of a submission or of a query response.
public struct XDSObjectList: Hashable, Sendable {
    public var submissionSets: [XDSSubmissionSet]
    public var documentEntries: [XDSDocumentEntry]
    public var folders: [XDSFolder]
    public var associations: [XDSAssociation]
    /// `ObjectRef` IDs (query responses with `returnType=ObjectRef`, references to existing objects).
    public var objectRefs: [String]

    public init(submissionSets: [XDSSubmissionSet] = [], documentEntries: [XDSDocumentEntry] = [], folders: [XDSFolder] = [],
                associations: [XDSAssociation] = [], objectRefs: [String] = []) {
        self.submissionSets = submissionSets
        self.documentEntries = documentEntries
        self.folders = folders
        self.associations = associations
        self.objectRefs = objectRefs
    }

    /// One submission set with its documents and folders, linked by `HasMember` associations;
    /// `submissionTime` is set to now when missing. A folder's `HasMember` to a document, given in
    /// `associations`, is made a member of the submission set too (§4.2.2.1.3).
    public static func submission(_ set: XDSSubmissionSet, documents: [XDSDocumentEntry], folders: [XDSFolder] = [],
                                  associations: [XDSAssociation] = []) -> XDSObjectList {
        var set = set
        if set.submissionTime == nil { set.submissionTime = .now() }
        let folderIDs = Set(folders.map(\.entryUUID))
        let members = documents.map { XDSAssociation.member(of: set.entryUUID, document: $0.entryUUID) }
            + folders.map { XDSAssociation.member(of: set.entryUUID, object: $0.entryUUID) }
            + associations.filter { $0.type == .hasMember && folderIDs.contains($0.source) }
                .map { XDSAssociation.member(of: set.entryUUID, object: $0.id) }
        return XDSObjectList(submissionSets: [set], documentEntries: documents, folders: folders, associations: members + associations)
    }

    public var isEmpty: Bool {
        submissionSets.isEmpty && documentEntries.isEmpty && folders.isEmpty && associations.isEmpty && objectRefs.isEmpty
    }
}

public enum XDSMetadata {
    /// A fresh `urn:uuid:` identifier.
    public static func newUUID() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }
}
