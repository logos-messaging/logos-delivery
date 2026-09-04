# BUILD NIM APP ----------------------------------------------------------------
FROM rustlang/rust:nightly-alpine3.19 AS nim-build

ARG NIMFLAGS
ARG MAKE_TARGET=wakunode2
ARG NIM_COMMIT
ARG HEAPTRACK_BUILD=0
ARG POSTGRES=0
# Jenkins and `make docker-image` pass both of these as build arguments.
#
# DEBUG selects the build mode. Make reads 0 as release and an unset value as
# debug, so no default here leaves a direct `docker build` unchanged.
# `make docker-image` passes DEBUG=0.
ARG DEBUG
# LOG_LEVEL is the chronicles compile-time floor: statements below it are not
# compiled into the binary. Unset leaves whatever default the build target
# already applies.
ARG LOG_LEVEL

# Get build tools and required header files
RUN apk add --no-cache bash git build-base openssl-dev linux-headers curl jq libbsd-dev

WORKDIR /app
COPY . .

# workaround for alpine issue: https://github.com/alpinelinux/docker-alpine/issues/383
RUN apk update && apk upgrade

# Ran separately from 'make' to avoid re-doing
RUN git submodule update --init --recursive

# Slowest build step for the sake of caching layers
RUN make -j$(nproc) deps QUICK_AND_DIRTY_COMPILER=1 ${NIM_COMMIT}

# The heaptracker hooks live in Nim's allocator, so patch the Nim that deps
# installed. Resolve it from the symlink rather than assuming a path.
RUN if [ "$HEAPTRACK_BUILD" = "1" ]; then \
      export PATH="$HOME/.nimble/bin:$PATH"; \
      NIM_ROOT=$(dirname "$(dirname "$(readlink -f "$(command -v nim)")")"); \
      git -C "$NIM_ROOT" apply /app/docs/tutorial/nim.2.2.4_heaptracker_addon.patch; \
    fi

# Build the final node binary
# -d:disableMarchNative is appended here, not left to the caller. Without it
# config.nims adds -march=native, and the image may then require CPU features
# unavailable on the runtime host. NIMFLAGS is applied last, so a caller can
# still add to it.
RUN make -j$(nproc) ${NIM_COMMIT} $MAKE_TARGET NIMFLAGS="${NIMFLAGS} -d:disableMarchNative" POSTGRES=${POSTGRES} DEBUG=${DEBUG} LOG_LEVEL=${LOG_LEVEL} HEAPTRACKER=${HEAPTRACK_BUILD}


# PRODUCTION IMAGE -------------------------------------------------------------

FROM alpine:3.18 AS prod

ARG MAKE_TARGET=wakunode2

LABEL maintainer="jakub@status.im"
LABEL source="https://github.com/waku-org/nwaku"
LABEL description="Wakunode: Waku client"
LABEL commit="unknown"
LABEL version="unknown"

# DevP2P, LibP2P, and JSON RPC ports
EXPOSE 30303 60000 8545

# Referenced in the binary
RUN apk add --no-cache libgcc libpq-dev bind-tools libstdc++

# Copy to separate location to accomodate different MAKE_TARGET values
COPY --from=nim-build /app/build/$MAKE_TARGET /usr/local/bin/

# Copy migration scripts for DB upgrades
COPY --from=nim-build /app/migrations/ /app/migrations/

# Symlink the correct wakunode binary
RUN ln -sv /usr/local/bin/$MAKE_TARGET /usr/bin/wakunode

ENTRYPOINT ["/usr/bin/wakunode"]

# By default just show help if called without arguments
CMD ["--help"]


# LOGOS DELIVERY NODE IMAGE ----------------------------------------------------

# Reuses the prod image but exposes the binary under its own name so the image
# identity and entrypoint are logosdeliverynode rather than the generic
# /usr/bin/wakunode symlink. Build with --build-arg MAKE_TARGET=logosdeliverynode.
FROM prod AS logosdeliverynode

LABEL source="https://github.com/logos-messaging/logos-delivery"
LABEL description="Logos Delivery node"

RUN ln -sv /usr/local/bin/logosdeliverynode /usr/bin/logosdeliverynode

ENTRYPOINT ["/usr/bin/logosdeliverynode"]


# DEBUG IMAGE ------------------------------------------------------------------

# Build debug tools: heaptrack
FROM alpine:3.18 AS heaptrack-build

RUN apk update
RUN apk add -- gdb git g++ make cmake zlib-dev boost-dev libunwind-dev
RUN git clone https://github.com/KDE/heaptrack.git /heaptrack

WORKDIR /heaptrack/build
# going to a commit that builds properly. We will revisit this for new releases
RUN git reset --hard f9cc35ebbdde92a292fe3870fe011ad2874da0ca
RUN cmake -DCMAKE_BUILD_TYPE=Release ..
RUN make -j$(nproc)


# Debug image
FROM prod AS debug-with-heaptrack

RUN apk add --no-cache gdb libunwind

# Add heaptrack
COPY --from=heaptrack-build /heaptrack/build/ /heaptrack/build/

ENV LD_LIBRARY_PATH=/heaptrack/build/lib/heaptrack/
RUN ln -s /heaptrack/build/bin/heaptrack /usr/local/bin/heaptrack

ENTRYPOINT ["/heaptrack/build/bin/heaptrack", "/usr/bin/wakunode"]
