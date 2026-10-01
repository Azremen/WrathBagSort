# WrathBagSort

A Backpack-sorting addon for the custom Runes of Magic client "Wrath of Eternal".
Sorts your regular Backpack alphabetically by item name, while deliberately
leaving Item Shop items and locked items untouched.

The native **"sort items"** button (and zBag's sort buttons) are hooked to run
this addon's sort instead of the game's default per-bag sort.
Opening the native Backpack opens this addon's custom bag window in its place;
you do not need to open a separate regular Backpack window manually.

## Why this exists

This client's addon API has several undocumented quirks (see
[AGENTS.md](AGENTS.md) for the full technical list), so the sorter deliberately
moves items slowly and verifies its own work instead of trusting a single fast
pass. If you've used other bag-sort addons before, this one will feel more
cautious and noisier in the chat log - that's intentional.

## ⚠️ Safety first

An early version of this addon genuinely lost an item (35x Transport Rune) by
moving it into the Item Shop Backpack instead of the regular Backpack. The
current sort path addresses regular Backpack slots at indices 61+ and refuses
PickupBagItem indices 1-60. **The Item Shop Backpack may remain open**; its
items are identified and excluded from sorting. Before sorting:

1. Use the custom bag window opened by the native Backpack toggle.
2. Run `/sortbag preview` first (after enabling testing output) and review the plan.

## Commands

All commands start with `/sortbag`.

| Command | What it does |
|---|---|
| `/sortbag bag` | Opens/closes the **custom bag window** (an icon grid showing the whole inventory) with Sort / Preview / Mode / Order buttons bound to this addon. |
| `/sortbag probe` | In testing mode, prints API diagnostics and a raw dump of all bag slots. Read-only. |
| `/sortbag preview` | In testing mode, prints the planned sort as `slot X -> Y: "Name" xCount` lines, using the current mode/direction. Read-only, moves nothing. |
| `/sortbag sort` | **Sorts the Backpack now** using the current mode/direction, paced to avoid this client's rapid-action limits, with automatic retries if some items don't land correctly the first time. (`sortconfirm` / `sort confirm` still work as aliases.) |
| `/sortbag testing on` | Enables diagnostic chat and saved-log output for this session. |
| `/sortbag testing off` | Disables diagnostic chat and saved-log output. Does not disable or undo sorting. |
| `/sortbag mode name` | Sort by item **name** (plain alphabetical). |
| `/sortbag mode type` | Sort by broad family first (equipment, consumables, other items, then quest items), then tooltip type and name. |
| `/sortbag mode tier` | Sort by item **tier** (grouped by tier, then name). Tier is read from the "Tier N" tooltip line. |
| `/sortbag order asc` | Sort **ascending** (A→Z). |
| `/sortbag order desc` | Sort **descending** (Z→A). |
| `/sortbag cancel` | Stops an in-progress sort as soon as possible. Already-completed moves are not undone. |
| `/sortbag log` | Opens/closes a copyable log window. The **top box** holds every line at once: click it, `Ctrl+A`, then `Ctrl+C` to copy the whole log (no need to copy line by line). The boxes below are the scrollable per-line view. |
| `/sortbag clearlog` | Clears the saved log (so the next `probe`/`preview` starts fresh). |
| `/sortbag tooltip <slot>` | Diagnostic: dumps every tooltip line for a bag slot (used to verify "type" detection). For addon development only. |
| `/sortbag reload` | Calls the client's `ReloadUI()`. Useful after editing the addon's files. |
| `/sortbag frames <substring> [exclude]` | In testing mode, searches global frame names. Read-only. |
| `/sortbag testswap <a> <b>` | **Moves/swaps items.** Low-level diagnostic using raw `PickupBagItem` indices; it does not apply the +60 offset. For addon development only. |
| `/sortbag testmove <uiFrom> <uiTo>` | **Moves an item.** Diagnostic using UI slot numbers and the +60 offset, with before/after output. For addon development only. |

Mode and order are saved between sessions (via `WrathBagSort_Settings`). Defaults: `name` + `asc`.

