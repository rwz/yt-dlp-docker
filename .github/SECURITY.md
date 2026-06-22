# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/rwz/yt-dlp-docker/security/advisories/new).
Don't open a public issue for anything exploitable.

## Supported versions

Only the latest `:nightly` and `:stable` images are maintained — the project is always-latest
by design, so there are no older versions to patch. Pull again to pick up fixes.

## Threat model

The wrapper deliberately mounts your files, and yt-dlp parses untrusted content and supports
`--exec`; the trade-offs and the least-privilege `yt-dlp-scoped` variant are described in the
README's [Security section](../README.md#security). Published images are cosign-signed with
provenance and an SBOM, so you can verify what you run.
