# dead-viewmodel-state — Remove the vestigial view-model layer

**Risk tier: `standard`**

Justification: this is deletion of code that is provably unreferenced (every removal
below is backed by an exhaustive grep for callers, independently re-verified by an
adversarial review pass), plus one small behaviour-preserving rewrite. No algorithm, no
new concurrency, no persistence-format change; everything touched is already `@MainActor`.
I considered `hi` because Tier 2 touches the mark-as-read write path, which is
user-facing — but the surviving path keeps its existing task and sync-suppression
structure unchanged. Override to `hi` if you'd rather the mark-read path get premium
scrutiny.

Source: `TODO.md` → `- [ ] (dead-viewmodel-state)`.
Revised after adversarial plan review; findings D1–D7 / T1–T5 are folded in below.

---

## PRECONDITION — land the working tree first (do not stash)

**This plan was written against the uncommitted working tree, which is mid-refactor of
the exact call path being changed.** At `HEAD`, `StatusItemController.markBlock`
pre-filters *in the database* via `db.rowidsMatching(compiled, priority:, isRead: !isRead)`.
In the working tree it pre-filters *in memory* via `emails.filter { $0.isRead != isRead }`,
and the same uncommitted diff deletes `rowidsMatching` from `IndexDB+Priority.swift`.

Both versions preserve the invariant this plan's Tier 2 hardening relies on (callers only
ever pass messages that need flipping), so the conclusion survives either way — but the
mechanism and every cited `StatusItemController` line number differ.

Therefore:

1. **Land** the uncommitted changes to `IndexDB+Priority.swift`,
   `StatusItemController.swift`, `IndexDBPriorityTests.swift`. Do **not** stash them —
   stashing restores `rowidsMatching` and invalidates the plan's description of the
   caller-side filter.
2. Re-verify the `StatusItemController` line references below (`:194-215`, `:596-620`)
   against the newly-committed tree before starting Tier 2.

All line numbers in this plan are working-tree-relative and become correct once step 1
lands.

---

## Goal

`MailModel` currently presents itself as a view-model but is really a service container
with a layer of dead view state bolted on. The menu-bar UI keeps its own list state in
`StatusItemController` and reads the index directly. Make the code say that.

Concretely: delete the state nothing populates, delete the optimistic-update machinery
that operates on it, and leave behind the two things in that pipeline that actually do
work — the immediate `allUnreadCount` badge delta and the DB write-back.

## Why this is safe (the evidence)

After a mark-as-read, `StatusItemController.markBlock` / `markSelection` (`:596-620`)
call `refreshEmails()`, which re-queries `searchSplitByPriority` **and** recomputes
`allUnreadCount` from `countAllUnreadExcludingDrafts()` (`:194-215`). The displayed rows
and the badge are therefore always reconciled from the database moments later. The only
thing the optimistic layer buys is a badge that updates *during* the AppleScript await
(which can take seconds) — and that comes from `allUnreadCount` alone.

Verified unreferenced (grep for callers returns nothing outside the code being deleted;
re-verified independently by the review pass, which found no missed caller):

| Symbol | Declared | Production callers |
|---|---|---|
| `MailModel.threadsForSelectedMailbox` | `MailModel:37` | only `ReadStatusController` (writes, then reads back) |
| `MailModel.messagesInSelectedThread` | `MailModel:38` | ditto |
| `MailModel.searchResults` | `MailModel:39` | ditto |
| `MailModel.selectedThreadId` | `MailModel:36` | ditto |
| `OptimisticUpdate.mailboxDeltas(forRemoving:)` | `OptimisticUpdate:53` | **none** (tests only) |
| `OptimisticUpdate.globalUnreadDelta(forRemoving:)` | `OptimisticUpdate:64` | **none** (tests only) |
| `OptimisticUpdate.applyingRemoval(to:removedByThread:)` | `OptimisticUpdate:71` | **none** (tests only) |
| `OptimisticUpdate.CountDelta` | `OptimisticUpdate:46` | **none** (tests only) |
| `IndexDB.threadIds(forMessages:)` | `IndexDB:188` | only `ReadStatusController:104` |
| `MessageHeader.withIsRead(_:)` | `MailStore/Models:100` | only `ReadStatusController` |
| `ThreadSummary.with(messageCount:unreadCount:)` | `IndexModels:82` | only `ReadStatusController` / `OptimisticUpdate` |
| `Mailbox.with(totalCount:unreadCount:)` | `MailStore/Models:36` | only `ReadStatusController:244` |
| `MailboxKind.viewScope(forSelectedKind:allMailboxesScope:)` | `MailStore/Models:74` | **none** (tests only) — *Tier 4* |
| `MailboxKind.isSystemIsolated` | `MailStore/Models:76` | only `viewScope` — *Tier 4* |
| `MailModel.selectedMailbox` / `.isAllMailboxesScope` | `MailModel:89,94` | **none** — *Tier 4* |

