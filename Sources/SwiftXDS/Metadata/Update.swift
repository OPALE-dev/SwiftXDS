import Foundation

extension XDSAssociationType {
    /// Status change of a registry object, in an Update Document Set (ITI-57, ITI TF-3 §4.2.2.2.6
    /// and ITI TF-2 §3.57.4.1.3.3.2).
    public static let updateAvailabilityStatus = XDSAssociationType(rawValue: "urn:ihe:iti:2010:AssociationType:UpdateAvailabilityStatus")
}

extension XDSAssociation {
    /// `OriginalStatus` and `NewStatus` of an `UpdateAvailabilityStatus` association; nil when a
    /// slot is missing or not a status.
    public var statusChange: (original: XDSAvailabilityStatus, new: XDSAvailabilityStatus)? {
        func status(_ name: String) -> XDSAvailabilityStatus? {
            let values = extraSlots.first { $0.name == name }?.values ?? []
            return values.count == 1 ? XDSAvailabilityStatus(rawValue: values[0]) : nil
        }
        guard let original = status("OriginalStatus"), let new = status("NewStatus") else { return nil }
        return (original, new)
    }

    /// The association that moves `target` from one status to another, from the submission set.
    public static func statusUpdate(of target: String, by submissionSet: String,
                                    from original: XDSAvailabilityStatus, to new: XDSAvailabilityStatus) -> XDSAssociation {
        var a = XDSAssociation(type: .updateAvailabilityStatus, source: submissionSet, target: target)
        a.extraSlots = [XDSSlot(name: "OriginalStatus", values: [original.rawValue]), XDSSlot(name: "NewStatus", values: [new.rawValue])]
        return a
    }
}

extension XDSObjectList {
    /// A submission (ITI-41) whose document replaces `original`, a DocumentEntry already in the
    /// registry: the registry deprecates the original (RPLC, ITI TF-3 §4.2.2.2.1).
    public static func replacement(of original: String, by document: XDSDocumentEntry, in set: XDSSubmissionSet) -> XDSObjectList {
        submission(set, documents: [document], associations: [XDSAssociation(type: .replace, source: document.entryUUID, target: original)])
    }

    /// An Update Document Set (ITI-57) that changes the status of objects already in the registry
    /// (DocumentEntry or Folder), usually Approved → Deprecated to withdraw a document.
    public static func statusUpdate(_ targets: [String], in set: XDSSubmissionSet,
                                    from original: XDSAvailabilityStatus = .approved, to new: XDSAvailabilityStatus = .deprecated) -> XDSObjectList {
        var set = set
        if set.submissionTime == nil { set.submissionTime = .now() }
        return XDSObjectList(submissionSets: [set],
                             associations: targets.map { .statusUpdate(of: $0, by: set.entryUUID, from: original, to: new) })
    }
}
