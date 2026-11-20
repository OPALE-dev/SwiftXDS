import Foundation

public enum XDSMetadataError: Error, Hashable, Sendable, CustomStringConvertible {
    case missingAttribute(element: String, attribute: String)
    case unexpectedElement(XName)
    case invalidValue(attribute: String, value: String)
    /// A `RegistryPackage` classified neither as a submission set nor as a folder.
    case unclassifiedRegistryPackage(id: String)

    public var description: String {
        switch self {
        case .missingAttribute(let e, let a): "\(e) without \(a)"
        case .unexpectedElement(let n): "unexpected element \(n)"
        case .invalidValue(let a, let v): "invalid \(a) '\(v)'"
        case .unclassifiedRegistryPackage(let id): "RegistryPackage \(id) is classified neither as a SubmissionSet nor as a Folder"
        }
    }
}

/// Encoding of XDS metadata as ebRIM 3.0 (ITI TF-3 §4.2.3), and back.
///
/// What the model does not know is kept: slots in `extraSlots`, classifications and external
/// identifiers of unknown schemes in `extraClassifications` and `extraIdentifiers`, as read. The
/// IDs of the known classifications and external identifiers are kept too (`XDSComponentIDs`).
enum RIM {
    static func name(_ local: String) -> XName { XName(Namespace.rim, local) }
    static let slot = name("Slot"), valueList = name("ValueList"), value = name("Value")
    static let nameElement = name("Name"), description = name("Description"), localizedString = name("LocalizedString")
    static let classification = name("Classification"), externalIdentifier = name("ExternalIdentifier")
    static let extrinsicObject = name("ExtrinsicObject"), registryPackage = name("RegistryPackage")
    static let association = name("Association"), objectRef = name("ObjectRef"), versionInfo = name("VersionInfo")
    static let registryObjectList = name("RegistryObjectList")
    static let xmlLang = XName(XMLWriter.xmlNamespace, "lang")

    static func attr(_ local: String, _ value: String?) -> XAttribute? {
        value.map { XAttribute(XName(local), $0) }
    }

    static func slot(_ name: String, _ values: [String]) -> XElement? {
        values.isEmpty ? nil : XElement(slot, attributes: [XAttribute(XName("name"), name)], elements: [
            XElement(valueList, elements: values.map { XElement(value, text: $0) }),
        ])
    }

    static func localized(_ element: XName, _ strings: [XDSLocalizedString]) -> XElement? {
        strings.isEmpty ? nil : XElement(element, elements: strings.map { s in
            XElement(localizedString, attributes: [
                attr("charset", s.charset), s.language.map { XAttribute(xmlLang, $0) }, XAttribute(XName("value"), s.value),
            ].compactMap { $0 })
        })
    }

    static func localizedStrings(_ e: XElement?) -> [XDSLocalizedString] {
        e?.elements(named: localizedString).map {
            XDSLocalizedString($0.attribute("value") ?? "", language: $0.attribute(xmlLang), charset: $0.attribute("charset"))
        } ?? []
    }

    /// UUIDs compare without case (RFC 4122); the schemes of SwiftXDS are lower case.
    static func normalized(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.lowercased().hasPrefix("urn:uuid:") ? s.lowercased() : s
    }

    // MARK: Component IDs

    /// Keys of `XDSComponentIDs`: `scheme#n` for the n-th classification of a scheme, the node for
    /// a node classification, the scheme for an external identifier.
    struct Keys {
        var counts: [String: Int] = [:]
        mutating func next(_ scheme: String) -> String {
            let n = counts[scheme, default: 0]
            counts[scheme] = n + 1
            return "\(scheme)#\(n)"
        }
    }

