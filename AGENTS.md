# AGENTS.md - notes for AI agents / future developers working on WrathBagSort

This file exists because this client's addon API has many undocumented quirks
that are expensive to rediscover. Read this before making further changes to
`WrathBagSort.lua`/`.xml`, and update it when you discover something new.

## Client environment

- This is a custom/private Runes of Magic client ("Wrath of Eternal"), NOT
  stock WoW or stock RoM. XML uses `xmlns="http://www.runewaker.com/"`.
- Other installed addons worth referencing: `Interface/Addons/AddonManager/`
  (Sol.lua library, LibStub, hooks), `Interface/zBag/` (note: NOT under
  `Interface/Addons/` - different install path on this client; its
  `BagSort.lua` is a second, independently-written bag sorter worth comparing
  against), `Interface/Addons/CopyChat/` (chat-copy via per-line EditBox).
- Testing changes: use `/sortbag reload` (calls `ReloadUI()`). This reparses
  both Lua and XML - a full client restart is NOT needed for iteration.

## Current source of truth

This section describes the current implementation. Older investigation notes
below are historical; if they conflict with this section or the current source,
follow the current source and this section.

- `.toc` order is `WrathBagSort.lua`, then `WrathBagSort.xml`,
  `WrathBagSortLog.xml`, and `WrathBagSortBag.xml`. Do not load XML before Lua.
- `WrathBagSort_TESTING_MODE` is reset to `false` on every Lua load. `Print()`
  writes neither chat nor `WrathBagSort_Log` unless the flag is exactly true.
  `/sortbag testing on|off` changes output mode for this session only; it does
  NOT enable/disable item-moving commands. `/sortbag sort`, `testmove`, and
  `testswap` can still move items with testing off.
- Current sort settings: `WrathBagSort_Settings.mode` is `name`, `type`, or
  `tier`; direction is `asc` or `desc`. `type` mode groups equipment, then
  consumables, then other items, then quest-marked items; tooltip parsing and
  keyword grouping are heuristic.
- Sort movement is paced by `PACING_DELAY = 1.5s`, retry passes back off by
  `RETRY_EXTRA_DELAY = 3s`, final checks wait `FINAL_VERIFY_DELAY = 5s`, and
  there are at most `MAX_RETRY_PASSES = 3` per round and
  `MAX_CORRECTION_ROUNDS = 8`. These are empirical mitigations, not engine
  guarantees. Moves are optimistic until the delayed end-of-round check.
- The custom UI has 12 pages of 30 slots, a live all-page item-name search,
  stack-count overlays, zBag-style item click/drag behavior, native utility
  buttons, and native MoneyFrameTemplate counters (account/bonus/player gold).
  Opening native `BagFrame` triggers the replacement UI; don't instruct the
  user to manually open a second regular Backpack. The Item Shop Backpack may
  remain open: `SwapSlots()` only issues indices above 60, and sort filters
  tooltip-marked Item Shop items.
  Pages I-II are always available. Pages III-XII can be selected read-only;
  `Rent Page` calls `OpenTimeFlagStoreUpFrame("BagLet" .. page)`. Item
  interactions and sorting must reject unavailable pages.
- Known unverified/incomplete behavior: after a rental completes, the page
  availability indicators may need a manual page switch or bag reopen to
  refresh; there is no confirmed rental-complete event hook yet. The separate
  native Item Shop Backpack window is not reproduced in the custom grid because
  its frame/data API has not been identified safely.
- Known error cleanup gap: if an unexpected Lua exception escapes the paced
  worker, its pcall wrapper clears `SortState` but does not currently restore
  the log frame's alpha/visibility. If touching this code, restore visibility
  from the saved sort state before clearing it.

## Confirmed client quirks (do not re-discover these the hard way)

1. **Slash command handlers** receive `function(_, message)` (two args), not
   `function(message)`.

