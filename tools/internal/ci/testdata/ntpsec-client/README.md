# NTPsec client assessment fixtures

The two gzip files are exact Debian Bookworm amd64 payloads, inspected and hashed
by tests without execution. They prove the assessment on real bytes without a
test-only policy override. `copyright` is the package's unmodified license notice.

Both packages are version `1.2.2+dfsg1-1+deb12u1`, downloaded from the
[Debian ntpsec pool](https://deb.debian.org/debian/pool/main/n/ntpsec/).

| Fixture | Debian package path | Uncompressed SHA-256 |
| --- | --- | --- |
| `ntpq.gz` | `ntpsec`: `/usr/bin/ntpq` | `b0cb0e98273e72575cb139a95719a15afad153a50749b653980850bb9161035a` |
| `libntpc.so.gz` | `python3-ntp`: `/usr/lib/python3/dist-packages/ntp/libntpc.so` | `61474fc2808110c2a0a791b89d04fd93471411536aab87ccb0cf4bd4a65d0681` |

The `.deb` SHA-256 values are respectively
`6ef804d1a7e37cb308a9f5b0ff67c9a981cc9cf956dadb44496110943efad9a2` and
`abeae7e827438c84831323e65544dd8ce0ad29ef0601b805cebe0aefd21b8ce2`.
Both payload hashes also match the bound diagnostics SBOM in
[CI run 40944524555](https://github.com/andrewdryga/emisar/actions/runs/40944524555),
artifact `12928826750`, revision `de4e9d607155eea3320b96a9eb23ce801ccb674d`.
The adjacent `diagnostics-ntpsec-findings.json` retains both complete findings
from that artifact's immutable raw scan.

[CVE-2026-102486](https://security-tracker.debian.org/tracker/CVE-2026-102486)
affects the NTS daemon parser. The
[upstream fix](https://github.com/ntpsec/ntpsec/commit/7cc079387a0c8f94a4a82ebd0fc3cbe32f705557)
changes `ntpd/nts_extens.c::extens_server_recv`.
[ntpd's build graph](https://github.com/ntpsec/ntpsec/blob/NTPsec_1_2_2/ntpd/wscript)
links that implementation into the daemon; the separate
[libntpc build](https://github.com/ntpsec/ntpsec/blob/NTPsec_1_2_2/libntp/wscript)
uses FFI/support sources. The final diagnostics bundle ships only the query
client and its Python/FFI support, and the predicate rejects daemon payloads,
copied parser symbols, unknown owned files and changes to these reviewed bytes.
