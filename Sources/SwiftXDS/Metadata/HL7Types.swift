import Foundation

/// HL7 v2 encoding used inside XDS metadata values (ITI TF-3 §4.2.3.1): components `^`,
/// subcomponents `&`, repetitions `~`, escapes `\F\ \S\ \T\ \R\ \E\`.
enum HL7Encoding {
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\E\\"
            case "^": out += "\\S\\"
            case "&": out += "\\T\\"
            case "~": out += "\\R\\"
            case "|": out += "\\F\\"
            default: out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", let end = s[s.index(after: i)...].firstIndex(of: "\\") {
                let code = s[s.index(after: i)..<end]
                switch code {
                case "E": out += "\\"
                case "S": out += "^"
                case "T": out += "&"
                case "R": out += "~"
                case "F": out += "|"
                default: out += "\\" + code + "\\"
                }
                i = s.index(after: end)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// Splits on a separator, keeping empty fields.
    static func split(_ s: String, _ separator: Character) -> [String] {
        s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    }

    /// Joins components, dropping trailing empty ones.
    static func join(_ parts: [String], _ separator: String) -> String {
        var p = parts
        while p.last?.isEmpty == true { p.removeLast() }
        return p.joined(separator: separator)
    }
}

/// An identifier with its assigning authority (CX), as `patientId` and `sourcePatientId` use it:
/// `id^^^&1.2.3&ISO`. Components the model does not name are kept, so a value reads back to the
/// same text; `XDSValidator` checks the restricted form `patientId` requires.
public struct CXIdentifier: Hashable, Sendable, CustomStringConvertible {
    public var id: String
    /// Assigning authority universal ID (CX.4.2): an OID for XDS affinity domains.
    public var assigningAuthority: String
    /// CX.4.3, `ISO` for an OID.
    public var assigningAuthorityType: String
    /// CX.4.1, the namespace ID of the assigning authority; empty in XDS `patientId`.
    public var assigningAuthorityNamespace: String?
    /// CX.5 identifier type code, if any (for example `NH`, `PI`).
    public var typeCode: String?
    /// Other components as received, escaped, by 1-based position (CX.2, CX.3, CX.6 and after).
    public var otherComponents: [Int: String]

    public init(id: String, assigningAuthority: String, assigningAuthorityType: String = "ISO", typeCode: String? = nil) {
        self.id = id
        self.assigningAuthority = assigningAuthority
        self.assigningAuthorityType = assigningAuthorityType
        self.typeCode = typeCode
        otherComponents = [:]
    }

    public var description: String {
        let authority = HL7Encoding.escape(assigningAuthorityNamespace ?? "") + "&" + HL7Encoding.escape(assigningAuthority)
            + "&" + HL7Encoding.escape(assigningAuthorityType)
        var parts = [HL7Encoding.escape(id), "", "", authority, typeCode.map(HL7Encoding.escape) ?? ""]
        for (index, value) in otherComponents {
            while parts.count < index { parts.append("") }
            parts[index - 1] = value
        }
        return HL7Encoding.join(parts, "^")
    }

    /// Parses `id^^^&oid&ISO`; `nil` without an ID or a universal ID.
    public init?(_ value: String) {
        let c = HL7Encoding.split(value, "^")
        guard let first = c.first, !first.isEmpty, c.count >= 4 else { return nil }
        let hd = HL7Encoding.split(c[3], "&")
        guard hd.count >= 2, !hd[1].isEmpty else { return nil }
        id = HL7Encoding.unescape(first)
        assigningAuthorityNamespace = hd[0].isEmpty ? nil : HL7Encoding.unescape(hd[0])
        assigningAuthority = HL7Encoding.unescape(hd[1])
        assigningAuthorityType = hd.count > 2 ? HL7Encoding.unescape(hd[2]) : ""
        typeCode = c.count > 4 && !c[4].isEmpty ? HL7Encoding.unescape(c[4]) : nil
        otherComponents = [:]
        for (i, component) in c.enumerated() where (i == 1 || i == 2 || i >= 5) && !component.isEmpty {
            otherComponents[i + 1] = component
        }
    }

    /// The form `patientId` requires (ITI TF-3 §4.2.3.1.7): CX.1 and CX.4 only, CX.4 being
    /// `&OID&ISO`.
    public var isAffinityDomainIdentifier: Bool {
        XDSValidator.isOID(assigningAuthority) && assigningAuthorityType == "ISO" && assigningAuthorityNamespace == nil
            && typeCode == nil && otherComponents.isEmpty
    }
}

/// A person (XCN), as `authorPerson` and `legalAuthenticator` use it. A convenience to build and read
/// the usual components (XCN.1 to XCN.6 and XCN.9): it writes the authority as `&OID&ISO` and does
/// not keep XCN.7, XCN.8 or XCN.10 and after. Metadata keeps author and authenticator values as
/// received, so rewriting metadata loses nothing.
public struct XCNPerson: Hashable, Sendable, CustomStringConvertible {
    public var id: String?
    public var family: String?
    public var given: String?
    public var middle: String?
    public var suffix: String?
    public var prefix: String?
    /// Assigning authority of `id` (universal ID, ISO).
    public var assigningAuthority: String?

