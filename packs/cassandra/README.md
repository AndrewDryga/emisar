# cassandra

Cassandra operations — read-only inspection (nodetool + cqlsh), the effective
runtime configuration, the limits a node accepts without a restart, plus
risk-tiered maintenance and node-lifecycle actions. Reads that return stored
application data are `high`; the switches that cut a node out of service are
`critical`, so account policy denies them until an operator opts in.

A representative sample below — run `emisar pack info cassandra` for the full,
current list (119 actions).

| ID                                          | Mutation        | Risk     |
| ------------------------------------------- | --------------- | -------- |
| `cassandra.nodetool_status`                 | none            | low      |
| `cassandra.nodetool_tpstats`                | none            | low      |
| `cassandra.nodetool_compactionstats`        | none            | low      |
| `cassandra.nodetool_tablestats`             | none            | low      |
| `cassandra.nodetool_getstreamthroughput`    | none            | low      |
| `cassandra.cqlsh_settings`                  | none            | medium   |
| `cassandra.nodetool_setinterdcstreamthroughput` | node_config | medium   |
| `cassandra.cqlsh_select_by_key`             | none            | high     |
| `cassandra.nodetool_repair`                 | cluster_state   | high     |
| `cassandra.nodetool_disablebinary`          | node_state      | critical |
| `cassandra.analyze_disk_pressure`           | none            | low      |

Runbooks that orchestrate these actions (e.g., a Cassandra repair advisor)
live in the cloud control plane, not in this pack. The runner's role is to
expose the actions truthfully and execute them safely; multi-step workflows
are composed and executed cloud-side.
