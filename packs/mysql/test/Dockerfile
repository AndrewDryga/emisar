# The real client for this pack's cases, from the image under test, so its version
# tracks the server's. The shared image's `mysql` is MariaDB's client, which accepted
# `\G` in batch mode while the MySQL 9 client refuses it, so that failure could not
# show there.
ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}

# The runner's uid has no passwd entry, so the client would log in as UNKNOWN_USER.
RUN printf '[client]\nuser=root\n' > /etc/mysql/conf.d/packtest-client.cnf