2. **`GetBagItemInfo(slot)`** returns `itemIndex, icon, name, itemCount,
   locked, itemQuality`. `locked` can come back as the literal **string**
   `"false"` (not boolean `false`) - this is truthy in Lua! Always normalize
   with a helper like `IsFlagSet()` before branching on it.
   - **CONFIRMED (live `/sortbag probe`): the 6th value is `itemQuality`, a
     number (0-5), NOT an "invalid" flag.** A normal item shows `..., false, 0`
     (`locked=false`, quality=0). There is no separate `invalid` return value.
     `IsFlagSet(itemQuality)` always returns false for these numbers, so the
     old `IsFlagSet(invalid)` check was dead code and has been removed. Only
     the 5th value (`locked`) is a real "don't move this item" flag.

3. **`PickupBagItem`'s index space is offset by +60 from the UI slot number**
   used by `GetBagItemInfo`. The Item Shop Backpack occupies `PickupBagItem`
   indices ~1-60 regardless of whether its window is open or closed. Real
   Backpack UI slot `N` must be addressed as `PickupBagItem(N + 60)`. This
   exactly matches `GetBagItemInfo`'s own first return value
   (`itemIndex == uiSlot + 60`) - always use that value, don't hardcode +60
   if you can read `itemIndex` instead.
   - Sort's `SwapSlots()` now enforces this boundary: it converts UI slots
     through `ToPickupIndex()` and refuses any pickup/place index at or below
     60. Keep all sorting state in UI-slot space and never call
     `PickupBagItem` with raw slot numbers from the sort path.
   - **This offset confusion caused a real misplacement**: 35x Transport Rune
     from transmuter output was routed outside the intended regular Backpack
     location. The items were not lost. Treat any PickupBagItem index-space
     question as safety-critical, not just a bug.
   - Placing onto an OCCUPIED real-Backpack slot performs a genuine atomic
     swap (confirmed via testing) - no need to stage through an empty buffer
     slot.

4. **`GameTooltip:SetBagItem(x)` must be called with `itemIndex`** (GetBagItemInfo's
   first return value), not the raw UI slot number. Passing the wrong value
   doesn't error - it silently keeps stale tooltip content, which once caused
   every single real item to be falsely detected as "Item Shop Item".

5. **`CreateFrame()` is NEVER reliably callable from addon Lua on this
   client** - confirmed failing even as the literal first statement in the
   addon's file on a full client restart. Don't attempt it again. Instead,
   reuse an XML-defined frame (this addon uses `WrathBagSortLogFrame` from
   `WrathBagSortLog.xml`).

6. **`frame:SetScript(...)` cannot be called from Lua at all** - throws
   `attempt to call method 'SetScript' (a nil value)`. Confirmed by grepping
   every other installed addon: none of them ever call `:SetScript(` from
   Lua, only via XML `<Scripts>` blocks. **Script handlers (OnUpdate, OnEvent,
   OnClick, etc.) can only be declared in XML at frame-definition time.** This
   addon's pacing relies on `WrathBagSortLog.xml` declaring:
   ```xml
   <Scripts>
       <OnUpdate>
           WrathBagSort.OnWorkerUpdate(arg1)
       </OnUpdate>
   </Scripts>
   ```
   and the Lua handler being exposed as the **global** `WrathBagSort.OnWorkerUpdate`
   (not a local), since XML can only call globals/table members.

7. **Hidden frames do NOT receive OnUpdate ticks.** A frame must be
   `:Show()`n to get OnUpdate pacing working. This addon shows
   `WrathBagSortLogFrame` for the duration of a sort and restores its prior
   visibility afterward. To avoid an annoying visible open/close flicker when
   the user didn't ask to see the log, it's shown with `SetAlpha(0)` when
   WrathBagSort itself is the one auto-showing it (alpha is restored to 1
   before hiding again, and never touched if the user had it open manually).

8. **The `.toc` load order matters**: `WrathBagSort.lua` must load BEFORE the
   `.xml` files. Reordering this (XML before Lua) **crashed the client**,
   likely because an XML `OnLoad` script fired before the Lua globals it
   needs existed. Every working addon on this client (AddonManager/zBag/
   CopyChat) loads Lua before XML - keep it that way.

