# cassandra

Cassandra operations — read-only inspection (nodetool + cqlsh) plus risk-tiered
maintenance and node-lifecycle actions.

A representative sample below — run `emisar pack info cassandra` for the full,
current list (45 actions).

| ID                                  | Mutation        | Risk     |
| ----------------------------------- | --------------- | -------- |
| `cassandra.nodetool_status`         | none            | low      |
| `cassandra.nodetool_tpstats`        | none            | low      |
| `cassandra.nodetool_compactionstats`| none            | low      |
| `cassandra.nodetool_tablestats`     | none            | low      |
| `cassandra.nodetool_repair`         | cluster_state   | high     |
| `cassandra.analyze_disk_pressure`   | none            | low      |

Runbooks that orchestrate these actions (e.g., a Cassandra repair advisor)
live in the cloud control plane, not in this pack. The runner's role is to
expose the actions truthfully and execute them safely; multi-step workflows
are composed and executed cloud-side.
