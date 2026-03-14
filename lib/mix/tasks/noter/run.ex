defmodule Mix.Tasks.Noter.Run do
  use Mix.Task

  @shortdoc "Run the LLM pipeline to generate session notes"

  @moduledoc """
  Runs the full noter pipeline against a completed transcription.

      mix noter.run SESSION_DIR [options]

  Stages (run in order, each skippable with a flag):

    1. **review**  — Shows terms from merged SRT not in vocab.txt or corrections.toml.
                     Prompts to add corrections interactively, saves back to corrections.toml.

    2. **process** — Runs the LLM pipeline (chunk → extract → aggregate → write notes).
                     Per-chunk extraction results are cached in SQLite.

  The campaign context for this session is loaded from `SESSION_DIR/campaign-context.md`.
  If that file doesn't exist, it is generated automatically from the previous session's
  notes and context before the pipeline runs.

  ## Options

    --skip-review    Skip the corrections review step
    --skip-process   Skip the LLM pipeline step (review only)
    --model          OpenAI model to use (default: gpt-4.1)
    --chunk-minutes  Chunk window size in minutes (default: 10)

  ## Example

      mix noter.run ~/sessions/stonewalkers/session-3
      mix noter.run ~/sessions/stonewalkers/session-3 --skip-review
  """

  @switches [
    skip_review: :boolean,
    skip_process: :boolean,
    model: :string,
    chunk_minutes: :integer
  ]

  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    session_dir =
      case positional do
        [dir | _] -> dir
        [] -> Mix.raise("SESSION_DIR is required. Usage: mix noter.run SESSION_DIR")
      end

    session_dir = Path.expand(session_dir)

    campaign_dir =
      case Noter.Campaign.find_campaign_dir(Path.dirname(session_dir)) do
        {:ok, dir} ->
          IO.puts("Campaign dir: #{dir}")
          dir

        {:error, :not_found} ->
          Mix.raise(
            "Could not find campaign directory (no players.toml found walking up from #{session_dir})"
          )
      end

    Mix.Task.run("app.start")

    llm_opts =
      []
      |> maybe_put(:model, Keyword.get(opts, :model))
      |> maybe_put(:chunk_minutes, Keyword.get(opts, :chunk_minutes))

    unless Keyword.get(opts, :skip_review, false) do
      run_review(session_dir, campaign_dir)
    end

    unless Keyword.get(opts, :skip_process, false) do
      run_process(session_dir, campaign_dir, llm_opts)
    end
  end

  defp run_review(session_dir, campaign_dir) do
    IO.puts("\n--- Stage 1: Corrections Review ---")

    srt_path = Noter.Session.merged_srt_path(session_dir)

    if File.exists?(srt_path) do
      {:ok, vocab} = Noter.Campaign.load_vocab(Path.join(session_dir, "tracks"))
      {:ok, corrections} = Noter.Campaign.load_corrections(campaign_dir)

      unknown = Noter.Corrections.find_unknown_terms(srt_path, vocab, corrections)

      if unknown == [] do
        IO.puts("No unknown terms found.")
      else
        updated = Noter.Corrections.interactive_review(unknown, corrections)

        if updated != corrections do
          case Noter.Campaign.save_corrections(campaign_dir, updated) do
            :ok -> IO.puts("Corrections saved.")
            {:error, reason} -> IO.puts("Warning: could not save corrections: #{inspect(reason)}")
          end
        end
      end
    else
      IO.puts("No merged.srt found at #{srt_path}, skipping review.")
    end
  end

  defp run_process(session_dir, campaign_dir, llm_opts) do
    IO.puts("\n--- Stage 2: LLM Pipeline ---")

    case Noter.Pipeline.run(session_dir, campaign_dir, llm_opts) do
      {:ok, notes_path} ->
        IO.puts("\nSession notes written to:\n  #{notes_path}")

      {:error, reason} ->
        Mix.raise("Pipeline failed: #{reason}")
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
