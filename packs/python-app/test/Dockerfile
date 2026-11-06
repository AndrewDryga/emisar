# The action client is the pinned Python image itself, so the interpreter the
# actions run, and the pip every case's venv bootstraps from it, are exactly
# the build the version row names.
ARG PACKTEST_IMAGE
FROM ${PACKTEST_IMAGE}

# The runner identity owns /opt/app so a case can create its venv at the
# default PY_VENV, /opt/app/venv, without overriding it.
RUN groupadd --gid 65532 packtest \
    && useradd --uid 65532 --gid 65532 --no-create-home --no-log-init --home-dir /tmp/packtest packtest \
    && install -d -o 65532 -g 65532 /opt/app

# The wheels the cases install. A case's venv carries a pip.conf pointing pip
# here and never at an index, so no case reaches the network.
COPY fixtures/wheels.py /opt/packtest/wheels.py
RUN python3 /opt/packtest/wheels.py /opt/packtest/wheels
