FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/yamanori99/DistSSHQueue.jl"
LABEL org.opencontainers.image.documentation="https://github.com/yamanori99/DistSSHQueue.jl/blob/main/testenv/docker-ssh/README.md"
LABEL org.opencontainers.image.description="Linux SSH worker for DistSSHQueue E2E (sshd, rsync, git, Julia 1.13). A DistSSHKit go/drive target, not the queue host."
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV SSH_USER=dev

RUN apt-get update && apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    git \
    openssh-client \
    openssh-server \
    rsync \
    sudo \
    vim-tiny \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash "${SSH_USER}" \
    && echo "${SSH_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${SSH_USER}" \
    && chmod 440 "/etc/sudoers.d/${SSH_USER}"

# Pin major.minor to the package floor (Project.toml `julia`).
# setup --check fails on major.minor mismatch without --ignore-julia-version.
# JULIA_RELEASE is the cache key: the channel stays 1.13 when 1.13.1 becomes
# 1.13.2, so an unpinned juliaup RUN would stay cached.
ARG JULIA_CHANNEL=1.13
ARG JULIA_RELEASE
RUN set -eu; \
    if [ -z "${JULIA_RELEASE}" ]; then \
      echo "JULIA_RELEASE is required (up.sh resolves it from versions.json)" >&2; \
      exit 1; \
    fi; \
    su - "${SSH_USER}" -c "\
    curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
        -fsSL https://install.julialang.org | sh -s -- --yes --default-channel ${JULIA_CHANNEL}"; \
    ln -sf "/home/${SSH_USER}/.juliaup/bin/julia" /usr/local/bin/julia; \
    su - "${SSH_USER}" -c '"$HOME/.juliaup/bin/julia" --version' > /tmp/julia-ver; \
    grep -qx "julia version ${JULIA_RELEASE}" /tmp/julia-ver || { \
      echo "channel ${JULIA_CHANNEL} is not ${JULIA_RELEASE}:" >&2; \
      cat /tmp/julia-ver >&2; \
      exit 1; \
    }; \
    rm -f /tmp/julia-ver

RUN mkdir -p /run/sshd /mounted-keys \
    && mkdir -p "/home/${SSH_USER}/.ssh" \
    && chmod 700 "/home/${SSH_USER}/.ssh" \
    && touch "/home/${SSH_USER}/.ssh/authorized_keys" \
    && chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys" \
    && chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh" \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && ssh-keygen -A

# On start: load mounted-keys/*.pub into authorized_keys; install inter-worker
# identity for dev, then run sshd. (COPY avoids classic-builder heredoc breakage.)
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 22
CMD ["/bin/bash", "/start.sh"]
