defmodule Emisar.RequestContext do
  @moduledoc """
  Request metadata stamped onto audit events — the IP, user-agent,
  request id, and MCP session of the inbound HTTP / WebSocket request.

  Built once at the boundary (auth plug, LiveView mount, MCP plug,
  runner connect / register), then carried on `%Auth.Subject{}` for an
  authenticated caller and passed explicitly on pre-auth flows (sign-in,
  MFA, password reset) that have no subject yet. A struct, not a bare
  map, so the field set is fixed: every audit write merges the same four
  keys, and an event with the default (all-nil) context — a system /
  engine origin — carries no request metadata, which is the point.

  Behind a proxy without `Plug.RemoteIp`, `ip_address` is the proxy IP.
  """
  defstruct ip_address: nil, user_agent: nil, request_id: nil, mcp_session_id: nil

  @type t :: %__MODULE__{
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          request_id: String.t() | nil,
          mcp_session_id: String.t() | nil
        }

  @doc """
  Build a context from a map (or keyword list) of the known keys; any
  other keys are ignored, so a boundary can hand over its raw capture
  without pre-filtering.
  """
  def new(fields \\ %{}), do: struct(__MODULE__, fields)
end
