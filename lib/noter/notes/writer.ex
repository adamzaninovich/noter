defmodule Noter.Notes.Writer do
  @moduledoc """
  Produces markdown session notes from aggregated facts via a single LLM call.
  """

  alias Noter.LLM.Client
  alias Noter.Notes.Prompts

  @doc """
  Calls the writing LLM with aggregated facts and campaign context.
  Returns `{:ok, markdown_string}` or `{:error, reason}`.
  `opts` are passed through to `Client.chat/3` for test plug injection.
  """
  def write(aggregated_facts, context, opts \\ []) do
    messages = Prompts.writing_messages(aggregated_facts, context)
    Client.chat(:writing, messages, opts)
  end
end