    /// An ID derived from the object ID and the key, so that the same object writes the same IDs
    /// every time. For an object with a `urn:uuid:` ID, a `urn:uuid:` (version 8, RFC 9562); for a
    /// symbolic ID (`Document01`, which the registry replaces), a symbolic ID too: two submissions
    /// that both use `Document01` must not send the same UUIDs.
    static func derivedID(object: String, key: String) -> String {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in (object + "|" + key).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        guard object.lowercased().hasPrefix("urn:uuid:") else {
            return object + "_" + String(fnv(0xcbf29ce484222325), radix: 16)
        }
        var bytes = withUnsafeBytes(of: fnv(0xcbf29ce484222325).bigEndian, Array.init) + withUnsafeBytes(of: fnv(0x84222325cbf29ce4).bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return "urn:uuid:" + [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    struct Writer {
        let object: String
        let ids: XDSComponentIDs
        var keys = Keys()

        func id(_ key: String) -> String { ids[key] ?? RIM.derivedID(object: object, key: key) }

        mutating func code(_ code: XDSCode, scheme: String) -> XElement {
            XElement(classification, attributes: [
                XAttribute(XName("classificationScheme"), scheme), XAttribute(XName("classifiedObject"), object),
                XAttribute(XName("id"), id(keys.next(scheme))), XAttribute(XName("nodeRepresentation"), code.code),
                XAttribute(XName("objectType"), XDSScheme.classificationType),
            ], elements: [slot("codingScheme", [code.codingScheme]), localized(nameElement, code.localizedDisplayName)].compactMap { $0 })
        }

        mutating func author(_ a: XDSAuthor, scheme: String) -> XElement {
            XElement(classification, attributes: [
                XAttribute(XName("classificationScheme"), scheme), XAttribute(XName("classifiedObject"), object),
                XAttribute(XName("id"), id(keys.next(scheme))), XAttribute(XName("nodeRepresentation"), ""),
                XAttribute(XName("objectType"), XDSScheme.classificationType),
            ], elements: [
                slot("authorPerson", a.person.map { [$0] } ?? []), slot("authorInstitution", a.institutions),
                slot("authorRole", a.roles), slot("authorSpecialty", a.specialties),
                slot("authorTelecommunication", a.telecommunications),
            ].compactMap { $0 })
        }

        func node(_ node: String) -> XElement {
            XElement(classification, attributes: [
                XAttribute(XName("classificationNode"), node), XAttribute(XName("classifiedObject"), object),
                XAttribute(XName("id"), id(node)), XAttribute(XName("objectType"), XDSScheme.classificationType),
            ])
        }

        /// Classifications or external identifiers kept as read, attached to this object by
        /// `attribute` (`classifiedObject`, `registryObject`), in the alphabetical place of the
        /// attributes SwiftXDS writes.
        func kept(_ elements: [XElement], attachedBy attribute: String) -> [XElement] {
            let name = XName(attribute)
            return elements.map { e in
                var e = e
                e.attributes.removeAll { $0.name == name }
                let at = e.attributes.firstIndex { $0.name.namespace == nil && $0.name.local > attribute } ?? e.attributes.endIndex
                e.attributes.insert(XAttribute(name, object), at: at)
                return e
            }
        }

        func identifier(_ value: String, scheme: String, label: String) -> XElement {
            XElement(externalIdentifier, attributes: [
                XAttribute(XName("id"), id(scheme)), XAttribute(XName("identificationScheme"), scheme),
                XAttribute(XName("objectType"), XDSScheme.externalIdentifierType),
                XAttribute(XName("registryObject"), object), XAttribute(XName("value"), value),
            ], elements: [localized(nameElement, [XDSLocalizedString(label)])!])
        }
    }

    static func object(_ element: XName, attributes: [XAttribute?], slots: [XElement?], extra: [XDSSlot],
                       title: [XDSLocalizedString], comments: [XDSLocalizedString], version: String?,
                       classifications: [XElement], identifiers: [XElement]) -> XElement {
        var children: [XElement] = slots.compactMap { $0 } + extra.compactMap { slot($0.name, $0.values) }
        if let t = localized(nameElement, title) { children.append(t) }
        if let d = localized(description, comments) { children.append(d) }
        if let version { children.append(XElement(versionInfo, attributes: [XAttribute(XName("versionName"), version)])) }
        return XElement(element, attributes: attributes.compactMap { $0 }, elements: children + classifications + identifiers)
    }

    // MARK: Reading

    struct Parsed {
        let object: String
        var slots: [String: [String]] = [:]
        var slotOrder: [String] = []
        var title: [XDSLocalizedString] = []
        var comments: [XDSLocalizedString] = []
        var version: String?
        var classifications: [XElement] = []
        var identifierElements: [XElement] = []

        /// `siblings`: classifications and external identifiers of the object placed next to it in
        /// the `RegistryObjectList`.
        init(_ e: XElement, siblings: [XElement]) throws {
            object = try RIM.required(e, "id")
            for child in e.elements + siblings {
                switch child.name {
                case slot:
                    let n = child.attribute("name") ?? ""
                    if slots[n] == nil { slotOrder.append(n) }
                    slots[n, default: []] += RIM.values(child)
                case nameElement: title = RIM.localizedStrings(child)
                case description: comments = RIM.localizedStrings(child)
                case versionInfo: version = child.attribute("versionName")
                case classification: classifications.append(child)
                case externalIdentifier: identifierElements.append(child)
                default: break
                }
            }
        }

        /// Removes and returns the classifications and external identifiers the object type does
        /// not know: `schemes` and `nodes` are its classification schemes and nodes, `identifiers`
        /// its identification schemes.
        mutating func setAside(schemes: Set<String>, nodes: Set<String>, identifiers: Set<String>) -> (classifications: [XElement], identifiers: [XElement]) {
            func known(_ c: XElement) -> Bool {
                if let node = RIM.normalized(c.attribute("classificationNode")) { return nodes.contains(node) }
                return scheme(c).map(schemes.contains) ?? false
            }
            func knownIdentifier(_ e: XElement) -> Bool {
                RIM.normalized(e.attribute("identificationScheme")).map(identifiers.contains) ?? false
            }
            // Detached from the object: its ID may change (a registry replaces a symbolic ID).
            func detached(_ e: XElement, _ attribute: String) -> XElement {
                var e = e
                e.attributes.removeAll { $0.name == XName(attribute) }
                return e
            }
            let unknown = (classifications.filter { !known($0) }.map { detached($0, "classifiedObject") },
                           identifierElements.filter { !knownIdentifier($0) }.map { detached($0, "registryObject") })
            let kept = (classifications.filter(known), identifierElements.filter(knownIdentifier))
            (classifications, identifierElements) = kept
            return unknown
        }

        func single(_ name: String) -> String? { slots[name]?.first }

        func scheme(_ c: XElement) -> String? { RIM.normalized(c.attribute("classificationScheme")) }

        func codes(_ scheme: String) -> [XDSCode] {
            classifications.filter { self.scheme($0) == scheme }.map { c in
                XDSCode(code: c.attribute("nodeRepresentation") ?? "",
                        codingScheme: c.elements(named: RIM.slot).first { $0.attribute("name") == "codingScheme" }.map(RIM.values)?.first ?? "",
                        localizedDisplayName: RIM.localizedStrings(c.element(named: RIM.nameElement)))
            }
        }

        func authors(_ scheme: String) -> [XDSAuthor] {
            classifications.filter { self.scheme($0) == scheme }.map { c in
                var s: [String: [String]] = [:]
                for e in c.elements(named: RIM.slot) { s[e.attribute("name") ?? "", default: []] += RIM.values(e) }
                return XDSAuthor(person: s["authorPerson"]?.first, institutions: s["authorInstitution"] ?? [],
                                 roles: s["authorRole"] ?? [], specialties: s["authorSpecialty"] ?? [],
                                 telecommunications: s["authorTelecommunication"] ?? [])
            }
        }

        func hasNode(_ node: String) -> Bool {
            classifications.contains { RIM.normalized($0.attribute("classificationNode")) == node }
        }

        func identifier(_ scheme: String) -> String? {
            identifierElements.first { RIM.normalized($0.attribute("identificationScheme")) == scheme }?.attribute("value")
        }

        /// The IDs read that differ from the derived ones.
        var componentIDs: XDSComponentIDs {
            var ids = XDSComponentIDs()
            var keys = Keys()
            func keep(_ key: String, _ e: XElement) {
                if let id = e.attribute("id"), id != RIM.derivedID(object: object, key: key) { ids[key] = id }
            }
            for c in classifications {
                if let node = RIM.normalized(c.attribute("classificationNode")) { keep(node, c) }
                else if let s = scheme(c) { keep(keys.next(s), c) }
            }
            for e in identifierElements {
                if let s = RIM.normalized(e.attribute("identificationScheme")) { keep(s, e) }
            }
            return ids
        }

        func extra(excluding known: Set<String>) -> [XDSSlot] {
            slotOrder.filter { !known.contains($0) }.map { XDSSlot(name: $0, values: slots[$0]!) }
        }
    }

    static func values(_ slot: XElement) -> [String] {
        slot.element(named: valueList)?.elements(named: value).map(\.text) ?? []
    }

    static func required(_ e: XElement, _ attribute: String) throws -> String {
        guard let v = e.attribute(attribute), !v.isEmpty else {
            throw XDSMetadataError.missingAttribute(element: e.name.local, attribute: attribute)
        }
        return v
    }

    /// A value the model types, refused when present but invalid (rather than lost).
    static func typed<T>(_ raw: String?, _ attribute: String, _ make: (String) -> T?) throws -> T? {
        guard let raw else { return nil }
        guard let value = make(raw) else { throw XDSMetadataError.invalidValue(attribute: attribute, value: raw) }
        return value
    }
}

extension XDSDocumentEntry {
    static let knownSlots: Set<String> = ["creationTime", "hash", "languageCode", "legalAuthenticator", "referenceIdList",
                                          "repositoryUniqueId", "serviceStartTime", "serviceStopTime", "size",
                                          "sourcePatientId", "sourcePatientInfo", "URI", "documentAvailability"]
    static let knownSchemes: Set<String> = [
        XDSScheme.documentEntryAuthor, XDSScheme.documentEntryClassCode, XDSScheme.documentEntryConfidentialityCode,
        XDSScheme.documentEntryEventCodeList, XDSScheme.documentEntryFormatCode, XDSScheme.documentEntryHealthcareFacilityTypeCode,
        XDSScheme.documentEntryPracticeSettingCode, XDSScheme.documentEntryTypeCode,
    ]

    public var element: XElement {
        var w = RIM.Writer(object: entryUUID, ids: componentIDs)
        var classifications: [XElement] = authors.map { w.author($0, scheme: XDSScheme.documentEntryAuthor) }
        func add(_ c: XDSCode?, _ scheme: String) { if let c { classifications.append(w.code(c, scheme: scheme)) } }
        add(classCode, XDSScheme.documentEntryClassCode)
        confidentialityCodes.forEach { add($0, XDSScheme.documentEntryConfidentialityCode) }
        eventCodes.forEach { add($0, XDSScheme.documentEntryEventCodeList) }
        add(formatCode, XDSScheme.documentEntryFormatCode)
        add(healthcareFacilityTypeCode, XDSScheme.documentEntryHealthcareFacilityTypeCode)
        add(practiceSettingCode, XDSScheme.documentEntryPracticeSettingCode)
        add(typeCode, XDSScheme.documentEntryTypeCode)
        if limitedMetadata { classifications.append(w.node(XDSScheme.documentEntryLimitedMetadata)) }
        classifications += w.kept(extraClassifications, attachedBy: "classifiedObject")
        var identifiers: [XElement] = []
        if let patientId {
            identifiers.append(w.identifier(patientId.description, scheme: XDSScheme.documentEntryPatientId, label: "XDSDocumentEntry.patientId"))
        }
        identifiers.append(w.identifier(uniqueId, scheme: XDSScheme.documentEntryUniqueId, label: "XDSDocumentEntry.uniqueId"))
        identifiers += w.kept(extraIdentifiers, attachedBy: "registryObject")
        let one = { (s: String?) in s.map { [$0] } ?? [] }
        return RIM.object(RIM.extrinsicObject, attributes: [
            RIM.attr("home", homeCommunityId), RIM.attr("id", entryUUID), RIM.attr("lid", logicalID), RIM.attr("mimeType", mimeType),
            RIM.attr("objectType", objectType), RIM.attr("status", availabilityStatus?.rawValue),
        ], slots: [
            RIM.slot("creationTime", one(creationTime?.value)), RIM.slot("hash", one(hash)),
            RIM.slot("languageCode", one(languageCode)), RIM.slot("legalAuthenticator", one(legalAuthenticator)),
            RIM.slot("referenceIdList", referenceIds), RIM.slot("repositoryUniqueId", one(repositoryUniqueId)),
            RIM.slot("serviceStartTime", one(serviceStartTime?.value)), RIM.slot("serviceStopTime", one(serviceStopTime?.value)),
            RIM.slot("size", one(size.map(String.init))), RIM.slot("sourcePatientId", one(sourcePatientId?.description)),
            RIM.slot("sourcePatientInfo", sourcePatientInfo), RIM.slot("URI", one(uri)),
            RIM.slot("documentAvailability", one(documentAvailability?.rawValue)),
        ], extra: extraSlots, title: localizedTitle, comments: localizedComments, version: version,
        classifications: classifications, identifiers: identifiers)
    }

    /// Reads an `ExtrinsicObject`; a value that is present but invalid (patient ID, date, status…)
    /// is an error, so that it is neither lost nor reported as missing.
    public init(element e: XElement, siblings: [XElement] = []) throws {
        var p = try RIM.Parsed(e, siblings: siblings)
        let unknown = p.setAside(schemes: Self.knownSchemes, nodes: [XDSScheme.documentEntryLimitedMetadata],
                                 identifiers: [XDSScheme.documentEntryPatientId, XDSScheme.documentEntryUniqueId])
        self.init(entryUUID: p.object, uniqueId: p.identifier(XDSScheme.documentEntryUniqueId) ?? "",
                  patientId: try RIM.typed(p.identifier(XDSScheme.documentEntryPatientId), "patientId", CXIdentifier.init),
                  mimeType: e.attribute("mimeType") ?? "",
                  objectType: RIM.normalized(e.attribute("objectType")) ?? XDSScheme.documentEntryStable)
        availabilityStatus = try RIM.typed(e.attribute("status"), "status", XDSAvailabilityStatus.init(rawValue:))
        homeCommunityId = e.attribute("home")
        logicalID = e.attribute("lid")
        version = p.version
        localizedTitle = p.title
        localizedComments = p.comments
        creationTime = try RIM.typed(p.single("creationTime"), "creationTime", XDSDateTime.init)
        hash = p.single("hash")
        languageCode = p.single("languageCode")
        legalAuthenticator = p.single("legalAuthenticator")
        referenceIds = p.slots["referenceIdList"] ?? []
        repositoryUniqueId = p.single("repositoryUniqueId")
        serviceStartTime = try RIM.typed(p.single("serviceStartTime"), "serviceStartTime", XDSDateTime.init)
        serviceStopTime = try RIM.typed(p.single("serviceStopTime"), "serviceStopTime", XDSDateTime.init)
        size = try RIM.typed(p.single("size"), "size") { Int64($0).flatMap { $0 >= 0 ? $0 : nil } }
        sourcePatientId = try RIM.typed(p.single("sourcePatientId"), "sourcePatientId", CXIdentifier.init)
        sourcePatientInfo = p.slots["sourcePatientInfo"] ?? []
        uri = p.single("URI")
        documentAvailability = try RIM.typed(p.single("documentAvailability"), "documentAvailability", XDSDocumentAvailability.init(rawValue:))
        authors = p.authors(XDSScheme.documentEntryAuthor)
        classCode = p.codes(XDSScheme.documentEntryClassCode).first
        confidentialityCodes = p.codes(XDSScheme.documentEntryConfidentialityCode)
        eventCodes = p.codes(XDSScheme.documentEntryEventCodeList)
        formatCode = p.codes(XDSScheme.documentEntryFormatCode).first
        healthcareFacilityTypeCode = p.codes(XDSScheme.documentEntryHealthcareFacilityTypeCode).first
        practiceSettingCode = p.codes(XDSScheme.documentEntryPracticeSettingCode).first
        typeCode = p.codes(XDSScheme.documentEntryTypeCode).first
        limitedMetadata = p.hasNode(XDSScheme.documentEntryLimitedMetadata)
        extraSlots = p.extra(excluding: Self.knownSlots)
        extraClassifications = unknown.classifications
        extraIdentifiers = unknown.identifiers
        componentIDs = p.componentIDs
    }
}

extension XDSSubmissionSet {
    static let knownSlots: Set<String> = ["submissionTime", "intendedRecipient"]

    public var element: XElement {
        var w = RIM.Writer(object: entryUUID, ids: componentIDs)
        var classifications: [XElement] = authors.map { w.author($0, scheme: XDSScheme.submissionSetAuthor) }
        if let contentTypeCode { classifications.append(w.code(contentTypeCode, scheme: XDSScheme.submissionSetContentTypeCode)) }
        classifications.append(w.node(XDSScheme.submissionSet))
        if limitedMetadata { classifications.append(w.node(XDSScheme.submissionSetLimitedMetadata)) }
        classifications += w.kept(extraClassifications, attachedBy: "classifiedObject")
        var identifiers = [
            w.identifier(uniqueId, scheme: XDSScheme.submissionSetUniqueId, label: "XDSSubmissionSet.uniqueId"),
            w.identifier(sourceId, scheme: XDSScheme.submissionSetSourceId, label: "XDSSubmissionSet.sourceId"),
        ]
        if let patientId {
            identifiers.append(w.identifier(patientId.description, scheme: XDSScheme.submissionSetPatientId, label: "XDSSubmissionSet.patientId"))
        }
        identifiers += w.kept(extraIdentifiers, attachedBy: "registryObject")
        return RIM.object(RIM.registryPackage, attributes: [
            RIM.attr("home", homeCommunityId), RIM.attr("id", entryUUID), RIM.attr("lid", logicalID),
            RIM.attr("objectType", XDSScheme.registryPackageType), RIM.attr("status", availabilityStatus?.rawValue),
        ], slots: [
            RIM.slot("submissionTime", submissionTime.map { [$0.value] } ?? []), RIM.slot("intendedRecipient", intendedRecipients),
        ], extra: extraSlots, title: localizedTitle, comments: localizedComments, version: version,
        classifications: classifications, identifiers: identifiers)
    }

    public init(element e: XElement, siblings: [XElement] = []) throws {
        var p = try RIM.Parsed(e, siblings: siblings)
        let unknown = p.setAside(schemes: [XDSScheme.submissionSetAuthor, XDSScheme.submissionSetContentTypeCode],
                                 nodes: [XDSScheme.submissionSet, XDSScheme.submissionSetLimitedMetadata],
                                 identifiers: [XDSScheme.submissionSetUniqueId, XDSScheme.submissionSetSourceId, XDSScheme.submissionSetPatientId])
        self.init(entryUUID: p.object, uniqueId: p.identifier(XDSScheme.submissionSetUniqueId) ?? "",
                  sourceId: p.identifier(XDSScheme.submissionSetSourceId) ?? "",
                  patientId: try RIM.typed(p.identifier(XDSScheme.submissionSetPatientId), "patientId", CXIdentifier.init),
                  submissionTime: try RIM.typed(p.single("submissionTime"), "submissionTime", XDSDateTime.init),
                  contentTypeCode: p.codes(XDSScheme.submissionSetContentTypeCode).first)
        authors = p.authors(XDSScheme.submissionSetAuthor)
        localizedTitle = p.title
        localizedComments = p.comments
        intendedRecipients = p.slots["intendedRecipient"] ?? []
        homeCommunityId = e.attribute("home")
        logicalID = e.attribute("lid")
        version = p.version
        availabilityStatus = try RIM.typed(e.attribute("status"), "status", XDSAvailabilityStatus.init(rawValue:))
        limitedMetadata = p.hasNode(XDSScheme.submissionSetLimitedMetadata)
        extraSlots = p.extra(excluding: Self.knownSlots)
        extraClassifications = unknown.classifications
        extraIdentifiers = unknown.identifiers
        componentIDs = p.componentIDs
    }
}

extension XDSFolder {
    static let knownSlots: Set<String> = ["lastUpdateTime"]

    public var element: XElement {
        var w = RIM.Writer(object: entryUUID, ids: componentIDs)
        var classifications = codeList.map { w.code($0, scheme: XDSScheme.folderCodeList) }
        classifications.append(w.node(XDSScheme.folder))
        if limitedMetadata { classifications.append(w.node(XDSScheme.folderLimitedMetadata)) }
        classifications += w.kept(extraClassifications, attachedBy: "classifiedObject")
        var identifiers = [w.identifier(uniqueId, scheme: XDSScheme.folderUniqueId, label: "XDSFolder.uniqueId")]
        if let patientId {
            identifiers.append(w.identifier(patientId.description, scheme: XDSScheme.folderPatientId, label: "XDSFolder.patientId"))
        }
        identifiers += w.kept(extraIdentifiers, attachedBy: "registryObject")
        return RIM.object(RIM.registryPackage, attributes: [
            RIM.attr("home", homeCommunityId), RIM.attr("id", entryUUID), RIM.attr("lid", logicalID),
            RIM.attr("objectType", XDSScheme.registryPackageType), RIM.attr("status", availabilityStatus?.rawValue),
        ], slots: [RIM.slot("lastUpdateTime", lastUpdateTime.map { [$0.value] } ?? [])], extra: extraSlots,
        title: localizedTitle, comments: localizedComments, version: version, classifications: classifications, identifiers: identifiers)
    }

    public init(element e: XElement, siblings: [XElement] = []) throws {
        var p = try RIM.Parsed(e, siblings: siblings)
        let unknown = p.setAside(schemes: [XDSScheme.folderCodeList], nodes: [XDSScheme.folder, XDSScheme.folderLimitedMetadata],
                                 identifiers: [XDSScheme.folderUniqueId, XDSScheme.folderPatientId])
        self.init(entryUUID: p.object, uniqueId: p.identifier(XDSScheme.folderUniqueId) ?? "",
                  patientId: try RIM.typed(p.identifier(XDSScheme.folderPatientId), "patientId", CXIdentifier.init),
                  codeList: p.codes(XDSScheme.folderCodeList), title: nil)
        localizedTitle = p.title
        localizedComments = p.comments
        lastUpdateTime = try RIM.typed(p.single("lastUpdateTime"), "lastUpdateTime", XDSDateTime.init)
        homeCommunityId = e.attribute("home")
        logicalID = e.attribute("lid")
        version = p.version
        availabilityStatus = try RIM.typed(e.attribute("status"), "status", XDSAvailabilityStatus.init(rawValue:))
        limitedMetadata = p.hasNode(XDSScheme.folderLimitedMetadata)
        extraSlots = p.extra(excluding: Self.knownSlots)
        extraClassifications = unknown.classifications
        extraIdentifiers = unknown.identifiers
        componentIDs = p.componentIDs
    }
}

extension XDSAssociation {
    public var element: XElement {
        XElement(RIM.association, attributes: [
            XAttribute(XName("associationType"), type.rawValue), XAttribute(XName("id"), id),
            XAttribute(XName("objectType"), XDSScheme.associationType),
            XAttribute(XName("sourceObject"), source), XAttribute(XName("targetObject"), target),
        ] + [RIM.attr("status", availabilityStatus?.rawValue)].compactMap { $0 },
        elements: ([RIM.slot("SubmissionSetStatus", submissionSetStatus.map { [$0.rawValue] } ?? [])] + extraSlots.map { RIM.slot($0.name, $0.values) }).compactMap { $0 })
    }

    public init(element e: XElement) throws {
        self.init(id: try RIM.required(e, "id"), type: XDSAssociationType(rawValue: try RIM.required(e, "associationType")),
                  source: try RIM.required(e, "sourceObject"), target: try RIM.required(e, "targetObject"))
        availabilityStatus = try RIM.typed(e.attribute("status"), "status", XDSAvailabilityStatus.init(rawValue:))
        for s in e.elements(named: RIM.slot) {
            let name = s.attribute("name") ?? ""
            if name == "SubmissionSetStatus" {
                submissionSetStatus = try RIM.typed(RIM.values(s).first, "SubmissionSetStatus", XDSSubmissionSetStatus.init(rawValue:))
            } else {
                extraSlots.append(XDSSlot(name: name, values: RIM.values(s)))
            }
        }
    }
}

extension XDSObjectList {
    /// The `rim:RegistryObjectList` element: object references, documents, submission sets,
    /// folders, then associations.
    public var registryObjectList: XElement {
        let children = objectRefs.map { XElement(RIM.objectRef, attributes: [XAttribute(XName("id"), $0)]) }
            + documentEntries.map(\.element) + submissionSets.map(\.element) + folders.map(\.element) + associations.map(\.element)
        return XElement(RIM.registryObjectList, elements: children)
    }

    /// `lcm:SubmitObjectsRequest` wrapping the object list (ITI-41, ITI-42, ITI-57).
    public var submitObjectsRequest: XElement {
        XElement(XName(Namespace.lcm, "SubmitObjectsRequest"), elements: [registryObjectList])
    }

    /// Reads a `rim:RegistryObjectList` (or any element whose children are registry objects).
    /// Classifications and external identifiers may be placed next to the object they belong to.
    public init(registryObjectList list: XElement) throws {
        self.init()
        let top = list.elements
        var siblings: [String: [XElement]] = [:]
        for c in top {
            let owner = c.name == RIM.classification ? c.attribute("classifiedObject")
                : c.name == RIM.externalIdentifier ? c.attribute("registryObject") : nil
            if let owner { siblings[owner, default: []].append(c) }
        }
        for e in top {
            let extra = e.attribute("id").flatMap { siblings[$0] } ?? []
            switch e.name {
            case RIM.extrinsicObject:
                documentEntries.append(try XDSDocumentEntry(element: e, siblings: extra))
            case RIM.registryPackage:
                let nodes = (e.elements(named: RIM.classification) + extra).compactMap { RIM.normalized($0.attribute("classificationNode")) }
                if nodes.contains(XDSScheme.folder) {
                    folders.append(try XDSFolder(element: e, siblings: extra))
                } else if nodes.contains(XDSScheme.submissionSet) {
                    submissionSets.append(try XDSSubmissionSet(element: e, siblings: extra))
                } else {
                    throw XDSMetadataError.unclassifiedRegistryPackage(id: e.attribute("id") ?? "")
                }
            case RIM.association:
                associations.append(try XDSAssociation(element: e))
            case RIM.objectRef:
                objectRefs.append(try RIM.required(e, "id"))
            default:
                continue
            }
        }
    }
}
