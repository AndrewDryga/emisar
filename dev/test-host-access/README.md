# Host-access recipe proof

`./run test pack-access [pack ...]` executes every selected
`setup.host_access` recipe on a disposable Debian or Fedora systemd host.

Each structured pack owns `test/host_access.yaml`. A proof names the exact
host-access group and recipe, one action mapped by that group, the protected
resource's denied starting state, any resource recreation that must survive,
and the direct access probe. The harness:

1. starts `emisar.service` as the default unprivileged service identity;
2. requires the mapped action's protected-resource probe to fail;
3. runs the recipe's published commands directly from `pack.yaml`;
4. runs the recipe's published verification commands;
5. recreates the protected resource when the proof declares one;
6. restarts `emisar.service`; and
7. reruns verification and the probe under the service's resulting user,
   groups, and ambient capabilities with `NoNewPrivileges=yes`.

The fixture stubs only service client calls whose server protocol is unrelated
to the Linux authority boundary, such as `rndc status` and `docker info`. Pack
behavior plans remain the evidence for vendor behavior. This suite proves the
published OS grant itself and never counts a stub as action behavior.

`./run check packs` fails if any published recipe lacks exactly one pack-owned
proof or if the proof names an action outside that access group. CI and the
weekly pack-behavior workflow execute the full recipe suite on Linux.
