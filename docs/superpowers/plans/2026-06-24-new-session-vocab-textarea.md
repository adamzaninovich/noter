# New Session Vocab Text Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the vocabulary file upload on the New Session page with a textarea that prefills from the previous session and accepts a dragged-in `.txt` file.

**Architecture:** Vocab stays on disk as `<session_dir>/vocab.txt` (no DB change). The upload pipeline accepts vocab **text** instead of a file path and writes it directly. The LiveView prefills a textarea from the most recent session's `vocab.txt` and a JS hook lets a dropped file replace the textarea contents.

**Tech Stack:** Elixir, Phoenix LiveView, daisyUI/Tailwind, plain JS hooks, ExUnit/Mox.

---

## File Structure

- `lib/noter/uploads.ex` — `process_uploads/5` takes vocab text; new `read_vocab/1` helper.
- `lib/noter/jobs.ex` — `start_upload_processing/4` passes vocab text through.
- `lib/noter_web/live/session_live/new.ex` — textarea instead of upload; mount autofill; save reads `params["vocab"]`.
- `lib/noter_web/live/session_live/upload_helpers.ex` — drop the `:vocab_file` branch.
- `assets/js/hooks.js` — new `DropVocab` hook.
- `test/noter/uploads_test.exs` — update process_uploads test to vocab text.
- `test/noter_web/live/session_live/new_test.exs` — autofill + empty + submit tests.

---

## Task 1: `Uploads.read_vocab/1` and vocab-text in `process_uploads/5`

**Files:**
- Modify: `lib/noter/uploads.ex` (`process_uploads/5` around lines 27-63; add `read_vocab/1`)
- Test: `test/noter/uploads_test.exs` (update `process_uploads/4` describe block, lines 39-90)

- [ ] **Step 1: Update the existing process_uploads test to pass vocab text**

In `test/noter/uploads_test.exs`, replace the file-based vocab setup and the call. Remove these lines (57-58):

```elixir
      vocab_path = Path.join(tmp_dir, "vocab.txt")
      File.write!(vocab_path, "dragon\nwizard")
```

Change the call (line 77) from:

```elixir
      {:ok, renamed} = Uploads.process_uploads(session, campaign, zip_path, vocab_path)
```

to:

```elixir
      {:ok, renamed} = Uploads.process_uploads(session, campaign, zip_path, "dragon\nwizard")
```

Then strengthen the vocab assertion (replace line 84 `assert File.exists?(Path.join(session_dir, "vocab.txt"))`) with:

```elixir
      assert File.read!(Path.join(session_dir, "vocab.txt")) == "dragon\nwizard"
```

- [ ] **Step 2: Add a focused test for read_vocab and blank-vocab skipping**

Add this describe block at the end of `test/noter/uploads_test.exs` (before the final `end` of the module):

```elixir
  describe "read_vocab/1" do
    test "returns file contents when vocab.txt exists", %{session: session} do
      File.mkdir_p!(Uploads.session_dir(session.id))
      File.write!(Path.join(Uploads.session_dir(session.id), "vocab.txt"), "orc\ngoblin")

      assert Uploads.read_vocab(session.id) == "orc\ngoblin"
    end

    test "returns empty string when vocab.txt is missing", %{session: session} do
      assert Uploads.read_vocab(session.id) == ""
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/noter/uploads_test.exs`
Expected: FAIL — `read_vocab/1` undefined and `process_uploads` still expects a path/`move_file!` will raise on a non-path string.

- [ ] **Step 4: Implement the vocab-text write in process_uploads**

In `lib/noter/uploads.ex`, change the `process_uploads` signature parameter name (line 31) from `vocab_path` to `vocab_text`, and replace the vocab block (lines 43-46):

```elixir
    if vocab_path do
      on_progress.("Copying vocabulary file...")
      move_file!(vocab_path, vocab_dest)
    end
```

with:

```elixir
    if vocab_text && String.trim(vocab_text) != "" do
      on_progress.("Saving vocabulary...")
      File.write!(vocab_dest, vocab_text)
    end
```

- [ ] **Step 5: Implement read_vocab/1**

In `lib/noter/uploads.ex`, add this function near `session_dir/1`:

