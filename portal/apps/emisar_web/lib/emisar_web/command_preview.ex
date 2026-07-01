defmodule EmisarWeb.CommandPreview do
  @moduledoc """
  Resolves an exec-kind action's `%{binary, argv}` template against a run's
  arguments into the copy-pasteable, shell-quoted command line an operator
  sees on the approval page — so they approve knowing *what will run*, not
  just the raw args.

  It is a faithful port of the runner's own rendering (Go
  `internal/expressions.RenderArgv` + `engine.redactedCommand`): the same
  `{{ args.x }}` substitution, whole-expression array expansion, scalar
  formatting, `sensitive: true` masking, and shell quoting the runner
  records as `executed_command` after a run. Callers gate on a pack-hash
  match first (`PacksRegistry.resolve_command/3`), so the template is
  guaranteed to be the exact one the runner will execute; this module only
  fills the arguments in.

  Display-only and pure — no Repo, no side effects.
  """

  @doc """
  Render `command` (`%{binary, argv}`) into a shell line, applying the
  action's declared defaults to `args` and masking `sensitive: true` values.
  `arg_specs` is the action's `args` schema list — each a string-keyed map
  (`%{"name" => ..., "default" => ..., "sensitive" => ...}`).

  `{:ok, line}` on success; `:error` if any `{{ args.x }}` reference can't be
  resolved or a value can't be formatted (the caller falls back to showing
  the raw args).
  """
  @spec render(%{binary: String.t(), argv: [String.t()]}, map(), [map()]) ::
          {:ok, String.t()} | :error
  def render(%{binary: binary, argv: argv}, args, arg_specs)
      when is_binary(binary) and is_list(argv) and is_map(args) and is_list(arg_specs) do
    merged = merge_defaults(args, arg_specs)

    case render_argv(argv, merged) do
      {:ok, rendered} ->
        secrets = sensitive_values(merged, arg_specs)
        {:ok, to_command_line(binary, rendered, secrets)}

      :error ->
        :error
    end
  end

  def render(_command, _args, _arg_specs), do: :error

  # Fill a declared default for any arg the caller didn't supply — the runner
  # applies defaults before templating, so a `--frequency={{ args.frequency }}`
  # slot resolves even when only `module` was dispatched.
  defp merge_defaults(args, arg_specs) do
    Enum.reduce(arg_specs, args, fn spec, acc ->
      case spec do
        %{"name" => name, "default" => default} when is_binary(name) and not is_nil(default) ->
          Map.put_new(acc, name, default)

        _ ->
          acc
      end
    end)
  end

  # Render each argv element. An element that is exactly `{{ args.x }}` and
  # resolves to a list expands into multiple tokens (RenderArgv's array case);
  # every other element renders to one token via inline substitution.
  defp render_argv(argv, args) do
    Enum.reduce_while(argv, {:ok, []}, fn raw, {:ok, acc} ->
      case render_element(raw, args) do
        {:ok, tokens} -> {:cont, {:ok, acc ++ tokens}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp render_element(raw, args) do
    case whole_expression(raw) do
      {:ok, expr} ->
        with {:ok, value} <- resolve(expr, args), do: expand(value)

      :error ->
        with {:ok, string} <- render_inline(raw, args, []), do: {:ok, [string]}
    end
  end

  # Inline substitution (RenderArgv's non-whole-expression path / Go `Render`):
  # replace each `{{ args.x }}` block with its formatted scalar, first-brace to
  # first-close, exactly as the runner scans it.
  defp render_inline(template, args, acc) do
    case :binary.split(template, "{{") do
      [only] ->
        {:ok, IO.iodata_to_binary(Enum.reverse([only | acc]))}

      [before, rest] ->
        case :binary.split(rest, "}}") do
          [_unterminated] ->
            :error

          [expr, tail] ->
            with {:ok, value} <- resolve(String.trim(expr), args),
                 {:ok, string} <- format_scalar(value) do
              render_inline(tail, args, [string, before | acc])
            end
        end
    end
  end

  # `{{ ... }}` with nothing around it and no nested braces → the body.
  defp whole_expression(string) do
    trimmed = String.trim(string)

    if String.starts_with?(trimmed, "{{") and String.ends_with?(trimmed, "}}") and
         byte_size(trimmed) >= 4 do
      body = trimmed |> binary_part(2, byte_size(trimmed) - 4) |> String.trim()

      if String.contains?(body, "{{") or String.contains?(body, "}}"),
        do: :error,
        else: {:ok, body}
    else
      :error
    end
  end

  # Only `args.<ident>` is supported, and the arg must be present — a missing
  # reference is an error (matching the runner), which drops the whole preview.
  defp resolve("args." <> name, args) do
    if valid_ident?(name) and Map.has_key?(args, name),
      do: {:ok, Map.get(args, name)},
      else: :error
  end

  defp resolve(_expr, _args), do: :error

  defp valid_ident?(name), do: String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)

  # A list value (a whole-expression element) expands into one token per item;
  # any other value is a single formatted token.
  defp expand(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case format_scalar(item) do
        {:ok, string} -> {:cont, {:ok, acc ++ [string]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp expand(value) do
    with {:ok, string} <- format_scalar(value), do: {:ok, [string]}
  end

  # Scalar → string, matching the runner's formatScalar. A map (or any other
  # non-scalar) can't be formatted → the preview drops rather than lie.
  defp format_scalar(nil), do: {:ok, ""}
  defp format_scalar(value) when is_binary(value), do: {:ok, value}
  defp format_scalar(true), do: {:ok, "true"}
  defp format_scalar(false), do: {:ok, "false"}
  defp format_scalar(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp format_scalar(value) when is_float(value), do: {:ok, format_float(value)}
  defp format_scalar(_value), do: :error

  # The runner formats floats with Go's `'f', -1` (shortest, no exponent). An
  # integer-valued float renders without the `.0`; anything else takes Elixir's
  # shortest round-trip — which may differ from Go only for extreme magnitudes
  # that would use exponent notation (not seen in real action args).
  defp format_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15,
      do: value |> trunc() |> Integer.to_string(),
      else: Float.to_string(value)
  end

  # String forms of every `sensitive: true` arg present, to mask out of the
  # rendered command (defense-in-depth — packs pass secrets via env, not argv).
  defp sensitive_values(args, arg_specs) do
    for spec <- arg_specs,
        spec["sensitive"] == true,
        name = spec["name"],
        is_binary(name),
        Map.has_key?(args, name),
        value = stringify(Map.get(args, name)),
        value != "",
        do: value
  end

  defp stringify(value) do
    case format_scalar(value) do
      {:ok, string} -> string
      :error -> ""
    end
  end

  defp to_command_line(binary, argv, secrets) do
    [binary | argv]
    |> Enum.map_join(" ", fn part -> part |> mask(secrets) |> shell_quote() end)
  end

  defp mask(string, secrets) do
    Enum.reduce(secrets, string, &String.replace(&2, &1, "[REDACTED]"))
  end

  # Bare when it's plain, single-quoted (embedded quotes escaped) otherwise —
  # the runner's shellQuote, so the preview reads identically to the recorded
  # `executed_command`.
  defp shell_quote(""), do: "''"

  defp shell_quote(string) do
    if String.match?(string, ~r/^[\w.\/:=@,+-]+$/),
      do: string,
      else: "'" <> String.replace(string, "'", "'\\''") <> "'"
  end
end
