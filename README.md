# Hanan Foundation — distribution repository

Public distribution point for the Hanan Foundation installer.

**This repository contains no source code.** It hosts:

- `bootstrap.sh` — the `curl | bash` installer
- `version.json` — the promoted release pair (installer + foundation)
- `pub.pem` — the public key used to verify signed releases
- `GitHub Releases` — built installer binaries and signed foundation archives

Source is kept in private repositories (`liwanagtan/hanan-installer`,
`liwanagtan/hanan-foundation`); this repo and its releases are the only
public surface.

## Install

On a fresh Ubuntu 26.04 host (amd64 or arm64), as a user with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/liwanagtan/hanan-installer-dist/main/bootstrap.sh | sudo bash
```

The bootstrap script will:

1. Require root and a supported platform (Ubuntu, linux amd64/arm64).
2. Read `version.json` to resolve the promoted installer/foundation versions.
3. Download the `hanan` CLI binary and verify its SHA-256 checksum.
4. Download the signed foundation release and verify the archive checksum,
   manifest digest, and OpenSSL signature against `pub.pem`
   (key fingerprint is embedded in `bootstrap.sh`).
5. Prompt (from `/dev/tty`, so `curl | bash` works) for deployment type,
   optional Hanan Profile, optional LAN CIDR, and the operator/MQTT passwords
   (written to root-owned 0600 files).
6. Run `hanan install --apply --provision --provision-tty ...` and print the
   Home Assistant onboarding follow-up.

### Preview without touching the system

```bash
curl -fsSL https://raw.githubusercontent.com/liwanagtan/hanan-installer-dist/main/bootstrap.sh | sudo bash -s -- --dry-run
```

### Scripted installs

Environment overrides (all optional):

| Variable | Purpose |
| --- | --- |
| `HANAN_INSTALLER_VERSION` | Pin an installer version |
| `HANAN_FOUNDATION_VERSION` | Pin a foundation version |
| `HANAN_DEPLOYMENT` | `customer` or `lab` |
| `HANAN_PROFILE` | `home`, `rentals`, `business`, `farm`, `warehouse` |
| `HANAN_LAN_CIDR` | e.g. `192.168.1.0/24` |
| `HANAN_OPERATOR_PASSWORD` | Operator password (must still meet 16–128 chars, safe charset) |
| `HANAN_MQTT_PASSWORD` | MQTT password (must differ from operator) |

## Release model

- A release in this repo is created by the CI workflow in the private
  `liwanagtan/hanan-installer` repo when a `v*` tag is pushed (or manually via
  `workflow_dispatch`).
- Each release bundles the installer binaries
  (`hanan-linux-amd64`, `hanan-linux-arm64`, each with `.sha256`) and the
  signed foundation bundle
  (`hanan-foundation-<ver>.tar.gz`, `.manifest.json`, `.tar.gz.sha256`,
  `.manifest.sig`).
- After publishing, the workflow updates `version.json` so plain
  `curl | bash` picks up the newest stable pair.

### Assets in a release

| Asset | Format |
| --- | --- |
| `hanan-linux-amd64` / `hanan-linux-arm64` | hanan CLI binary |
| `hanan-linux-*.sha256` | `sha256sum` of the binary |
| `hanan-foundation-<ver>.tar.gz` | signed foundation archive |
| `hanan-foundation-<ver>.manifest.json` | artifact manifest (includes `sha256`, `compatibility`) |
| `hanan-foundation-<ver>.tar.gz.sha256` | `sha256sum` of the archive |
| `hanan-foundation-<ver>.manifest.sig` | OpenSSL signature over the manifest |

Example pinned URL form:

```
https://github.com/liwanagtan/hanan-installer-dist/releases/download/v0.1.0/hanan-foundation-0.1.1.tar.gz
```

## Security notes

- The release signing key is generated offline and stored out of band; only
  its public half (`pub.pem`) lives here.
- `bootstrap.sh` embeds the expected `pub.pem` fingerprint so a well-formed
  key even without a valid signature still cannot be substituted silently.
- Passwords are never transmitted through this repo; they are generated on
  the target host (or entered interactively) and written to root-owned 0600
  files under `/root/.hanan-bootstrap-pw.*`.
- If a release's signature or checksums fail verification, `bootstrap.sh`
  aborts with a clear error. Verify a release offline with the foundation
  repo's `scripts/verify-release.sh`.

## Repository maintenance

`main` is the only branch. Changes to `bootstrap.sh` or `pub.pem` are pushed
directly and take effect for future installs immediately; `version.json` is
updated by the release workflow. When rotating the signing key, also update
`EXPECTED_PUB_PEM_FINGERPRINT` in `bootstrap.sh` in the same commit.