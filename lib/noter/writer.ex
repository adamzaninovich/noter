defmodule Noter.Writer do
  @moduledoc """
  Writes final session notes from aggregated facts via the LLM.
  """

  alias Noter.LLM

  @system_message """
  You are a careful session chronicler for a tabletop RPG.

  Your job is to transform structured session facts into clear, natural player notes.

  ACCURACY
  - Use only the provided facts.
  - Do not invent events.
  - Do not infer motives.
  - Do not add missing context.
  - If something is not in the facts, it does not exist.

  STYLE
  - Write like a player's session recap, not a report.
  - Use natural language.
  - Be concise but complete.
  - Avoid repetition.
  - Do not mention JSON, data structures, or extraction.

  INTERPRETATION
  - Do not reinterpret facts.
  - Do not merge separate events.
  - Do not change wording meaningfully.
  - You may rephrase for readability only.

  OMISSIONS
  - If a section has no information, omit it entirely.
  - Do not write placeholders like "None."

  ORDERING
  - Preserve chronological order when describing events.

  FAILSAFE
  If the facts are empty or missing, output exactly:
  "No session events detected."

  OUTPUT
  Return only Markdown notes.
  No commentary.
  No explanation.
  No metadata.
  """

  @doc """
  Generates Markdown session notes from aggregated facts.

  `context` is the campaign context string (may be empty).
  `facts` is the map returned by `Noter.Aggregator.aggregate/1`.
  """
  def write(context, facts, opts \\ []) do
    user_msg = """
    Context (authoritative):
    #{context}

    Extracted session facts (authoritative JSON):
    #{Jason.encode!(facts, pretty: true)}

    Task:
    Write clean, natural session notes like a player recap.

    Rules:
    - Only use facts from the provided JSON.
    - Do not invent events.
    - Do not infer motives.
    - Do not add anything not present.
    - If a section has no entries, omit it.
    - Deduplicate implicitly.
    - Keep tone natural and readable.
    - Do NOT mention JSON, chunks, or transcripts.

    Output Markdown:

    # Session Notes

    ## Summary
    Short narrative recap.

    ## Major Events
    Chronological bullet list.

    ## Locations
    Name — what happened there.

    ## NPCs
    Name — who they are and why they matter.

    ## Information Learned
    Clues, lore, revelations.

    ## Combat
    Opponents, notable moments, outcome.

    ## Party Decisions
    Decisions affecting future events.

    ## Character Moments
    Roleplay or reveals.

    ## Loose Threads
    Unresolved questions.

    ## Inventory / Rewards
    Items, money, conditions, level ups.
    """

    messages = [
      %{"role" => "system", "content" => @system_message},
      %{"role" => "user", "content" => user_msg}
    ]

    LLM.chat(messages, opts)
  end
end
