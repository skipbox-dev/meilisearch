# Compile
FROM    rust:1.99-alpine3.22 AS chef

RUN     apk add -q --no-cache -u ca-certificates build-base openssl-dev

# cargo-chef splits the build in two: the dependencies, which only change
# with Cargo.toml/Cargo.lock, and Meilisearch's own crates. This keeps the
# dependency layer cached when only Meilisearch's code changes.
RUN     cargo install --locked cargo-chef@0.1.78

WORKDIR /

# Install the toolchain pinned in rust-toolchain.toml once, so that the
# dependencies and Meilisearch are compiled with the same compiler.
COPY    rust-toolchain.toml .
RUN     rustup toolchain install

# Compute the dependency recipe (manifests and lock file only)
FROM    chef AS planner

COPY    . .
RUN     cargo chef prepare --recipe-path recipe.json

FROM    chef AS compiler

ARG     EXTRA_ARGS
ENV     RUSTFLAGS="-C target-feature=-crt-static"

# Build the dependencies only. This layer is reused as long as the recipe,
# the features and the toolchain stay the same.
COPY    --from=planner /recipe.json recipe.json
RUN     cargo chef cook --release -p meilisearch -p meilitool ${EXTRA_ARGS} --recipe-path recipe.json

# These change with every commit, so they come after the dependency layer.
ARG     COMMIT_SHA
ARG     COMMIT_DATE
ARG     GIT_TAG
ENV     VERGEN_GIT_SHA=${COMMIT_SHA} VERGEN_GIT_COMMIT_TIMESTAMP=${COMMIT_DATE} VERGEN_GIT_DESCRIBE=${GIT_TAG}

COPY    . .
RUN     set -eux; \
        apkArch="$(apk --print-arch)"; \
        cargo build --release -p meilisearch -p meilitool ${EXTRA_ARGS}

# Run
FROM    alpine:3.22 AS runtime
LABEL   org.opencontainers.image.source="https://github.com/meilisearch/meilisearch"

ENV     MEILI_HTTP_ADDR 0.0.0.0:7700
ENV     MEILI_SERVER_PROVIDER docker

RUN     apk add -q --no-cache -u ca-certificates-bundle libgcc tini curl

# add meilisearch and meilitool to the `/bin` so you can run it from anywhere
# and it's easy to find.
COPY    --from=compiler /target/release/meilisearch /bin/meilisearch
COPY    --from=compiler /target/release/meilitool /bin/meilitool
# To stay compatible with the older version of the container (pre v0.27.0) we're
# going to symlink the meilisearch binary in the path to `/meilisearch`
RUN     ln -s /bin/meilisearch /meilisearch

# This directory should hold all the data related to meilisearch so we're going
# to move our PWD in there.
# We don't want to put the meilisearch binary
WORKDIR /meili_data


EXPOSE  7700/tcp

ENTRYPOINT ["tini", "--"]
CMD     /bin/meilisearch
