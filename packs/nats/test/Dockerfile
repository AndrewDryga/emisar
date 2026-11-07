ARG PACKTEST_RUNNER_IMAGE=emisar-runner-tools:latest
FROM ${PACKTEST_RUNNER_IMAGE}
USER root
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) digest=f8a3e106deebed7afe736b7090359bda3aa62a04b310440bedc1d11a93c0ab4f ;; \
      arm64) digest=91c661f1173ee9bfe07514eef55a29d25ac7757a0868c179e825eba976073adc ;; \
      *) exit 1 ;; \
    esac; \
    curl --fail --silent --show-error --location --globoff --proto '=https' \
      --proto-redir '=https' --max-redirs 5 --connect-timeout 10 --max-time 90 \
      "https://github.com/nats-io/natscli/releases/download/v0.5.1/nats-0.5.1-linux-${TARGETARCH}.zip" \
      --output /tmp/nats.zip; \
    printf '%s  /tmp/nats.zip\n' "$digest" | sha256sum -c -; \
    python3 -c 'import pathlib,zipfile; z=zipfile.ZipFile("/tmp/nats.zip"); names=[n for n in z.namelist() if n.endswith("/nats")]; assert len(names)==1; p=pathlib.Path("/usr/local/bin/nats"); p.write_bytes(z.read(names[0])); p.chmod(0o755)'; \
    rm /tmp/nats.zip; \
    nats --version
USER packtest
