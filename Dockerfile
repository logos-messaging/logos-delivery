# BUILD NIM APP ----------------------------------------------------------------
FROM rustlang/rust:nightly-alpine3.19 AS nim-build

ARG NIMFLAGS
ARG MAKE_TARGET=wakunode2
ARG NIM_COMMIT
ARG LOG_LEVEL=TRACE
ARG HEAPTRACK_BUILD=0

# Get build tools and required header files
RUN apk add --no-cache bash git build-base openssl-dev linux-headers curl jq bsd-compat-headers

WORKDIR /app
COPY . .

# workaround for alpine issue: https://github.com/alpinelinux/docker-alpine/issues/383
RUN apk update && apk upgrade

# Ran separately from 'make' to avoid re-doing
RUN git submodule update --init --recursive

RUN if [ "$HEAPTRACK_BUILD" = "1" ]; then \
      git apply --directory=vendor/nimbus-build-system/vendor/Nim docs/tutorial/nim.2.2.4_heaptracker_addon.patch; \
    fi

# Slowest build step for the sake of caching layers
RUN make -j$(nproc) deps QUICK_AND_DIRTY_COMPILER=1 ${NIM_COMMIT}

# Build the final node binary
RUN make -j$(nproc) ${NIM_COMMIT} $MAKE_TARGET LOG_LEVEL=${LOG_LEVEL} NIMFLAGS="${NIMFLAGS}"


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
RUN apk add --no-cache libgcc libpq-dev bind-tools

# Copy to separate location to accomodate different MAKE_TARGET values
COPY --from=nim-build /app/build/$MAKE_TARGET /usr/local/bin/

# Copy migration scripts for DB upgrades
COPY --from=nim-build /app/migrations/ /app/migrations/

# Symlink the correct wakunode binary
RUN ln -sv /usr/local/bin/$MAKE_TARGET /usr/bin/wakunode

ENTRYPOINT ["/usr/bin/wakunode"]

# By default just show help if called without arguments
CMD ["--help"]


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
