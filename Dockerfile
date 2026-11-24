# syntax=docker/dockerfile:1
# AddonSim in a container: the simulator built from these sources, served on port 8765, its data in one volume, the
# host's folders it may browse (for your AddOns folder) mounted at /host.
#
#   docker compose up --build            (compose.yaml: your home folder browsable; ADDONSIM_FOLDER for another)
#
# or by hand:
#
#   docker build -t addonsim .
#   docker run --rm -p 127.0.0.1:8765:8765 -v addonsim-data:/data -v "<a folder with your addons in it>:/host:ro" addonsim
#
# then open http://localhost:8765/ and choose your AddOns folder in the page (its folder browser starts at /host).
# docs/docker.md has the rest (a project's scenarios with the CLI, settings, what is kept where).

ARG BUN_VERSION=1.4.5

# The native core (native/: the scene's walk and layout, the stream's store), built for this system
FROM rust:1-bookworm AS native
WORKDIR /build/native
COPY native/Cargo.toml native/Cargo.lock ./
COPY native/src ./src
RUN cargo build --release --locked

# LuaJIT 2.1 from its sources: the simulator runs on the current 2.1 (the distribution's package is years older)
FROM debian:bookworm-slim AS luajit
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
ARG LUAJIT_BRANCH=v2.1
RUN mkdir -p /build/luajit \
    && curl -fsSL "https://github.com/LuaJIT/LuaJIT/archive/refs/heads/${LUAJIT_BRANCH}.tar.gz" \
        | tar -xz --strip-components=1 -C /build/luajit \
    && make -C /build/luajit -j"$(nproc)" PREFIX=/usr/local \
    && make -C /build/luajit install PREFIX=/usr/local DESTDIR=/out

FROM oven/bun:${BUN_VERSION}
COPY --from=luajit /out/usr/local/ /usr/local/
WORKDIR /app
# The dependencies first, so a change to the sources does not install them again
COPY package.json bun.lock bunfig.toml ./
RUN bun install --frozen-lockfile
COPY . .
COPY --from=native /build/native/target/release/libaddonsim_native.so native/target/release/
# Everything the app keeps (the game's files, the saved variables, the interface source, the settings) lives in /data:
# the checkout's own folders point there. `addonsim` is the CLI, and the package a project's config imports
# (/node_modules is where a project mounted anywhere finds it)
RUN mkdir -p /data/cache /data/saved /data/interface /data/config /host \
    && rm -rf cache saved interface \
    && ln -s /data/cache cache && ln -s /data/saved saved && ln -s /data/interface interface \
    && mkdir -p /node_modules && ln -s /app /node_modules/addonsim \
    && printf '#!/bin/sh\nexec bun /app/src/cli/main.ts "$@"\n' > /usr/local/bin/addonsim \
    && chmod +x /usr/local/bin/addonsim docker/entrypoint.sh \
    && chown -R bun:bun /data /app/cache /app/saved /app/interface \
    && luajit -v
ENV ADDONSIM_HOST=0.0.0.0 \
    ADDONSIM_NO_BROWSER=1 \
    ADDONSIM_BROWSE=/host \
    XDG_CONFIG_HOME=/data/config
USER bun
VOLUME ["/data"]
EXPOSE 8765
ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["bun", "run", "start"]