```elixir
  def read_vocab(session_id) do
    case File.read(Path.join(session_dir(session_id), "vocab.txt")) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/noter/uploads_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/noter/uploads.ex test/noter/uploads_test.exs
git commit -m "Accept vocab text in process_uploads and add read_vocab"
```

---

## Task 2: Pass vocab text through `start_upload_processing/4`

**Files:**
- Modify: `lib/noter/jobs.ex` (lines 188-211)

- [ ] **Step 1: Rename the vocab parameter to vocab_text**

In `lib/noter/jobs.ex`, rename `vocab_path` to `vocab_text` in `start_upload_processing/4` (line 188) and `run_upload_processing_task/4` (line 197) and the `Uploads.process_uploads` call argument (line 210). The function bodies just forward the value, so this is a pure rename:

```elixir
  def start_upload_processing(session_params, campaign, zip_path, vocab_text) do
    {:ok, pid} =
      Task.Supervisor.start_child(@supervisor, fn ->
        run_upload_processing_task(session_params, campaign, zip_path, vocab_text)
      end)

    {:ok, pid}
  end

  defp run_upload_processing_task(session_params, campaign, zip_path, vocab_text) do
```

and the call:

```elixir
        case Uploads.process_uploads(
               session,
               campaign,
               zip_path,
               vocab_text,
               on_progress
             ) do
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 3: Commit**

```bash
git add lib/noter/jobs.ex
git commit -m "Forward vocab text through start_upload_processing"
```

---

## Task 3: `DropVocab` JS hook

**Files:**
- Modify: `assets/js/hooks.js`

- [ ] **Step 1: Add the DropVocab hook**

In `assets/js/hooks.js`, add (mirrors the existing `DropJson` hook):

```javascript
export const DropVocab = {
  mounted() {
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
      this.el.classList.add("border-primary")
    })
    this.el.addEventListener("dragleave", () => {
      this.el.classList.remove("border-primary")
    })
    this.el.addEventListener("drop", (e) => {
      e.preventDefault()
      this.el.classList.remove("border-primary")
      const file = e.dataTransfer.files[0]
      if (file) {
        file.text().then((text) => {
          this.el.value = text
          this.el.dispatchEvent(new Event("input", { bubbles: true }))
        })
      }
    })
  },
}
```

(`app.js` registers hooks via `import * as hooks`, so the named export is picked up automatically — no further wiring needed.)

- [ ] **Step 2: Commit**

```bash
git add assets/js/hooks.js
git commit -m "Add DropVocab hook for dropping a vocab file into a textarea"
```

---

## Task 4: New Session LiveView — textarea, autofill, save

**Files:**
- Modify: `lib/noter_web/live/session_live/new.ex` (mount lines 18-40; render vocab block lines 113-127; save lines 169-195)
- Modify: `lib/noter_web/live/session_live/upload_helpers.ex` (lines 38-51)
- Test: `test/noter_web/live/session_live/new_test.exs`

- [ ] **Step 1: Write failing LiveView tests for autofill, empty, and submit**

Append these tests to `test/noter_web/live/session_live/new_test.exs` (before the module's final `end`). Add `alias Noter.Sessions` and `alias Noter.Uploads` to the existing aliases near the top.

```elixir
  test "prefills vocab from the most recent session", %{conn: conn, campaign: campaign} do
    {:ok, prev} = Sessions.create_session(campaign, %{name: "Earlier Session"})
    File.mkdir_p!(Uploads.session_dir(prev.id))
    File.write!(Path.join(Uploads.session_dir(prev.id), "vocab.txt"), "Tharivol\nNeverwinter")
    on_exit(fn -> File.rm_rf(Uploads.session_dir(prev.id)) end)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    assert has_element?(view, "#session-vocab", "Tharivol")
  end

  test "vocab textarea is empty for the first session", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    assert has_element?(view, "#session-vocab")
    refute has_element?(view, "#session-vocab", "Tharivol")
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/noter_web/live/session_live/new_test.exs`
Expected: FAIL — `#session-vocab` element does not exist yet.

- [ ] **Step 3: Add the vocab autofill assign in mount**

In `lib/noter_web/live/session_live/new.ex`, add `alias Noter.Uploads` near the other aliases (after line 6). In `mount/3`, compute the prefill value after loading the campaign (after line 21):

