defmodule Emisar.CredoCheckProbe do
  @moduledoc """
  Runs one custom Credo check from `credo/checks/` against a probe source.

  Credo loads those files only when `mix credo` runs, so an AST regression in a
  check is invisible to the suite until someone reintroduces the very shape the
  check exists to stop — a green gate then promises enforcement that isn't
  there. A fixture test loads the sources (`load/0`), parses a probe at a path
  the check cares about, and asserts both what must fire and what must not.
  """
  alias Credo.SourceFile

  @checks_dir Path.expand("../../../../credo/checks", __DIR__)

  @doc """
  Loads every check source. Call it from `setup_all`.

  All of them, rather than a per-module list: `Code.require_file/1` loads each
  file once per run whoever asks first, and requiring the whole directory also
  proves every check still compiles.
  """
  def load do
    {:ok, _started} = Application.ensure_all_started(:credo)

    @checks_dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.each(&Code.require_file/1)
  end

  @doc """
  The check module named `name`, resolved at runtime.

  A literal `Emisar.Checks.X` reference would make the compiler warn about an
  undefined module — the checks are never compiled into the app — and the gate
  fails on warnings in test output. `safe_concat` can insist the atom exists
  because `load/0` has already required its source.
  """
  def check(name), do: Module.safe_concat([:Emisar, :Checks, name])

  @doc "Every issue `check` reports for `source` parsed at `filename`."
  def issues(check, source, filename), do: source |> SourceFile.parse(filename) |> check.run([])

  @doc "The sorted triggers `check` reports for `source` at `filename`."
  def triggers(check, source, filename) do
    check |> issues(source, filename) |> Enum.map(& &1.trigger) |> Enum.sort()
  end

  @doc "The sorted line numbers `check` reports — for the checks that carry no trigger."
  def lines(check, source, filename) do
    check |> issues(source, filename) |> Enum.map(& &1.line_no) |> Enum.sort()
  end
end
