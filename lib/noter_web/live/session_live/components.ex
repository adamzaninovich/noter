defmodule NoterWeb.SessionLive.Components do
  @moduledoc """
  Function components for the session show LiveView.

  Contains `turn_row/1` and `file_indicator/1` used in the transcript review UI.
  """
  use NoterWeb, :html

  def file_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <%= if @exists? do %>
        <.icon name="hero-check-circle" class="size-4 text-success" />
      <% else %>
        <.icon name="hero-x-circle" class="size-4 text-base-content/30" />
      <% end %>
      <span>{@label}</span>
    </div>
    """
  end

  def turn_row(assigns) do
    ~H"""
    <div class={[
      "flex flex-wrap sm:flex-nowrap items-start gap-x-2 gap-y-1 py-2 px-2 rounded-lg transition-colors border",
      cond do
        @turn.deleted? -> "border-error/30"
        @turn.edited? -> "border-info/30"
        true -> "border-base-content/5"
      end
    ]}>
      <button
        :if={not @read_only?}
        type="button"
        data-play-turn
        data-turn-start={@turn.start}
        data-turn-end={@turn.end}
        class="btn btn-ghost btn-xs mt-0.5 shrink-0"
      >
        <span data-play-icon class="hero-play-solid size-3"></span>
      </button>
      <span class="badge badge-ghost badge-sm font-mono mt-0.5 shrink-0">
        {format_time(@turn.start)}
      </span>
      <span class={[
        "badge badge-sm mt-0.5 shrink-0 w-16 justify-center",
        Map.get(@speaker_colors, @turn.speaker, "badge-neutral")
      ]}>
        {@turn.speaker}
      </span>
      <%!-- Action buttons: on mobile sit in the metadata row, on desktop next to text --%>
      <%= unless @read_only? do %>
        <div class="flex items-center gap-0.5 shrink-0 mt-0.5 sm:order-last sm:opacity-0 sm:group-hover:opacity-100">
          <%= if @turn.edited? or @turn.deleted? do %>
            <span class={[
              "badge badge-xs",
              if(@turn.deleted?, do: "badge-error", else: "badge-info")
            ]}>
              {if(@turn.deleted?, do: "deleted", else: "edited")}
            </span>
            <button
              type="button"
              phx-click="start_edit"
              phx-value-turn-id={@turn.id}
              class="btn btn-ghost btn-xs"
              title="Edit turn"
            >
              <.icon name="hero-pencil-square-mini" class="size-3" />
            </button>
            <button
              type="button"
              phx-click="remove_edit"
              phx-value-turn-id={@turn.id}
              class="btn btn-ghost btn-xs text-warning"
              title="Revert"
            >
              <.icon name="hero-arrow-uturn-left-mini" class="size-3" />
            </button>
          <% else %>
            <button
              type="button"
              phx-click="start_edit"
              phx-value-turn-id={@turn.id}
              class="btn btn-ghost btn-xs"
              title="Edit turn"
            >
              <.icon name="hero-pencil-square-mini" class="size-3" />
            </button>
            <button
              type="button"
              phx-click="delete_turn"
              phx-value-turn-id={@turn.id}
              class="btn btn-ghost btn-xs text-error"
              title="Delete turn"
            >
              <.icon name="hero-trash-mini" class="size-3" />
            </button>
          <% end %>
        </div>
      <% end %>
      <%!-- Content: edit form or text --%>
      <%= if @turn.editing? do %>
        <div class="basis-full sm:basis-auto sm:flex-1">
          <.form
            for={@turn.edit_form}
            id={"edit-form-#{@turn.id}"}
            phx-submit="save_edit"
            class="space-y-2"
          >
            <.input
              field={@turn.edit_form[:text]}
              type="textarea"
              class="textarea textarea-bordered textarea-sm w-full"
              rows="3"
              id={"edit-textarea-#{@turn.id}"}
              phx-hook=".CmdEnterSubmit"
            />
            <div class="flex items-center gap-2">
              <button type="submit" class="btn btn-primary btn-xs">Save</button>
              <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">
                Cancel
              </button>
            </div>
          </.form>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CmdEnterSubmit">
            export default {
              mounted() {
                this.el.addEventListener("keydown", (e) => {
                  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                    e.preventDefault()
                    this.el.closest("form").requestSubmit()
                  }
                })
              }
            }
          </script>
        </div>
      <% else %>
        <div class="basis-full sm:basis-auto sm:flex-1 min-w-0">
          <p class="text-sm leading-relaxed">
            <%= cond do %>
              <% @turn.deleted? -> %>
                <span class="italic text-base-content/40">
                  <%= for word <- @turn.display_words do %>
                    {word.word}
                  <% end %>
                </span>
              <% @turn.edited? -> %>
                <%= for {type, text} <- word_diff(@turn.original_text, hd(@turn.display_words).word) do %>
                  <%= case type do %>
                    <% :eq -> %>
                      <span>{text}</span>
                    <% :del -> %>
                      <span class="bg-error/20 text-error/70 line-through">{text}</span>
                    <% :ins -> %>
                      <span class="bg-success/20 text-success font-medium">{text}</span>
                  <% end %>
                <% end %>
              <% true -> %>
                <%= for word <- @turn.display_words do %>
                  {leading_space(word.word)}<span
                    class={[
                      not @read_only? &&
                        "cursor-pointer hover:outline hover:outline-1 hover:outline-base-content/20 rounded-sm",
                      word.replaced? && "bg-success/20 text-success font-medium"
                    ]}
                    phx-click={if(not @read_only?, do: "prefill_replacement")}
                    phx-value-word={strip_display_word(word.word)}
                  >{String.trim_leading(word.word)}</span>
                <% end %>
            <% end %>
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp word_diff(original, edited) do
    old_words = String.split(original)
    new_words = String.split(edited)
    List.myers_difference(old_words, new_words) |> format_diff_chunks()
  end

  defp format_diff_chunks(chunks) do
    Enum.flat_map(chunks, fn
      {:eq, words} -> [{:eq, Enum.join(words, " ")}]
      {:del, words} -> [{:del, Enum.join(words, " ")}]
      {:ins, words} -> [{:ins, Enum.join(words, " ")}]
    end)
  end

  defp leading_space(word) do
    case Regex.run(~r/\A(\s+)/, word) do
      [_, ws] -> ws
      _ -> ""
    end
  end

  defp strip_display_word(word) do
    word
    |> String.trim_leading()
    |> String.replace(~r/[.,;:!?\-"')\]]+\z/, "")
  end
end
