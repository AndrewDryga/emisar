ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE} AS configured

# Both pinned images leave these storage settings commented out. Refuse a
# changed upstream shape instead of silently installing duplicate YAML keys.
RUN ! grep -Eq '^(data_file_directories|commitlog_directory):' /etc/cassandra/cassandra.yaml \
    && sed -i \
        -e 's/^authenticator:.*/authenticator: PasswordAuthenticator/' \
        -e 's/^authorizer:.*/authorizer: CassandraAuthorizer/' \
        /etc/cassandra/cassandra.yaml \
    && printf '\ndata_file_directories:\n  - /var/lib/cassandra/data\n  - "/srv/cassandra extra data"\ncommitlog_directory: "/srv/cassandra commitlog"\n# disk-config-extra-fixture-42c8\n' \
        >> /etc/cassandra/cassandra.yaml \
    && install -d -o cassandra -g cassandra -m 0750 \
        /var/lib/cassandra/data '/srv/cassandra extra data' '/srv/cassandra commitlog' \
        /tmp/cassandra-outside \
    && touch /tmp/cassandra-outside/cassandra-outside-sentinel-9e31 \
    && touch /var/lib/cassandra/cassandra-parent-sentinel-4dd0 \
    && ln -s /tmp/cassandra-outside /var/lib/cassandra/data/escapeproof

FROM configured AS client

RUN mkdir -p /tmp/packtest/.cassandra \
    && printf '[authentication]\ncredentials = /tmp/packtest/.cassandra/credentials\n' \
        > /tmp/packtest/.cassandra/cqlshrc \
    && printf '[plain_text_auth]\nusername = cassandra\npassword = packtest-canary-cassandra-49ab\n\n[PlainTextAuthProvider]\nusername = cassandra\npassword = packtest-canary-cassandra-49ab\n' \
        > /tmp/packtest/.cassandra/credentials \
    && chmod 600 /tmp/packtest/.cassandra/credentials \
    && chown -R 65532:65532 /tmp/packtest

FROM configured AS sut