Production default: `WrathBagSort_TESTING_MODE = false`. Diagnostics routed
through `Print()` are suppressed and are not appended to the saved log while
off. `/sortbag testing on` enables them for the current session;
`/sortbag reload` resets the flag to false. This is an **output** switch, not
a safety lock: `/sortbag sort`, `testmove`, and `testswap` can still move items
while testing mode is off.

The **custom bag window** (`/sortbag bag`) uses twelve Roman-numeral page tabs
with 30 slots per page, like the native Backpack. Locked rented pages can be
opened in read-only mode; a **Rent Page** button opens the native timed rental
store (diamond cost/term are handled by the game). The footer shows the native occupied/capacity count (for example,
`52/60`), not the full API address range. The toolbar includes Sort, Preview,
Mode, Order, and the native Goods, Partner, Transmuter, and Garbage windows.
Use the **Find** box to search item names across all bag pages; matching slots
stay highlighted, other slots dim, matching pages get a `+`, and the first
matching page opens automatically. Press Escape or click `X` to clear the search.
Hovering an item shows its tooltip. Left-click picks up an item, right-click
uses it, Shift-click links/splits stacks, Ctrl-click opens the item preview,
and drag-and-drop moves items between bag slots. Stack quantities appear at
the lower-right of each icon. Item interactions only act on regular Backpack
indices (61+); Item Shop Backpack indices 1-60 are refused. The lower-right
footer also shows account diamonds, bonus/ruby currency, and gold, matching
the native zBag money frames.

The log (`WrathBagSort_Log`) is saved as a plain, newline-joined block in the
client's saved-variables file, so you can open it and copy the output directly:

```
Documents\WrathOfEternal\SaveVariables.lua
```

(`Documents` = `Belgeler` on a Turkish Windows; there is also a per-character
copy under `Documents\WrathOfEternal\<CharacterName>\SaveVariables.lua`.)

## What a sort run looks like

```
/sortbag sort
sorting 52 items (paced to avoid this client's rapid-action limit)...
  swapping slot 46 (Blend Rune) <-> slot 7 (empty)
  swapping slot 17 (Crow Grass) <-> slot 9 (Plague-Infested Tooth)
  ...
  skipping for now: pickup from slot 23 put nothing on the cursor (will retry after the rest)
  ...
  retrying unmoved item(s) (pass 1/3)...
  ...
sort complete; 48 moves performed, 0 mismatches
```

- `skipping for now` lines are normal - this client occasionally drops a bag
  action if it's issued too quickly after a previous one. The addon notices
  and retries it automatically.
- If the final report shows mismatches, the addon will automatically re-read
  the bag and try another "correction round" (up to 8 times) before
  giving up. If it still reports mismatches, stop and inspect the inventory
  with `/sortbag probe` before deciding whether to retry. Do not treat a
  mismatch report as a guarantee that every item is safe; this client has
  caused a real item loss in an earlier version of the addon.

## Known limitations

- Sorting a full 50+ item Backpack can take anywhere from a few seconds to a
  couple of minutes, depending on how many retries this client's engine
  forces. This is intentional - speed is traded for never losing an item.
- Item Shop items and locked items are always left in place; they are
  never counted as "free" destination slots for other items either.
- The separate native Item Shop Backpack window is not reproduced in the
  custom bag UI, but it does not need to be closed during sorting: sorting
  refuses PickupBagItem indices 1-60 and filters Item Shop items from targets.
  Its separate display/data API has not been identified safely.
- After renting a bag page, its tab may remain marked read-only until you
  switch pages or reopen the bag window.
- Type-mode grouping is heuristic and based on tooltip text. If a localized
  item appears in the wrong family, use `/sortbag tooltip <slot>` while
  testing mode is on to inspect its tooltip lines.
- Only the regular Backpack is supported. Bank, house storage, and other
  containers are not handled.

## Files

- `WrathBagSort.toc` - addon manifest (must load `WrathBagSort.lua` before the
  `.xml` files - see AGENTS.md for why).
- `WrathBagSort.lua` - all sorting logic and slash command handling.
- `WrathBagSort.xml` - minimal addon shell.
- `WrathBagSortLog.xml` - the copyable log window; also hosts the `OnUpdate`
  script that paces sorting (see AGENTS.md).

For the full list of client-specific quirks, past bugs, and why the code is
structured the way it is, see [AGENTS.md](AGENTS.md).