9. **This client has significant, variable read-lag**: `GetBagItemInfo`
   checked immediately after a `PickupBagItem` action can still show the OLD
   contents for several seconds (observed lag up to 7+ seconds in some
   cases). **Never verify a move synchronously in the same tick.** By
   contrast, `CursorHasItem()` is NOT laggy - it reliably reflects the
   immediate real-time cursor state right after a `PickupBagItem` call, so
   use it (not `GetBagItemInfo`) for per-move success/failure checks.

10. **This client appears to rate-limit/drop rapid-fire bag actions.** Firing
    many `PickupBagItem` calls back-to-back with zero delay works for a
    while (observed: ~13 consecutive successful moves) then a pickup
    silently puts nothing on the cursor - looks like anti-speedhack/anti-dupe
    throttling, not a logic bug. A `PACING_DELAY` between moves is required.

11. **A slot that was just touched (received a displaced item, or was just
    emptied) needs real additional settle time before it can be acted on
    again** - separate from and in addition to both #9 (read-lag) and #10
    (rate limiting). Observed failures recurring on the same slot across
    multiple retry attempts only ~1.5s apart, succeeding once ~4-5s had
    elapsed since it was last touched. This has been the single most
    recurring root cause of sort-reliability bugs in this addon - see
    `RETRY_EXTRA_DELAY` below.

12. **`/sortbag sort confirm` (two words, with a space) sometimes never
    submitted from the chat box at all** (text stayed in the input, nothing
    happened). Root cause unconfirmed, but switched to single-word commands:
    `/sortbag sort` is now the primary form, and `/sortbag sortconfirm` /
    `sort confirm` are still accepted as aliases.

13. **`GetBagCount()` returns occupied count, native capacity, full address
  count.** Live probe output: `52, 60, 360` on a character with 52 occupied
  slots, 60 active capacity, and 360 API-addressable positions across 12
  possible pages. Use the 2nd value for the native capacity display and the
  3rd for scanning the full slot address range. `GetBagSlotCount()` reads the
  3rd value; it does not mean all pages are rented/usable.

14. **The OnUpdate elapsed-time argument is named differently by the two
    scripting paths.** `frame:SetScripts("OnUpdate", "...(this, elapsedTime)")`
    (the Lua API, as used by `WaitTimer.lua`) provides `this` + `elapsedTime`,
    while XML `<OnUpdate>` scripts here use the WoW-style positional `arg1`
    (`WrathBagSort.OnWorkerUpdate(arg1)`). `OnWorkerUpdate`/`GetElapsedArg`
    accept both `(arg1)` and `(this, arg1)` shapes and pick whichever is a
    number, so either convention works - keep that defensive handling if the
    XML script is ever reordered.

## Current architecture (WrathBagSort.lua)

### Testing / production output

- `WrathBagSort_TESTING_MODE` is a global set to `false` at Lua load by
  default. `Print()` returns immediately unless it is exactly `true`, so
  production mode emits nothing to chat and does not append/save diagnostic
  lines to `WrathBagSort_Log`.
- `/sortbag testing on|off` toggles the flag for the current session; a UI
  reload resets it to `false`. Keep every diagnostic routed through `Print()`
  so this gate remains effective.

### Custom bag grid (WrathBagSortBag.xml)

- Slot buttons inherit the XML `WrathBagSortSlotTemplate`, which defines the
  icon and bottom-right stack-count `FontString` overlay like zBag's
  `zTBagItem` template. Their `OnLoad` registers bag updates and positions
  them; click, drag-start, receive-drag, and hover handlers follow
  `zBagItem_OnClick` in `Interface/zBag/zBagTmpl.xml` / `zBagTmpl.lua`.
- Lua sets the count overlay for stacks larger than one and clears it for
  empty/single items. Keep count text as an XML child of the slot button so
  it draws above the icon; this client has no verified
  `CreateUIComponent("FontString", ...)` usage.
