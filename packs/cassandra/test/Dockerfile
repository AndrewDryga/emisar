ARG PACKTEST_VERSION=5.0.8
FROM cassandra:${PACKTEST_VERSION} AS client

RUN mkdir -p /root/.cassandra \
    && printf '[authentication]\ncredentials = /root/.cassandra/credentials\n' \
        > /root/.cassandra/cqlshrc \
    && printf '[plain_text_auth]\nusername = cassandra\npassword = cassandra\n\n[PlainTextAuthProvider]\nusername = cassandra\npassword = cassandra\n' \
        > /root/.cassandra/credentials \
    && chmod 600 /root/.cassandra/credentials

FROM cassandra:${PACKTEST_VERSION} AS sut

RUN sed -i \
        -e 's/^authenticator:.*/authenticator: PasswordAuthenticator/' \
        -e 's/^authorizer:.*/authorizer: CassandraAuthorizer/' \
        /etc/cassandra/cassandra.yaml
