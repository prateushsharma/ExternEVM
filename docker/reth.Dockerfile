FROM rust:1.83 AS builder

WORKDIR /build
COPY ./reth ./reth
WORKDIR /build/reth

RUN cargo build --release -p reth --bin reth

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates curl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/reth/target/release/reth /usr/local/bin/reth
COPY ./docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 8545 8546 30303

ENTRYPOINT ["/entrypoint.sh"]