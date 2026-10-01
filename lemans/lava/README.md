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
  "headers": { "X-Lava-Token": "<your-lava-token>" }
}
```

Add/update it with:
```sh
claude mcp add --transport http lava https://lava.infra.foundries.io/mcp \
  --header "X-Lava-Token: <your-lava-token>"
```
It is the **same token** as the REST one, but the MCP expects it in the
**`X-Lava-Token`** header (not `Authorization`). After changing it, reload with
`/mcp` (reconnect) or restart, so the running session picks up the header.

> **Header name matters.** This lava-mcp build reads **`X-Lava-Token`**. An
> earlier revision of this doc used `C-Lava-Token`, which this server ignores —
> the token is then dropped, `whoami` returns an empty user, and every MCP
> **write** tool (`submit_job`, `open_board_session`, …) 403s with
> "Authentication credentials were not provided", while reads and
> `create_artifact_upload` still work. If writes 403, check this header first.
> (`submit.sh`/`connect.sh` accept either name when reading the token for REST.)

What the MCP is good for here:
- **Reads** (`list_devices`, `get_lab_health`, `list_jobs`, `get_job_logs`,
  `find_boot_template`, …) — these query public LAVA data and work regardless.
- **Artifact hosting** — `create_artifact_upload` mints the lab-reachable,
  token-guarded upload URL used in Step 1. This is MCP-native and does not need
  LAVA job-submit auth.

✅ **Writes work once the header is right.** With `X-Lava-Token` (above),
`whoami` returns your username and the MCP **write** tools (`submit_job`,
`cancel_job`, `open_board_session`, …) authenticate as you. The earlier
"writes 403" note here was the `C-Lava-Token` symptom, not a server bug — see
the header warning above. `submit.sh` still submits/monitors over the **REST
API** (`Authorization: Token`) because `make` cannot speak MCP; the interactive
session (`connect.sh`) uses the MCP write tools directly.

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

The MCP `submit_job` tool works once the `X-Lava-Token` header is set (see the
MCP section above). `submit.sh` nevertheless submits over the **REST API** —
`make` cannot speak MCP, and REST needs no MCP session. To submit by hand:

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

## Flashing: interactive (default) vs flash-only

After uploading the tarball, `make flash-lava` / `make flash-lava-yocto` ask —
on a terminal — how to flash:

```
Flash flash-lava.yaml how?
  [Y] interactive — reserve a board, flash it, open its serial console (default)
  [n] flash-only  — submit a one-shot flash job and wait for it to boot remotely
Flash interactively and open the console? [Y/n]
```

Either path flashes the board **exactly once**.

- **Enter / Y → interactive** — `lemans/lava/connect.sh` reserves a board and
  flashes it, then drops you on its serial console (see below).
- **n → flash-only** — submits a throwaway qdl deploy+boot job over the LAVA REST
  API and polls it to `health: Complete` (which means it flashed *and* booted to
  a login prompt), then releases the board. No console.
- **non-tty** (CI, piped stdin) defaults to **flash-only** — a console needs a
  terminal to attach to.
- `FLASH_LAVA_CONNECT=1` forces interactive, `=0` forces flash-only (no prompt).

### Interactive session (connect.sh)

`connect.sh` talks to the LAVA MCP directly over JSON-RPC with `curl` (so the
`X-Lava-Token` header must be correct — see the MCP section above):

1. `open_board_session(lemans-evk, console=true, downloads=[<the tarball>])` —
   reserves a board and a Debian container next to it (board USB + serial mapped
   in), and pre-stages the tarball at `/lava-downloads` (the container can't
   fetch the token-guarded URL itself, so LAVA stages it).
2. `run_device_command qdl_enter` — forces the board into EDL (this device's
   user command runs tac-api `bootToEDL`; there is no generic `recovery_mode`).
   Override the command name with `FLASH_LAVA_EDL_CMD` for a differently-wired
   board.
3. `run_in_session "tar -xzf … && qdl …"` — flashes the board over USB **from
   inside the container**, so the board you log into is the one you flashed.
   The qdl arg list (firehose/rawprogram/patch and any nested `path:`) is parsed
   from the **same job YAML**, so flat vs nested is handled automatically.
4. `attach_console` — `ssh -W` to the board's UART through the gateway, run
   under `socat` for a raw tty. You watch it boot and get a login prompt.
5. On exit, `close_board_session` **auto-releases the board** (don't leave it
   held for the 60-min job timeout).

Controls / knobs:
- `connect.sh <tarball> <job-yaml>` runs standalone (uploads the tarball itself
  if no `get_url`/token is passed).
- Raw-console escape is **`Ctrl-]`**; exiting the console releases the board.

Prerequisites (connect.sh installs/falls back automatically):
- **`websocat`** — required for the SSH gateway tunnel (`ProxyCommand`). If
  missing it is fetched to `~/.local/bin`.
- **`socat`** — for a raw interactive tty. If missing, connect.sh falls back to
  a line-buffered `ssh -W`; `sudo apt-get install -y socat` for the full
  experience.

If connect.sh dies without cleaning up, release the board manually: the LAVA MCP
`close_board_session(session_id)`, or cancel the job
(`curl …/jobs/<id>/cancel/`). `list_board_sessions` shows sessions you own.

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
