# Session-Level Player Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Discord→character player map a per-session snapshot that freezes at session creation, so a player-character death/replacement is handled cleanly without disturbing history or the normal workflow.

**Architecture:** Add `sessions.player_map` (a `:map`). New sessions inherit their map from the most recent prior session in the campaign, falling back to `campaign.player_map` (now just a "seed" for the first session), falling back to `%{}`. Prep and speaker-coloring read the session's own map instead of the live campaign map. The campaign-level map editor becomes editable only before the first session exists; each session gets an Advanced panel to hand-edit its own map.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, daisyUI/Tailwind.

## Global Constraints

- Elixir lists have no index access; use `Enum.at`/pattern matching.
- Never use map-access syntax on structs; access fields directly.
- Fields set programmatically must NOT be in a `cast` list — set them on the struct directly. `sessions.player_map` is set programmatically at creation (Task 3) but is user-editable via a dedicated changeset in the session editor (Task 7).
- Migrations: generate with `mix ecto.gen.migration <name>` so timestamps/conventions are correct.
- Run `mix precommit` before the final commit and fix all issues.
- Follow existing LiveView patterns already in `campaign_live/show.ex` (daisyUI `collapse`, `.PlayerInput` colocated hook, row-based editing).
- Commit messages and PR body contain NO attribution/`Co-Authored-By`/"Generated with" trailers.
- Bump `mix.exs` version (currently `1.6.0`) once, as part of the final task — this is a minor feature → `1.7.0`.

---

### Task 1: Migration — add `sessions.player_map` and backfill

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_player_map_to_sessions.exs` (via generator)

**Interfaces:**
- Produces: a `player_map` `:map` column on `sessions`, default `%{}`, not null, backfilled from each session's campaign's `player_map`. `campaigns.player_map` is left in place.

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration add_player_map_to_sessions`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Noter.Repo.Migrations.AddPlayerMapToSessions do
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :player_map, :map, null: false, default: %{}
    end

    flush()

    # Freeze the current campaign roster onto every existing session.
    # Before this change ships, all existing sessions belong to the
    # current (pre-swap) roster, so this backfill is correct.
    execute("""
    UPDATE sessions
    SET player_map = campaigns.player_map
    FROM campaigns
    WHERE sessions.campaign_id = campaigns.id
    """)
  end

  def down do
    alter table(:sessions) do
      remove :player_map
    end
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `mix ecto.migrate`
Expected: migration applies cleanly; `sessions` now has `player_map`.

- [ ] **Step 4: Verify the backfill in a rollback/redo cycle**

