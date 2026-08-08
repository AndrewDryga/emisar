defmodule Emisar.Catalog.CommandPreview do
  @moduledoc """
  Renders a trusted action's `%{binary, argv}` template against a run's
  arguments into the shell-quoted, secret-masked command line an operator
  approves against — so they decide knowing *what will run*, not just which
  arguments were sent.

  This is canonical action behavior, not presentation: it is a faithful port
  of the runner's own rendering (Go `internal/expressions.RenderArgv` +
  `engine.redactedInvocation`) — the same `{{ args.x }}` substitution, optional
  `{{ args.x? }}` element dropping, whole-expression array expansion, scalar
  formatting, `sensitive: true` masking, and shell quoting the runner records
  as `executed_command` after a run.

  Both the template AND the arg declarations come from the same hash-proven
  `Emisar.Catalog.PublishedRegistry.Action`
  (`PublishedRegistry.resolve_action/4`), never from a runner's mutable
  advertisement, so a forged advertisement cannot move a default or drop a
  `sensitive` flag out of the rendered line.

  Pure — no Repo, no side effects.
  """

  alias Emisar.Catalog.PublishedRegistry.Action
  alias Emisar.JSONNumber

  @redacted "[REDACTED]"
  # The runner's bare-token allowlist, ASCII by construction — anything else
  # (a space, a metacharacter, any non-ASCII rune) is single-quoted.
  @bare_token ~r/\A[A-Za-z0-9_.\/:=@,+-]+\z/

  @doc """
  Render `action`'s command template against `args`, returning
  `{:ok, safe_line}` or `:error`.

  `args` is the run's decoded raw argument map. Every value the action or the
  run marks sensitive is masked out of the line before quoting, so a raw
  secret never reaches the result; `extra_sensitive_names` carries the run's
  own snapshot (`sensitive_arg_names`), which still masks a value the action's
  current declaration no longer marks.

  `:error` — never a partial line — when the action carries no command, a
  required `{{ args.x }}` reference can't be resolved, or a value can't be
  formatted the way the runner would.
  """
  @spec render(Action.t(), map(), [String.t()]) :: {:ok, String.t()} | :error
  def render(action, args, extra_sensitive_names \\ [])

  def render(%Action{command: %{binary: binary, argv: argv}, args: specs}, args, extra_names)
      when is_map(args) and is_list(extra_names) do
    merged = merge_defaults(args, specs)

    case render_argv(argv, merged) do
      {:ok, rendered} ->
        secrets = sensitive_values(merged, specs, extra_names)
        {:ok, to_command_line(binary, rendered, secrets)}

      :error ->
        :error
    end
  end

  def render(_action, _args, _extra_names), do: :error

  # Fill a declared default for any arg the caller didn't supply — the runner
  # validates defaults in before templating, so a `--frequency={{ args.frequency }}`
  # slot resolves even when only `module` was dispatched.
  defp merge_defaults(args, specs) do
    Enum.reduce(specs, args, fn spec, acc ->
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
  # an element carrying an optional expression that resolved to empty is
  # dropped whole; every other element renders to one token.
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
      {:ok, expr} -> render_whole(expr, args)
      :error -> render_inline(raw, args, [], false)
    end
  end

  defp render_whole(expr, args) do
    case resolve(expr, args) do
      {:ok, value, optional?} ->
        if optional? and empty?(value), do: {:ok, []}, else: expand(value)

      :error ->
        :error
    end
  end

  # Inline substitution (RenderArgv's non-whole-expression path / Go
  # `renderTemplate`): replace each `{{ args.x }}` block with its formatted
  # scalar, first-brace to first-close, exactly as the runner scans it. An
  # optional expression that resolves to empty substitutes nothing and marks
  # the whole element for dropping — `-namespace={{ args.ns? }}` omits the flag
  # rather than passing `-namespace=`.
  defp render_inline(template, args, acc, drop?) do
    case :binary.split(template, "{{") do
      [only] ->
        if drop?, do: {:ok, []}, else: {:ok, [IO.iodata_to_binary(Enum.reverse([only | acc]))]}

      [before, rest] ->
        substitute(rest, args, [before | acc], drop?)
    end
  end

  defp substitute(rest, args, acc, drop?) do
    case :binary.split(rest, "}}") do
      [_unterminated] ->
        :error

      [expr, tail] ->
        expr |> String.trim() |> resolve(args) |> substituted(tail, args, acc, drop?)
    end
  end

  defp substituted({:ok, value, optional?}, tail, args, acc, drop?) do
    if optional? and empty?(value) do
      render_inline(tail, args, acc, true)
    else
      with {:ok, string} <- format_scalar(value),
           do: render_inline(tail, args, [string | acc], drop?)
    end
  end

  defp substituted(:error, _tail, _args, _acc, _drop?), do: :error

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

  # Only `args.<ident>` is supported. A trailing `?` marks the reference
  # optional: an absent arg then resolves to nil instead of failing the whole
  # preview. Anything else — another root, a call, a bad identifier, an absent
  # required arg — is an error, matching the runner.
  defp resolve(expr, args) do
    {body, optional?} = split_optional(expr)

    case body do
      "args." <> name -> resolve_arg(name, args, optional?)
      _ -> :error
    end
  end

  defp resolve_arg(name, args, optional?) do
    cond do
      not valid_ident?(name) -> :error
      Map.has_key?(args, name) -> {:ok, Map.get(args, name), optional?}
      optional? -> {:ok, nil, true}
      true -> :error
    end
  end

  defp split_optional(expr) do
    trimmed = String.trim(expr)

    if String.ends_with?(trimmed, "?"),
      do: {trimmed |> binary_part(0, byte_size(trimmed) - 1) |> String.trim(), true},
      else: {expr, false}
  end

  defp valid_ident?(name), do: String.match?(name, ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)

  # Empty for the purpose of dropping an optional element: nil, the empty
  # string, or an empty list. A numeric zero or `false` is a real value.
  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(_value), do: false

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
  defp format_scalar(%JSONNumber{raw: raw}), do: {:ok, raw}
  defp format_scalar(_value), do: :error

  # Go's `strconv.FormatFloat(v, 'f', -1, 64)`: the shortest digits that round
  # trip, always in fixed notation. Erlang's `:short` gives the same digits but
  # may spell them with an exponent, so shift the point back into place.
  defp format_float(value) do
    shortest = Float.to_string(value)

    case String.split(shortest, "e") do
      [decimal] -> trim_fraction(decimal)
      [decimal, exponent] -> shift_point(decimal, String.to_integer(exponent))
    end
  end

  defp shift_point(decimal, exponent) do
    {sign, unsigned} = split_sign(decimal)
    {integer, fraction} = split_fraction(unsigned)
    digits = integer <> fraction
    point = byte_size(integer) + exponent
    length = byte_size(digits)

    cond do
      point <= 0 ->
        sign <> trim_fraction("0." <> String.duplicate("0", -point) <> digits)

      point >= length ->
        sign <> digits <> String.duplicate("0", point - length)

      true ->
        placed =
          binary_part(digits, 0, point) <> "." <> binary_part(digits, point, length - point)

        sign <> trim_fraction(placed)
    end
  end

  defp split_sign("-" <> unsigned), do: {"-", unsigned}
  defp split_sign(decimal), do: {"", decimal}

  defp split_fraction(unsigned) do
    case String.split(unsigned, ".") do
      [integer, fraction] -> {integer, fraction}
      [integer] -> {integer, ""}
    end
  end

  # Trailing zeros past the point are not significant digits; the point itself
  # stops the trim, so an integer's own zeros are safe.
  defp trim_fraction(decimal) do
    if String.contains?(decimal, "."),
      do: decimal |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: decimal
  end

  # Every string form of every sensitive value, longest first. `mask/2` already
  # matches leftmost-longest, so the order is not what keeps an overlapping
  # secret (`abc` inside `abc123`) whole — it keeps this list shaped like the
  # runner's, whose `strings.Replacer` resolves a tie by argument order. A list
  # arg expands into separate argv tokens, so each element is its own secret —
  # masking only the whole form would leave the elements in the line. The run's
  # own snapshot masks values the action stopped declaring sensitive.
  defp sensitive_values(args, specs, extra_names) do
    specs
    |> declared_sensitive_names()
    |> Enum.concat(extra_names)
    |> Enum.filter(&Map.has_key?(args, &1))
    |> Enum.flat_map(&arg_strings(Map.get(args, &1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp declared_sensitive_names(specs) do
    for %{"name" => name} = spec <- specs, spec["sensitive"] == true, is_binary(name), do: name
  end

  defp arg_strings(value) do
    case expand(value) do
      {:ok, strings} -> strings
      :error -> []
    end
  end

  defp to_command_line(binary, argv, secrets) do
    [binary | argv]
    |> Enum.map_join(" ", fn part -> part |> mask(secrets) |> shell_quote() end)
  end

  # ONE pass over the token, never a fold of per-secret replacements: a fold
  # re-scans the text it has already masked, so a secret that is a substring of
  # the marker itself ("ED", "RED") rewrites the marker a previous secret left
  # behind — `[R[REDACTED]ACTED]`, which both mangles the line the operator
  # approves against and spells out which substring the value was.
  # `String.replace/3` with the list matches leftmost-longest in a single scan,
  # so an overlapping secret still masks whole.
  defp mask(string, secrets), do: String.replace(string, secrets, @redacted)

  # Bare when it's plain, single-quoted (embedded quotes escaped) otherwise —
  # the runner's shellQuote, so the preview reads identically to the recorded
  # `executed_command`.
  defp shell_quote(""), do: "''"

  defp shell_quote(string) do
    if String.match?(string, @bare_token),
      do: string,
      else: "'" <> String.replace(string, "'", "'\\''") <> "'"
  end
end
