defmodule Emisar.Compat do
  @moduledoc """
  Control-plane version-compatibility policy for runners and the
  emisar-mcp bridge. The single place that answers "is this observed
  version current, out of date, or below the minimum this control plane
  still supports?" and whether the operator has turned hard enforcement
  on.

  The policy is deployment config — the emisar operator's call, not a
  tenant setting — read at call time:

      config :emisar, Emisar.Compat,
        runner_minimum: ">= 0.4.0",
        runner_recommended: ">= 0.5.0",
        runner_enforce: false,
        mcp_minimum: ">= 0.4.0",
        mcp_recommended: ">= 0.5.0",
        mcp_enforce: false

  `*_minimum` / `*_recommended` are Elixir `Version` requirement strings
  (`>= 0.4.0`, `~> 0.5`); a malformed one raises rather than silently
  accepting every version. An omitted threshold is treated as satisfied.
  Enforcement defaults off (warn-only), and even when on it never blocks a
  `:unknown` (missing / unparseable) version — only `:unsupported`.
  """

  @type status :: :supported | :outdated | :unsupported | :unknown

  # -- Runners --------------------------------------------------------

  @doc "Classify an observed runner version against the configured runner policy."
  @spec runner_status(String.t() | nil) :: status()
  def runner_status(version), do: status(version, :runner_minimum, :runner_recommended)

  @doc "True when the operator has turned on hard runner-version enforcement."
  def enforce_runners?, do: raw(:runner_enforce) == true

  @doc "The configured minimum runner-version requirement string, for operator-facing messages."
  def runner_minimum, do: raw(:runner_minimum)

  @doc "The configured recommended runner-version requirement string, for operator-facing messages."
  def runner_recommended, do: raw(:runner_recommended)

  # -- MCP bridge -----------------------------------------------------

  @doc "Classify an observed emisar-mcp bridge version against the configured MCP policy."
  @spec mcp_status(String.t() | nil) :: status()
  def mcp_status(version), do: status(version, :mcp_minimum, :mcp_recommended)

  @doc "True when the operator has turned on hard MCP-bridge-version enforcement."
  def enforce_mcp?, do: raw(:mcp_enforce) == true

  @doc "The configured minimum MCP-bridge-version requirement string, for operator-facing messages."
  def mcp_minimum, do: raw(:mcp_minimum)

  @doc "The configured recommended MCP-bridge requirement string, for operator-facing messages."
  def mcp_recommended, do: raw(:mcp_recommended)

  # -- Evaluation -----------------------------------------------------

  # A missing or unparseable observed version is :unknown and NEVER blocked
  # (enforcement acts on :unsupported only), so a runner/client reporting a
  # nonstandard version string can't be locked out.
  defp status(version, minimum_key, recommended_key) do
    case parse(version) do
      :error ->
        :unknown

      {:ok, parsed} ->
        cond do
          not meets?(parsed, minimum_key) -> :unsupported
          not meets?(parsed, recommended_key) -> :outdated
          true -> :supported
        end
    end
  end

  # An unset threshold is always met — no policy configured for it.
  defp meets?(%Version{} = version, key) do
    case requirement(key) do
      nil -> true
      requirement -> Version.match?(version, requirement, allow_pre: true)
    end
  end

  defp parse(version) when is_binary(version), do: Version.parse(String.trim(version))
  defp parse(_), do: :error

  # Parse (and thereby validate) the configured requirement — a malformed
  # one raises here rather than degrading to "accept everything".
  defp requirement(key) do
    case raw(key) do
      nil -> nil
      requirement -> Version.parse_requirement!(requirement)
    end
  end

  defp raw(key), do: :emisar |> Emisar.Config.get_env(__MODULE__, []) |> Keyword.get(key)
end
