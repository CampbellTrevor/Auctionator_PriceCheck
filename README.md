# Auctionator Price Check

Lightweight companion addon for Auctionator that adds:

- `/pc` window for name/link/ID lookups
- `!pc <item>` and `!pricecheck <item>` chat-triggered lookups
- price + age output from Auctionator historical scan data

It reads local Auctionator data only. No external service calls.

## Requirements

- World of Warcraft
- Auctionator installed and collecting scan data

## Commands

- `/pc`
  - Toggle the Price Check window.
- `/pc <query>`
  - Lookup by item name, item link, or item ID.
- `/pc refresh` (also `rebuild`, `reindex`)
  - Clear PriceCheck caches and rebuild on next lookup.

Chat commands:

- `!pc <query>`
- `!pricecheck <query>`

Supported chat sources include say/yell/guild/party/raid/instance/channel events.

## Lookup Behavior

- Numeric IDs and explicit item links are the most reliable.
- Plain text names use:
  1. exact catalog matches,
  2. then fuzzy matches.
- For ambiguous plain-text names, up to 3 matches are returned.
- Name cache is persisted in:
  - `AUCTIONATOR_PRICECHECK_NAME_CACHE`

## Why Name Results Can Differ

WoW item name data is cached asynchronously. If an item is uncached, a name lookup may miss until item info is loaded. The addon requests missing item names in the background and stores successful names for future sessions.

## Chat Reply Notes

- Public auto-send is subject to WoW protected chat API restrictions.
- If blocked, the addon falls back to prepared/manual output.
- Blocking is tracked per chat type.

## Project Layout

- `Core.lua`
  - Main addon flow (UI, lookup pipeline, chat handlers, cache orchestration).
- `Utilities.lua`
  - Shared string/format/display helpers.
- `NameCache.lua`
  - Persistent name cache helpers and item name load request helper.

## Saved Variables

- `AUCTIONATOR_PRICECHECK_NAME_CACHE`

## Troubleshooting

If an item has an Auctionator tooltip price but name lookup fails:

1. Query once by explicit item link or ID.
2. Wait briefly for item info events.
3. Retry by name.
4. If needed, run `/pc refresh`.

