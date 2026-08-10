# strace and gdb for this pack's behavior cases. Both attach to a process with
# ptrace, so the case grants CAP_SYS_PTRACE and starts a target of its own —
# the SUT is a process, not a service.
ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends strace gdb procps \
    && rm -rf /var/lib/apt/lists/*

# The target the cases attach to. It has to keep making syscalls: strace -c
# prints nothing at all when it counted none, so an idle process makes the
# summary case pass or fail on whether the target happened to do anything.
RUN printf '#!/bin/sh\nwhile :; do dd if=/dev/zero of=/dev/null bs=1 count=1 2>/dev/null; done\n' \
        > /usr/local/bin/packtest-busy \
    && chmod 0755 /usr/local/bin/packtest-busy

# Back to the default identity: a case that needs root asks for it, and the
# harness selects it with a Compose user override.
USER packtest
