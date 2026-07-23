ARG PACKTEST_VERSION=5.0.8
ARG PACKTEST_DIGEST
FROM cassandra:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS client

RUN mkdir -p /tmp/packtest/.cassandra \
    && printf '[authentication]\ncredentials = /tmp/packtest/.cassandra/credentials\n' \
        > /tmp/packtest/.cassandra/cqlshrc \
    && printf '[plain_text_auth]\nusername = cassandra\npassword = packtest-canary-cassandra-49ab\n\n[PlainTextAuthProvider]\nusername = cassandra\npassword = packtest-canary-cassandra-49ab\n' \
        > /tmp/packtest/.cassandra/credentials \
    && chmod 600 /tmp/packtest/.cassandra/credentials \
    && chown -R 65532:65532 /tmp/packtest

FROM cassandra:${PACKTEST_VERSION}${PACKTEST_DIGEST} AS sut

RUN sed -i \
        -e 's/^authenticator:.*/authenticator: PasswordAuthenticator/' \
        -e 's/^authorizer:.*/authorizer: CassandraAuthorizer/' \
        /etc/cassandra/cassandra.yaml
