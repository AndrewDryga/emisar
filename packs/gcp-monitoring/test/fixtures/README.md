# Cloud Logging fixture provenance

`healthcheck.json` is a harvested Cloud Logging entry from a production diagnostic
review. The existing compact message projection omitted its entire nested
`healthCheckProbeResult`, causing repeated requests for a person to export JSON.

Project, instance-group name and ID, insert ID, and IP addresses are stable
pseudonyms. The timestamp ordering, health transitions, protocol, target port,
probe text, and exact latency values retain the observed provider behavior.
The fixture server adds explicitly synthetic hostile strings and canary secrets
only for output-size, redaction, continuation, and ambiguity cases.

The hosted API shape and scoped `resourceNames` contract follow Google's
[LogEntry](https://docs.cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry)
and [entries.list](https://docs.cloud.google.com/logging/docs/reference/v2/rest/v2/entries/list)
references. Fixture passes do not establish live provider compatibility.
