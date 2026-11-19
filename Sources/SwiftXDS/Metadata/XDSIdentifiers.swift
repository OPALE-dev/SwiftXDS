/// Fixed identifiers of XDS metadata (ITI TF-3 §4.2.5) and ebRIM/ebRS vocabularies.
public enum XDSScheme {
    // DocumentEntry
    public static let documentEntryStable = "urn:uuid:7edca82f-054d-47f2-a032-9b2a5b5186c1"
    public static let documentEntryOnDemand = "urn:uuid:34268e47-fdf5-41a6-ba33-82133c465248"
    public static let documentEntryAuthor = "urn:uuid:93606bcf-9494-43ec-9b4e-a7748d1a838d"
    public static let documentEntryClassCode = "urn:uuid:41a5887f-8865-4c09-adf7-e362475b143a"
    public static let documentEntryConfidentialityCode = "urn:uuid:f4f85eac-e6cb-4883-b524-f2705394840f"
    public static let documentEntryEventCodeList = "urn:uuid:2c6b8cb7-8b2a-4051-b291-b1ae6a575ef4"
    public static let documentEntryFormatCode = "urn:uuid:a09d5840-386c-46f2-b5ad-9c3699a4309d"
    public static let documentEntryHealthcareFacilityTypeCode = "urn:uuid:f33fb8ac-18af-42cc-ae0e-ed0b0bdb91e1"
    public static let documentEntryPracticeSettingCode = "urn:uuid:cccf5598-8b07-4b77-a05e-ae952c785ead"
    public static let documentEntryTypeCode = "urn:uuid:f0306f51-975f-434e-a61c-c59651d33983"
    public static let documentEntryPatientId = "urn:uuid:58a6f841-87b3-4a3e-92fd-a8ffeff98427"
    public static let documentEntryUniqueId = "urn:uuid:2e82c1f6-a085-4c72-9da3-8640a32e42ab"
    public static let documentEntryLimitedMetadata = "urn:uuid:ab9b591b-83ab-4d03-8f5d-f93b1fb92e85"

    // SubmissionSet
    public static let submissionSet = "urn:uuid:a54d6aa5-d40d-43f9-88c5-b4633d873bdd"
    public static let submissionSetAuthor = "urn:uuid:a7058bb9-b4e4-4307-ba5b-e3f0ab85e12d"
    public static let submissionSetContentTypeCode = "urn:uuid:aa543740-bdda-424e-8c96-df4873be8500"
    public static let submissionSetPatientId = "urn:uuid:6b5aea1a-874d-4603-a4bc-96a0a7b38446"
    public static let submissionSetSourceId = "urn:uuid:554ac39e-e3fe-47fe-b233-965d2a147832"
    public static let submissionSetUniqueId = "urn:uuid:96fdda7c-d067-4183-912e-bf5ee74998a8"
    public static let submissionSetLimitedMetadata = "urn:uuid:5003a9db-8d8d-49e6-bf0c-990e34ac7707"

    // Folder
    public static let folder = "urn:uuid:d9d542f3-6cc4-48b6-8870-ea235fbc94c2"
    public static let folderCodeList = "urn:uuid:1ba97051-7806-41a8-a48b-8fce7af683c5"
    public static let folderPatientId = "urn:uuid:f64ffdf0-4b97-4e06-b79f-a52b38ec2f8a"
    public static let folderUniqueId = "urn:uuid:75df8f67-9973-4fbe-a900-df66cefecc5a"
    public static let folderLimitedMetadata = "urn:uuid:2c144a76-29a9-4b7c-af54-b25409fe7d03"

    // ebRIM object types
    public static let registryPackageType = "urn:oasis:names:tc:ebxml-regrep:ObjectType:RegistryObject:RegistryPackage"
    public static let classificationType = "urn:oasis:names:tc:ebxml-regrep:ObjectType:RegistryObject:Classification"
    public static let externalIdentifierType = "urn:oasis:names:tc:ebxml-regrep:ObjectType:RegistryObject:ExternalIdentifier"
    public static let associationType = "urn:oasis:names:tc:ebxml-regrep:ObjectType:RegistryObject:Association"
}

/// Availability of a registry object.
public enum XDSAvailabilityStatus: String, Sendable, Hashable, CaseIterable {
    case approved = "urn:oasis:names:tc:ebxml-regrep:StatusType:Approved"
    case deprecated = "urn:oasis:names:tc:ebxml-regrep:StatusType:Deprecated"
    /// Transient state during a submission.
    case submitted = "urn:oasis:names:tc:ebxml-regrep:StatusType:Submitted"
}

/// Association types between registry objects (ITI TF-3 §4.2.2).
public struct XDSAssociationType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let hasMember = XDSAssociationType(rawValue: "urn:oasis:names:tc:ebxml-regrep:AssociationType:HasMember")
    public static let replace = XDSAssociationType(rawValue: "urn:ihe:iti:2007:AssociationType:RPLC")
    public static let transform = XDSAssociationType(rawValue: "urn:ihe:iti:2007:AssociationType:XFRM")
    public static let append = XDSAssociationType(rawValue: "urn:ihe:iti:2007:AssociationType:APND")
    public static let transformAndReplace = XDSAssociationType(rawValue: "urn:ihe:iti:2007:AssociationType:XFRM_RPLC")
    public static let signs = XDSAssociationType(rawValue: "urn:ihe:iti:2007:AssociationType:signs")
    public static let isSnapshotOf = XDSAssociationType(rawValue: "urn:ihe:iti:2010:AssociationType:IsSnapshotOf")

    public var description: String { rawValue }
}

/// `DocumentEntry.documentAvailability`.
public enum XDSDocumentAvailability: String, Sendable, Hashable {
    case online = "urn:ihe:iti:2010:DocumentAvailability:Online"
    case offline = "urn:ihe:iti:2010:DocumentAvailability:Offline"
}