`Mailbox.unreadCount` is written by `ReadStatusController:244` but **never displayed** —
the menu-bar badge reads only `allUnreadCount` (`StatusItemController:766`). Per-mailbox
counts remain correct in the DB (`recomputeMailboxCounts`) and are reloaded by
`refreshFromIndexDB`; only the pointless optimistic mutation goes.

## Acceptance criteria

1. `xcodebuild -project FMail.xcodeproj -scheme FMail -destination 'platform=macOS' build`
   and `test` both succeed — **after `xcodegen generate`** (see the build note below).
2. **No test added or modified by this change invokes `MailScripter`.** (D1 — the tests
   must not be able to touch the developer's real Mail.app.)
3. Marking a block or a selection read/unread from the menu still: writes `is_read` to the
   local index, fires the AppleScript at Mail.app, and surfaces failures via
   `bulkActionError`. The badge still updates before the AppleScript returns — **this last
   part is a manual check only** (T2); no automated path exists and none is proposed.
4. `MailModel` no longer declares any list/thread/search state.
5. `OptimisticUpdate.swift` no longer exists.
6. **After Tiers 1–3**, no symbol in the evidence table marked *(Tiers 1–3)* remains in the
   tree. The three symbols marked *Tier 4* are governed by criterion 8 instead (D4).
7. `grep -rn "threadsForSelectedMailbox\|messagesInSelectedThread\|searchResults\|selectedThreadId" FMail/`
   returns nothing.
8. **If Tier 4 is taken:** `MailboxKind.viewScope`, `MailboxKind.isSystemIsolated`,
   `MailModel.selectedMailbox`, `MailModel.isAllMailboxesScope`, `MailModel.selection`,
   `select(_:)`, `selectAllMailboxes()` and `SidebarSelection` are all gone, along with
   their tests. If Tier 4 is dropped, they all remain and that is a deliberate choice.
9. Net line count is down by roughly **330–450** lines across source + tests (the low end
   if Tier 4 is dropped) (T5).

## Build note — this project is XcodeGen-generated (D5)

`FMail.xcodeproj` is **not tracked in git**; it is generated from `project.yml`, whose
`sources:` uses a directory glob. The on-disk `project.pbxproj` currently carries 8
explicit references to `OptimisticUpdate`.

**Every tier that adds or deletes a file (Tiers 1, 3, 4) must run `xcodegen generate`
before building**, or `xcodebuild` fails on stale file references and never compiles the
new test file. `xcodegen` is installed at `/opt/homebrew/bin/xcodegen`. Without this step
the per-tier "builds and tests green on its own" claim is false.

---

## Tiers

Each tier builds, tests green, and is revertible on its own.

### Tier 1 — Delete the dead half of `OptimisticUpdate` and its tests
Pure deletion, zero production callers, no behaviour change.

- `FMail/UI/OptimisticUpdate.swift`: delete the `// MARK: — Removal` section entirely —
  `CountDelta`, `mailboxDeltas(forRemoving:)`, `globalUnreadDelta(forRemoving:)`,
  `applyingRemoval(to:removedByThread:)`.
- `FMailTests/OptimisticUpdateTests.swift`: delete the six removal tests
  (`testRemovalMailboxDeltasTotalAndUnread`, `testGlobalUnreadDeltaCountsOnlyUnread`,
  `testApplyingRemovalDecrementsCounts`, `testApplyingRemovalDropsEmptiedThread`,
  `testApplyingRemovalClampsUnreadAtZero`, `testApplyingRemovalLeavesUnaffectedThreads`).
- Run `xcodegen generate` (no files added/removed here, but keep the habit — it is
  required from Tier 3 on).

**Exit state:** `OptimisticUpdate` = `unreadDelta`, `mailboxUnreadDeltas`,
`applyingReadFlip`. Six tests remain.

### Tier 2 — Collapse `ReadStatusController` to the path that does work
The substantive tier. `setReadStatus(rowids:isRead:)` keeps its exact signature, return
type, error strings, `suppressSync` windows, and AppleScript dispatch.

**Delete** (D2 — this list is exhaustive; `applyOptimisticThreadBulkRead` was missing from
the previous draft and its omission would have left the tier non-compiling):
- `applyOptimisticThreadBulkRead(perThread:isRead:)` (`:138-170`) — the main body. Its two
  surviving lines (the `allUnreadCount` delta and the `persistIsRead` call) are absorbed
  into the rewritten flip below.
- `applyOptimisticReadFlags(messageRowIds:isRead:)` (`:176-235`) — the fallback that cannot
  work (it derives `prevIsRead` only from permanently-empty arrays).
- `flipReadInVisibleArrays(rowIds:isRead:)` (`:250-261`) — operates on empty arrays.
- `applyMailboxUnreadDeltas(_:)` (`:240-246`) — mutates a field nothing displays.
- `groupByThread(_:)` (`:100-112`) — existed only to feed thread summaries and to pick the
  fallback branch; both are gone.

**Keep unchanged:** `SkipWindow`, `suppressSync`, `mailScripterEntries`, and
`persistIsRead` (same fire-and-forget `Task`, same error surfacing).

**Rewrite** `applyOptimisticReadFlip(messages:isRead:)` (`:88-95`) to the surviving work.
Make it **`internal`, not `private`** (D1) so the new tests can drive it directly without
going through `setReadStatus` and therefore without ever reaching `MailScripter`. This is
an access-level widening, not a new protocol seam — it stays inside the project's
no-abstractions constraint. It no longer needs to be `async` (its only `await` was
`groupByThread`); keep it `async` if that leaves the `setReadStatus` call site untouched.

**The hardening, pinned exactly (D3).** Today the global delta is
`allMessages.count * unreadDelta(isRead:)` (`:163`) — it multiplies by *every* message
without checking whether each was already in the target state. That is only correct
because both callers pre-filter. Remove that hidden coupling as follows, and **no other
way**:

```
let toFlip = resolved.filter { $0.isRead != isRead }
```

- `toFlip` feeds **the badge delta and `persistIsRead`** — so the counter is right
  regardless of what the caller passes.
- `resolved` continues to feed **the AppleScript dispatch and the return value** — so
  `setReadStatus`'s contract (including the `.failed` arm's `resolved.count` at `:79` and
  the empty guard at `:50-52`) is byte-for-byte unchanged.

