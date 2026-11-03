ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE} AS configured

# Medusa supports one data directory, and the runner-tools container reads the
# same paths from its own copy of cassandra.yaml. Both pinned images leave
# these settings commented out; refuse a changed upstream shape instead of
# installing duplicate YAML keys. Password authentication makes Medusa's CQL
# login real.
RUN ! grep -Eq '^(data_file_directories|commitlog_directory):' /etc/cassandra/cassandra.yaml \
    && sed -i \
        -e 's/^authenticator:.*/authenticator: PasswordAuthenticator/' \
        -e 's/^authorizer:.*/authorizer: CassandraAuthorizer/' \
        /etc/cassandra/cassandra.yaml \
    && printf '\ndata_file_directories:\n  - /var/lib/cassandra/data\ncommitlog_directory: /var/lib/cassandra/commitlog\n' \
        >> /etc/cassandra/cassandra.yaml

# Medusa 0.31.1 needs Python 3.11 or 3.12; both pinned images are Debian
# bookworm with Python 3.11. psutil has no aarch64 wheel, so build it here and
# copy only the virtualenv into the client.
FROM configured AS medusa
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc python3-dev python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/medusa \
    && /opt/medusa/bin/pip install --no-cache-dir cassandra-medusa==0.31.1 \
    && test "$(/opt/medusa/bin/medusa --version)" = 0.31.1

FROM configured AS client
COPY --from=medusa /opt/medusa /opt/medusa
COPY fixtures/medusa.ini /etc/medusa/medusa.ini
COPY fixtures/packtest-cassandra-stop fixtures/packtest-cassandra-start /usr/local/bin/
# The runner reads medusa.ini through the cassandra group (gid 999 in both
# images), as the pack's host-access recipe grants it. Restores download into
# MEDUSA_RESTORE_TEMP_DIR and run as root.
RUN ln -s /opt/medusa/bin/medusa /opt/medusa/bin/medusa-wrapper /usr/local/bin/ \
    && chown root:cassandra /etc/medusa/medusa.ini \
    && chmod 0640 /etc/medusa/medusa.ini \
    && chmod 0755 /usr/local/bin/packtest-cassandra-stop /usr/local/bin/packtest-cassandra-start \
    && install -d -m 0700 /srv/medusa-restore

FROM configured AS sut
COPY fixtures/packtest-supervise /usr/local/bin/packtest-supervise
RUN chmod 0755 /usr/local/bin/packtest-supervise
ENTRYPOINT ["/usr/local/bin/packtest-supervise"]
