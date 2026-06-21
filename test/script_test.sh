#!/usr/bin/env bash
# Unit tests for shell/yt-dlp-docker.sh — the executable multi-call wrapper.
# Uses the YTDLP_DOCKER_DRY_RUN seam (prints the docker argv, runs no docker).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../shell/yt-dlp-docker.sh"

export YTDLP_DOCKER_DRY_RUN=1

bindir="$(mktemp -d)"
ln -s "$script" "$bindir/yt-dlp"
ln -s "$script" "$bindir/yt-dlp-scoped"

# Fake docker that logs its argv to a file — lets tests observe pull/prune/run
# without a real daemon. Resolved via PATH only when a test prepends "$bindir".
dockerlog="$bindir/docker.log"
cat > "$bindir/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dockerlog"
EOF
chmod +x "$bindir/docker"

home="$(mktemp -d)"
outside="$(mktemp -d)"
export HOME="$home"
mkdir -p "$home/sub"

fail() { echo "TEST FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

# Count only docker's own -v flags (those before the image ref), so a user-supplied
# yt-dlp -v after the image isn't miscounted as a bind mount.
n_mounts() { printf '%s' "${1%%ghcr.io/*}" | grep -o -- '-v ' | wc -l | tr -d ' '; }

# t1: default mode, CWD under HOME -> exactly one bind mount ($HOME), plus flags
out="$( cd "$home/sub" && "$bindir/yt-dlp" foo )"
echo "$out" | grep -q -- "-v $home:$home"        || fail "t1 missing HOME mount"
[ "$(n_mounts "$out")" = "1" ]                    || fail "t1 expected exactly one -v mount"
echo "$out" | grep -q -- "-e HOME=$home"          || fail "t1 HOME should be real home"
echo "$out" | grep -q 'ghcr.io/rwz/yt-dlp-docker:nightly' || fail "t1 image ref"
echo "$out" | grep -q -- '--cap-drop=ALL'         || fail "t1 cap-drop"
echo "$out" | grep -q -- '--security-opt=no-new-privileges' || fail "t1 no-new-privileges"
ok "t1 default/under-HOME: single HOME mount + flags"

# t2: default mode, CWD outside HOME -> HOME mount AND PWD mount
out="$( cd "$outside" && "$bindir/yt-dlp" foo )"
echo "$out" | grep -q -- "-v $home:$home"        || fail "t2 missing HOME mount"
echo "$out" | grep -q -- "-v $outside:$outside"  || fail "t2 missing PWD mount"
ok "t2 default/outside-HOME: HOME + PWD mounts"

# t3: default mode refuses /
if ( cd / && "$bindir/yt-dlp" foo ) >/dev/null 2>&1; then fail "t3 should refuse /"; fi
msg="$( ( cd / && "$bindir/yt-dlp" foo ) 2>&1 || true )"
echo "$msg" | grep -q 'refusing to run from /'   || fail "t3 missing refusal message"
ok "t3 refuses /"

# t4: --user gated on Linux only
out_linux="$( cd "$home" && YTDLP_DOCKER_OS=Linux "$bindir/yt-dlp" foo )"
echo "$out_linux" | grep -q -- "--user $(id -u):$(id -g)" || fail "t4 Linux should add --user"
if ( cd "$home" && YTDLP_DOCKER_OS=Darwin "$bindir/yt-dlp" foo ) | grep -q -- '--user'; then
  fail "t4 Darwin should NOT add --user"
fi
ok "t4 --user gated on Linux"

# t5: scoped dispatch (basename) — CWD-only mount, HOME=PWD, NOT all of HOME; no config dir yet
out="$( cd "$home/sub" && "$bindir/yt-dlp-scoped" foo )"
echo "$out" | grep -q -- "-v $home/sub:$home/sub" || fail "t5 scoped missing PWD mount"
echo "$out" | grep -q -- "-e HOME=$home/sub"       || fail "t5 scoped HOME should be PWD"
if echo "$out" | grep -q -- "-v $home:$home "; then fail "t5 scoped must NOT mount all of HOME"; fi
if echo "$out" | grep -q -- '/cfg'; then fail "t5 scoped: no config dir -> no /cfg mount"; fi
echo "$out" | grep -q -- '--no-config'             || fail "t5 scoped should pass --no-config"
echo "$out" | grep -q -- '--cap-drop=ALL'                   || fail "t5 scoped missing --cap-drop=ALL"
echo "$out" | grep -q -- '--security-opt=no-new-privileges' || fail "t5 scoped missing no-new-privileges"
echo "$out" | grep -q -- "-w $home/sub"                     || fail "t5 scoped missing -w PWD"
ok "t5 scoped: CWD-only, HOME=PWD, no config when absent"

# t6: scoped with config dir present -> ro mount is a docker flag (before the image);
# --config-locations + --no-config are yt-dlp flags and must come AFTER the image.
mkdir -p "$home/.config/yt-dlp"
out="$( cd "$home/sub" && "$bindir/yt-dlp-scoped" foo )"
echo "$out" | grep -q -- "-v $home/.config/yt-dlp:/cfg:ro" || fail "t6 scoped missing config mount"
preimg="${out%%ghcr.io/rwz/yt-dlp-docker*}"
postimg="${out#*ghcr.io/rwz/yt-dlp-docker:nightly }"
if echo "$preimg" | grep -q -- '--config-locations'; then fail "t6 --config-locations must not be a docker flag"; fi
echo "$postimg" | grep -q -- '--config-locations /cfg' || fail "t6 missing --config-locations after image"
echo "$postimg" | grep -q -- '--no-config'             || fail "t6 missing --no-config after image"
ok "t6 scoped: ro config mount; --no-config + --config-locations passed to yt-dlp"

# t7: caller-shell independence — invoking via a non-bash caller still works (own shebang)
out="$( cd "$home/sub" && sh -c "'$bindir/yt-dlp' foo" )"
echo "$out" | grep -q 'ghcr.io/rwz/yt-dlp-docker:nightly' || fail "t7 sh-caller invocation failed"
ok "t7 runs from a non-bash caller (sh -c)"

# t8: YTDLP_DOCKER_IMAGE override switches the channel
out="$( cd "$home/sub" && YTDLP_DOCKER_IMAGE=ghcr.io/rwz/yt-dlp-docker:stable "$bindir/yt-dlp" foo )"
echo "$out" | grep -q 'ghcr.io/rwz/yt-dlp-docker:stable' || fail "t8 image override ignored"
ok "t8 YTDLP_DOCKER_IMAGE override"

# t9: YTDLP_DOCKER_RUN_ARGS is spliced in before the image (docker-level flags)
out="$( cd "$home/sub" && YTDLP_DOCKER_RUN_ARGS='--read-only --tmpfs /tmp' "$bindir/yt-dlp" foo )"
echo "$out" | grep -q -- '--read-only --tmpfs /tmp ghcr.io/rwz/yt-dlp-docker' \
  || fail "t9 RUN_ARGS not spliced before image"
ok "t9 YTDLP_DOCKER_RUN_ARGS spliced before image"

# t10: YTDLP_DOCKER_NO_PULL skips the per-run pull + prune (but still runs the container)
: > "$dockerlog"
( cd "$home/sub" && YTDLP_DOCKER_DRY_RUN='' YTDLP_DOCKER_NO_PULL=1 PATH="$bindir:$PATH" "$bindir/yt-dlp" foo )
grep -q '^run ' "$dockerlog"           || fail "t10 NO_PULL should still run the container"
if grep -qE 'pull|prune' "$dockerlog"; then fail "t10 NO_PULL must skip pull+prune"; fi
ok "t10 YTDLP_DOCKER_NO_PULL skips pull+prune, still runs"

# t11: without NO_PULL the per-run pull + prune happen
: > "$dockerlog"
( cd "$home/sub" && YTDLP_DOCKER_DRY_RUN='' PATH="$bindir:$PATH" "$bindir/yt-dlp" foo )
grep -q '^pull '      "$dockerlog"     || fail "t11 expected a docker pull"
grep -q 'image prune' "$dockerlog"     || fail "t11 expected a docker image prune"
ok "t11 default path pulls + prunes"

# t12: unset HOME fails with a clear, HOME-mentioning message (not "unbound variable")
rc=0
( unset HOME; cd "$home/sub" && "$bindir/yt-dlp" foo ) >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "t12 expected failure when HOME unset"
msg="$( ( unset HOME; cd "$home/sub" && "$bindir/yt-dlp" foo ) 2>&1 || true )"
echo "$msg" | grep -q 'HOME' || fail "t12 message should mention HOME"
ok "t12 unset HOME fails clearly"

# t13: dry-run performs no docker side effects (no inspect/pull/prune/run)
: > "$dockerlog"
( cd "$home/sub" && PATH="$bindir:$PATH" "$bindir/yt-dlp" foo ) >/dev/null
[ ! -s "$dockerlog" ] || fail "t13 dry-run must not invoke docker: $(cat "$dockerlog")"
ok "t13 dry-run performs no docker side effects"

# t14: a user-supplied yt-dlp -v (verbose) after the image is NOT miscounted as a bind mount
out="$( cd "$home/sub" && "$bindir/yt-dlp" -v https://example.com/x )"
[ "$(n_mounts "$out")" = "1" ] || fail "t14 user -v must not be counted as a mount"
ok "t14 user -v not miscounted as a mount"

echo "SCRIPT TESTS PASSED"
