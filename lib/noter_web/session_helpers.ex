defmodule NoterWeb.SessionHelpers do
  @moduledoc """
  Shared formatting and display helpers used across session and campaign LiveViews.
  """

  def format_time(seconds) when is_number(seconds) do
    total = trunc(seconds)
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    Enum.map_join([h, m, s], ":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  def format_time(_), do: "00:00:00"

  def status_badge_class(status) do
    case status do
      "done" -> "badge-success"
      status when status in ~w(uploading trimming transcribing reviewing) -> "badge-info"
      _ -> "badge-soft badge-info"
    end
  end
end