This is the reading that keeps the seam frozen. The alternative — filtering the whole
pipeline — would change the return value for an all-already-in-state batch, and is
explicitly rejected.

**Two behaviour changes, both improvements, both deliberate:**
1. The badge delta is now correct even if a caller passes already-flipped messages
   (previously a latent badge-drift bug).
2. (T1) Today, if `threadIds(forMessages:)` throws, `groupByThread` returns `[]` and the
   fallback does *nothing* — no badge delta, no `persistIsRead` — while the AppleScript
   still fires. After the rewrite there is no such hole: flip and persist run
   unconditionally.

**Exit state:** `ReadStatusController` ≈ 279 → ~120 lines. `OptimisticUpdate` has exactly
one live caller left (`unreadDelta`).

### Tier 3 — Delete `MailModel`'s dead state and fold away `OptimisticUpdate`
- `FMail/UI/MailModel.swift`: remove `selectedThreadId`, `threadsForSelectedMailbox`,
  `messagesInSelectedThread`, `searchResults` (`:36-39`) and the comment block at `:32-35`
  that explains why they're empty. Remove the three clearing lines from `select(_:)`
  (`:305-307`); the stale-id guard and `selection = newSelection` stay.
- `FMail/UI/OptimisticUpdate.swift`: **delete the file.** What remains after Tier 2 is
  `unreadDelta` (one line) and two functions with no callers (`mailboxUnreadDeltas`,
  `applyingReadFlip`). Inline `unreadDelta` into `ReadStatusController` as a private helper.
