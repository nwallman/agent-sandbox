FROM agent-sandbox:base
USER root
RUN npm install -g pnpm
RUN apt-get update && apt-get install -y --no-install-recommends chromium && rm -rf /var/lib/apt/lists/*
RUN mv /usr/bin/chromium /usr/bin/chromium-bin \
    && printf '#!/bin/sh\nexec /usr/bin/chromium-bin --no-sandbox --disable-setuid-sandbox "$@"\n' > /usr/bin/chromium \
    && chmod +x /usr/bin/chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
USER agent
WORKDIR /workspace
