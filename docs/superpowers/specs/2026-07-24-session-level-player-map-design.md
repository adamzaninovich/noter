# Session-Level Player Map (Character Swaps)

**Date:** 2026-07-24
**Status:** Approved

## Problem

A campaign's roster is stored as `campaigns.player_map`: a flat `%{discord_username => character_name}` map, applied at prep/upload time to rename each Discord user's FLAC to their character name, and used in the review UI to assign speaker colors.

When a player character (PC) dies and the player rolls a new character, the same Discord username must map to a **different** character name going forward, while the old (dead) character must stay valid for that campaign's history. A flat, campaign-wide 1:1 map cannot represent this: editing the row overwrites the old character, and — because prep reads the **live** campaign map at processing time — re-processing or late/out-of-order processing of an older session would rename that player's audio to the *new* character.

This is a rare event. The solution must add **zero friction to the normal workflow** and only surface when a swap actually happens.

## Key facts about the current system

- Prep applies the map at upload time (`Noter.Uploads.process_uploads/5`, `lib/noter/uploads.ex:59` and `:163`), reading `campaign.player_map`. Character names are then baked into the transcript's speaker labels, so **already-processed sessions already carry the correct (old) names** — history does not disappear on its own.
- The only live consumers of the map are: (1) prep/re-prep, and (2) speaker colors (`Noter.Sessions.ReviewState.build_speaker_colors/2`, `lib/noter_web/live/session_live/review_state.ex:171`).
- Sessions are always **created in order**, but are not necessarily finished (processed) in order, and a session may be created before the previous one finishes.
- Sessions are created through a single funnel: `Noter.Sessions.create_session/2` (`lib/noter/sessions.ex:63`), called from `Noter.Jobs.run_upload_processing_task/4` (`lib/noter/jobs.ex:198`).

## Design

Make the player map a **per-session snapshot** that freezes at session creation and never changes unless edited by hand on that session.

### Data model

- Add `player_map` (`:map`, default `%{}`) to `sessions`.
- **Keep** `campaigns.player_map`, but narrow its role to **seed for the first session only** (see Inheritance). It is no longer the live roster.

### Inheritance at creation

`create_session/2` seeds the new session's `player_map`, set **programmatically** (not via `cast`):

```
new session's player_map ← most recent prior session's player_map in the campaign
                          ← (if no prior session) campaign.player_map
                          ← (if that is empty) %{}
```

"Most recent prior session" = the campaign's session with the greatest `inserted_at` (tie-break by `id`) at creation time. Because sessions are created in order, each session freezes the roster true at its point in the campaign timeline, with **no extra steps** on the normal path.

### Prep reads the session's own map

- `lib/noter/uploads.ex:59`: `campaign.player_map` → `session.player_map`
- `lib/noter/uploads.ex:163`: `session.campaign.player_map` → `session.player_map`

Prep now depends only on the frozen snapshot, so processing late or out of order is always correct. `campaign` remains a parameter of `process_uploads/5` (still used for common replacements, etc.); only the player-map source changes.

### Speaker colors

`ReviewState.build_speaker_colors/2` sources characters from `session.player_map` instead of `campaign.player_map`, so a dead PC keeps a stable color in its own old sessions. The function's signature changes from `(speakers, campaign)` to `(speakers, session)` (or it takes the map directly); update the single call site accordingly.

### UI

**Campaign show page (`campaign_live/show.ex`) — Player Map card:**
- Editable **only while the campaign has no sessions** (initial setup). This preserves today's campaign-creation UX: create campaign → set up roster in settings.
- Once at least one session exists, render the map **read-only** (show the seed). No Edit button. (Future, out of scope: aggregate and show every character from every session here.)

**Session show page (`session_live/show.ex`) — new Advanced panel:**
- Add a collapsible **Advanced** section (styled like the campaign settings panel) containing a Player Map editor that edits **that session's** `player_map`. This mirrors the existing campaign player-map editor (add/remove rows, inline `.PlayerInput` hook behavior, save).
- This is the **only** way a created session's map changes — matching the rule "nothing about a created session changes unless changed manually."
- Editing stores the snapshot; it takes effect on the next (re)process. It does not retroactively alter an already-baked transcript.

### Migration (ordered)

1. Add `player_map` (`:map`, default `%{}`, not null) to `sessions`.
2. Data migration: for every existing session, copy its campaign's current `player_map` onto the session. Before this change ships, all existing sessions belong to the current (pre-swap) roster, so freezing today's map onto them is correct.
3. **Do not** drop `campaigns.player_map` — it remains the first-session seed.

Legacy safety: after backfill, no session has an empty snapshot unless its campaign's map was already empty, in which case prep falls back to `campaign.player_map` (also empty) — same behavior as today.

## What does not change

- The normal upload/processing flow and its UI.
- Already-processed transcripts (names are already baked in).
- Common replacements (campaign-level, untouched).
- No date/range logic; no per-session picker on the happy path.

## Walkthrough: the dead-PC case

1. This feature ships; the data migration freezes every existing session on the current roster.
2. On the next session (the one introducing the new character), the Advanced panel shows the inherited roster; the user changes that one player's row to the new character name.
3. Every later session inherits the new character forward; every older session keeps the dead PC. Re-processing any old session — even months late — renames correctly, because prep reads that session's frozen snapshot.

## Testing

- `create_session/2` seeds from the most recent prior session; falls back to `campaign.player_map`; falls back to `%{}` for the first session with an empty campaign seed.
- Editing a prior session's map does **not** change an already-created later session.
- Prep (`resolve_character` path) uses `session.player_map`, not the live campaign map.
- `build_speaker_colors` uses the session's map.
- Campaign Player Map card: editable with zero sessions, read-only with ≥1 session.
- Session Advanced Player Map editor: add/remove/save round-trips to `session.player_map`.
- Migration backfills existing sessions from their campaign's map.
