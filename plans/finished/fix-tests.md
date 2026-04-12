# Plan: Mock system commands in uploads tests via Behaviour + Mox

## Context

The 5 failing tests in `Noter.UploadsTest` all fail with `:enoent` because `ffmpeg` isn't on the CI runner's PATH. The tests call `System.cmd("ffmpeg", ...)` both to **generate fixture files** (test setup) and **indirectly via production code** (`Uploads` and `Prep` modules). Rather than requiring ffmpeg in CI, we should mock the system command layer so these tests verify logic without needing real binaries.

## Approach

Introduce a `Noter.SystemCmd` behaviour with a default implementation that delegates to `System.cmd/3` and `Port.open/2`. Use Mox in tests to stub responses.

### 1. Add Mox dependency

**File:** `mix.exs`

Add `{:mox, "~> 1.0", only: :test}` to deps.

### 2. Create the behaviour module

**File:** `lib/noter/system_cmd.ex`

```elixir
defmodule Noter.SystemCmd do
  @callback cmd(binary(), [binary()], keyword()) :: {binary(), non_neg_integer()}
  @callback open_port({:spawn_executable, binary()}, list()) :: port()

  def cmd(program, args, opts \\ []) do
    impl().cmd(program, args, opts)
  end

  def open_port(name, settings) do
    impl().open_port(name, settings)
  end

  defp impl do
    Application.get_env(:noter, :system_cmd, Noter.SystemCmd.Default)
  end
end
```

### 3. Create the default (real) implementation

**File:** `lib/noter/system_cmd/default.ex`

```elixir
defmodule Noter.SystemCmd.Default do
  @behaviour Noter.SystemCmd

  @impl true
  def cmd(program, args, opts), do: System.cmd(program, args, opts)

  @impl true
  def open_port(name, settings), do: Port.open(name, settings)
end
```

### 4. Replace System.cmd / Port.open calls in production code

**File:** `lib/noter/uploads.ex` — 4 call sites:
- Line 88: `System.cmd("ffmpeg", ...)` -> `Noter.SystemCmd.cmd("ffmpeg", ...)`
- Line 103: `System.cmd("audiowaveform", ...)` -> `Noter.SystemCmd.cmd("audiowaveform", ...)`
- Line 119: `System.cmd("ffprobe", ...)` -> `Noter.SystemCmd.cmd("ffprobe", ...)`
- Line 232: `System.find_executable("ffmpeg")` + Line 242: `Port.open(...)` -> `Noter.SystemCmd.open_port(...)`
  - For `find_executable`, just hardcode `"ffmpeg"` since `open_port({:spawn_executable, ...})` will use the mock anyway

**File:** `lib/noter/prep.ex` — 2 call sites:
- Line 13: `System.cmd("unzip", ...)` -> `Noter.SystemCmd.cmd("unzip", ...)`
- Line 74: `System.cmd("ffmpeg", ...)` -> `Noter.SystemCmd.cmd("ffmpeg", ...)`

### 5. Configure Mox in test environment

**File:** `test/test_helper.exs` — add:
```elixir
Mox.defmock(Noter.SystemCmd.Mock, for: Noter.SystemCmd)
```

**File:** `config/test.exs` — add:
```elixir
config :noter, :system_cmd, Noter.SystemCmd.Mock
```

### 6. Rewrite the failing tests

**File:** `test/noter/uploads_test.exs`

Remove all `System.cmd("ffmpeg", ...)` fixture-generation calls. Instead:
- Create dummy files with `File.write!/2` (the mock won't actually read them)
- Use `Mox.expect/3` to stub `cmd/3` and `open_port/2` with appropriate return values
- For `mix_tracks_to_wav` test: expect `cmd("ffmpeg", args, opts)` and return `{"", 0}`, then write a dummy output file in the mock
- For `trim_session` test: expect `open_port` calls and simulate port messages (`{port, {:exit_status, 0}}`) back to the caller
- For `encode_merged_m4a` tests: same port-message simulation, verify progress callbacks fire
- For `process_uploads` test: expect both `cmd("unzip", ...)` and `cmd("ffmpeg", ...)`, write dummy files in the mock callback
- Remove the `ffprobe` verification assertion from `mix_tracks_to_wav` test (that was testing ffmpeg itself, not our code)

Key detail for `open_port` mocking: `ffmpeg_with_progress/6` uses `Port.open` and then receives port messages. The mock's `open_port` can spawn a process that sends the expected port-like messages (`{port, {:data, "out_time_us=500000\n"}}` and `{port, {:exit_status, 0}}`).

### 7. Keep @tag :integration but remove from default exclude

The `@tag :integration` tags stay for documentation, but since tests will now work without ffmpeg, no exclusion is needed.

## Files to modify

| File | Change |
|------|--------|
| `mix.exs` | Add `:mox` dep |
| `lib/noter/system_cmd.ex` | New behaviour module |
| `lib/noter/system_cmd/default.ex` | New default impl |
| `lib/noter/uploads.ex` | Replace 4 System.cmd/Port.open calls |
| `lib/noter/prep.ex` | Replace 2 System.cmd calls |
| `config/test.exs` | Add `:system_cmd` config |
| `test/test_helper.exs` | Define Mox mock |
| `test/noter/uploads_test.exs` | Rewrite 5 failing tests with Mox expects |

## Verification

1. `mix deps.get` (fetch Mox)
2. `mix test test/noter/uploads_test.exs` — all 5 previously-failing tests pass
3. `mix precommit` — full suite green, no credo/compile warnings
