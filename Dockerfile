FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="clone-tests"
LABEL org.opencontainers.image.description="Continuous git clone speed and network diagnostics for GitHub.com"
LABEL org.opencontainers.image.source="https://github.com/maxwellpower/clone-tests"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    curl \
    ca-certificates \
    mtr-tiny \
    dnsutils \
    bind9-host \
    traceroute \
    iproute2 \
    iputils-ping \
    net-tools \
    perl \
    coreutils \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY clone-tests.sh analyze.sh .version ./
RUN chmod +x clone-tests.sh analyze.sh

# Logs are written here — mount a host volume to persist them
VOLUME /app/logs

ENTRYPOINT ["./clone-tests.sh"]