- `FMailTests/OptimisticUpdateTests.swift`: **delete the file.** Five of its six remaining
  tests cover deleted functions; the sixth (`testUnreadDeltaSign`, `:31-34`) covers
  `unreadDelta`, which survives — **carry that assertion into the new test file** (D7). It
  is the one place a flipped sign silently inverts the badge.
- Orphaned helpers — delete, each now provably callerless:
  `IndexDB.threadIds(forMessages:)` (`IndexDB:188`),
  `MessageHeader.withIsRead(_:)` (`MailStore/Models:100`),
  `ThreadSummary.with(messageCount:unreadCount:)` (`IndexModels:82`),
  `Mailbox.with(totalCount:unreadCount:)` (`MailStore/Models:36`).
- **New test file** `FMailTests/ReadStatusControllerTests.swift`. Build a real tmp `IndexDB`
  the way `MCPTestFixture:31-38` already does, and drive the **`internal`
  `applyOptimisticReadFlip`** directly — **never `setReadStatus`** (D1). Cover:
  (a) flipping to read persists `is_read` to the index;
  (b) `allUnreadCount` decrements by the number of *actually-flipped* messages;
  (c) passing already-read rowids does not move the counter (the Tier 2 hardening);
  (d) the sign convention carried over from `testUnreadDeltaSign` — read is `-1`,
      unread is `+1`.
  The empty/unmatched-rowid error string on `setReadStatus` is **not** covered by an
  automated test, because reaching it requires calling `setReadStatus`, which dispatches
  AppleScript. Verify it manually or leave it uncovered; do not introduce a seam for it.
- Run `xcodegen generate` (files added and removed).

**Exit state:** acceptance criteria 4, 5, 6, 7 hold.

### Tier 4 — (optional, separable) Delete the selection machinery
Same drift, distinct decision — **drop this tier without affecting 1–3 if you'd rather keep
the seam for a future window UI.** The menu-bar app has no sidebar and nothing reads the
derived selection state.

- `MailModel`: remove `selectedMailbox` (`:89`), `isAllMailboxesScope` (`:94`), `selection`,
  `select(_:)`, `selectAllMailboxes()`, the `selectAllMailboxes()` call in `boot()`
  (`:161-163`), and `enum SidebarSelection` (`:319`).
- `MailStore/Models.swift`: remove `MailboxKind.viewScope(forSelectedKind:allMailboxesScope:)`
  (`:74`) — zero production callers — **and `MailboxKind.isSystemIsolated` (`:76`)** (T4),
  whose only caller is `viewScope`. Leaving it behind would recreate in miniature the exact
  "green tests over inert machinery" condition this whole item exists to kill.
- `FMailTests/UILogicTests.swift`: remove the `MailboxKind.viewScope` tests (`:11-48`),
  **`testIsSystemIsolated` (`:50-59`)** (T4), and `MailModelLogicTests`' three `testSelect*`
  tests (`:67-95`). The `PriorityListSettings.entriesMatching` tests in the same file are
  unrelated — **keep them.**
- **Keep `IndexDB.ThreadViewScope`** — still used by `loadThreadMessages(threadId:scope:)`
  with a `.excludeDrafts` default, which MCP reaches via `MCPHandlers:263` and
  `MCPHandlers+ThreadExport:22`.
