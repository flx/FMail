# DONE

Implemented and committed. Items are moved here from TODO.md by `/done`.

## Features



## Bugs



## Architecture

- [x] (dead-viewmodel-state) Delete the vestigial `MailModel` list state and the dead optimistic-update paths — **2026-07-13**, commit `3af5943`. `MailModel`'s `threadsForSelectedMailbox` / `messagesInSelectedThread` / `searchResults` / `selectedThreadId` were never populated by anything (the real list lives in `StatusItemController`, fed straight from `IndexDB.searchSplitByPriority`), which left most of the optimistic-update pipeline inert — `applyOptimisticReadFlags` derived `prevIsRead` only from those permanently-empty arrays, so it never persisted anything, and `OptimisticUpdate`'s whole removal half had zero production callers while its 147-line test file stayed green. Kept the two parts that did real work (the immediate `allUnreadCount` badge delta and the DB write-back), deleted the rest plus the selection machinery (there is no sidebar) and the helpers left callerless. Net −357 lines; `OptimisticUpdate.swift` and `OptimisticUpdateTests.swift` are gone; new `ReadStatusControllerTests` covers the surviving behaviour against a real tmp `IndexDB`. Deliberate behaviour changes: the badge delta now counts only messages that actually change state (deduped by rowid) instead of multiplying by every message passed, and persist writes chain so two rapid mark actions commit in call order. `setReadStatus`'s contract is byte-for-byte unchanged.
