ARG PACKTEST_VERSION=4.3.3-management
ARG PACKTEST_DIGEST
FROM rabbitmq:${PACKTEST_VERSION}${PACKTEST_DIGEST}
# A minimal AMQP client so a behavior case can HOLD a live connection open —
# close_connection needs a real connection to act on, and rabbitmqctl /
# rabbitmqadmin keep no AMQP session of their own.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pika \
    && rm -rf /var/lib/apt/lists/*