- Run `xcodegen generate` (files removed).

---

## Interface between tiers

The only contract that crosses tier boundaries is
`ReadStatusController.setReadStatus(rowids:isRead:) async -> (applied: Int, error: String?)`.
Its signature, return values, and error strings are **frozen across all four tiers** —
`StatusItemController` calls it (two call sites) and is not otherwise touched. Every tier is
a strict subtraction behind that call except the Tier 2 hardening, which — under the pinned
reading above — changes only which messages count toward the badge delta and the DB write,
never the return value.

- Tier 1 → 2: Tier 2 assumes the removal half of `OptimisticUpdate` is gone; it compiles
  either way (it never called it).
- Tier 2 → 3: Tier 3 assumes `ReadStatusController` no longer references the four `MailModel`
  arrays or the orphaned helpers, and that `applyOptimisticReadFlip` is `internal`. Tier 3
  will not compile until Tier 2 lands.
- Tier 3 → 4: independent. Tier 4 touches `selection`, which Tier 3 leaves alone.

## Load-bearing assumptions

1. **The post-action re-query is what makes the rows correct.** `refreshEmails()` runs after
   every mark action and re-reads both the rows and the unread total from the index. If that
   call is ever removed, the optimistic layer being deleted here would have been the only
   thing updating the UI — but it wasn't updating it anyway (it wrote to empty arrays), so
   removing it cannot make that worse. Stated for the record, not because it's fragile.
2. **`persistIsRead`'s DB write is not awaited** before `refreshEmails()` re-queries.
   (T3 — corrected justification:) actors serialize *access*, not cross-task *ordering*, so
   nothing structurally guarantees the fire-and-forget `setIsReadBatch` task (`:270`)
   enqueues before `refreshEmails`' `countAllUnreadExcludingDrafts`. In practice the
   seconds-long AppleScript await masks the gap entirely. This plan preserves that structure
   exactly and does **not** fix it; if it ever races, that is a separate item.
3. **`ReadStatusController.setReadStatus` has exactly two callers**, both in
   `StatusItemController`. MCP is read-only and does not reach it. Verified.
4. **The tests never reach Mail.app** (D1 — this replaces the previous, wrong assumption
   that `setReadStatus` was safe to call under test). It is not: with a tmp-fixture
   `indexDB` but no `model.mailboxes`, `mailScripterEntries` produces `BatchEntry`s with
   `accountEmail: nil` / `mailboxPathComponents: nil` (`:117-130`), which take
   `MailScripter`'s cross-account fallback (`MailScripter:254-258`) — a real `osascript`
   walk over every mailbox of every account matching on `apple_rowid`. Fixture rowids
   (`MCPTestFixture:47,60` uses `1001`) collide with real ones trivially, so such a test can
   **flip the read state of a real message in the developer's mailbox**. It would also
   require Apple Events automation permission under `xcodebuild test` and carries a 600s
   timeout (`MailScripter:196`). Hence: tests drive the `internal` flip directly and
   acceptance criterion 2 forbids touching `MailScripter` at all.
5. `Mailbox.unreadCount` staying stale between syncs is acceptable because nothing renders
   it. If a future UI renders per-mailbox counts, it should read them from the index, not
   from an optimistic in-memory delta.

## Out of scope

- The `misfiled-core-types`, `mcp-readonly-seam`, and `indexdb-reader-split` TODO items.
- Introducing any protocol seam or test double. The codebase has zero protocols by
  deliberate choice; this change does not earn the first one. (Widening
  `applyOptimisticReadFlip` to `internal` is an access-level change, not a seam.)
- Fixing the unawaited `persistIsRead` write (assumption 2).
- Changing the `suppressSync` windows (`SkipWindow` = 120s/180s) — that's the accepted
  `wall-clock sync suppression` trade recorded in `TODO.md`.
- Reinstating a window/reader UI. If that ever happens, this state gets rebuilt against the
  real reader, not resurrected from git.
