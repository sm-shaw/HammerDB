FROM ubuntu:24.04
LABEL maintainer="Pooja Jain"

ARG TARGETARCH
ARG HAMMERDB_VERSION=6.0

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl unzip gnupg apt-utils iputils-ping vim \
        netcat-traditional libxft-dev libcairo2-dev xauth python3 \
        libaio1t64 file && \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) \
            archive="HammerDB-${HAMMERDB_VERSION}-Prod-Lin-UBU24.tar.gz"; \
            sha1="b66c66d4bb436cb942e6535b1fbbb11b5fee7a27" \
            ;; \
        arm64) \
            archive="HammerDB-${HAMMERDB_VERSION}-Prod-Lin-UBU24-ARM64.tar.gz"; \
            sha1="f80a54f841231a75b03a395bb388a92c2e45f494" \
            ;; \
        *) \
            echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; \
            exit 1 \
            ;; \
    esac; \
    curl --fail --location --show-error \
        "https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/${archive}" \
        --output "/tmp/${archive}"; \
    echo "${sha1}  /tmp/${archive}" | sha1sum --check -; \
    tar -xzf "/tmp/${archive}" -C /home; \
    ln -s "/home/HammerDB-${HAMMERDB_VERSION}" /home/hammerdb; \
    rm -f "/tmp/${archive}"

WORKDIR /home/hammerdb

CMD ["tail", "-f", "/dev/null"]
