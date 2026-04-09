# Update Download ZIP

## Context

The download ZIP currently includes audio, transcripts, and vocab. Two new optional text files need to be added: `campaign-context.md` (from `session.context`) and `{session-slug}-notes.md` (from `session.session_notes`). Additionally, downloads should be available once the reviewing stage is finalized — statuses `noting` and `done` (i.e., after reviewing is complete, but not during reviewing).

## Changes

**File:** `lib/noter_web/controllers/download_controller.ex`

### 1. Relax the status gate (line 12)

Change `session.status == "done"` to allow download after reviewing is finalized (`noting` or `done`):

```elixir
if session.status in ~w(noting done) do
```

### 2. Add two new helper functions and wire them into the pipeline

Add `add_context/3` and `add_notes/3` to the entry pipeline (after `add_vocab`):

```elixir
entries =
  []
  |> add_merged_audio(session_dir, root)
  |> add_tracks(session_dir, root)
  |> add_transcripts(session, root)
  |> add_vocab(session_dir, root)
  |> add_context(session, root)
  |> add_notes(session, root)
```

**`add_context/3`** — adds `{root}/campaign-context.md` from `session.context` if not nil:

```elixir
defp add_context(entries, session, root) do
  if session.context do
    [[source: {:stream, [session.context]}, path: "#{root}/campaign-context.md"] | entries]
  else
    entries
  end
end
```

**`add_notes/3`** — adds `{root}/{slug}-notes.md` from `session.session_notes` if not nil:

```elixir
defp add_notes(entries, session, root) do
  if session.session_notes do
    [[source: {:stream, [session.session_notes]}, path: "#{root}/#{session.slug}-notes.md"] | entries]
  else
    entries
  end
end
```

## Verification

1. `mix precommit` passes
2. Manual test: download a session with both `context` and `session_notes` set — verify both `.md` files appear in the zip
3. Download a session where one or both are nil — verify missing files are simply absent
4. Download a session in `noting` status — verify it works
5. Confirm `uploading`/`trimming`/`transcribing`/`reviewing` statuses still block download
