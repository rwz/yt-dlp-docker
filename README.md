# yt-dlp-docker

A transparent, always-latest [yt-dlp](https://github.com/yt-dlp/yt-dlp) in a container.
Install one small executable and `yt-dlp <url>` works exactly like a local install — except
it tracks the latest yt-dlp nightly by default (a `:stable` channel is also available) and
ships every useful optional dependency (full YouTube support via Deno + yt-dlp-ejs,
`curl_cffi` impersonation, ffmpeg, aria2, AtomicParsley),
with nothing to install or maintain on the host but Docker.

## Requirements

[Docker](https://docs.docker.com/get-docker/) installed and running — the only host dependency.
On macOS, start Docker Desktop (or Colima) first.

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
ln -sf yt-dlp ~/.local/bin/yt-dlp-scoped
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

Nothing to do — the script pulls the image on each run (best-effort, non-fatal: once the image
is cached, a registry outage won't block you — only a first-ever run needs the registry) and
prunes the now-untagged previous
image of the same tag, so a single rolling tag (e.g. `:nightly`) never accumulates old layers.
Images you've explicitly pinned (`:nightly-YYYY.MM.DD`) or other channels you've pulled
(`:stable`) stay tagged and are kept until you remove them yourself (`docker image rm`).
Pull/prune progress is printed live on stderr, so a slow first pull is visibly downloading
rather than looking like a hang. Pin a `:nightly-YYYY.MM.DD` tag (via `YTDLP_DOCKER_IMAGE`) if
you need reproducibility.

Set `YTDLP_DOCKER_NO_PULL=1` to skip the per-run pull and prune entirely — useful for
metered, offline, or tight-loop use, where you keep whatever image is already cached.

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
exists), and sets `HOME` to the working directory. Only `~/.config/yt-dlp` is honored as
configuration — yt-dlp's default config search is disabled, so a stray `yt-dlp.conf` in the
directory you run from is never loaded. It works from every shell because it is the
same executable invoked under a different name. The trade-off: paths outside the current
directory (e.g. `-o ~/elsewhere`, `--cookies ~/cookies.txt`, `~/.netrc`) are not visible — keep
what you need under the directory you run it from.

Extra hardening for either name — pass extra `docker run` flags via
`YTDLP_DOCKER_RUN_ARGS` (they are spliced in before the image):

```sh
export YTDLP_DOCKER_RUN_ARGS='--read-only --tmpfs /tmp'
```

## Troubleshooting

### macOS: `operation not permitted` on `~/Downloads`, `~/Desktop`, `~/Documents`

```
docker: Error response from daemon: ... mkdir /Users/you/Downloads: operation not permitted: unknown
```

These folders are protected by macOS privacy controls (TCC), and VM-based Docker backends share
your filesystem through a host process that needs explicit permission to enter them. Since the
default `yt-dlp` mode mounts `$HOME` and runs from your current directory, working inside one of
these folders (or writing into one via `-o`) fails until access is granted. The fix is to give
your Docker backend **Full Disk Access** in System Settings → Privacy & Security, then restart it.

## Limitations

- Paths containing a `:` are unsupported (Docker `-v` splits on `:`).
- The host needs `bash` available (the script's shebang). Any shell can *invoke* it.

## Architectures

`linux/amd64` and `linux/arm64`. Other arches are intentionally unsupported: Deno (required
for YouTube) has no armv7/musl build.

## License

Released into the public domain under the [Unlicense](UNLICENSE).
