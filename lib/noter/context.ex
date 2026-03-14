defmodule Noter.Context do
  @moduledoc """
  Generates and manages per-session campaign context documents.

  Each session has its own `campaign-context.md` in the session directory.
  When starting a new session, this context is generated from the *previous*
  session's notes and context, rather than maintaining a single shared file.

  Flow for session N:
    1. Look for session N-1's context (`campaign-context.md`) and notes (`session-N-1-notes.md`)
    2. Feed them to the LLM to produce session N's `campaign-context.md`
    3. This context is then used as input to the fact extractor and note writer
  """

  alias Noter.LLM

  @system_message """
  You maintain a living campaign context document for a tabletop RPG campaign.

  Your job is to update the context based on the latest session notes.

  Rules:
  - Preserve all still-relevant information from the existing context.
  - Incorporate new facts, NPCs, locations, and plot threads from the session notes.
  - Remove or update information that has been resolved or superseded.
  - Keep the document concise, organized, and authoritative.
  - Write in present tense where appropriate.
  - Do not invent information not present in either document.

  Output only the updated context document in Markdown.
  No commentary or explanation.
  """

  @doc """
  Generates a campaign context document for a session by combining the
  previous session's context and notes.

  Returns `{:ok, context_markdown}` or `{:error, reason}`.
  """
  def generate(prev_context, prev_notes, opts \\ []) do
    user_msg = """
    Existing campaign context:
    #{prev_context}

    Latest session notes:
    #{prev_notes}

    Update the campaign context to reflect what happened in this session.
    """

    messages = [
      %{"role" => "system", "content" => @system_message},
      %{"role" => "user", "content" => user_msg}
    ]

    LLM.chat(messages, opts)
  end

  @doc """
  Reads the context file for a session directory.
  Returns `{:ok, content}` or `{:ok, ""}` if not present.
  """
  def read(session_dir) do
    path = Noter.Session.context_path(session_dir)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes the context markdown to the session directory.
  """
  def write(session_dir, markdown) do
    path = Noter.Session.context_path(session_dir)
    File.write(path, markdown)
  end
end
