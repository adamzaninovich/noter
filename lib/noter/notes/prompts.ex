defmodule Noter.Notes.Prompts do
  @moduledoc """
  Prompt templates for the notes generation pipeline.
  Ported verbatim from the n8n workflow nodes.
  """

  @doc """
  Returns messages for the fact extraction LLM call.
  """
  def extraction_messages(chunk_text, chunk_range, context) do
    user_content = """
    Context (authoritative, may be empty):
    #{context || ""}

    Transcript chunk (authoritative):
    Range: #{chunk_range}
    #{chunk_text}

    Task:
    Extract structured facts that are explicitly supported by the transcript chunk.

    Strict rules:
    - Only include facts supported by the chunk text.
    - Do not invent events, outcomes, NPC identities, motives, or locations.
    - Capture table talk, jokes, banter, sarcasm, pop-culture references, out-of-character asides, side conversations, hypothetical discussion, rules debate, and planning talk in the `banter` category. Do not include banter content in any other category unless it clearly results in an in-fiction action or party decision.
    - If uncertain, omit rather than guess.
    - Do not include quotes or timestamps in the output.
    - Output must be valid JSON that matches the required schema exactly.
    - Use arrays, even if empty.
    - Keep each entry short and specific.

    If nothing factual occurred in this chunk, return empty arrays for everything.

    Return JSON only.
    """

    [
      %{
        "role" => "system",
        "content" =>
          "You extract structured, transcript-grounded facts from a TTRPG session chunk. You do not write prose notes. You do not invent events. Return valid JSON only."
      },
      %{"role" => "user", "content" => user_content}
    ]
  end

  @doc """
  Returns messages for the note writing LLM call.
  """
  def writing_messages(aggregated_facts, context) do
    system_content = """
    You are a careful session chronicler for a tabletop RPG.

    Your job is to transform structured session facts into clear, natural player notes.

    You must obey these rules strictly:

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

    user_content = """
    Context (authoritative):
    #{context || ""}

    Extracted session facts (authoritative JSON):
    #{Jason.encode!(aggregated_facts, pretty: true)}

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

    [
      %{"role" => "system", "content" => system_content},
      %{"role" => "user", "content" => user_content}
    ]
  end
end
