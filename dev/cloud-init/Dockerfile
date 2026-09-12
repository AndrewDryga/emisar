FROM ubuntu:26.04@sha256:513c074113a871b51a8d16ab445c88779d6452d937a164fb5cc479f32668a41d

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloud-init \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["cloud-init"]
