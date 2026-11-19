# Replacing and Withdrawing Documents

Replace a document by a new one (RPLC), or withdraw it (ITI-57).

## Overview

`XDSObjectList.replacement(of:by:in:)` builds a submission whose new entry
replaces the current one; the registry then deprecates the original, and its
transformations (XFRM) and addenda (APND) with it:

```swift
let v2 = XDSObjectList.replacement(of: current.entryUUID, by: newEntry, in: submissionSet)
_ = try await client.provideAndRegister(v2,
    documents: [XDSDocument(entryUUID: newEntry.entryUUID, data: kos)], to: repositoryURL)
```

`deprecate(_:in:registry:)` withdraws documents with an ITI-57 status update,
from Approved to Deprecated; `updateDocumentSet(_:registry:)` sends any
update, such as a return to Approved. A replaced document cannot be approved
again.

```swift
_ = try await client.deprecate([v2EntryUUID], in: updateSet, registry: registryURL)
```

Metadata updates that create a new version of an object are not implemented
yet.
