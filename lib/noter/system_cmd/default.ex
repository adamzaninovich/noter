defmodule Noter.SystemCmd.Default do
  @moduledoc false

  @behaviour Noter.SystemCmd

  @impl true
  def cmd(program, args, opts), do: System.cmd(program, args, opts)

  @impl true
  def open_port(name, settings), do: Port.open(name, settings)

  @impl true
  def find_executable(program), do: System.find_executable(program)
end
