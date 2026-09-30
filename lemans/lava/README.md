# Flashing a lemans-evk board via LAVA

These job definitions flash a **remote** lemans-evk board in the LAVA lab
(`lava.infra.foundries.io`), instead of running `qdl` over USB against a
locally attached board. The lab boards are not USB-reachable, so LAVA fetches a
flat flash tarball over HTTP onto its worker and runs `qdl` there
(`deploy: to: qdl` + `boot: method: qdl`, `storage: ufs`).

Two jobs, mirroring the two local USB flash paths:

| Job YAML | `make` target it packages | Flashes | rootfs |
|---|---|---|---|
| `flash-lava.yaml` | `make flash-lava` | boot chain + kernel (LUNs 0–5, rootfs stripped) | ✗ |
| `flash-lava-yocto.yaml` | `make flash-lava-yocto` | complete Yocto release (all 6 LUNs + patches) | ✓ |

`flash-lava` = `flash-loader` + `flash-kernel` combined; `flash-lava-yocto` =
the LAVA counterpart of `flash-yocto`.

## Quick start (automated)

`make flash-lava` and `make flash-lava-yocto` do the whole thing — package the
tarball, then run `submit.sh`, which uploads it, submits the LAVA job, and
monitors it to completion:

```sh
make flash-lava          # boot chain + kernel  → submit + monitor
make flash-lava-yocto    # full Yocto release   → submit + monitor
```

Requirements: the `claude` CLI (used to mint the upload URL through the LAVA
MCP — the one step plain shell can't do), `jq`, and a LAVA token reachable to
`submit.sh` (pulled from `~/.claude.json`, or set `$LAVA_TOKEN`). To only build
the tarball without touching the lab, run the packaging target directly:
`make flash-lava-package` / `make flash-lava-yocto-package`.

Override the submitted definition with `FLASH_LAVA_JOB=` /
`FLASH_LAVA_YOCTO_JOB=`. The rest of this document explains what `submit.sh`
does step by step, and how to run it by hand.

## Prerequisites

- A LAVA API token for your user (see [Generating a LAVA API
  token](#generating-a-lava-api-token) below). Validate it:
  ```sh
  TOK=<your-lava-token>
  curl -s -H "Authorization: Token $TOK" \
    https://lava.infra.foundries.io/api/v0.3/system/whoami/
  # → {"user":"<you>"}
  ```
  Note the header is `Authorization: Token <tok>` for the REST API.
- The flash tarball, from either:
  - `make flash-lava`        → `lemans/output/lemans-flash.qcomflash.tar.gz` (flat)
  - `make flash-lava-yocto`  → `lemans/output/lemans-yocto.qcomflash.tar.gz` (flat)
  - or Yocto's own emitted `core-image-base-iq-9075-evk.rootfs.qcomflash.tar.gz`
    (**nested** — see the `path:` note below).

## Generating a LAVA API token

The token authenticates you to `lava.infra.foundries.io` — both for the REST
API used here and for the MCP server below. It maps to your LAVA user (job
submissions are attributed to you, and `visibility: personal` jobs are visible
only to you).

1. Log in to the LAVA web UI: <https://lava.infra.foundries.io/> (Foundries.io
   SSO).
2. Open your **Authentication Tokens** page:
   <https://lava.infra.foundries.io/api/tokens/> (also reachable from the
   user menu → *API → Authentication Tokens*).
3. **Create** a token; give it a description you'll recognise (e.g.
   `lemans-flash-mcp`). Copy the value immediately — LAVA shows the secret
   once.
4. Treat it as a password: do **not** commit it. Keep it in your shell env
   (`export LAVA_TOKEN=...`) or the MCP config (below), not in these YAMLs —
   that is why the deploy blocks use `<ARTIFACT_TOKEN>` / `<your-lava-token>`
   placeholders.

Validate as shown in Prerequisites (`whoami` → your username). Revoke/rotate
from the same page; a revoked token immediately 401/403s everywhere.

REST calls send it as **`Authorization: Token <token>`**. (The `Token ` prefix
matters — a bare token, or `Bearer`, is rejected.)

## MCP server

