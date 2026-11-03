# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS compiler
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ git curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-linux_x64.tar.xz \
    | tar xJ -C /opt
ENV PATH=/opt/nim-2.2.10/bin:$PATH \
    POLYWORLD_DEPS=/workspace/deps \
    GIT_TERMINAL_PROMPT=0
WORKDIR /workspace/generals
COPY dependencies.lock ./
COPY tools/fetch_deps.sh tools/fetch_deps.sh
# The optional credential exists only during dependency checkout.
RUN --mount=type=secret,id=github_token \
    if [ -s /run/secrets/github_token ]; then \
      export GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=credential.helper \
        GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; printf "password="; cat /run/secrets/github_token; echo; }; f'; \
    fi; \
    sh tools/fetch_deps.sh
COPY config.nims ./
COPY src src
RUN nim c --skipParentCfg:on -d:release -d:coworld \
    --nimcache:/tmp/generals-cache -o:/out/generals src/generals.nim
RUN mkdir -p /out/licenses && \
    for dependency in /workspace/deps/*; do \
      name=$(basename "$dependency"); \
      for license in "$dependency"/LICENSE "$dependency"/LICENSE.*; do \
        if [ -f "$license" ]; then \
          mkdir -p "/out/licenses/$name"; \
          cp "$license" "/out/licenses/$name/"; \
        fi; \
      done; \
    done

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4t64 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=compiler /out/generals /usr/local/bin/generals
COPY LICENSE /usr/share/doc/generals/LICENSE
COPY --from=compiler /out/licenses /usr/share/doc/generals/dependencies
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/generals"]
