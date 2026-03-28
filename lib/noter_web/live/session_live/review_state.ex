defmodule NoterWeb.SessionLive.ReviewState do
  @moduledoc """
  Review state management for session transcript review.

  Handles assign defaults, state computation, recomputation after edits,
  and speaker color assignment.
  """
  use Phoenix.VerifiedRoutes, endpoint: NoterWeb.Endpoint, router: NoterWeb.Router

  alias Noter.Sessions.Session
  alias Noter.Transcription.Transcript

  import NoterWeb.SessionHelpers
  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [stream: 3, stream: 4, stream_insert: 3]

  @speaker_palette ~w(badge-primary badge-secondary badge-accent badge-info badge-success badge-warning badge-error)

  def assign_review_state_defaults(socket, session) do
    reviewing? = session.status in ~w(reviewing noting done)

    socket
    |> assign(:reviewing?, reviewing?)
    |> assign(:review_loaded?, false)
    |> assign(:raw_turns, [])
    |> assign(:display_turns, [])
    |> assign(:replacements, %{})
    |> assign(:compiled_patterns, {%{}, []})
    |> assign(:edits, %{})
    |> assign(:match_counts, %{})
    |> assign(:speaker_colors, %{})
    |> assign(:editing_turn_id, nil)
    |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
    |> assign(:trimmed_audio_url, nil)
    |> assign(:done_stats, nil)
    |> assign(:read_only?, false)
    |> assign(:import_open?, false)
    |> stream(:turns, [])
  end

  def assign_review_state(socket, session) do
    if session.status in ~w(reviewing noting done) do
      raw_turns = Transcript.parse_turns(session.transcript_json)
      replacements = Session.replacements(session)
      compiled_patterns = Transcript.compile_patterns(replacements)
      edits = Session.edits(session)

      {replaced_turns, match_counts} =
        Transcript.apply_replacements(raw_turns, replacements, compiled_patterns)

      display_turns =
        replaced_turns
        |> Transcript.apply_edits(edits)
        |> stamp_editing_state()

      speakers = raw_turns |> Enum.map(& &1.speaker) |> Enum.uniq()
      speaker_colors = build_speaker_colors(speakers, socket.assigns.campaign)

      done_stats =
        if session.status in ~w(noting done) do
          compute_done_stats(session, raw_turns, replacements, edits)
        else
          nil
        end

      socket
      |> assign(:reviewing?, true)
      |> assign(:review_loaded?, true)
      |> assign(:raw_turns, raw_turns)
      |> assign(:display_turns, display_turns)
      |> assign(:replacements, replacements)
      |> assign(:compiled_patterns, compiled_patterns)
      |> assign(:edits, edits)
      |> assign(:match_counts, match_counts)
      |> assign(:speaker_colors, speaker_colors)
      |> assign(:editing_turn_id, nil)
      |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
      |> assign(:trimmed_audio_url, ~p"/sessions/#{session.id}/audio/trimmed")
      |> assign(:done_stats, done_stats)
      |> assign(:read_only?, session.status in ~w(noting done))
      |> assign(:import_open?, false)
      |> stream(:turns, display_turns, reset: true)
    else
      socket
      |> assign(:reviewing?, false)
      |> assign(:review_loaded?, true)
      |> assign(:raw_turns, [])
      |> assign(:display_turns, [])
      |> assign(:replacements, %{})
      |> assign(:compiled_patterns, {%{}, []})
      |> assign(:edits, %{})
      |> assign(:match_counts, %{})
      |> assign(:speaker_colors, %{})
      |> assign(:editing_turn_id, nil)
      |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
      |> assign(:trimmed_audio_url, nil)
      |> assign(:done_stats, nil)
      |> assign(:read_only?, false)
      |> assign(:import_open?, false)
    end
  end

  def recompute_review(socket, session) do
    raw_turns = socket.assigns.raw_turns
    replacements = Session.replacements(session)
    compiled_patterns = Transcript.compile_patterns(replacements)
    edits = Session.edits(session)

    {replaced_turns, match_counts} =
      Transcript.apply_replacements(raw_turns, replacements, compiled_patterns)

    new_turns =
      replaced_turns
      |> Transcript.apply_edits(edits)
      |> stamp_editing_state()

    prev_turns = socket.assigns.display_turns
    changed = diff_turns(prev_turns, new_turns)

    socket
    |> assign(:session, session)
    |> assign(:replacements, replacements)
    |> assign(:compiled_patterns, compiled_patterns)
    |> assign(:edits, edits)
    |> assign(:match_counts, match_counts)
    |> assign(:display_turns, new_turns)
    |> assign(:editing_turn_id, nil)
    |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
    |> then(fn socket ->
      Enum.reduce(changed, socket, fn turn, sock ->
        stream_insert(sock, :turns, turn)
      end)
    end)
  end

  def find_display_turn(socket, turn_id) do
    raw_turn = Enum.find(socket.assigns.raw_turns, &(&1.id == turn_id))

    {[replaced], _counts} =
      Transcript.apply_replacements(
        [raw_turn],
        socket.assigns.replacements,
        socket.assigns.compiled_patterns
      )

    [replaced]
    |> Transcript.apply_edits(socket.assigns.edits)
    |> hd()
    |> Map.merge(%{editing?: false, edit_form: nil})
  end

  def compute_done_stats(session, raw_turns, replacements, edits) do
    duration =
      if session.trim_start_seconds && session.trim_end_seconds do
        format_time(session.trim_end_seconds - session.trim_start_seconds)
      else
        format_time(session.duration_seconds || 0)
      end

    speakers = raw_turns |> Enum.map(& &1.speaker) |> Enum.uniq()

    %{
      duration: duration,
      speaker_count: length(speakers),
      turn_count: length(raw_turns),
      replacement_count: map_size(replacements),
      edit_count: map_size(edits)
    }
  end

  def build_speaker_colors(speakers, campaign) do
    all_characters =
      campaign.player_map
      |> Map.values()
      |> Enum.sort()

    color_index =
      all_characters
      |> Enum.with_index()
      |> Map.new(fn {name, idx} ->
        {name, Enum.at(@speaker_palette, rem(idx, length(@speaker_palette)))}
      end)

    next_idx = map_size(color_index)

    {colors, _} =
      Enum.reduce(speakers, {color_index, next_idx}, fn speaker, {acc, idx} ->
        if Map.has_key?(acc, speaker) do
          {acc, idx}
        else
          color = Enum.at(@speaker_palette, rem(idx, length(@speaker_palette)))
          {Map.put(acc, speaker, color), idx + 1}
        end
      end)

    Map.take(colors, speakers)
  end

  defp diff_turns(prev, next) do
    prev_map =
      Map.new(prev, fn t ->
        {t.id, {t.display_words, Map.get(t, :edited?, false), Map.get(t, :deleted?, false)}}
      end)

    Enum.filter(next, fn turn ->
      prev_val = Map.get(prev_map, turn.id)
      curr_val = {turn.display_words, turn.edited?, turn.deleted?}
      prev_val != curr_val
    end)
  end

  defp stamp_editing_state(turns) do
    Enum.map(turns, &Map.merge(&1, %{editing?: false, edit_form: nil}))
  end
end
