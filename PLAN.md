# noter — Phoenix Application

Replaces the n8n workflow and `process-transcript` bash script. Built as a
Phoenix application from the start so the web UI (phase 2) is an extension of
the same project rather than a rewrite. Core domain logic is interface-agnostic;
Mix tasks provide the CLI now, `NoterWeb` will provide the web UI later.

## Full session workflow

```
1.  [manual]           Receive zip archive of per-player flac files from Craig bot
2.  [manual]           Listen to merged recording, note session start/end timestamps
3.  [mix noter.prep]   Extract zip, clip tracks to timestamps, rename to character names
4.  [manual]           Review and update vocab.txt for this session
5.  [transcribe-audio] Run existing Docker transcription pipeline
6.  [mix noter.run]    Review merged SRT, triage misspellings → update corrections
7.  [mix noter.run]    Run LLM pipeline → session notes
8.  [mix noter.run]    Update campaign context from new notes (for next session)
9.  [manual]           Review and edit final notes
```

Steps 3, 7, and 8 are fully automatable. Step 6 is partially automatable
(flag suspicious terms; human confirms). Steps 2, 4, and 9 stay manual.

Step 2 (timestamp finding) and step 6 (corrections review) are the strongest
candidates for the phase 2 web UI — both involve media interaction that is
awkward in a terminal.

## Bootstrapping

```bash
phx.new noter --database sqlite3 --no-mailer
```

Phoenix + Ecto + SQLite + LiveView. No mailer. SQLite is sufficient and keeps
deployment simple for a personal tool.

## Architecture

Core domain logic lives in `lib/noter/` with no awareness of CLI or web.
Mix tasks and the Phoenix web layer are both adapters on top of the same modules.

```
noter/
  lib/
    noter/
      # Core domain (pure functions, no interface dependencies)
      pipeline.ex         # orchestrates the full LLM pipeline
      chunker.ex          # transcript chunking + applying corrections
      extractor.ex        # per-chunk fact extraction (structured JSON)
      aggregator.ex       # merge + deduplicate facts across chunks
      writer.ex           # note writing from aggregated facts
      context.ex          # update campaign context from session notes
      prep.ex             # extract zip, clip + rename audio files
      corrections.ex      # SRT review + corrections triage
      llm.ex              # OpenAI Chat Completions HTTP client
      campaign.ex         # load campaign config files
      session.ex          # find/validate session files
    noter_web/            # Phase 2 — Phoenix web interface
      ...
  lib/mix/tasks/noter/
    prep.ex               # mix noter.prep
    run.ex                # mix noter.run
  priv/
    repo/migrations/      # Ecto migrations
  mix.exs
  mix.lock
```

Ecto / SQLite is used for caching LLM extraction results per chunk (avoids
re-spending API calls on re-runs) and tracking processed sessions. Campaign
config stays as human-editable files (see below).

## Campaign config

A campaign directory holds config that persists across sessions. All
human-editable files use TOML — no JSON.

```
~/campaigns/stormlight/
  players.toml        # discord username → character name (set once, reused)
  corrections.toml    # cumulative corrections {"Alefi" = "Alethi", ...}
  context.md          # current campaign context (prose, updated after each session)
  vocab.txt           # whisper vocabulary hints (reviewed each session)
```

Example `players.toml`:
```toml
vastlysuperiorman = "Rinah"
indifferentpineapple = "Tarra"
nate6484 = "Milo"
tuffymcfuklbee = "Adam"
_karmapolice = "Xilak"
taevus = "Kai"
```

Example `corrections.toml`:
```toml
Alefi = "Alethi"
Alephi = "Alethi"
Harold = "herald"
Taro = "Tarra"
```

### Campaign directory discovery

Mix tasks take the session directory as an argument and walk up the directory
tree looking for `players.toml`. This mirrors how `git` finds its config.

```bash
mix noter.prep ~/sessions/stormlight-42/archive.zip --start 00:13:57 --end 03:27:37
mix noter.run ~/sessions/stormlight-42/
```

## Session directory layout

```
~/sessions/stormlight-42/
  [raw zip contents after extract]
  1-vastlysuperiorman.flac
  2-indifferentpineapple.flac
  ...
  [after mix noter.prep]
  Kai.flac
  Rinah.flac
  ...
  transcripts/
    Kai.json
    Rinah.json
    merged.json
    merged.srt
    speaker_mapping.json
  stormlight-42-notes.md
```

## Mix tasks

### `mix noter.prep`

Handles everything between receiving the zip and running transcription.

```bash
mix noter.prep ~/sessions/stormlight-42/archive.zip --start 00:13:57 --end 03:27:37
```

1. Discovers campaign dir by walking up from the session directory
2. Extracts zip into session directory
3. Clips each flac track to the given timestamps via ffmpeg
4. Renames files using `players.toml` (discord username → character name)

### `mix noter.run`

Replaces `process-transcript`. Runs against a completed transcription.

```bash
mix noter.run ~/sessions/stormlight-42/
```

Stages (each skippable via flags):

1. **review** — shows terms from merged SRT not in vocab.txt or corrections.toml;
   prompts to add corrections interactively, saves back to corrections.toml
2. **process** — runs the LLM pipeline (chunk → extract → aggregate → write notes),
   caches per-chunk extraction results in SQLite
3. **update-context** — feeds new notes + existing context to LLM, writes
   updated `context.md` to campaign directory for next session

## Dependencies

- `phoenix`, `phoenix_live_view`, `ecto_sqlite3` — from `phx.new`
- `req` — HTTP client for OpenAI API calls
- `jason` — already included by Phoenix
- `{:toml, "~> 0.7"}` — parsing TOML campaign config files

No OpenAI Elixir library — a thin `llm.ex` wrapper over `Req` against the
stable Chat Completions API is straightforward.

## LLM

OpenAI Chat Completions API:
- Structured outputs (JSON schema enforcement) for fact extraction
- Plain completion for note writing and context updates

API key from environment / sops-nix secrets, same pattern as `HF_TOKEN`.
Multi-model support (Ollama, Claude) can be added later if needed.

## Phase 2: web UI

The web app is the same Phoenix project with `NoterWeb` filled in — no
rearchitecting required. Deployment: `mix release` built into a Docker
container, kept running, with new releases pushed to it.

Campaign directory is configured in `config.exs` rather than discovered by
walking up the tree. The web UI adds:

- **Session management** — create a new session (upload zip), or open an
  existing session
- **Waveform scrubber** — play merged recording, click to set start/end
  timestamps, feeds into the prep pipeline
- **Corrections review** — audio-synced SRT view, click a line to hear it,
  quickly accept/reject/edit corrections

LiveView is well-suited to all of these.

## Open questions

None outstanding — ready to build.