```elixir
    vocab =
      case Sessions.list_sessions(campaign.id) do
        [latest | _] -> Uploads.read_vocab(latest.id)
        [] -> ""
      end
```

Add `|> assign(:vocab, vocab)` to the socket pipeline (e.g. after the `:campaign` assign), and **remove** the vocab upload line (line 39):

```elixir
     |> allow_upload(:vocab_file, accept: ~w(.txt), max_entries: 1, max_file_size: 1_000_000)}
```

so the pipeline ends after the `:zip_file` `allow_upload`.

- [ ] **Step 4: Replace the vocab upload block with a textarea**

In `render/1`, replace the entire "Vocab Upload" block (lines 113-127):

```heex
                  <%!-- Vocab Upload --%>
                  <div>
                    <label class="label font-medium">Vocabulary File (TXT)</label>
                    <div class="flex flex-col gap-2" phx-drop-target={@uploads.vocab_file.ref}>
                      <.live_file_input
                        upload={@uploads.vocab_file}
                        class="file-input file-input-bordered w-full"
                      />
                      <.upload_entries
                        entries={@uploads.vocab_file.entries}
                        upload_ref={@uploads.vocab_file.ref}
                        upload={@uploads.vocab_file}
                      />
                    </div>
                  </div>
```

with:

```heex
                  <%!-- Vocab text --%>
                  <div>
                    <label class="label font-medium" for="session-vocab">Vocabulary</label>
                    <textarea
                      name="vocab"
                      id="session-vocab"
                      rows="6"
                      phx-hook="DropVocab"
                      placeholder="One term per line. Drop a vocab.txt file here to replace."
                      class="textarea textarea-bordered w-full font-mono text-sm"
                    >{@vocab}</textarea>
                  </div>
```

- [ ] **Step 5: Read vocab text in the save handler**

In `lib/noter_web/live/session_live/new.ex`, update the `save` handler. Change the head (line 169) to capture all params and drop the vocab consume (line 181); pass `params["vocab"]` instead of `List.first(vocab_paths)`:

```elixir
  def handle_event("save", %{"session" => session_params} = params, socket) do
    campaign = socket.assigns.campaign

    if socket.assigns.uploads.zip_file.entries == [] do
      {:noreply, put_flash(socket, :error, "A ZIP file is required.")}
    else
      changeset =
        %Noter.Sessions.Session{campaign_id: campaign.id}
        |> Sessions.change_session(session_params)

      if changeset.valid? do
        zip_paths = consume_uploaded_entries(socket, :zip_file, &consume_to_tmp/2)

        Jobs.start_upload_processing(
          session_params,
          campaign,
          List.first(zip_paths),
          params["vocab"]
        )

        {:noreply, assign(socket, processing?: true, processing_status: "Creating session...")}
      else
        {:noreply, assign(socket, form: to_form(%{changeset | action: :validate}))}
      end
    end
  end
```

- [ ] **Step 6: Remove the vocab_file branch from cancel_upload_by_ref**

In `lib/noter_web/live/session_live/upload_helpers.ex`, replace the `cancel_upload_by_ref/3` `case` (lines 39-44) so only `:zip_file` remains:

```elixir
    upload_name =
      case upload_ref do
        r when r == socket.assigns.uploads.zip_file.ref -> :zip_file
        _ -> nil
      end
```

- [ ] **Step 7: Run the LiveView tests to verify they pass**

Run: `mix test test/noter_web/live/session_live/new_test.exs`
Expected: PASS (including the existing form/breadcrumb/validate tests).

- [ ] **Step 8: Commit**

```bash
git add lib/noter_web/live/session_live/new.ex lib/noter_web/live/session_live/upload_helpers.ex test/noter_web/live/session_live/new_test.exs
git commit -m "Replace vocab upload with prefilled textarea on new session page"
```

---

## Task 5: Full verification

- [ ] **Step 1: Run the full suite and precommit**

Run: `mix precommit`
Expected: PASS — no compile warnings, formatter clean, all tests green.

- [ ] **Step 2: Fix anything precommit flags, then re-run**

Run: `mix precommit`
Expected: PASS.

- [ ] **Step 3: Commit any precommit fixes (if any)**

```bash
git add -A
git commit -m "Fix precommit issues for vocab textarea"
```