    public init(id: String? = nil, family: String? = nil, given: String? = nil, middle: String? = nil,
                suffix: String? = nil, prefix: String? = nil, assigningAuthority: String? = nil) {
        self.id = id
        self.family = family
        self.given = given
        self.middle = middle
        self.suffix = suffix
        self.prefix = prefix
        self.assigningAuthority = assigningAuthority
    }

    public var description: String {
        let e = { (s: String?) in s.map(HL7Encoding.escape) ?? "" }
        let authority = assigningAuthority.map { "&" + HL7Encoding.escape($0) + "&ISO" } ?? ""
        return HL7Encoding.join([e(id), e(family), e(given), e(middle), e(suffix), e(prefix), "", "", authority], "^")
    }

    public init(_ value: String) {
        let c = HL7Encoding.split(value, "^")
        func at(_ i: Int) -> String? { i < c.count && !c[i].isEmpty ? HL7Encoding.unescape(c[i]) : nil }
        id = at(0); family = at(1); given = at(2); middle = at(3); suffix = at(4); prefix = at(5)
        if c.count > 8 {
            let hd = HL7Encoding.split(c[8], "&")
            assigningAuthority = hd.count > 1 && !hd[1].isEmpty ? HL7Encoding.unescape(hd[1]) : nil
        }
    }
}

/// An organisation (XON), as `authorInstitution` uses it: `name^^^^^&oid&ISO^^^^id`. Like
/// `XCNPerson`, a convenience that keeps XON.1, XON.6.2 and XON.10 only.
public struct XONOrganization: Hashable, Sendable, CustomStringConvertible {
    public var name: String
    public var identifier: String?
    public var assigningAuthority: String?

    public init(name: String, identifier: String? = nil, assigningAuthority: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.assigningAuthority = assigningAuthority
    }

    public var description: String {
        let authority = assigningAuthority.map { "&" + HL7Encoding.escape($0) + "&ISO" } ?? ""
        return HL7Encoding.join([HL7Encoding.escape(name), "", "", "", "", authority, "", "", "", identifier.map(HL7Encoding.escape) ?? ""], "^")
    }

    public init(_ value: String) {
        let c = HL7Encoding.split(value, "^")
        name = HL7Encoding.unescape(c.first ?? "")
        if c.count > 5 {
            let hd = HL7Encoding.split(c[5], "&")
            assigningAuthority = hd.count > 1 && !hd[1].isEmpty ? HL7Encoding.unescape(hd[1]) : nil
        }
        identifier = c.count > 9 && !c[9].isEmpty ? HL7Encoding.unescape(c[9]) : nil
    }
}

/// XDS date and time (DTM, UTC): `YYYY[MM[DD[hh[mm[ss]]]]]`.
public struct XDSDateTime: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: String

    /// Accepts 4 to 14 digits with an even length after the year, and real dates and times
    /// (month 1–12, day within the month, hour 0–23, minute and second 0–59).
    public init?(_ value: String) {
        let n = value.count
        guard (4...14).contains(n), n == 4 || n % 2 == 0, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let digits = Array(value.utf8).map { Int($0) - 48 }
        func field(_ at: Int, _ length: Int) -> Int? {
            at + length <= digits.count ? digits[at..<(at + length)].reduce(0) { $0 * 10 + $1 } : nil
        }
        let year = field(0, 4)!
        if let month = field(4, 2) {
            guard (1...12).contains(month) else { return nil }
            if let day = field(6, 2) {
                guard day >= 1, day <= Self.days(inMonth: month, year: year) else { return nil }
            }
        }
        if let hour = field(8, 2), hour > 23 { return nil }
        if let minute = field(10, 2), minute > 59 { return nil }
        if let second = field(12, 2), second > 59 { return nil }
        self.value = value
    }

    static func days(inMonth month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Second precision, UTC.
    public init(_ date: Date) {
        let c = Self.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        value = String(format: "%04d%02d%02d%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    public static func now() -> XDSDateTime { XDSDateTime(Date()) }

    /// The start of the period the value denotes, UTC.
    public var date: Date? {
        let padded = Array((value + String("0101000000".suffix(14 - value.count))).utf8).map { Int($0) - 48 }
        func field(_ at: Int, _ length: Int) -> Int { padded[at..<(at + length)].reduce(0) { $0 * 10 + $1 } }
        return Self.calendar.date(from: DateComponents(year: field(0, 4), month: field(4, 2), day: field(6, 2),
                                                       hour: field(8, 2), minute: field(10, 2), second: field(12, 2)))
    }

    public var description: String { value }

    /// Compares as instants, shorter values standing for the start of their period.
    public static func < (a: XDSDateTime, b: XDSDateTime) -> Bool {
        (a.value + String(repeating: "0", count: 14 - a.value.count)) < (b.value + String(repeating: "0", count: 14 - b.value.count))
    }
}
