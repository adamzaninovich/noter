defmodule Noter.SystemCmd.Default do
  @moduledoc false

  @behaviour Noter.SystemCmd

  @impl true
  def cmd(program, args, opts), do: System.cmd(program, args, opts)

  @impl true
  def open_port(name, settings), do: Port.open(name, settings)
end
