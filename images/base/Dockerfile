FROM debian:bookworm-slim@sha256:f06537653ac770703bc45b4b113475bd402f451e85223f0f2837acbf89ab020a
ARG AGENT_USER_UID=1000
ARG AGENT_USER_GID=1000
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ssh ca-certificates gnupg sudo procps less vim jq unzip dos2unix docker.io bc \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*
RUN groupadd -g ${AGENT_USER_GID} agent \
    && useradd -m -u ${AGENT_USER_UID} -g agent -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/agent
USER root
RUN mkdir -p /workspace && chown agent:agent /workspace
USER agent
WORKDIR /workspace
RUN git config --global --add safe.directory /workspace \
    && git config --global core.autocrlf input \
    && git config --global core.filemode false \
    && git config --global user.name "Agent Sandbox" \
    && git config --global user.email "sandbox@localhost"
ENTRYPOINT ["/bin/bash"]
