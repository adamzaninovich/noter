defmodule Noter.Repo do
  use Ecto.Repo,
    otp_app: :noter,
    adapter: Ecto.Adapters.SQLite3
end
