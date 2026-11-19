import Foundation

/// Outcome of a registry or repository transaction (`rs:RegistryResponse`, and the `status` and
/// `RegistryErrorList` of `AdhocQueryResponse` and `RetrieveDocumentSetResponse`).
public struct RegistryResponse: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case success = "urn:oasis:names:tc:ebxml-regrep:ResponseStatusType:Success"
        case failure = "urn:oasis:names:tc:ebxml-regrep:ResponseStatusType:Failure"
        case partialSuccess = "urn:ihe:iti:2007:ResponseStatusType:PartialSuccess"
    }

    public var status: Status
    public var errors: [RegistryError]
    public var requestID: String?

    public init(status: Status, errors: [RegistryError] = [], requestID: String? = nil) {
        self.status = status
        self.errors = errors
        self.requestID = requestID
    }

    public static let success = RegistryResponse(status: .success)

    public static func failure(_ errors: [RegistryError]) -> RegistryResponse {
        RegistryResponse(status: .failure, errors: errors)
    }

    public var isSuccess: Bool { status == .success }

    static let errorList = XName(Namespace.rs, "RegistryErrorList")
    static let errorName = XName(Namespace.rs, "RegistryError")

    /// `rs:RegistryResponse`.
    public var element: XElement {
        var e = XElement(XName(Namespace.rs, "RegistryResponse"), attributes: [XAttribute(XName("status"), status.rawValue)])
        if let requestID { e.setAttribute(XName("requestId"), requestID) }
        if let list = errorListElement { e.append(list) }
        return e
    }

    /// `rs:RegistryErrorList`, absent without errors.
    public var errorListElement: XElement? {
        guard !errors.isEmpty else { return nil }
        let highest = errors.contains { $0.severity == .error } ? RegistryError.Severity.error : .warning
        return XElement(Self.errorList, attributes: [XAttribute(XName("highestSeverity"), highest.rawValue)],
                        elements: errors.map(\.element))
    }

    /// Reads the `status` attribute and `RegistryErrorList` child of any response element; a
    /// `rs:RegistryResponse` child is read instead when present (ITI-43 responses).
    public init(element e: XElement) throws {
        if e.attribute("status") == nil, let inner = e.element(named: XName(Namespace.rs, "RegistryResponse")) {
            try self.init(element: inner)
            return
        }
        guard let raw = e.attribute("status") else {
            throw XDSMetadataError.missingAttribute(element: e.name.local, attribute: "status")
        }
        guard let status = Status(rawValue: raw) ?? Status.allCases.first(where: { raw.hasSuffix(":" + $0.shortName) }) else {
            throw XDSMetadataError.invalidValue(attribute: "status", value: raw)
        }
        let errors = try e.element(named: Self.errorList)?.elements(named: Self.errorName).map(RegistryError.init(element:)) ?? []
        self.init(status: status, errors: errors, requestID: e.attribute("requestId"))
    }
}

extension RegistryResponse.Status: CaseIterable {
    var shortName: String { String(rawValue.split(separator: ":").last!) }
}

/// One `rs:RegistryError`.
public struct RegistryError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable {
        case error = "urn:oasis:names:tc:ebxml-regrep:ErrorSeverityType:Error"
        case warning = "urn:oasis:names:tc:ebxml-regrep:ErrorSeverityType:Warning"
    }

    /// Error code, usually one of `XDSErrorCode`.
    public var errorCode: String
    public var codeContext: String
    public var location: String?
    public var severity: Severity

    public init(_ errorCode: String, _ codeContext: String, location: String? = nil, severity: Severity = .error) {
        self.errorCode = errorCode
        self.codeContext = codeContext
        self.location = location
        self.severity = severity
    }

    public var description: String {
        "\(errorCode): \(codeContext)" + (location.map { " (\($0))" } ?? "")
    }

    public var element: XElement {
        var e = XElement(RegistryResponse.errorName, attributes: [
            XAttribute(XName("codeContext"), codeContext), XAttribute(XName("errorCode"), errorCode),
            XAttribute(XName("severity"), severity.rawValue),
        ])
        if let location { e.setAttribute(XName("location"), location) }
        return e
    }

    public init(element e: XElement) throws {
        guard let code = e.attribute("errorCode") else {
            throw XDSMetadataError.missingAttribute(element: "RegistryError", attribute: "errorCode")
        }
        errorCode = code
        codeContext = e.attribute("codeContext") ?? e.trimmedText
        location = e.attribute("location")
        let s = e.attribute("severity") ?? Severity.error.rawValue
        severity = s.hasSuffix("Warning") ? .warning : .error
    }
}

