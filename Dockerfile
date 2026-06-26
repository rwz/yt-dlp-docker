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
#
# Install into a plain --target tree, then split it: yt-dlp + yt-dlp-ejs (which change
# every nightly) go to /opt/ytdlp; the heavy, slow-moving deps (curl-cffi, pycryptodomex,
# …) stay in /opt/deps. The runtime stage COPYs them as two layers so a nightly bump only
# re-ships the small /opt/ytdlp layer. --no-compile ships no build-time .pyc, whose embedded
# source mtimes would otherwise make the layers non-reproducible (defeating the split).
RUN pip install --no-cache-dir --no-compile ${YTDLP_PRE} --only-binary=:all: \
      --target /opt/deps ${YTDLP_REQ} \
 && mkdir -p /opt/ytdlp \
 && mv /opt/deps/yt_dlp /opt/deps/yt_dlp-*.dist-info \
       /opt/deps/yt_dlp_ejs /opt/deps/yt_dlp_ejs-*.dist-info /opt/ytdlp/

# Deno is hand-pinned: bump DENO_VERSION and BOTH DSUM checksums together from
# https://github.com/denoland/deno/releases — Dependabot does not track this raw
# download. Each DSUM is the sha256 of that arch's .zip.
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
    unzip -j /tmp/deno.zip deno -d /usr/local/bin; \
    chmod +x /usr/local/bin/deno; \
    rm /tmp/deno.zip

# ---- runtime ----
FROM debian:trixie-slim@sha256:4e401d95de7083948053197a9c3913343cd06b706bf15eb6a0c3ccd26f436a0e
LABEL dev.rwz.yt-dlp-docker=true \
      org.opencontainers.image.source=https://github.com/rwz/yt-dlp-docker \
      org.opencontainers.image.description="Transparent, always-latest yt-dlp CLI in Docker" \
      org.opencontainers.image.licenses=Unlicense
# Also drop apt/dpkg logs + the ldconfig aux-cache (not just apt lists): they embed
# build-time timestamps as file *content*, which the reproducible-build timestamp
# rewrite can't normalize — leaving them re-churns this layer's digest every rebuild.
#
# apt-get upgrade pulls Debian security patches for packages already baked into the
# digest-pinned base and their transitive deps (e.g. libssh2, in via aria2). The pin
# freezes the base layer, so without this an installed-but-vulnerable package never
# gets the fix and the Trivy gate (ignore-unfixed) goes red the day Debian publishes
# one. Still reproducible — the layer just legitimately re-ships when a pkg changes.
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
      python3 ffmpeg aria2 atomicparsley ca-certificates tini \
    && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache
# Deps first (heavy, slow-moving) then yt-dlp (thin, changes nightly), as two layers, so
# the big deps layer keeps its digest across nightlies and only the small one re-downloads.
COPY --from=builder /opt/deps /opt/deps
COPY --from=builder /opt/ytdlp /opt/ytdlp
COPY --from=builder /usr/local/bin/deno /usr/local/bin/deno
# pip --target writes no console script, so provide a trivial one. yt-dlp goes first on
# PYTHONPATH so the thin layer shadows the deps tree; python3 is the base image's (same
# debian digest as the builder → matching ABI for the compiled deps). DONTWRITEBYTECODE
# keeps --rm runs from littering the trees with throwaway .pyc.
# HOME=/tmp is a writable default for a bare `docker run`; the wrapper overrides it
# to a mounted dir so yt-dlp's cache (notably the yt-dlp-ejs JS solver) persists at
# $HOME/.cache/yt-dlp across runs instead of being thrown away with --rm.
ENV PYTHONPATH=/opt/ytdlp:/opt/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/tmp
RUN printf '#!/usr/bin/env python3\nimport sys\nfrom yt_dlp import main\nsys.exit(main())\n' \
      > /usr/local/bin/yt-dlp \
 && chmod +x /usr/local/bin/yt-dlp
RUN yt-dlp --version > /IMAGE_VERSION \
    && python3 -c 'import curl_cffi, Cryptodome' \
    && deno --version
ENTRYPOINT ["tini", "-g", "--", "yt-dlp"]
