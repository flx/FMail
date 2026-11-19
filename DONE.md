# DONE

Implemented and committed. Items are moved here from TODO.md by `/done`.

## Features

- [x] (mcp-draft-reply) MCP `draft_reply`: open a reply / reply-all in Mail.app pre-filled with draft text and attachments (files on disk, or attachments of indexed emails); never sends — **2026-11-19**. Mail.app discards its native quote on any AppleScript write to a reply's content (verified), so the drafter pastes text + files via System Events when FMail has Accessibility and the screen is unlocked, else falls back to AppleScript content with a plain-text quote. Tunnel `path` attachments confined to iCloud Drive/FMail; text/paths passed via `osascript` argv. Reaches Mail only through the injected `MCPContext.drafter` capability (first slice of `mcp-readonly-seam`). Tests in `MCPDraftReplyTests`.

## Bugs

- [x] (mcp-null-origin) Local MCP server accepted `Origin: null` and any Content-Type, so a web page (sandboxed iframe / https→http form POST with a `text/plain` JSON body) could call tools on the default unauthenticated loopback server, including unconfined `save_to_path` writes — **2026-11-19**. `originIsAllowed` now rejects `null`; `POST /mcp` requires `Content-Type: application/json` (415 otherwise).

- [x] (mailscripter-test-guard) `MailScripter.runOsascript` refuses to run under XCTest (`XCTestConfigurationFilePath` set), so no test can drive the developer's real Mail.app — **2026-11-19**.

## Architecture

- [x] (dead-viewmodel-state) Delete the vestigial `MailModel` list state and the dead optimistic-update paths — **2026-07-13**, commit `3af5943`. `MailModel`'s `threadsForSelectedMailbox` / `messagesInSelectedThread` / `searchResults` / `selectedThreadId` were never populated by anything (the real list lives in `StatusItemController`, fed straight from `IndexDB.searchSplitByPriority`), which left most of the optimistic-update pipeline inert — `applyOptimisticReadFlags` derived `prevIsRead` only from those permanently-empty arrays, so it never persisted anything, and `OptimisticUpdate`'s whole removal half had zero production callers while its 147-line test file stayed green. Kept the two parts that did real work (the immediate `allUnreadCount` badge delta and the DB write-back), deleted the rest plus the selection machinery (there is no sidebar) and the helpers left callerless. Net −357 lines; `OptimisticUpdate.swift` and `OptimisticUpdateTests.swift` are gone; new `ReadStatusControllerTests` covers the surviving behaviour against a real tmp `IndexDB`. Deliberate behaviour changes: the badge delta now counts only messages that actually change state (deduped by rowid) instead of multiplying by every message passed, and persist writes chain so two rapid mark actions commit in call order. `setReadStatus`'s contract is byte-for-byte unchanged.
