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
         {:ok, transcript} <- Session.read_transcript(session_dir) do
      IO.puts(
        "Transcript loaded: #{length(transcript.segments)} segments, #{trunc(transcript.duration)}s"
      )

      chunks = Chunker.chunk(transcript, corrections, players, opts)
      IO.puts("Chunks: #{length(chunks)}")

      IO.puts("\nExtracting facts...")

      total = length(chunks)

      extraction_result =
        chunks
        |> Task.async_stream(
          fn chunk ->
            IO.write(
              "  chunk #{chunk.chunk_index}/#{total} (#{chunk.range_start}–#{chunk.range_end})... "
            )

            result = Extractor.extract(session_dir, context, chunk, opts)
            IO.puts("done")
            {chunk, result}
          end,
          max_concurrency: 3,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, {chunk, {:ok, facts}}}, {:ok, acc} -> {:cont, {:ok, [{chunk, facts} | acc]}}
          {:ok, {_chunk, {:error, reason}}}, _ -> {:halt, {:error, "Extraction failed: #{inspect(reason)}"}}
          {:exit, reason}, _ -> {:halt, {:error, "Task crashed: #{inspect(reason)}"}}
        end)

      with {:ok, fact_pairs_reversed} <- extraction_result do
        fact_pairs = Enum.reverse(fact_pairs_reversed)

        IO.puts("\nAggregating facts...")
        facts = Aggregator.aggregate(fact_pairs)

        IO.puts("Writing notes...")

        with {:ok, notes} <- Writer.write(context, facts, opts) do
          notes_path = Session.notes_path(session_dir)
          File.write!(notes_path, notes)
          IO.puts("Notes written to #{notes_path}")
          {:ok, notes_path}
        end
      end
    end
  end

  @doc """
  Generates the campaign context for `session_dir` from the previous session.
  Writes `campaign-context.md` into `session_dir`.
  """
  def generate_context(session_dir, opts \\ []) do
    session_dir = Path.expand(session_dir)

    case Session.find_previous_session(session_dir) do
      {:error, :no_previous_session} ->
        IO.puts("No previous session found — starting with empty context.")
        with :ok <- Context.write(session_dir, ""), do: {:ok, ""}

      {:ok, prev_dir} ->
        IO.puts("Using previous session: #{Path.basename(prev_dir)}")

        prev_context =
          case Context.read(prev_dir) do
            {:ok, c} -> c
            _ -> ""
          end

        prev_notes =
          case File.read(Session.notes_path(prev_dir)) do
            {:ok, n} -> n
            _ -> ""
          end

        if prev_context == "" and prev_notes == "" do
          IO.puts("Previous session has no context or notes — starting with empty context.")
          with :ok <- Context.write(session_dir, ""), do: {:ok, ""}
        else
          IO.puts("Generating campaign context from previous session...")

          with {:ok, context_md} <- Context.generate(prev_context, prev_notes, opts),
               :ok <- Context.write(session_dir, context_md) do
            IO.puts("Campaign context written to #{Session.context_path(session_dir)}")
            {:ok, context_md}
          end
        end
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
