#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-yt-dlp-docker:test}"
BUILD="${BUILD:-1}"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

if [ "$BUILD" = "1" ]; then
  echo "Building $IMAGE ..."
  docker build -t "$IMAGE" .
fi

echo "== core capabilities on $IMAGE =="

# yt-dlp runs and prints a date-style version
docker run --rm "$IMAGE" --version | grep -qE '^[0-9]{4}\.[0-9]' \
  || fail "yt-dlp --version not a date-style version"
ok "yt-dlp --version"

# /IMAGE_VERSION baked in, looks like a yt-dlp version (YYYY.MM.DD[...])
docker run --rm --entrypoint cat "$IMAGE" /IMAGE_VERSION | grep -qE '^[0-9]{4}\.[0-9]' \
  || fail "/IMAGE_VERSION missing or malformed"
ok "/IMAGE_VERSION present"

# entrypoint is exactly: tini -g -- yt-dlp
ep="$(docker image inspect --format '{{join .Config.Entrypoint " "}}' "$IMAGE")"
[ "$ep" = "tini -g -- yt-dlp" ] || fail "entrypoint is '$ep', expected 'tini -g -- yt-dlp'"
ok "entrypoint tini -g -- yt-dlp"

# required binaries on PATH
docker run --rm --entrypoint sh "$IMAGE" -c '
  for b in ffmpeg ffprobe aria2c AtomicParsley deno yt-dlp; do
    command -v "$b" >/dev/null || { echo "missing $b"; exit 1; }
  done' || fail "a required binary is missing"
ok "ffmpeg/ffprobe/aria2c/AtomicParsley/yt-dlp present"

# curl_cffi importable (impersonation library actually installed)
docker run --rm --entrypoint python3 "$IMAGE" -c 'import curl_cffi' \
  || fail "curl_cffi not importable"
ok "curl_cffi importable"

# yt-dlp can enumerate impersonate targets (proves curl_cffi is wired in)
docker run --rm "$IMAGE" --list-impersonate-targets 2>/dev/null | grep -qiE 'chrome.*curl_cffi$' \
  || fail "no working impersonate target (chrome via curl_cffi) listed"
ok "impersonate targets listed"

echo "== Deno / JS runtime =="

# deno present and recent enough (>= 2.x)
docker run --rm --entrypoint deno "$IMAGE" --version | grep -qE '^deno 2\.' \
  || fail "deno missing or older than 2.x"
ok "deno 2.x present"

# yt-dlp's debug header detects deno and does NOT warn about a missing JS runtime.
# `yt-dlp -v` prints the [debug] header (then exits with a usage error, hence || true).
hdr="$(docker run --rm "$IMAGE" -v 2>&1 || true)"
echo "$hdr" | grep -qi 'JS runtimes:' || fail "no 'JS runtimes:' line in -v header"
echo "$hdr" | grep -i 'JS runtimes:' | grep -qi 'deno' || fail "yt-dlp did not detect deno"
if echo "$hdr" | grep -qi 'No supported JavaScript runtime'; then
  fail "yt-dlp reports no JS runtime (YouTube would be degraded)"
fi
ok "yt-dlp detects deno; no JS-runtime degradation warning"

echo "CORE SMOKE PASSED"
