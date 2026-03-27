defmodule NoterWeb.Hooks.RequireSettings do
  @moduledoc """
  on_mount hook that redirects to /settings when required settings are missing.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if Noter.Settings.configured?("transcription_url") do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/settings")}
    end
  end
end
