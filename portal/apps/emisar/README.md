# emisar (cloud)

Phoenix umbrella app containing the cloud control plane. Sibling
`emisar_web` provides the HTTP / WebSocket / LiveView surface; this app
holds the domain contexts (`Accounts`, `Runners`, `Catalog`, `Policies`,
`Runs`, `Approvals`, `Audit`, `Billing`) and the Ecto schema. The
runner binary lives at `runner/` in the umbrella root; the MCP stdio
bridge at `mcp/`.

Run from the umbrella root (`portal/`) — `mix test`, `mix ecto.setup`,
`mix phx.server`. See `docker-compose.yml` at the repo root to boot
the full stack locally.