The `lava` MCP server (this session's `mcp__lava__*` tools) is an HTTP MCP
proxy in front of the same LAVA instance. It is configured per-project in
`~/.claude.json` under `projects → <your-project-path> → mcpServers → lava`:

```json
"lava": {
  "type": "http",
  "url": "https://lava.infra.foundries.io/mcp",
  "headers": { "C-Lava-Token": "<your-lava-token>" }
}
```

Add/update it with:
```sh
claude mcp add --transport http lava https://lava.infra.foundries.io/mcp \
  --header "C-Lava-Token: <your-lava-token>"
```
It is the **same token** as the REST one, but the MCP expects it in the
**`C-Lava-Token`** header (not `Authorization`). After changing it, reload with
`/mcp` (reconnect) or restart, so the running session picks up the header.

What the MCP is good for here:
- **Reads** (`list_devices`, `get_lab_health`, `list_jobs`, `get_job_logs`,
  `find_boot_template`, …) — these query public LAVA data and work regardless.
- **Artifact hosting** — `create_artifact_upload` mints the lab-reachable,
  token-guarded upload URL used in Step 1. This is MCP-native and does not need
  LAVA job-submit auth.

⚠️ **Known limitation on this instance:** MCP **write** tools (`submit_job`,
`cancel_job`, `list_remote_artifact_tokens`) currently **403** — the MCP
session does not authenticate the LAVA user (`whoami` returns an empty user
even after `/mcp` reconnect), so job submission through the MCP fails. The
token itself is valid, so submit/cancel/monitor via the **REST API** with
`Authorization: Token` as in Steps 2–3. If a future MCP build forwards the
token correctly (`whoami` returns your username), `submit_job` can replace the
REST `curl` and the rest of the flow is unchanged.

## Step 1 — host the tarball where the lab can fetch it

The worker downloads the tarball over HTTPS, so it needs a lab-reachable URL.
Easiest is the LAVA MCP artifact store (mints a short-lived token-guarded URL):

- `create_artifact_upload(filename=..., size_bytes=<exact size>)` returns a
  `put_command`, a `get_url`, and a `token`.
- Run the `put_command` to upload the bytes (they do not pass through the model).
  You can run it from wherever the file lives (e.g. your build host) to avoid
  round-tripping a large file.

Substitute the returned `get_url` and `token` into the job YAML's
`<ARTIFACT_URL>` and `<ARTIFACT_TOKEN>` placeholders. The URL expires in a few
hours; re-mint + re-upload if it lapses. Keep `visibility: personal` since the
token is inline in the deploy URL.

Any other lab-reachable HTTPS host works too (artifactory/S3/etc.); just point
`url:` at it and set `headers:` as that host requires.

## Step 2 — submit

**The LAVA MCP `submit_job` tool currently 403s** on this instance — the MCP
session does not authenticate (`whoami` returns empty even after reconnecting).
The token itself is valid, so submit via the REST API directly:

```sh
JOB=flash-lava-yocto.yaml          # or flash-lava.yaml, with placeholders filled in
jq -Rs '{definition: .}' "$JOB" > /tmp/payload.json
# validate first (catches schema errors before burning board time):
curl -s -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
     --data @/tmp/payload.json \
     https://lava.infra.foundries.io/api/v0.3/jobs/validate/
# → {"message":"Job valid."}
# submit:
curl -s -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
     --data @/tmp/payload.json \
     https://lava.infra.foundries.io/api/v0.3/jobs/
# → {"message":"job(s) successfully submitted","job_ids":[<id>]}
```

## Step 3 — monitor

The job is `visibility: personal`, so the MCP (which reads anonymously) 404s on
it. Poll and read logs via REST with the token:

```sh
ID=<job_id>
# state / health:
curl -s -H "Authorization: Token $TOK" \
     https://lava.infra.foundries.io/api/v0.3/jobs/$ID/
# full logs:
curl -s -H "Authorization: Token $TOK" \
     https://lava.infra.foundries.io/api/v0.3/jobs/$ID/logs/
# cancel (note: this endpoint is a GET), to free the board early:
curl -s -H "Authorization: Token $TOK" \
     https://lava.infra.foundries.io/api/v0.3/jobs/$ID/cancel/
```

A healthy run shows, in the logs: `qdl-deploy` (download + extract) →
`flash-qdl` taking real time (tens of seconds; **0 s means it failed
instantly** — usually the `path:` problem below) → `minimal-boot` reaching a
login prompt → `health: Complete`.

## The `path:` gotcha (nested vs flat tarballs)

`qdl` runs from the directory named by `path:` inside the tarball (root if
`path:` is unset), and looks for `firehose_program` / `rawprogram` / `patch`
relative to it.

- **Flat tarball** (both `make` targets, `tar -C <dir> .`): files at the root
  → **omit `path:`**, and `rootfs_image: rootfs.img`.
- **Nested tarball** (Yocto's own `.qcomflash.tar.gz`): everything under e.g.
  `core-image-base-iq-9075-evk/` → **set** `path: core-image-base-iq-9075-evk`
  and `rootfs_image: core-image-base-iq-9075-evk/rootfs.img`.

Wrong `path:` → qdl fails at once with
`failed to open "prog_firehose_ddr.elf" for reading`.

`flash-lava-yocto.yaml` is written for Yocto's own (nested) tarball; comments
in it say exactly what to change for the flat `make` output.

## Login credentials

The `minimal` boot's `auto_login` in these files uses the **Yocto** distro
creds (`root` / `oelinux123`, prompt `root@lemans-evk`). A **Buildroot** rootfs
presents `buildroot login:` and may differ — adjust `auto_login` / `prompts`
accordingly, or drop the final `boot` action for a flash-only job.

## Validated on hardware

Both definitions have been run end to end on a lab `lemans-evk` board:

- `flash-lava.yaml`       — flashed all 6 LUNs and booted to a login prompt.
- `flash-lava-yocto.yaml` — `health: Complete`: flashed all 6 LUNs incl. the
  ~924 MB rootfs, booted, and auto-login succeeded.