- Each XML slot also owns a `CooldownFrameTemplate`. Refresh cooldown state
  from `GetBagItemCooldown(itemIndex)` via `CooldownFrame_SetTime`, and listen
  for `BAG_UPDATE_COOLDOWN` as well as `BAG_ITEM_UPDATE`.
- Keep interaction semantics aligned with zBag: left-click picks up,
  right-click calls `UseBagItem`, Shift-click links/splits stacks,
  Ctrl-click opens item preview, and drag/drop calls `PickupBagItem` on the
  target slot. Resolve the slot's `itemIndex` using `GetBagItemInfo` first.
- Every interaction path must reject `itemIndex <= 60` before calling
  `PickupBagItem` or `UseBagItem`; this is the Item Shop Backpack index
  range. Do not use the raw UI slot number for these APIs.
- The utility toolbar intentionally mirrors zBag's native buttons for Goods,
  Partner, Transmuter (`OpenMagicBoxButton_OnClick`), and Garbage. Anchor
  opened utility frames beside `WrathBagSortBagFrame` where the native addon
  does so. Do not invent an Item Shop Backpack frame/API name; that separate
  view still needs its own verified native data source.
- The footer uses zBag's `MoneyFrameTemplate` pattern: `account` mode for
  diamonds, `bonus` mode for ruby/bonus currency, and the default PLAYER money
  frame for gold. Keep these as native money frames rather than hand-parsing
  currency APIs.
- The UI shows 12 pages of 30 slots, but not all 360 API addresses are
  necessarily available. Mirror zBag's `zBag_CheckBagButtonLet`: pages I-II
  are always available; for pages III-XII, `GetBagPageLetTime(page)` is
  considered unavailable only when it returns `(true, -1)`. Let users select
  unavailable tabs for read-only viewing, but reject every item interaction
  and exclude all those slots from sorting. The contextual Rent Page button
  opens `OpenTimeFlagStoreUpFrame("BagLet" .. page)`, matching zBag's native
  time-flag rental flow; the game handles its diamond cost/term. `GetBagCount()`'s second
  return is the native occupied-capacity value (e.g. 60); its third return
  is the full address-space size (e.g. 360), not the visible capacity.
- The bag search scans item names in all `GetBagSlotCount()` UI slots,
  case-insensitive substring match (same basic approach as zBag's
  `FindBagItemByName`). It builds `BagSearchMatches` and `BagSearchPages`,
  auto-selects the first matching page, keeps matches at alpha 1, dims other
  slots, and marks matching page tabs with `+`. Search includes readable
  locked-page contents but item click/drop guards still keep those pages
  read-only. Escape and the X button clear the EditBox.

The sort algorithm, in order of execution:

1. `ReadOccupiedSlots()` - scans all bag slots via `GetBagItemInfo`, applies
   `IsFlagSet` normalization, and separates slots into three categories:
   - sortable items (returned in `slots`; each gets `itemType` from
     `ExtractType()`, `itemTier` from `ExtractTier()`, and a quest marker from
     `IsQuestItem()`)
   - Item Shop items (tracked in `itemShopSlots`, detected via
     `IsItemShopSlot()` tooltip scanning - **never moved, ever**)
   - locked items (tracked in `lockedSlots`/`lockedCount` - also never moved;
     their slots must NOT be treated as free destinations either - this was a
     real bug, fixed once already, watch for regressions)
2. `BuildSortedItems()` - sorts the occupied items using
  `WrathBagSort_Settings.mode` (`"name"` = plain alphabetical, `"type"` =
  broad family rank (equipment, consumables, other, quest), then tooltip
  `itemType` and name, `"tier"` = tier then name) and
  `WrathBagSort_Settings.direction` (`"asc"`/`"desc"`). Text comparisons are
  case-insensitive; final ties are broken by slot number. `GetTypeGroup()`
  puts quest-marked tooltip items last, treats any `itemTier > 0` or
  equipment-type keyword as equipment, potion/medicine/food/drink keywords
  as consumables, and everything else as other.
