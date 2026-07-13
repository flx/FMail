# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

## Features



## Bugs

- [ ] (mailscripter-test-guard) Fail fast in `MailScripter.runOsascript` when running under XCTest — a test that reaches it can silently flip the read state of real messages in your real mailbox. `runOsascript` (`MailScripter:544-556`) unconditionally does `process.run()` on `/usr/bin/osascript`, and there is **no** test-environment guard anywhere in the target (grepped for `XCTestConfigurationFilePath` / `isRunningTests` / `NSClassFromString("XCTest")` — nothing). The live path: a test calling `ReadStatusController.setReadStatus` against a tmp-fixture model (an `indexDB` but no `model.mailboxes`) makes `mailScripterEntries` build `BatchEntry`s with `accountEmail: nil` / `mailboxPathComponents: nil`, which take the cross-account fallback — a real AppleScript walk over every mailbox of every account matching on `apple_rowid` (`MailScripter:385`, `whose id is aUID`). Fixture rowids (`MCPTestFixture` uses `1001`/`1002`) collide with real ones trivially, so the walk finds and mutates a genuine message. It would also need Apple Events automation permission and carries a 600s timeout, so it can hang CI too.

  Surfaced by the `dead-viewmodel-state` work (commit `3af5943`), which now *depends* on the rule "no test calls `setReadStatus`" — enforced today only by a doc comment. Direction: have `runOsascript` return `.failed` (not run the process) when `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`. Cost: S.

## Architecture

From the architecture review on 2026-07-13 (build + tests green at `693abf1`).
Ordered by ROI. Items reference each other by slug.

- [ ] (misfiled-core-types) Move `BodyCleaner`, `SearchSort` and `PriorityListSettings` to their correct layers — pure file moves, no behaviour change, erases all three wrong-direction dependency arrows. `Core/Index/BodyIndexer:66` calls `BodyCleaner.split` (declared in `MCP/BodyCleaner.swift`); `IndexDB.search` and its ranked variants (`IndexDB:227,282,386`) are parameterised by `SearchSort` (declared in `MCP/MCPModels.swift:217`) — so Core depends on MCP. `UI/MailModel:279-280` calls `PriorityListSettings` (declared in `MenuBar/`) while MenuBar depends on `MailModel` — a view/view-model cycle. All three are Core/config concerns filed in the wrong folder. Cost: S.

- [ ] (mcp-readonly-seam) Enforce the read-only MCP posture in the type system instead of by convention — `MCPContext` is documented "read-only by design" but hands handlers the whole `IndexDB` actor, whose write API (`setIsReadBatch`, `upsertMessages`, `replaceThreads`, `pruneMessagesNotIn`) is fully reachable. Separately `MCPHandlers+Attachment:401` calls the global `MailScripter.fetchBodies` from the `fetch_from_server` tool (registered at `MCPTools:26`, so invocable over the tunnel), driving AppleScript into Mail.app. There are zero protocols in the app target, so no read-only façade exists. No handler writes today and `fetch_from_server` is a deliberate documented exception — but nothing distinguishes read from write, so the next exception costs nothing and the posture erodes silently. Give handlers a narrowed read-only index view and route deliberate side effects through an explicit named capability. Cost: M.

- [ ] (indexdb-reader-split) Split reader connections from the single writer connection — exactly one `IndexDB(path:)` is ever constructed (`MailModel:139`), opening one connection (`IndexDB:48`), shared by `Indexer`, `BodyIndexer`, `MCPContext`, `StatusItemController` and `ReadStatusController`. Full sync holds the actor for the whole duration of each coarse call (`pruneMessagesNotIn` over ~150k rows at `Indexer:78`, `replaceThreads` at `:136`, `incrementalUpdateFTS` at `:142`), so every MCP read and menu open queues behind it. `SyncCoordinator:122-124` already hand-maintains a subsystem mutex (pausing BodyIndexer during sync) purely because the connection is shared. WAL is already enabled (`Schema:11`), so concurrent readers are one `sqlite3_open_v2` away. Bites harder as MCP-over-tunnel usage grows. Cost: M.

- [ ] (di-config-convergence) Converge the three DI stories and make config injectable — currently constructor injection (`MailModel` → coordinators), a hard singleton (`OAuthStore.shared`, reached from `MCPServer:369,385`, `OAuthHandlers`, `StatusItemController:657`, `MinimalSettingsView:41`) and static UserDefaults enums (`MCPSettings` referenced from 12 files across every layer; `PriorityListSettings` from 4) coexist. Concrete cost: because `OAuthStore` is `@MainActor`, the `MCPServer` actor must hop to the main actor to check auth on *every request* (`MCPServer:364 denyIfMissingAuth`) — an isolation hop forced by where the state lives, not by what it is. Start by de-singletoning `OAuthStore` (make it an actor or inject it) and injecting a settings snapshot at server start. Cost: M.

- [ ] (typed-error-boundaries) Propagate `TunnelStartRefusal`'s typed-error shape to the other boundaries — seven subsystem error enums exist and are well-formed, but every UI boundary collapses them to `String` (`LoadState.failed(String)`, `bulkActionError: String?`, `MCPServerStatus.error(String)`, `TunnelState.error(String)`, with `String(describing: error)` at `MailModel:183,242` and `SyncCoordinator:105,142`). Nothing upstream can branch on failure *kind* (retryable / fatal / permissions / user-fixable), and there is no retry policy as a system. `TunnelCoordinator:24-50` already does this right: a typed refusal enum carrying a `userMessage` per case. Keep the string for display, carry a typed cause for recovery. Cost: M.

Reviewed and deliberately accepted — **not** open work, recorded so the reasoning
isn't relitigated:

- **Domain/persistence type fusion** (`IndexedMessage`/`MessageHeader` are both the
  domain model and the row shape). Correct: the app *is* a projection of a mail store.
- **Single target, no enforced module boundaries.** Defensible against real SPM
  friction at 22k lines. Revisit only if `misfiled-core-types` recurs — `Core`
  (pure Foundation/SQLite, no AppKit, no MCP) is the one boundary worth enforcing.
- **Wall-clock sync suppression** (`ReadStatusController:24-31` sets `skipSyncsUntil`
  to now+120s/+180s around the AppleScript write-back). It's a timing guess standing
  in for a causal signal, but it works. If it ever misbehaves, the structural fix is a
  write-generation marker (record the rowids written, reconcile against them) rather
  than a wider window.
- **Non-atomic full sync.** Actor reentrancy lets MCP/menu reads land between the
  coarse steps of `runFullSync`, so a reader can briefly see pruned messages against
  stale thread rows and stale mailbox counts. `replaceThreads` is itself atomic
  (`IndexDB+Write:254`), so there's no torn read *within* a step. Document the
  consistency contract MCP clients get rather than making the sync atomic, which
  would worsen `indexdb-reader-split`.
