import Foundation

/// Stored query IDs (ITI TF-2 §3.18.4.1.2.3.7, Table 3.18.4.1.2.3.7-1).
public enum XDSStoredQueryID {
    public static let findDocuments = "urn:uuid:14d4debf-8f97-4251-9a74-a90016b0af0d"
    public static let findSubmissionSets = "urn:uuid:f26abbcb-ac74-4422-8a30-edb644bbc1a9"
    public static let findFolders = "urn:uuid:958f3006-baad-4929-a4de-ff1114824431"
    public static let getAll = "urn:uuid:10b545ea-725c-446d-9b95-8aeb444eddf3"
    public static let getDocuments = "urn:uuid:5c4f972b-d56b-40ac-a5fc-c8ca9b40b9d4"
    public static let getFolders = "urn:uuid:5737b14c-8a1a-4539-b659-e03a34a5e1e4"
    public static let getAssociations = "urn:uuid:a7ae438b-4bc2-4642-93e9-be891f7bb155"
    public static let getDocumentsAndAssociations = "urn:uuid:bab9529a-4a10-40b3-a01f-f68a615d247a"
    public static let getSubmissionSets = "urn:uuid:51224314-5390-4169-9b91-b1980040715a"
    public static let getSubmissionSetAndContents = "urn:uuid:e8e3cb2c-e39c-46b9-99e4-c12f57260b83"
    public static let getFolderAndContents = "urn:uuid:b909a503-523d-4517-8acf-8e5834dfc4c7"
    public static let getFoldersForDocument = "urn:uuid:10cae35a-c7f9-4cf5-b61e-fc3278ffb578"
    public static let getRelatedDocuments = "urn:uuid:d90e5407-b356-4d91-a89f-873917b4b0e6"
    public static let findDocumentsByReferenceId = "urn:uuid:12941a89-e02e-4be5-967c-ce4bfc8fe492"

    public static let all: Set<String> = [
        findDocuments, findSubmissionSets, findFolders, getAll, getDocuments, getFolders, getAssociations,
        getDocumentsAndAssociations, getSubmissionSets, getSubmissionSetAndContents, getFolderAndContents,
        getFoldersForDocument, getRelatedDocuments, findDocumentsByReferenceId,
    ]
}

/// `returnType`: full objects, or their IDs only.
public enum XDSReturnType: String, Sendable, Hashable {
    case leafClass = "LeafClass"
    case objectRef = "ObjectRef"
}