3. `BuildUsableSlots(total, itemShopSlots, lockedSlots)` - the ascending list
   of slots allowed as sort destinations (excludes both Item Shop and
   locked slots).
4. `StartSortRound(wasVisible, priorMoveCount, correctionRound)` - builds the
   `desiredSlot`/`expectedName`/`location`/`occupant` bookkeeping tables for
   one "round" of sorting and kicks off `DoNextSwap()`.
5. `DoNextSwap()` - the queue processor. Performs exactly ONE swap per call
   via `SwapSlots()` (which uses `CursorHasItem()` checks, not
   `GetBagItemInfo`, per quirk #9). On success, updates `location`/`occupant`
   bookkeeping **including the displaced item's new location** (a past bug:
   forgetting this one bookkeeping line caused cascading cyclic mismatches -
   see git history / old memory notes if this regresses). On failure
   (`SwapSlots` returns false), does NOT abort the whole sort (adapted from
   zBag's resilience pattern) - just marks `hadFailureThisPass` and moves on;
   failed items are retried in a subsequent pass within the same round (up
   to `MAX_RETRY_PASSES`).
6. `OnWorkerUpdateInner(a, b)` - the OnUpdate handler. Waits `PACING_DELAY`
   between moves, or `PACING_DELAY + RETRY_EXTRA_DELAY` before the first move
   of a new retry pass or a new correction round (both cases use a slot that
   was recently touched, per quirk #11). Once a round is fully processed,
   waits `FINAL_VERIFY_DELAY` then calls `FinishSort()`.
7. `FinishSort()` - does a full `GetBagItemInfo`-based consistency check
   against `desiredSlot`. If mismatches remain and
   `correctionRound < MAX_CORRECTION_ROUNDS`, automatically calls
   `StartSortRound()` again with a freshly re-read bag state (ground truth,
   not stale in-memory bookkeeping) instead of requiring the user to retype
   the command. Only after exhausting all correction rounds does it print
   the final warnings and a hint to run `/sortbag sort` again
   manually.

### Native sort-button hook

At load time the addon replaces the global `RefreshBag` (what the native
"sort items" button `BagRefreshButton` calls) and `zBag_SortFull` (zBag's
"full sort" button) with a wrapper that calls `ExecuteSort()`. This makes the
in-game sort button run OUR sort instead of the native per-bag sort.

- `RefreshBag` is the key hook: zBag's "sort items" button (`zBag_Sort`) also
  calls `RefreshBag` once per bag, so hooking it covers both the native button
  and zBag's button. The re-entrancy guard in `ExecuteSortInner` absorbs the
  extra calls.
- Load-order caveat: if `zBag` loads after this addon (alphabetical order puts
  "WrathBagSort" before "zBag"), the `zBag_SortFull` hook is skipped at load
  time. `RefreshBag` is native and always available, so the primary button
  still works. A delayed/event-based hook would be needed to reliably catch
  zBag's functions.

### Important Lua gotcha hit while building this

`FinishSort`, `StartSortRound`, and `DoNextSwap` call each other in a cycle.
**`local function Foo() ... Bar() ... end` cannot forward-reference a sibling
`Bar` declared LATER in the same file** - the identifier resolves to a global
(nil) at compile time, causing a silent "attempt to call a nil value" at
runtime, not a load-time error. Fix pattern used here:

```lua
local FinishSort
local StartSortRound
local DoNextSwap

-- any constants referenced inside these functions' bodies must ALSO be
-- declared before the first function body that reads them
local MAX_CORRECTION_ROUNDS = 8

FinishSort = function() ... StartSortRound(...) ... end
StartSortRound = function() ... DoNextSwap() ... end
DoNextSwap = function() ... end
```

Apply this pattern to any future mutually-recursive local functions in this
file.

### Tuning constants (all empirically chosen - not guaranteed values)

| Constant | Current value | Purpose |
|---|---|---|
| `PACING_DELAY` | 1.5s | Wait between consecutive moves, to avoid the rate limit (quirk #10). |
| `RETRY_EXTRA_DELAY` | 3.0s | Extra backoff (on top of `PACING_DELAY`) before the first move of a new retry pass or correction round, for a slot that was recently touched (quirk #11). |
| `FINAL_VERIFY_DELAY` | 5.0s | Wait before doing the final/round-end `GetBagItemInfo` consistency check (quirk #9). |
| `MAX_RETRY_PASSES` | 3 | Intra-round retries for failed pickups before giving up on that round. |
| `MAX_CORRECTION_ROUNDS` | 8 | Full re-read-and-resort rounds after a round finishes with mismatches. |

If sort reliability regresses, these are the first things to reconsider -
nearly every past reliability bug traced back to one of these being too
short, not to a logic error (though check for logic errors first via careful
log analysis - it's been both, historically, roughly 50/50).

### Diagnostic slash commands (for future debugging)

- `/sortbag probe` - now also dumps the full `GetBagCount()` return list and
  the 6th `GetBagItemInfo` value per slot (to settle quirks #13/#14). Read-only.
- `/sortbag tooltip <uiSlot>` - dumps every tooltip line (left + right) for a
  slot. Use this to verify/tune `ExtractType()`, `ExtractTier()`, and quest
  classification heuristics.
- `/sortbag testswap <rawA> <rawB>` - RAW `PickupBagItem` diagnostic. Does
  **NOT** apply the +60 offset - caller must add it manually. Historically
  used to discover the offset in the first place.
- `/sortbag testmove <uiFrom> <uiTo>` - offset-aware diagnostic that reads
  and writes using the same UI slot numbering as `probe`/`preview`. Prefer
  this one for any "did this specific move actually work" investigation -
  it won't confuse you with mismatched addressing like `testswap` can.
- `/sortbag frames <substring> [exclude]` - read-only scan of frame-like
  globals by name. In production mode its output is suppressed; enable
  `/sortbag testing on` first.

### Sort modes / settings

`WrathBagSort_Settings` (a saved variable) holds `mode` (`"name"`/`"type"`) and
`direction` (`"asc"`/`"desc"`). Set via `/sortbag mode <name|type>` and
`/sortbag order <asc|desc>`; defaults are `name` + `asc`.

- `name` mode: sort by item name (case-insensitive), tie-break by slot.
- `type` mode: sort by `GetTypeGroup()` (equipment, consumables, other, quest),
  then `ExtractType()` result, then name and slot. `ExtractType()` and
  `ExtractTier()` are tooltip heuristics; quest classification checks tooltip
  text for `quest`, and may need localization-specific additions.
- `direction` reverses the whole sort (descending).

**Tooltip classification is heuristic, not fully battle-tested** - RoM tooltip
layout varies by item kind. `ExtractType()` returns the first eligible white or
red line after the item name; `ExtractTier()` reads `Tier N`; `IsQuestItem()`
looks for `quest` text. `GetTypeGroup()` uses tier/type keywords to group
equipment, consumables, other items, then quest items. Verify unusual/localized
items with `/sortbag tooltip <slot>` before relying on `type` mode.

## Safety-critical reminders

- 35x Transport Rune from transmuter output was once routed to the wrong
  inventory destination by the early +60 offset bug; the items were not lost.
  Any change to index arithmetic, Item Shop detection, or locked-item
  detection must still be treated as safety-critical.
- Keep a working `/sortbag cancel` escape hatch, and keep `/sortbag preview`
  read-only so the planned moves can be reviewed before committing. (The
  two-step `sort` -> `sortconfirm` gate was removed at the user's request:
  `/sortbag sort` now sorts directly. `sortconfirm`/`sort confirm` remain as
  no-op aliases.)
- Prefer pcall-wrapping any new risky entry point - this client fails
  silently (no visible red error text) on uncaught Lua errors, which
  previously manifested as the chat input mysteriously refusing to submit
  further commands.
