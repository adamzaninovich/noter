defmodule Noter.SystemCmd do
  @moduledoc """
  Behaviour for executing system commands and opening ports.
  """

  @callback cmd(binary(), [binary()], keyword()) :: {binary(), non_neg_integer()}
  @callback open_port({:spawn_executable, binary()}, list()) :: port()
  @callback find_executable(binary()) :: binary() | nil

  def cmd(program, args, opts \\ []) do
    impl().cmd(program, args, opts)
  end

  def open_port(name, settings) do
    impl().open_port(name, settings)
  end

  def find_executable(program) do
    impl().find_executable(program)
  end

  defp impl do
    Application.get_env(:noter, :system_cmd, Noter.SystemCmd.Default)
  end
end
