#!/usr/bin/env bash
# Guards the property the whole layer split exists to deliver: the runtime apt layer
# (~179MB — two thirds of the image) must be byte-identical across rebuilds, so clients
# re-download it only when a Debian package actually changes (~6x/year) rather than on
# every nightly.
#
# It is easy to break by accident. Anything that writes a build-time timestamp into a
# file's *content* churns the layer digest, and the reproducible-build machinery cannot
# help: SOURCE_DATE_EPOCH and rewrite-timestamp normalize file *metadata* only. That is
# how /var/cache/fontconfig went unnoticed — 21KB of *.cache-9 files, baking in the font
# directories' mtimes, re-shipped 179MB to every client daily while 5846 of the layer's
# 5850 files were identical.
#
# Two builds, two ways to break it:
#   A  the pinned base, as CI builds it
#   B  the same base with every mtime rewritten, standing in for a Dependabot base bump
# A vs B differ in both wall-clock build time and base mtimes, so a single comparison
# catches caches keyed on either. Identical layer digest = pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${DOCKERFILE:-$REPO_ROOT/Dockerfile}"
PLATFORM="${PLATFORM:-linux/$(docker version --format '{{.Server.Arch}}')}"

fail() { echo "LAYER STABILITY FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

# --- extract the runtime stanza from the real Dockerfile ------------------------------
# Deliberately strict: if the Dockerfile is restructured this fails loudly rather than
# silently testing something else (same contract as deno-update.yml's regex rewrite).
BASE="$(grep -oE '^FROM debian:trixie-slim@sha256:[0-9a-f]{64}$' "$DOCKERFILE" | tail -1)"
[ -n "$BASE" ] || fail "no 'FROM debian:trixie-slim@sha256:...' line found in $DOCKERFILE"

# The apt RUN block: from the 'RUN echo "apt-epoch:' line through the last continuation.
APT_RUN="$(awk '
  /^RUN echo "apt-epoch:/ { inblock = 1 }
  inblock                 { print; if ($0 !~ /\\$/) exit }
' "$DOCKERFILE")"
[ -n "$APT_RUN" ] || fail "could not locate the 'RUN echo \"apt-epoch:\"' block in $DOCKERFILE"
grep -q 'apt-get install' <<<"$APT_RUN" || fail "extracted block has no apt-get install; extraction drifted"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/Dockerfile.a" <<EOF
$BASE
ARG APT_EPOCH=0
$APT_RUN
EOF

# Rewriting every mtime reproduces what a base rebuild does to file timestamps without
# depending on some older digest still being pullable.
cat > "$WORK/Dockerfile.b" <<EOF
$BASE AS perturbed
RUN find / -xdev -exec touch -h -d @1700000000 {} + 2>/dev/null || true
FROM perturbed
ARG APT_EPOCH=0
$APT_RUN
EOF

echo "== runtime apt layer stability on $PLATFORM =="
echo "   base: ${BASE#FROM }"

# Same flags as build.yml's push step, so this measures what clients actually pull.
build() {
  SOURCE_DATE_EPOCH=0 docker buildx build \
    -f "$WORK/Dockerfile.$1" --platform "$PLATFORM" --no-cache \
    -o "type=oci,dest=$WORK/$1.tar,compression=gzip,rewrite-timestamp=true" \
    "$WORK" >/dev/null 2>&1 || fail "build $1 failed"
}

# Digest of the top layer — the apt layer in both variants (b's perturb step is a
# separate, lower layer).
top_layer() {
  python3 - "$WORK/$1.tar" <<'PY'
import json, sys, tarfile
tf = tarfile.open(sys.argv[1])
blob = lambda d: json.load(tf.extractfile("blobs/sha256/" + d.split(":")[1]))
m = blob(json.load(tf.extractfile("index.json"))["manifests"][0]["digest"])
if "manifests" in m:
    m = blob(m["manifests"][0]["digest"])
print(m["layers"][-1]["digest"])
PY
}

build a; ok "built A (pinned base)"
build b; ok "built B (base with rewritten mtimes)"

A="$(top_layer a)"
B="$(top_layer b)"
echo "   A: $A"
echo "   B: $B"

[ "$A" = "$B" ] || fail "apt layer digest is not reproducible — every rebuild re-ships it
  to every client. Something in the layer embeds a build-time timestamp as file content;
  find it and add its path to the 'rm -rf' at the end of the apt RUN. To locate it, unpack
  both layer blobs and diff the file contents (not mtimes) — the culprit is usually a
  cache under /var/cache."
ok "apt layer digest identical across both builds"

echo "LAYER STABILITY PASSED"
