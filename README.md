# yt-dlp-docker

A transparent, always-latest [yt-dlp](https://github.com/yt-dlp/yt-dlp) in a container.
Install one small executable and `yt-dlp <url>` works exactly like a local install — except
it is always the latest nightly and ships every useful optional dependency (full YouTube
support via Deno + yt-dlp-ejs, `curl_cffi` impersonation, ffmpeg, aria2, AtomicParsley),
with nothing to install or maintain on the host but Docker.

This is a spiritual successor to `mikenye/docker-youtube-dl`. It is **not** a yt-dlp fork.

## Requirements

- Docker, and `bash` on the host (the script runs under its own `#!/usr/bin/env bash` shebang —
  you do **not** need bash as your interactive shell; fish/zsh/etc. all work).
- **Linux host** for transparent file ownership (downloads owned by you). macOS/Windows
  Docker Desktop work too — the VM maps ownership for you (the script omits `--user` there).

## Install

The wrapper is a single executable script, [`shell/yt-dlp-docker.sh`](shell/yt-dlp-docker.sh).
Put it on your `PATH` as `yt-dlp`. Because it is a real executable (not a shell function), it
works identically from **any** shell and from scripts/cron — there is nothing to `source` and
no per-shell variant to maintain.

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/rwz/yt-dlp-docker/main/shell/yt-dlp-docker.sh \
  -o ~/.local/bin/yt-dlp
chmod +x ~/.local/bin/yt-dlp

# optional: the least-privilege variant (see Security) — same file, second name
ln -s yt-dlp ~/.local/bin/yt-dlp-scoped
```

Make sure `~/.local/bin` is on your `PATH` (most setups already do this; otherwise add
`export PATH="$HOME/.local/bin:$PATH"` to your shell config). Then use it like normal:

```sh
yt-dlp https://www.youtube.com/watch?v=...
yt-dlp -x --audio-format mp3 <url>
yt-dlp -o '~/Videos/%(title)s.%(ext)s' <url>      # paths under $HOME work
yt-dlp --cookies ~/cookies.txt <url>
```

The script selects its behavior from the name it is invoked as (`yt-dlp` vs `yt-dlp-scoped`),
so a single file serves both modes.

## Channels

The image defaults to `:nightly` (yt-dlp's recommended channel — freshest extractor fixes,
low regression risk). Switch channels without editing the script via `YTDLP_DOCKER_IMAGE`:

```sh
export YTDLP_DOCKER_IMAGE=ghcr.io/rwz/yt-dlp-docker:stable
```

Available tags:

- `ghcr.io/rwz/yt-dlp-docker:nightly` — default.
- `ghcr.io/rwz/yt-dlp-docker:stable` — monthly-ish stable.
- `ghcr.io/rwz/yt-dlp-docker:latest` — alias for `:stable`.
- `ghcr.io/rwz/yt-dlp-docker:nightly-YYYY.MM.DD` (and `:stable-YYYY.MM.DD`) — immutable date pin / rollback.

## Updating

Nothing to do — the script pulls the image on each run (best-effort, non-fatal: a registry
outage never blocks a download you could otherwise make) and reclaims the previous image so
only the latest is kept on disk. Pin a `:nightly-YYYY.MM.DD` tag (via `YTDLP_DOCKER_IMAGE`) if
you need reproducibility.

## Authentication / cookies

`--cookies-from-browser` cannot work in a container (no browser/keyring). Export a Netscape
`cookies.txt` and pass `--cookies ~/cookies.txt` (visible via the `$HOME` mount). Prefer a
throwaway account — cookies used from a datacenter IP risk bans.

## Security

By default (`yt-dlp`) the script mounts all of `$HOME` (read-write) for maximum fidelity.
Because the container runs as you (`--user` on Linux), this grants no privilege beyond your own
files — but yt-dlp parses untrusted content and supports `--exec`, so a hostile page/config
could read or modify your files.

For least privilege, install the **`yt-dlp-scoped`** symlink (shown in Install) and use it: it
mounts only the current directory (read-write) plus your `~/.config/yt-dlp` (read-only, if it
exists), and sets `HOME` to the working directory. It works from every shell because it is the
same executable invoked under a different name. The trade-off: paths outside the current
directory (e.g. `-o ~/elsewhere`, `--cookies ~/cookies.txt`, `~/.netrc`) are not visible — keep
what you need under the directory you run it from.

Extra hardening for either name: add `--read-only --tmpfs /tmp`.

## Limitations

- Paths containing a `:` are unsupported (Docker `-v` splits on `:`).
- The host needs `bash` available (the script's shebang). Any shell can *invoke* it.

## Architectures

`linux/amd64` and `linux/arm64`. Other arches are intentionally unsupported: Deno (required
for YouTube) has no armv7/musl build.
