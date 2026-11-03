FROM nimlang/nim:2.2.10 AS basic-build
WORKDIR /build
RUN git clone https://github.com/treeform/bassy.git && cd bassy && git checkout a9effcaab13abc9dfe42d7658cf87ee4783b0e14
RUN git clone https://github.com/treeform/fixxy.git && cd fixxy && git checkout 05e5446dffb70093056cebb0c57721a60deaf52a
COPY integrations/softmax/basic_worker.nim /build/basic_worker.nim
RUN nim c -d:release --parallelBuild:1 --path:/build/bassy/src --path:/build/fixxy/src -o:/build/generals-basic basic_worker.nim

FROM python:3.12-slim AS player
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
RUN pip install --no-cache-dir websockets==16.0
COPY integrations/__init__.py /app/integrations/__init__.py
COPY integrations/softmax/__init__.py integrations/softmax/protocol.py integrations/softmax/player.py integrations/softmax/builder_player.py /app/integrations/softmax/
COPY competition/agents/expander_python /app/competition/agents/expander_python
RUN chmod -R a+rX /app
# The runner mounts /tmp destinations. Code and dependencies need no write access.
USER 10001:10001
CMD ["python", "-m", "integrations.softmax.player"]

FROM python:3.12-slim AS game
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 JAX_PLATFORMS=cpu OMP_NUM_THREADS=1
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends util-linux && rm -rf /var/lib/apt/lists/*
COPY --from=basic-build /build/generals-basic /usr/local/bin/generals-basic
COPY --from=basic-build /build/bassy/LICENSE /usr/share/doc/generals-basic/BASSY-LICENSE
COPY --from=basic-build /build/fixxy/LICENSE /usr/share/doc/generals-basic/FIXXY-LICENSE
COPY integrations/softmax/requirements.lock /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
COPY generals /app/generals
COPY integrations/__init__.py /app/integrations/__init__.py
COPY integrations/softmax/__init__.py integrations/softmax/config.py integrations/softmax/protocol.py integrations/softmax/engine.py integrations/softmax/ffa_map.py integrations/softmax/artifacts.py integrations/softmax/replay.py integrations/softmax/server.py integrations/softmax/file_players.py /app/integrations/softmax/
COPY integrations/softmax/static /app/integrations/softmax/static
RUN chmod -R a+rX /app
EXPOSE 8080
CMD ["python", "-m", "integrations.softmax.server"]

FROM game AS hunter
COPY integrations/softmax/hunter_player.py /app/integrations/softmax/
USER 10001:10001
CMD ["python", "-m", "integrations.softmax.hunter_player"]

# The hosted Polyworld engine needs only Nim's standard library. Native desktop
# graphics and their private dependencies remain available in polyworld/.
FROM nimlang/nim:2.2.10 AS polyworld-build
WORKDIR /build
COPY polyworld/src/generals/common.nim polyworld/src/generals/maps.nim polyworld/src/generals/profiles.nim polyworld/src/generals/worlds.nim /build/generals/
COPY integrations/softmax/polyworld_bridge.nim /build/polyworld_bridge.nim
COPY integrations/softmax/polyworld_hosted.nim /build/polyworld_hosted.nim
RUN nim c -d:release --mm:arc --path:/build -o:/build/generals-polyworld /build/polyworld_bridge.nim

FROM nimlang/nim:2.2.10 AS replay-build
RUN apt-get update && apt-get install -y --no-install-recommends python3 xz-utils && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch 5.0.7 https://github.com/emscripten-core/emsdk.git /opt/emsdk && /opt/emsdk/emsdk install 5.0.7 && /opt/emsdk/emsdk activate 5.0.7
ENV PATH=/opt/emsdk/upstream/emscripten:$PATH
WORKDIR /build
COPY polyworld/dependencies.lock /build/polyworld/dependencies.lock
COPY polyworld/tools/fetch_deps.sh /build/polyworld/tools/fetch_deps.sh
RUN sh polyworld/tools/fetch_deps.sh
COPY polyworld /build/polyworld
COPY integrations/softmax/polyworld_hosted.nim integrations/softmax/replay-dependencies.lock /build/integrations/softmax/
COPY integrations/softmax/tools/build_polyworld_viewer.sh /build/integrations/softmax/tools/
RUN bash integrations/softmax/tools/build_polyworld_viewer.sh /build/replay-viewer

FROM python:3.12-slim AS polyworld-game
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 GENERALS_ENGINE=polyworld
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends util-linux && rm -rf /var/lib/apt/lists/*
COPY --from=basic-build /build/generals-basic /usr/local/bin/generals-basic
COPY --from=basic-build /build/bassy/LICENSE /usr/share/doc/generals-basic/BASSY-LICENSE
COPY --from=basic-build /build/fixxy/LICENSE /usr/share/doc/generals-basic/FIXXY-LICENSE
COPY --from=polyworld-build /build/generals-polyworld /usr/local/bin/generals-polyworld
COPY --from=replay-build /build/replay-viewer /app/polyworld-viewer
COPY polyworld/LICENSE /usr/share/doc/generals-polyworld/LICENSE
COPY integrations/softmax/requirements-polyworld.lock /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
COPY generals/assets /app/generals/assets
COPY LICENSE /usr/share/doc/generals-coworld/LICENSE
COPY integrations/__init__.py /app/integrations/__init__.py
COPY integrations/softmax/__init__.py integrations/softmax/config.py integrations/softmax/protocol.py integrations/softmax/polyworld_engine.py integrations/softmax/artifacts.py integrations/softmax/replay.py integrations/softmax/server.py integrations/softmax/file_players.py /app/integrations/softmax/
COPY integrations/softmax/static /app/integrations/softmax/static
RUN chmod -R a+rX /app
EXPOSE 8080
CMD ["python", "-m", "integrations.softmax.server"]
