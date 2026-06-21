# syntax=docker/dockerfile:1

# ---- builder ----
# Base pinned by digest, bumped by Dependabot (docker ecosystem). Keep both FROM
# lines on the same debian:trixie-slim digest — Dependabot updates them together.
FROM debian:trixie-slim@sha256:4e401d95de7083948053197a9c3913343cd06b706bf15eb6a0c3ccd26f436a0e AS builder
ARG YTDLP_REQ="yt-dlp[default,curl-cffi]"
ARG YTDLP_PRE="--pre"
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
# YTDLP_PRE selects the channel: "--pre" (default) = nightly, "" = stable.
# (Named YTDLP_PRE, not PIP_PRE, so it can't collide with pip's PIP_* config env vars.)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir ${YTDLP_PRE} --only-binary=:all: ${YTDLP_REQ} xattr \
    && pip freeze > /opt/venv/requirements.lock

ARG DENO_VERSION=v2.8.3
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) DA=x86_64;  DSUM=30455b845ffa6082209c3590269c910ad3b7efdf28c9879afd4006c47ae54197 ;; \
      arm64) DA=aarch64; DSUM=d4589cc1ffcbf1995c92a0127d932aaf832ac70cfdcc6d5b7bf38043cf303575 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fL "https://github.com/denoland/deno/releases/download/${DENO_VERSION}/deno-${DA}-unknown-linux-gnu.zip" -o /tmp/deno.zip; \
    echo "${DSUM}  /tmp/deno.zip" | sha256sum -c -; \
    unzip /tmp/deno.zip -d /usr/local/bin; \
    chmod +x /usr/local/bin/deno; \
    rm /tmp/deno.zip

# ---- runtime ----
FROM debian:trixie-slim@sha256:4e401d95de7083948053197a9c3913343cd06b706bf15eb6a0c3ccd26f436a0e
LABEL dev.rwz.yt-dlp-docker=true \
      org.opencontainers.image.source=https://github.com/rwz/yt-dlp-docker \
      org.opencontainers.image.description="Transparent, always-latest yt-dlp CLI in Docker" \
      org.opencontainers.image.licenses=Unlicense
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 ffmpeg aria2 atomicparsley ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /usr/local/bin/deno /usr/local/bin/deno
# HOME=/tmp is a writable default for a bare `docker run`; the wrapper overrides it
# to a mounted dir so yt-dlp's cache (notably the yt-dlp-ejs JS solver) persists at
# $HOME/.cache/yt-dlp across runs instead of being thrown away with --rm.
ENV PATH=/opt/venv/bin:$PATH \
    HOME=/tmp
RUN yt-dlp --version > /IMAGE_VERSION \
    && python3 -c 'import sys, curl_cffi' \
    && deno --version
ENTRYPOINT ["tini", "-g", "--", "yt-dlp"]