/// Values of stored query parameters (ITI TF-2 §3.18.4.1.2.3.5): strings in single quotes (a
/// quote doubled), several values in parentheses, numbers and dates bare, codes as `code^^scheme`.
public enum XDSQueryValue {
    public static func string(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func list(_ values: [String]) -> String {
        "(" + values.map(string).joined(separator: ",") + ")"
    }

    public static func code(_ c: XDSCode) -> String { c.code + "^^" + c.codingScheme }

    /// Reads `code^^scheme`.
    public static func code(_ value: String) -> XDSCode? {
        guard let r = value.range(of: "^^") else { return nil }
        let code = String(value[..<r.lowerBound]), scheme = String(value[r.upperBound...])
        return code.isEmpty || scheme.isEmpty ? nil : XDSCode(code: code, codingScheme: scheme, localizedDisplayName: [])
    }

    /// The values of one `rim:Value`: `'a'`, `('a','b')`, `20261119` or `(1,2)`.
    public static func parse(_ text: String) -> [String]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard t.hasPrefix("(") else { return item(t).map { [$0] } }
        guard t.hasSuffix(")"), t.count >= 2 else { return nil }
        var items: [String] = [], current = "", quoted = false
        let inner = Array(t.dropFirst().dropLast())
        var i = 0
        while i < inner.count {
            let c = inner[i]
            if c == "'" {
                if quoted, i + 1 < inner.count, inner[i + 1] == "'" { current += "''"; i += 2; continue }
                quoted.toggle()
                current.append(c)
            } else if c == ",", !quoted {
                guard let v = item(current) else { return nil }
                items.append(v)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        guard !quoted, let last = item(current) else { return nil }
        items.append(last)
        return items
    }

    static func item(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard t.hasPrefix("'") else { return t.contains("'") || t.contains("(") ? nil : t }
        guard t.count >= 2, t.hasSuffix("'") else { return nil }
        let body = String(t.dropFirst().dropLast())
        // A single quote inside must be doubled.
        guard body.replacingOccurrences(of: "''", with: "").contains("'") == false else { return nil }
        return body.replacingOccurrences(of: "''", with: "'")
    }
}

/// A period for time parameters: `from` included, `to` excluded (ITI TF-2 §3.18.4.1.2.3.6).
public struct XDSTimeRange: Hashable, Sendable {
    public var from: XDSDateTime?
    public var to: XDSDateTime?

    public init(from: XDSDateTime? = nil, to: XDSDateTime? = nil) {
        self.from = from
        self.to = to
    }

    /// A value that is missing is outside any range.
    public func contains(_ t: XDSDateTime?) -> Bool {
        guard let t else { return false }
        if let from, t < from { return false }
        if let to, !(t < to) { return false }
        return true
    }
}

/// An `AdhocQueryRequest` (ITI-18): a stored query ID and its parameters.
public struct XDSStoredQuery: Hashable, Sendable {
    public var id: String
    /// Parameters as ebRIM slots, values already encoded (`XDSQueryValue`); two slots of the same
    /// name are ANDed, values within a slot ORed.
    public var parameters: [XDSSlot]
    public var returnType: XDSReturnType
    /// `home` of the query, for queries across communities.
    public var homeCommunityId: String?

    public init(id: String, parameters: [XDSSlot] = [], returnType: XDSReturnType = .leafClass, homeCommunityId: String? = nil) {
        self.id = id
        self.parameters = parameters
        self.returnType = returnType
        self.homeCommunityId = homeCommunityId
    }

    public static let request = XName(Namespace.query, "AdhocQueryRequest")
    static let responseOption = XName(Namespace.query, "ResponseOption")
    static let adhocQuery = XName(Namespace.rim, "AdhocQuery")

    public var element: XElement {
        let query = XElement(Self.adhocQuery, attributes: [RIM.attr("home", homeCommunityId), RIM.attr("id", id)].compactMap { $0 },
                             elements: parameters.compactMap { RIM.slot($0.name, $0.values) })
        return XElement(Self.request, elements: [
            XElement(Self.responseOption, attributes: [XAttribute(XName("returnComposedObjects"), "true"),
                                                       XAttribute(XName("returnType"), returnType.rawValue)]),
            query,
        ])
    }

    public init(element e: XElement) throws {
        guard let query = e.element(named: Self.adhocQuery) else { throw XDSMetadataError.unexpectedElement(e.name) }
        // ITI-18 requires LeafClass or ObjectRef: no default.
        guard let raw = e.element(named: Self.responseOption)?.attribute("returnType") else {
            throw XDSMetadataError.missingAttribute(element: "ResponseOption", attribute: "returnType")
        }
        guard let returnType = XDSReturnType(rawValue: raw) else { throw XDSMetadataError.invalidValue(attribute: "returnType", value: raw) }
        self.init(id: try RIM.required(query, "id"),
                  parameters: query.elements(named: RIM.slot).map { XDSSlot(name: $0.attribute("name") ?? "", values: RIM.values($0)) },
                  returnType: returnType, homeCommunityId: query.attribute("home"))
    }

    /// The decoded values of a parameter: one list per slot (ANDed), each the ORed values.
    public func values(_ name: String) throws -> [[String]] {
        try parameters.filter { $0.name == name }.map { slot in
            try slot.values.flatMap { text -> [String] in
                guard let v = XDSQueryValue.parse(text) else { throw XDSMetadataError.invalidValue(attribute: name, value: text) }
                return v
            }
        }
    }

    // MARK: Builders

    /// FindDocuments: the patient's documents that match the filter.
    public static func findDocuments(patientId: CXIdentifier, _ filter: XDSDocumentFilter = XDSDocumentFilter(),
                                     returnType: XDSReturnType = .leafClass) -> XDSStoredQuery {
        XDSStoredQuery(id: XDSStoredQueryID.findDocuments,
                       parameters: [XDSSlot(name: "$XDSDocumentEntryPatientId", values: [XDSQueryValue.string(patientId.description)])] + filter.parameters,
                       returnType: returnType)
    }

    /// GetDocuments by `entryUUID`.
    public static func getDocuments(entryUUIDs: [String], returnType: XDSReturnType = .leafClass, homeCommunityId: String? = nil) -> XDSStoredQuery {
        XDSStoredQuery(id: XDSStoredQueryID.getDocuments, parameters: [XDSSlot(name: "$XDSDocumentEntryEntryUUID", values: [XDSQueryValue.list(entryUUIDs)])]
                       + home(homeCommunityId), returnType: returnType, homeCommunityId: homeCommunityId)
    }

    /// GetDocuments by `uniqueId`.
    public static func getDocuments(uniqueIds: [String], returnType: XDSReturnType = .leafClass, homeCommunityId: String? = nil) -> XDSStoredQuery {
        XDSStoredQuery(id: XDSStoredQueryID.getDocuments, parameters: [XDSSlot(name: "$XDSDocumentEntryUniqueId", values: [XDSQueryValue.list(uniqueIds)])]
                       + home(homeCommunityId), returnType: returnType, homeCommunityId: homeCommunityId)
    }

    /// GetSubmissionSetAndContents, by `entryUUID` or, with `byUniqueId`, by `uniqueId`.
    public static func getSubmissionSetAndContents(_ id: String, byUniqueId: Bool = false, formatCodes: [XDSCode] = [],
                                                   confidentialityCodes: [[XDSCode]] = [], returnType: XDSReturnType = .leafClass,
                                                   homeCommunityId: String? = nil) -> XDSStoredQuery {
        var parameters = [XDSSlot(name: byUniqueId ? "$XDSSubmissionSetUniqueId" : "$XDSSubmissionSetEntryUUID", values: [XDSQueryValue.string(id)])]
        if !formatCodes.isEmpty { parameters.append(XDSSlot(name: "$XDSDocumentEntryFormatCode", values: [XDSQueryValue.list(formatCodes.map(XDSQueryValue.code))])) }
        for group in confidentialityCodes where !group.isEmpty {
            parameters.append(XDSSlot(name: "$XDSDocumentEntryConfidentialityCode", values: [XDSQueryValue.list(group.map(XDSQueryValue.code))]))
        }
        return XDSStoredQuery(id: XDSStoredQueryID.getSubmissionSetAndContents, parameters: parameters + home(homeCommunityId),
                              returnType: returnType, homeCommunityId: homeCommunityId)
    }

    static func home(_ id: String?) -> [XDSSlot] {
        id.map { [XDSSlot(name: "$homeCommunityId", values: [XDSQueryValue.string($0)])] } ?? []
    }
}

/// The optional parameters of FindDocuments, and how a registry matches them.
public struct XDSDocumentFilter: Hashable, Sendable {
    public var status: [XDSAvailabilityStatus]
    /// Codes of one parameter are ORed.
    public var classCodes: [XDSCode]
    public var typeCodes: [XDSCode]
    public var practiceSettingCodes: [XDSCode]
    public var healthcareFacilityTypeCodes: [XDSCode]
    public var formatCodes: [XDSCode]
    /// ANDed groups of ORed codes.
    public var eventCodes: [[XDSCode]]
    public var confidentialityCodes: [[XDSCode]]
    public var creationTime: XDSTimeRange?
    public var serviceStartTime: XDSTimeRange?
    public var serviceStopTime: XDSTimeRange?
    /// `authorPerson` values, with `%` and `_` wildcards (SQL LIKE), ORed.
    public var authorPersons: [String]
    /// `objectType` values (Stable, On-Demand); empty means Stable only.
    public var documentEntryTypes: [String]

    public init(status: [XDSAvailabilityStatus] = [.approved]) {
        self.status = status
        classCodes = []; typeCodes = []; practiceSettingCodes = []; healthcareFacilityTypeCodes = []; formatCodes = []
        eventCodes = []; confidentialityCodes = []; authorPersons = []; documentEntryTypes = []
    }

    var parameters: [XDSSlot] {
        var p = [XDSSlot(name: "$XDSDocumentEntryStatus", values: [XDSQueryValue.list(status.map(\.rawValue))])]
        func codes(_ name: String, _ c: [XDSCode]) {
            if !c.isEmpty { p.append(XDSSlot(name: name, values: [XDSQueryValue.list(c.map(XDSQueryValue.code))])) }
        }
        codes("$XDSDocumentEntryClassCode", classCodes)
        codes("$XDSDocumentEntryTypeCode", typeCodes)
        codes("$XDSDocumentEntryPracticeSettingCode", practiceSettingCodes)
        codes("$XDSDocumentEntryHealthcareFacilityTypeCode", healthcareFacilityTypeCodes)
        codes("$XDSDocumentEntryFormatCode", formatCodes)
        eventCodes.forEach { codes("$XDSDocumentEntryEventCodeList", $0) }
        confidentialityCodes.forEach { codes("$XDSDocumentEntryConfidentialityCode", $0) }
        func range(_ name: String, _ r: XDSTimeRange?) {
            if let from = r?.from { p.append(XDSSlot(name: "$XDSDocumentEntry\(name)From", values: [from.value])) }
            if let to = r?.to { p.append(XDSSlot(name: "$XDSDocumentEntry\(name)To", values: [to.value])) }
        }
        range("CreationTime", creationTime)
        range("ServiceStartTime", serviceStartTime)
        range("ServiceStopTime", serviceStopTime)
        if !authorPersons.isEmpty { p.append(XDSSlot(name: "$XDSDocumentEntryAuthorPerson", values: [XDSQueryValue.list(authorPersons)])) }
        if !documentEntryTypes.isEmpty { p.append(XDSSlot(name: "$XDSDocumentEntryType", values: [XDSQueryValue.list(documentEntryTypes)])) }
        return p
    }

    /// Reads the parameters of a FindDocuments query (or of the filters other queries share).
    /// Errors are registry errors: `XDSStoredQueryParamNumber`, `XDSRegistryError` for a value.
    public init(query: XDSStoredQuery) throws {
        self.init(status: [])
        func values(_ name: String) throws -> [[String]] {
            do { return try query.values(name) } catch { throw RegistryError(XDSErrorCode.registryError, "\(error)", location: name) }
        }
        func single(_ name: String) throws -> String? {
            let v = try values(name)
            guard !v.isEmpty else { return nil }
            guard v.count == 1, v[0].count == 1 else { throw RegistryError(XDSErrorCode.storedQueryParamNumber, "\(name) takes one value", location: name) }
            return v[0][0]
        }
        func codes(_ name: String) throws -> [[XDSCode]] {
            try values(name).map { group in
                try group.map { v in
                    guard let c = XDSQueryValue.code(v) else { throw RegistryError(XDSErrorCode.registryError, "\(name): '\(v)' is not code^^scheme", location: name) }
                    return c
                }
            }
        }
        func time(_ name: String) throws -> XDSTimeRange? {
            func dtm(_ n: String) throws -> XDSDateTime? {
                guard let v = try single(n) else { return nil }
                guard let t = XDSDateTime(v) else { throw RegistryError(XDSErrorCode.registryError, "\(n): '\(v)' is not a DTM", location: n) }
                return t
            }
            let from = try dtm("$XDSDocumentEntry\(name)From"), to = try dtm("$XDSDocumentEntry\(name)To")
            return from == nil && to == nil ? nil : XDSTimeRange(from: from, to: to)
        }
        status = try values("$XDSDocumentEntryStatus").flatMap { $0 }.map { v in
            guard let s = XDSAvailabilityStatus(rawValue: v) else { throw RegistryError(XDSErrorCode.registryError, "unknown status '\(v)'", location: "$XDSDocumentEntryStatus") }
            return s
        }
        classCodes = try codes("$XDSDocumentEntryClassCode").flatMap { $0 }
        typeCodes = try codes("$XDSDocumentEntryTypeCode").flatMap { $0 }
        practiceSettingCodes = try codes("$XDSDocumentEntryPracticeSettingCode").flatMap { $0 }
        healthcareFacilityTypeCodes = try codes("$XDSDocumentEntryHealthcareFacilityTypeCode").flatMap { $0 }
        formatCodes = try codes("$XDSDocumentEntryFormatCode").flatMap { $0 }
        eventCodes = try codes("$XDSDocumentEntryEventCodeList")
        confidentialityCodes = try codes("$XDSDocumentEntryConfidentialityCode")
        creationTime = try time("CreationTime")
        serviceStartTime = try time("ServiceStartTime")
        serviceStopTime = try time("ServiceStopTime")
        authorPersons = try values("$XDSDocumentEntryAuthorPerson").flatMap { $0 }
        documentEntryTypes = try values("$XDSDocumentEntryType").flatMap { $0 }.map { $0.lowercased() }
    }

    /// Whether a DocumentEntry matches every parameter given.
    public func matches(_ d: XDSDocumentEntry) -> Bool {
        func any(_ c: XDSCode?, _ list: [XDSCode]) -> Bool { list.isEmpty || (c.map { v in list.contains { $0.matches(v) } } ?? false) }
        func all(_ entry: [XDSCode], _ groups: [[XDSCode]]) -> Bool {
            groups.allSatisfy { group in group.contains { g in entry.contains { $0.matches(g) } } }
        }
        let types = documentEntryTypes.isEmpty ? [XDSScheme.documentEntryStable] : documentEntryTypes
        guard status.contains(where: { $0 == d.availabilityStatus }), types.contains(d.objectType) else { return false }
        guard any(d.classCode, classCodes), any(d.typeCode, typeCodes), any(d.practiceSettingCode, practiceSettingCodes),
              any(d.healthcareFacilityTypeCode, healthcareFacilityTypeCodes), any(d.formatCode, formatCodes),
              all(d.eventCodes, eventCodes), all(d.confidentialityCodes, confidentialityCodes) else { return false }
        if let r = creationTime, !r.contains(d.creationTime) { return false }
        if let r = serviceStartTime, !r.contains(d.serviceStartTime) { return false }
        if let r = serviceStopTime, !r.contains(d.serviceStopTime) { return false }
        if !authorPersons.isEmpty {
            let persons = d.authors.compactMap(\.person)
            guard authorPersons.contains(where: { pattern in persons.contains { Self.like($0, pattern) } }) else { return false }
        }
        return true
    }

    /// SQL LIKE: `%` any run, `_` any one character. Iterative, memory linear in the pattern.
    static func like(_ value: String, _ pattern: String) -> Bool {
        let v = Array(value), p = Array(pattern)
        // row[j]: the first i characters of the value match the first j of the pattern.
        var row = [Bool](repeating: false, count: p.count + 1)
        row[0] = true
        for j in 0..<p.count where p[j] == "%" { row[j + 1] = row[j] }
        for i in 0..<v.count {
            var next = [Bool](repeating: false, count: p.count + 1)
            for j in 0..<p.count {
                switch p[j] {
                case "%": next[j + 1] = next[j] || row[j + 1]
                case "_": next[j + 1] = row[j]
                default: next[j + 1] = row[j] && p[j] == v[i]
                }
            }
            row = next
        }
        return row[p.count]
    }
}

/// An `AdhocQueryResponse` (ITI-18): status, errors and the objects found.
public struct XDSQueryResponse: Hashable, Sendable {
    public var response: RegistryResponse
    public var objects: XDSObjectList

    public init(response: RegistryResponse, objects: XDSObjectList = XDSObjectList()) {
        self.response = response
        self.objects = objects
    }

    public static let name = XName(Namespace.query, "AdhocQueryResponse")

    public var element: XElement {
        var e = XElement(Self.name, attributes: [XAttribute(XName("status"), response.status.rawValue)])
        if let list = response.errorListElement { e.append(list) }
        e.append(objects.registryObjectList)
        return e
    }

    public init(element e: XElement) throws {
        guard e.name == Self.name else { throw XDSMetadataError.unexpectedElement(e.name) }
        response = try RegistryResponse(element: e)
        objects = try e.element(named: RIM.registryObjectList).map(XDSObjectList.init(registryObjectList:)) ?? XDSObjectList()
    }
}
