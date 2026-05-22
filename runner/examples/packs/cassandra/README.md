# cassandra

Read-only Cassandra inspection actions plus the data-disk analyzer script.

| ID                                  | Mutation        | Risk     |
| ----------------------------------- | --------------- | -------- |
| `cassandra.nodetool_status`         | none            | low      |
| `cassandra.nodetool_tpstats`        | none            | low      |
| `cassandra.nodetool_compactionstats`| none            | low      |
| `cassandra.nodetool_tablestats`     | none            | medium   |
| `cassandra.nodetool_repair`         | cluster_state   | high     |
| `cassandra.analyze_disk_pressure`   | none            | low      |

Runbooks that orchestrate these actions (e.g., a Cassandra repair advisor)
live in the cloud control plane, not in this pack. The runner's role is to
expose the actions truthfully and execute them safely; multi-step workflows
are composed and executed cloud-side.
