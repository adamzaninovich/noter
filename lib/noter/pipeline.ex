defmodule Noter.Pipeline do
  @moduledoc """
  Orchestrates the full LLM pipeline for a session:
    1. Load context from previous session (or use provided context)
    2. Read and chunk the merged transcript
    3. Extract facts from each chunk (with SQLite caching)
    4. Aggregate facts across chunks
    5. Write session notes
  """

  alias Noter.{Aggregator, Campaign, Chunker, Context, Extractor, Session, Writer}

  @doc """
  Runs the full pipeline for a session directory.

  Options:
    - `:model` - LLM model to use
    - `:chunk_minutes` - chunk window size (default: 10)
    - `:skip_context` - if true, use empty context (default: false)
  """
  def run(session_dir, campaign_dir, opts \\ []) do
    session_dir = Path.expand(session_dir)

    IO.puts("\n=== noter pipeline ===")
    IO.puts("Session: #{session_dir}")

    with :ok <- Session.validate_for_run(session_dir),
         {:ok, corrections} <- Campaign.load_corrections(campaign_dir),
         {:ok, players} <- Campaign.load_players(campaign_dir),
         {:ok, context} <- load_context(session_dir, opts),
         {:ok, transcript} <- Session.read_transcript(session_dir),
         chunks = Chunker.chunk(transcript, corrections, players, opts),
         _ = IO.puts("Transcript loaded: #{length(transcript.segments)} segments, #{trunc(transcript.duration)}s"),
         _ = IO.puts("Chunks: #{length(chunks)}\n\nExtracting facts..."),
         {:ok, fact_pairs} <- extract_all(chunks, session_dir, context, opts),
         _ = IO.puts("\nAggregating facts..."),
         facts = Aggregator.aggregate(fact_pairs),
         _ = IO.puts("Writing notes..."),
         {:ok, notes} <- Writer.write(context, facts, opts) do
      notes_path = Session.notes_path(session_dir)

      case File.write(notes_path, notes) do
        :ok ->
          IO.puts("Notes written to #{notes_path}")
          {:ok, notes_path}

        {:error, reason} ->
          {:error, "Failed to write notes to #{notes_path}: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  Generates the campaign context for `session_dir` from the previous session.
  Writes `campaign-context.md` into `session_dir`.
  """
  def generate_context(session_dir, opts \\ []) do
    session_dir = Path.expand(session_dir)

    with {:ok, prev_dir} <- Session.find_previous_session(session_dir),
         _ = IO.puts("Using previous session: #{Path.basename(prev_dir)}"),
         prev_context = read_or_default(Context.read(prev_dir)),
         prev_notes = read_or_default(File.read(Session.notes_path(prev_dir))),
         {:has_input, true} <- {:has_input, prev_context != "" || prev_notes != ""},
         _ = IO.puts("Generating campaign context from previous session..."),
         {:ok, context_md} <- Context.generate(prev_context, prev_notes, opts),
         :ok <- Context.write(session_dir, context_md) do
      IO.puts("Campaign context written to #{Session.context_path(session_dir)}")
      {:ok, context_md}
    else
      {:error, :no_previous_session} ->
        IO.puts("No previous session found — starting with empty context.")
        write_empty_context(session_dir)

      {:has_input, false} ->
        IO.puts("Previous session has no context or notes — starting with empty context.")
        write_empty_context(session_dir)

      error ->
        error
    end
  end

  defp write_empty_context(session_dir) do
    with :ok <- Context.write(session_dir, ""), do: {:ok, ""}
  end

  defp read_or_default({:ok, content}), do: content
  defp read_or_default(_), do: ""

  defp extract_all(chunks, session_dir, context, opts) do
    total = length(chunks)

    result =
      chunks
      |> Task.async_stream(
        fn chunk ->
          result = Extractor.extract(session_dir, context, chunk, opts)
          {chunk, result}
        end,
        max_concurrency: 3,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {chunk, {:ok, facts}}}, {:ok, acc} ->
          IO.puts("  chunk #{chunk.chunk_index}/#{total} (#{chunk.range_start}–#{chunk.range_end})... done")
          {:cont, {:ok, [{chunk, facts} | acc]}}

        {:ok, {chunk, {:error, reason}}}, _ ->
          IO.puts("  chunk #{chunk.chunk_index}/#{total} (#{chunk.range_start}–#{chunk.range_end})... failed")
          {:halt, {:error, "Extraction failed: #{inspect(reason)}"}}

        {:exit, reason}, _ ->
          {:halt, {:error, "Task crashed: #{inspect(reason)}"}}
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp load_context(session_dir, opts) do
    if Keyword.get(opts, :skip_context, false) do
      {:ok, ""}
    else
      context_path = Session.context_path(session_dir)

      if File.exists?(context_path) do
        File.read(context_path)
      else
        IO.puts("No campaign-context.md found — generating from previous session...")
        generate_context(session_dir, opts)
      end
    end
  end
end