Run: `mix ecto.rollback && mix ecto.migrate`
Expected: both succeed without error.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations
git commit -m "feat: add player_map column to sessions with backfill"
```

---

### Task 2: Session schema — add field and edit changeset

**Files:**
- Modify: `lib/noter/sessions/session.ex`
- Test: `test/noter/sessions_test.exs` (create if absent)

**Interfaces:**
- Produces: `Session` schema field `player_map` (`:map`, default `%{}`); `Session.player_map_changeset/2` casting only `:player_map`.

- [ ] **Step 1: Write the failing test**

Add to `test/noter/sessions_test.exs` (create the file with the standard header if it does not exist):

```elixir
defmodule Noter.SessionsTest do
  use Noter.DataCase, async: true

  alias Noter.Sessions
  alias Noter.Sessions.Session

  describe "player_map_changeset/2" do
    test "casts player_map" do
      changeset =
        Session.player_map_changeset(%Session{}, %{
          "player_map" => %{"alice" => "Thorin"}
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :player_map) == %{"alice" => "Thorin"}
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/noter/sessions_test.exs`
Expected: FAIL — `player_map_changeset/2` undefined (and/or field missing).

- [ ] **Step 3: Add the field and changeset**

In `lib/noter/sessions/session.ex`, add the field inside `schema "sessions" do` (next to the other fields):

```elixir
    field :player_map, :map, default: %{}
```

And add a new changeset function alongside the others:

```elixir
  def player_map_changeset(session, attrs) do
    cast(session, attrs, [:player_map])
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/noter/sessions_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/noter/sessions/session.ex test/noter/sessions_test.exs
git commit -m "feat: add player_map field and changeset to Session"
```

---

### Task 3: Inheritance — seed `player_map` in `create_session/2`

**Files:**
- Modify: `lib/noter/sessions.ex`
- Test: `test/noter/sessions_test.exs`

**Interfaces:**
- Consumes: `Session.player_map` field (Task 2), `campaign.player_map`.
- Produces: `create_session/2` sets the new session's `player_map` from the most recent prior session in the campaign, else `campaign.player_map`, else `%{}`. Also `Sessions.update_session_player_map/2` for later tasks.

- [ ] **Step 1: Write the failing tests**

Add to `test/noter/sessions_test.exs`:

```elixir
  describe "create_session/2 player_map inheritance" do
    setup do
      {:ok, campaign} =
        Noter.Campaigns.create_campaign(%{
          "name" => "Camp #{System.unique_integer([:positive])}",
          "player_map" => %{"alice" => "Thorin"}
        })

      %{campaign: campaign}
    end

    test "first session inherits from campaign seed", %{campaign: campaign} do
      {:ok, session} = Sessions.create_session(campaign, %{"name" => "S1"})
      assert session.player_map == %{"alice" => "Thorin"}
    end

    test "later session inherits from the most recent prior session", %{campaign: campaign} do
      {:ok, s1} = Sessions.create_session(campaign, %{"name" => "S1"})
      {:ok, s1} = Sessions.update_session_player_map(s1, %{"alice" => "Gandalf"})
      assert s1.player_map == %{"alice" => "Gandalf"}

      {:ok, s2} = Sessions.create_session(campaign, %{"name" => "S2"})
      assert s2.player_map == %{"alice" => "Gandalf"}
    end

    test "editing a prior session does not change an already-created later session",
         %{campaign: campaign} do
      {:ok, s1} = Sessions.create_session(campaign, %{"name" => "S1"})
      {:ok, s2} = Sessions.create_session(campaign, %{"name" => "S2"})

      {:ok, _s1} = Sessions.update_session_player_map(s1, %{"alice" => "Gandalf"})

      reloaded = Sessions.get_session!(s2.id)
      assert reloaded.player_map == %{"alice" => "Thorin"}
    end

    test "first session with empty campaign seed gets empty map" do
      {:ok, campaign} =
        Noter.Campaigns.create_campaign(%{"name" => "Empty #{System.unique_integer([:positive])}"})

      {:ok, session} = Sessions.create_session(campaign, %{"name" => "S1"})
      assert session.player_map == %{}
    end
  end
```

Note: confirm `Sessions.get_session!/1` exists (it does — `lib/noter/sessions.ex:60`). Confirm `Campaigns.create_campaign/1` accepts `player_map` in its changeset (it does — `campaign.ex` casts `:player_map`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/noter/sessions_test.exs`
Expected: FAIL — inheritance not implemented / `update_session_player_map/2` undefined.

- [ ] **Step 3: Implement inheritance and the update helper**

Ensure `import Ecto.Query` is present at the top of `lib/noter/sessions.ex` (add it if missing). Replace `create_session/2` (`lib/noter/sessions.ex:63`) with:

```elixir
  def create_session(%Noter.Campaigns.Campaign{} = campaign, attrs) do
    %Session{campaign_id: campaign.id, player_map: seed_player_map(campaign)}
    |> Session.changeset(attrs)
    |> Repo.insert()
    |> broadcast_session_created()
  end

  defp seed_player_map(%Noter.Campaigns.Campaign{} = campaign) do
    case latest_session(campaign.id) do
      %Session{player_map: pm} -> pm || %{}
      nil -> campaign.player_map || %{}
    end
  end

  defp latest_session(campaign_id) do
    Session
    |> where([s], s.campaign_id == ^campaign_id)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end
```

Add the update helper near `update_session/2`:

```elixir
  def update_session_player_map(%Session{} = session, player_map) do
    session
    |> Session.player_map_changeset(%{player_map: player_map})
    |> Repo.update()
  end
```

Because `player_map` is set on the struct before `Session.changeset/2` (which does not cast it), the seeded value persists on insert without being user-castable.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/noter/sessions_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/noter/sessions.ex test/noter/sessions_test.exs
git commit -m "feat: seed session player_map from prior session or campaign"
```

---

### Task 4: Prep reads the session's own map

**Files:**
- Modify: `lib/noter/uploads.ex` (lines 59 and 163)

**Interfaces:**
- Consumes: `session.player_map` (Task 2/3).
- Produces: prep renaming uses `session.player_map` rather than the live campaign map.

- [ ] **Step 1: Update the two prep call sites**

At `lib/noter/uploads.ex:59`, change:

```elixir
      {:ok, renamed} = Prep.rename_flacs(extracted_dir, renamed_dir, campaign.player_map)
```

to:

```elixir
      {:ok, renamed} = Prep.rename_flacs(extracted_dir, renamed_dir, session.player_map)
```

Confirm `session` is in scope in that function (`process_uploads/5` receives it). If the function currently only receives `campaign`, pass `session` through — check the `process_uploads` head and its caller `Noter.Jobs.run_upload_processing_task/4` (`lib/noter/jobs.ex:206`), which already passes `session`.

At `lib/noter/uploads.ex:163`, change:

```elixir
        character_name = Prep.resolve_character(basename, session.campaign.player_map)
```

to:

```elixir
        character_name = Prep.resolve_character(basename, session.player_map)
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings. If `session.campaign` was only preloaded for the player map at line 163, the preload may now be unused — leave other uses intact; only remove a preload if nothing else needs it (verify with a grep for `session.campaign` in that function).

- [ ] **Step 3: Run the existing prep/upload tests**

Run: `mix test test/noter/uploads_test.exs test/noter/prep_test.exs`
Expected: PASS (or "no such file" — if these test files don't exist, skip; do not create speculative tests here).

- [ ] **Step 4: Commit**

```bash
git add lib/noter/uploads.ex
git commit -m "feat: prep uses session player_map instead of campaign map"
```

---

### Task 5: Speaker colors use the session's map

**Files:**
- Modify: `lib/noter_web/live/session_live/review_state.ex` (lines 57 and 171)
- Test: `test/noter_web/live/session_live/review_state_test.exs` (create if absent)

**Interfaces:**
- Consumes: `session.player_map`.
- Produces: `build_speaker_colors/2` takes `(speakers, session)` and colors from `session.player_map`.

- [ ] **Step 1: Write the failing test**

Create/append `test/noter_web/live/session_live/review_state_test.exs`:

```elixir
defmodule NoterWeb.SessionLive.ReviewStateTest do
  use ExUnit.Case, async: true

  alias Noter.Sessions.Session
  alias NoterWeb.SessionLive.ReviewState

  test "build_speaker_colors sources characters from session.player_map" do
    session = %Session{player_map: %{"alice" => "Thorin", "bob" => "Gandalf"}}
    colors = ReviewState.build_speaker_colors(["Thorin", "Gandalf"], session)

    assert Map.has_key?(colors, "Thorin")
    assert Map.has_key?(colors, "Gandalf")
    assert colors["Thorin"] != nil
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/noter_web/live/session_live/review_state_test.exs`
Expected: FAIL — `build_speaker_colors/2` expects a campaign.

- [ ] **Step 3: Update the function and its call site**

At `lib/noter_web/live/session_live/review_state.ex:171`, change the head and body:

```elixir
  def build_speaker_colors(speakers, %Noter.Sessions.Session{} = session) do
    all_characters =
      session.player_map
      |> Map.values()
      |> Enum.sort()
```

(leave the rest of the function body unchanged).

At `lib/noter_web/live/session_live/review_state.ex:57`, change:

```elixir
      speaker_colors = build_speaker_colors(speakers, socket.assigns.campaign)
```

to:

```elixir
      speaker_colors = build_speaker_colors(speakers, session)
```

(`session` is the second argument of `assign_review_state/2`, so it is in scope.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/noter_web/live/session_live/review_state_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/noter_web/live/session_live/review_state.ex test/noter_web/live/session_live/review_state_test.exs
git commit -m "feat: speaker colors use session player_map"
```

---

### Task 6: Campaign map editor becomes editable only before the first session

**Files:**
- Modify: `lib/noter_web/live/campaign_live/show.ex` (Player Map card, ~lines 99–238)
- Test: `test/noter_web/live/campaign_live/show_test.exs` (append; create if absent)

**Interfaces:**
- Consumes: existing `@sessions_empty?` assign (`lib/noter_web/live/campaign_live/show.ex:26`, kept current by the `{:session_created, ...}` handler at line 455).
- Produces: campaign Player Map is hand-editable only when `@sessions_empty?`; otherwise read-only.

- [ ] **Step 1: Write the failing tests**

Append to `test/noter_web/live/campaign_live/show_test.exs` (create with standard `NoterWeb.ConnCase` header if absent):

```elixir
  describe "campaign player map editability" do
    test "shows Edit button when campaign has no sessions", %{conn: conn} do
      {:ok, campaign} =
        Noter.Campaigns.create_campaign(%{"name" => "NoSessions #{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}")
      assert has_element?(view, "button[phx-click='edit_player_map']")
    end

    test "hides Edit button once a session exists", %{conn: conn} do
      {:ok, campaign} =
        Noter.Campaigns.create_campaign(%{
          "name" => "WithSession #{System.unique_integer([:positive])}",
          "player_map" => %{"alice" => "Thorin"}
        })

      {:ok, _session} = Noter.Sessions.create_session(campaign, %{"name" => "S1"})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}")
      refute has_element?(view, "button[phx-click='edit_player_map']")
    end
  end
```

Add `import Phoenix.LiveViewTest` and `import Phoenix.VerifiedRoutes`/`use NoterWeb.ConnCase` as the file's existing header dictates.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/noter_web/live/campaign_live/show_test.exs`
Expected: the "hides Edit button once a session exists" test FAILS (button still shown).

- [ ] **Step 3: Gate the Edit button on `@sessions_empty?`**

In `lib/noter_web/live/campaign_live/show.ex`, find the Edit button (~line 109):

```elixir
                  <%= if !@editing_player_map do %>
                    <button type="button" phx-click="edit_player_map" class="btn btn-sm btn-ghost">
                      <.icon name="hero-pencil-square" class="size-4" /> Edit
                    </button>
                  <% end %>
```

Change the condition to also require an empty campaign:

```elixir
                  <button
                    :if={!@editing_player_map and @sessions_empty?}
                    type="button"
                    phx-click="edit_player_map"
                    class="btn btn-sm btn-ghost"
                  >
                    <.icon name="hero-pencil-square" class="size-4" /> Edit
                  </button>
```

Also update the card description (~line 105) to reflect the seed role:

```elixir
                    <p class="text-sm text-base-content/60">
                      Starting roster for this campaign. Editable until the first session is created; each session keeps its own copy.
                    </p>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/noter_web/live/campaign_live/show_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/noter_web/live/campaign_live/show.ex test/noter_web/live/campaign_live/show_test.exs
git commit -m "feat: lock campaign player map after first session"
```

---

### Task 7: Session Advanced panel with a per-session player-map editor

**Files:**
- Modify: `lib/noter_web/live/session_live/show.ex` (mount assigns, render, handle_events)
- Test: `test/noter_web/live/session_live/show_test.exs` (append; create if absent)

**Interfaces:**
- Consumes: `Sessions.update_session_player_map/2` (Task 3), `session.player_map`.
- Produces: an Advanced collapsible panel on the session page with an editable player-map table that persists to `session.player_map`.

- [ ] **Step 1: Write the failing test**

Append to `test/noter_web/live/session_live/show_test.exs`:

```elixir
  describe "session player map editor" do
    setup %{conn: conn} do
      {:ok, campaign} =
        Noter.Campaigns.create_campaign(%{
          "name" => "PM #{System.unique_integer([:positive])}",
          "player_map" => %{"alice" => "Thorin"}
        })

      {:ok, session} = Noter.Sessions.create_session(campaign, %{"name" => "S1"})
      %{conn: conn, campaign: campaign, session: session}
    end

    test "renders the advanced player map panel", %{conn: conn, campaign: campaign, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      assert has_element?(view, "#session-advanced")
    end

    test "saving updates the session player_map", %{conn: conn, campaign: campaign, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      view |> element("button[phx-click='edit_session_player_map']") |> render_click()

      view
      |> form("#session-player-map-form", %{
        "player" => %{"0" => %{"discord" => "alice", "character" => "Gandalf"}}
      })
      |> render_submit()

      reloaded = Noter.Sessions.get_session!(session.id)
      assert reloaded.player_map == %{"alice" => "Gandalf"}
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/noter_web/live/session_live/show_test.exs`
Expected: FAIL — no `#session-advanced` element.

- [ ] **Step 3: Add mount assigns**

In `lib/noter_web/live/session_live/show.ex` `mount/3`, add these assigns (after `:session` is assigned, ~line 37):

```elixir
      |> assign(:advanced_open?, false)
      |> assign(:editing_session_player_map, false)
      |> assign(:session_player_rows, session_player_map_to_rows(session.player_map))
```

- [ ] **Step 4: Add the Advanced panel to the template**

In `render/1`, just before the closing `</Layouts.app>` (~line 930, inside the outer content div), add a collapsible panel mirroring the campaign settings pattern:

```elixir
        <%!-- Advanced (collapsible) --%>
        <div class="collapse collapse-arrow bg-base-200 shadow-sm" id="session-advanced">
          <input type="checkbox" checked={@advanced_open?} phx-click="toggle_advanced" />
          <div class="collapse-title font-medium flex items-center gap-2">
            <.icon name="hero-cog-6-tooth" class="size-5" /> Advanced
          </div>
          <div class="collapse-content space-y-6">
            <div class="card bg-base-100 border border-base-content/5">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="card-title text-sm">Player Map</h3>
                    <p class="text-sm text-base-content/60">
                      Discord → character names used when (re)processing this session.
                    </p>
                  </div>
                  <button
                    :if={!@editing_session_player_map}
                    type="button"
                    phx-click="edit_session_player_map"
                    class="btn btn-sm btn-ghost"
                  >
                    <.icon name="hero-pencil-square" class="size-4" /> Edit
                  </button>
                </div>

                <%= if @editing_session_player_map do %>
                  <.form
                    for={%{}}
                    id="session-player-map-form"
                    phx-change="update_session_players"
                    phx-submit="save_session_player_map"
                  >
                    <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-200 mt-2">
                      <table class="table" id="session-player-map-table">
                        <thead>
                          <tr>
                            <th>Discord Name</th>
                            <th>Character Name</th>
                            <th></th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr :if={@session_player_rows == []}>
                            <td colspan="3" class="text-center text-base-content/50 py-6">
                              No players added yet.
                            </td>
                          </tr>
                          <tr :for={row <- @session_player_rows} id={"session-player-row-#{row.id}"}>
                            <td>
                              <input
                                type="text"
                                value={row.discord}
                                name={"player[#{row.id}][discord]"}
                                placeholder="Discord username"
                                class="input input-bordered input-sm w-full"
                                id={"session-player-discord-#{row.id}"}
                              />
                            </td>
                            <td>
                              <input
                                type="text"
                                value={row.character}
                                name={"player[#{row.id}][character]"}
                                placeholder="Character name"
                                class="input input-bordered input-sm w-full"
                                id={"session-player-character-#{row.id}"}
                              />
                            </td>
                            <td>
                              <button
                                type="button"
                                phx-click="remove_session_player"
                                phx-value-id={row.id}
                                class="btn btn-ghost btn-sm btn-square text-error"
                              >
                                <.icon name="hero-x-mark" class="size-4" />
                              </button>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>

                    <div class="flex gap-2 mt-2">
                      <button
                        type="button"
                        phx-click="add_session_player"
                        class="btn btn-sm btn-outline"
                      >
                        <.icon name="hero-plus" class="size-4" /> Add Player
                      </button>
                      <.button type="submit" class="btn btn-sm btn-primary">Save</.button>
                      <button
                        type="button"
                        phx-click="cancel_edit_session_player_map"
                        class="btn btn-sm btn-ghost"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                <% else %>
                  <div :if={@session.player_map == %{}} class="text-center py-4 text-base-content/50">
                    No players mapped for this session.
                  </div>
                  <div
                    :if={@session.player_map != %{}}
                    class="overflow-x-auto rounded-box border border-base-content/5 bg-base-200 mt-2"
                  >
                    <table class="table">
                      <thead>
                        <tr>
                          <th>Discord Name</th>
                          <th>Character Name</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={{discord, character} <- @session.player_map}>
                          <td class="font-mono">{discord}</td>
                          <td>{character}</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
```

- [ ] **Step 5: Add the handle_event clauses and the private row helper**

Add these `handle_event/3` clauses in `lib/noter_web/live/session_live/show.ex` (alongside the other handlers):

```elixir
  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :advanced_open?, !socket.assigns.advanced_open?)}
  end

  def handle_event("edit_session_player_map", _params, socket) do
    {:noreply, assign(socket, editing_session_player_map: true, advanced_open?: true)}
  end

  def handle_event("cancel_edit_session_player_map", _params, socket) do
    rows = session_player_map_to_rows(socket.assigns.session.player_map)

    {:noreply,
     socket
     |> assign(:editing_session_player_map, false)
     |> assign(:session_player_rows, rows)
     |> assign(:advanced_open?, true)}
  end

  def handle_event("update_session_players", %{"player" => player_params}, socket) do
    rows =
      Enum.map(socket.assigns.session_player_rows, fn row ->
        case Map.get(player_params, to_string(row.id)) do
          %{"discord" => discord, "character" => character} ->
            %{row | discord: discord, character: character}

          _ ->
            row
        end
      end)

    {:noreply, assign(socket, session_player_rows: rows, advanced_open?: true)}
  end

  def handle_event("update_session_players", _params, socket) do
    {:noreply, assign(socket, advanced_open?: true)}
  end

  def handle_event("add_session_player", _params, socket) do
    new_row = %{id: System.unique_integer([:positive]), discord: "", character: ""}

    {:noreply,
     assign(socket,
       session_player_rows: socket.assigns.session_player_rows ++ [new_row],
       advanced_open?: true
     )}
  end

  def handle_event("remove_session_player", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.session_player_rows, &(&1.id == id))
    {:noreply, assign(socket, session_player_rows: rows, advanced_open?: true)}
  end

  def handle_event("save_session_player_map", %{"player" => player_params}, socket) do
    entries =
      player_params
      |> Map.values()
      |> Enum.reject(fn %{"discord" => d, "character" => c} -> d == "" and c == "" end)

    discord_names = Enum.map(entries, & &1["discord"])
    duplicates = discord_names -- Enum.uniq(discord_names)

    if duplicates != [] do
      {:noreply,
       socket
       |> put_flash(:error, "Duplicate Discord name: #{Enum.uniq(duplicates) |> Enum.join(", ")}")
       |> assign(:advanced_open?, true)}
    else
      player_map = Map.new(entries, fn %{"discord" => d, "character" => c} -> {d, c} end)
      save_session_player_map(socket, player_map)
    end
  end

  def handle_event("save_session_player_map", _params, socket) do
    save_session_player_map(socket, %{})
  end
```

Add these private helpers:

```elixir
  defp save_session_player_map(socket, player_map) do
    case Sessions.update_session_player_map(socket.assigns.session, player_map) do
      {:ok, session} ->
        {:noreply,
         socket
         |> put_flash(:info, "Player map saved.")
         |> assign(:session, session)
         |> assign(:session_player_rows, session_player_map_to_rows(session.player_map))
         |> assign(:editing_session_player_map, false)
         |> assign(:advanced_open?, true)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save player map.")
         |> assign(:advanced_open?, true)}
    end
  end

  defp session_player_map_to_rows(player_map) do
    Enum.map(player_map, fn {discord, character} ->
      %{id: System.unique_integer([:positive]), discord: discord, character: character}
    end)
  end
```

Confirm `alias Noter.Sessions` is present at the top of the module (it is — used as `Sessions.get_session_by_slug!`).

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/noter_web/live/session_live/show_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/noter_web/live/session_live/show.ex test/noter_web/live/session_live/show_test.exs
git commit -m "feat: per-session player map editor in Advanced panel"
```

---

### Task 8: Full verification, version bump, and PR

**Files:**
- Modify: `mix.exs` (version bump)

- [ ] **Step 1: Bump the version**

In `mix.exs`, change `version: "1.6.0"` to `version: "1.7.0"`.

- [ ] **Step 2: Run the full precommit suite**

Run: `mix precommit`
Expected: compiles with no warnings, formatting clean, all tests pass. Fix anything that fails.

- [ ] **Step 3: Commit the version bump**

```bash
git add mix.exs
git commit -m "chore: bump version to 1.7.0"
```

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin session-level-player-map
gh pr create --title "Session-level player map (character swaps)" --body "<summary + test plan>"
```

The PR body must contain NO attribution trailers.

---

## Self-Review

**Spec coverage:**
- Data model (`sessions.player_map`, keep `campaigns.player_map`) → Tasks 1, 2. ✓
- Inheritance at creation (prior session → campaign seed → `%{}`) → Task 3. ✓
- Prep reads session map (`uploads.ex:59`, `:163`) → Task 4. ✓
- Speaker colors use session map → Task 5. ✓
- Campaign editor editable only before first session; read-only after → Task 6. ✓
- Session Advanced panel editor (only way a session's map changes by hand) → Task 7. ✓
- Migration ordered, backfill from campaign, do NOT drop campaign column → Task 1. ✓
- "Editing a prior session doesn't change a later created session" → Task 3 test. ✓

**Placeholder scan:** No TBD/TODO; all code shown; the only `<summary + test plan>` placeholder is the PR body, filled at execution. ✓

**Type consistency:** `player_map` (`:map`) consistent across schema, changeset, inheritance, prep, colors, UI. `update_session_player_map/2` defined in Task 3, consumed in Task 7. `session_player_map_to_rows/1`, `save_session_player_map/2` defined and used within Task 7. `@sessions_empty?` reused from existing code in Task 6. ✓