/// Error codes of ITI TF-3 Table 4.2.4.1-2 (all of them), and of Metadata Update (ITI-57).
public enum XDSErrorCode {
    public static let registryError = "XDSRegistryError"
    public static let registryMetadataError = "XDSRegistryMetadataError"
    public static let repositoryError = "XDSRepositoryError"
    public static let repositoryMetadataError = "XDSRepositoryMetadataError"
    public static let registryBusy = "XDSRegistryBusy"
    public static let repositoryBusy = "XDSRepositoryBusy"
    public static let registryOutOfResources = "XDSRegistryOutOfResources"
    public static let registryNotAvailable = "XDSRegistryNotAvailable"
    public static let missingDocument = "XDSMissingDocument"
    public static let missingDocumentMetadata = "XDSMissingDocumentMetadata"
    public static let patientIdDoesNotMatch = "XDSPatientIdDoesNotMatch"
    public static let unknownPatientId = "XDSUnknownPatientId"
    public static let duplicateUniqueIdInRegistry = "XDSDuplicateUniqueIdInRegistry"
    public static let registryDuplicateUniqueIdInMessage = "XDSRegistryDuplicateUniqueIdInMessage"
    public static let repositoryDuplicateUniqueIdInMessage = "XDSRepositoryDuplicateUniqueIdInMessage"
    public static let nonIdenticalHash = "XDSNonIdenticalHash"
    public static let nonIdenticalSize = "XDSNonIdenticalSize"
    public static let documentUniqueIdError = "XDSDocumentUniqueIdError"
    public static let unknownRepositoryId = "XDSUnknownRepositoryId"
    public static let unknownCommunity = "XDSUnknownCommunity"
    public static let unknownStoredQuery = "XDSUnknownStoredQuery"
    public static let storedQueryMissingParam = "XDSStoredQueryMissingParam"
    public static let storedQueryParamNumber = "XDSStoredQueryParamNumber"
    public static let tooManyResults = "XDSTooManyResults"
    public static let resultNotSinglePatient = "XDSResultNotSinglePatient"
    public static let replaceFailed = "XDSReplaceFailed"
    public static let extraMetadataNotSaved = "XDSExtraMetadataNotSaved"
    public static let unresolvedReference = "UnresolvedReferenceException"
    public static let metadataUpdateError = "XDSMetadataUpdateError"
    public static let metadataVersionError = "XDSMetadataVersionError"
    public static let metadataUpdateOperationError = "XDSMetadataUpdateOperationError"
    public static let patientIDReconciliationError = "XDSPatientIDReconciliationError"
    public static let missingHomeCommunityId = "XDSMissingHomeCommunityId"
    public static let unavailableCommunity = "XDSUnavailableCommunity"
    public static let repositoryOutOfResources = "XDSRepositoryOutOfResources"
    public static let registryDeprecatedDocumentError = "XDSRegistryDeprecatedDocumentError"
    public static let partialAppendContentNotProcessed = "PartialAppendContentNotProcessed"
    public static let partialFolderContentNotProcessed = "PartialFolderContentNotProcessed"
    public static let partialReplaceContentNotProcessed = "PartialReplaceContentNotProcessed"
    public static let partialTransformNotProcessed = "PartialTransformNotProcessed"
    public static let partialTransformReplaceNotProcessed = "PartialTransformReplaceNotProcessed"
    public static let partialRelationshipContentNotProcessed = "PartialRelationshipContentNotProcessed"
    public static let invalidDocumentContent = "InvalidDocumentContent"
}
