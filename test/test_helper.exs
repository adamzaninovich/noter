ExUnit.configure(max_cases: 4)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Noter.Repo, :manual)

Mox.defmock(Noter.SystemCmd.Mock, for: Noter.SystemCmd)
