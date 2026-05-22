# linux-core

Safe, read-only Linux diagnostics plus narrow systemd unit control.

| ID                         | Mutation        | Risk     | Notes                              |
| -------------------------- | --------------- | -------- | ---------------------------------- |
| `linux.disk_usage`         | none            | low      | `df -P -h` on path allowlist       |
| `linux.memory`             | none            | low      | `free -m`                          |
| `linux.uptime`             | none            | low      | `uptime`                           |
| `linux.journalctl`         | none            | medium   | `journalctl -u <unit>` w/ window   |
| `linux.systemctl_status`   | none            | low      | `systemctl status <unit>`          |
| `linux.systemctl_restart`  | service_state   | high     | `systemctl restart <unit>`         |

The runner advertises these actions to the control plane on connect. Cloud
policy decides who can call which; the runner re-validates arguments against
each action's declared schema and refuses anything that doesn't validate.
