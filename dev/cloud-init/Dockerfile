FROM ubuntu:resolute-20261105.1@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloud-init \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["cloud-init"]
