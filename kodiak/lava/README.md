# Flashing a qcs6490-rb3gen2 board via LAVA

These job definitions flash a **remote** RB3 Gen2 (`qcs6490-rb3gen2`) board in
the LAVA lab (`lava.infra.foundries.io`), instead of running `qdl` over USB
against a locally attached board. The lab boards are not USB-reachable, so LAVA
fetches a flat flash tarball over HTTP onto its worker and runs `qdl` there
(`deploy: to: qdl` + `boot: method: qdl`, `storage: ufs`).

Three jobs, mirroring the local USB flash paths:

| Job YAML | `make` target it packages | Flashes | rootfs | Runs |
|---|---|---|---|---|
| `flash-lava.yaml` | `make flash-lava` | loader + kernel (LUNs 0,1,2,4; efi partition only on LUN 0) | ✗ | — |
| `flash-lava-yocto.yaml` | `make flash-lava-yocto` | complete Yocto release (all LUNs + patches) | ✓ | — |
| generated from `test-plan` | `make flash-lava-test` | loader + kernel | ✗ (UKI rebuilt w/ test overlay) | full test-definitions suite |

`flash-lava` = `flash-bootimage` + `flash-uki` combined; `flash-lava-yocto` = the
LAVA counterpart of `flash-yocto`. `flash-lava-test` flashes the same loader +
kernel as `flash-lava`, then runs the LAVA test-definitions suite against it
remotely — see
[Running the full test suite (flash-lava-test)](#running-the-full-test-suite-flash-lava-test)
below.

RB3 Gen2 uses **LUNs 0, 1, 2, 4** (there is no LUN 3 or 5), so the rawprogram
list is shorter than on 6-LUN platforms.

## Quick start (automated)

`make flash-lava` and `make flash-lava-yocto` do the whole thing — package the
tarball, then run `submit.sh`, which uploads it, submits the LAVA job, and
monitors it to completion:

```sh
make flash-lava          # loader + kernel     → submit + monitor
make flash-lava-yocto    # full Yocto release  → submit + monitor
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
  - `make flash-lava`        → `kodiak/output/kodiak-flash.qcomflash.tar.gz` (flat)
  - `make flash-lava-yocto`  → `kodiak/output/kodiak-yocto.qcomflash.tar.gz` (flat)
  - or Yocto's own emitted `core-image-base-rb3gen2-core-kit.rootfs.qcomflash.tar.gz`
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
   `kodiak-flash-mcp`). Copy the value immediately — LAVA shows the secret
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

With `X-Lava-Token` set correctly, `whoami` returns your username and the MCP
**write** tools (`submit_job`, `cancel_job`, `open_board_session`, …)
authenticate as you. `submit.sh` still submits/monitors over the **REST API**
(`Authorization: Token`) because `make` cannot speak MCP; the interactive
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
  `core-image-base-rb3gen2-core-kit/` → **set** `path:
  core-image-base-rb3gen2-core-kit` and
  `rootfs_image: core-image-base-rb3gen2-core-kit/rootfs.img`.

Wrong `path:` → qdl fails at once with
`failed to open "prog_firehose_ddr.elf" for reading`.

`flash-lava-yocto.yaml` is written for the flat `make flash-lava-yocto` output;
comments in it say exactly what to change for Yocto's own (nested) tarball.

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

- **Enter / Y → interactive** — `kodiak/lava/connect.sh` reserves a board and
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

1. `open_board_session(qcs6490-rb3gen2, console=true, downloads=[<the tarball>])`
   — reserves a board and a Debian container next to it (board USB + serial
   mapped in), and pre-stages the tarball at `/lava-downloads` (the container
   can't fetch the token-guarded URL itself, so LAVA stages it).
   Override the device type with `FLASH_LAVA_DEVICE_TYPE`.
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
creds (`root` / `oelinux123`). The prompt patterns cover the Yocto core-kit
(`root@rb3gen2-core-kit`) and a fallback `root@(.*):[/~]#`. A **Buildroot**
rootfs may present a different login prompt and creds — adjust `auto_login` /
`prompts` accordingly, or drop the final `boot` action for a flash-only job.

## Device type

`device_type: qcs6490-rb3gen2` in both YAMLs targets the RB3 Gen2 in the lab.
Confirm the exact device-type string in your LAVA instance with the MCP
`list_devices` (or the web UI). If it differs, update the `device_type:` line in
each YAML and pass `FLASH_LAVA_DEVICE_TYPE=<name>` to `connect.sh`.

## Running the full test suite (flash-lava-test)

`make flash-lava-test` flashes a board and then runs the test plan
`kodiak/lava/test-plan` against it (`boot-handoff`, `remoteproc-smoke`,
`fastrpc`, `optee-xtest`), unattended end to end. The job, the packaging
and the submission are shared by every board: see
[qcom/lava/README.md](../../qcom/lava/README.md). kodiak.mk sets the board
variables (device type, qdl files, prompts, UKI ingredients) and uses the
`initramfs` overlay described below.

### Why ukify, not transfer_overlay

kodiak's rootfs is an initramfs baked directly into the UKI (`efi.bin`), not
a flashed partition — so LAVA's normal overlay injection, which only ever
acts on an extracted `rootfs_image` file, has nothing to inject into.
`transfer_overlay` (the usual fallback for a non-deployed rootfs) is also a
dead end on this lab: its `http`/`nfs` paths need the DUT to get a DHCP
lease (this lab's switch port doesn't hand one out), and its `zmodem` path
needs a `uart` entry in the device dictionary (not set for
`qcs6490-rb3gen2`).

The fix: the job's first `deploy: to: downloads` action runs a
`postprocess: docker` step that rebuilds the UKI with the LAVA test overlay
(which LAVA stages into the downloads dir as `overlay-*.tar.gz`) merged into
a copy of the initramfs, using the same `ukify`/`mkfs.fat`/`mcopy` recipe as
the `uki` make target. It splices the rebuilt `efi.bin` back into a copy of
the flash tarball at its original path, and the second `deploy: to: qdl`
flashes *that* tarball. Everything downstream (qdl boot, minimal boot, test
definitions) is identical to `flash-lava.yaml`.

### Packaging and submitting

`make flash-lava-test` packages **two** tarballs: the normal flash tarball
(`kodiak-flash.qcomflash.tar.gz`, same as `flash-lava`) and
`kodiak-ukify-ingredients.tar.gz` with the inputs the postprocess step needs to
rebuild the UKI (the kernel as `vmlinuz.efi`, the DTB, `rootfs.cpio.gz`, the
UKI stub and the UEFI fallback loader). It writes the job to
`kodiak/output/kodiak-flash-lava-test.yaml` and hands it with both tarballs to
`qcom/lava/submit-test.sh`, which uploads each one, fills in their URLs and
the names of the LAVA remote artifact tokens (so the job is public), and
submits and follows the job. This job has no interactive mode. To only build
the tarballs: `make flash-lava-test-package`; to only write the job: `make
flash-lava-test-job`. `LAVA_TEST_REPO` and `LAVA_TEST_BRANCH` select the
test-definitions repository and branch.

### fastrpc TESTS: parameter

The `fastrpc` test's `TESTS:` parameter is copied as-is from the
hardware-validated `lemans` job (`"adsp:adsp:0:0 cdsp:cdsp:3:0"`). The format
is `<case>:<remoteproc-name>:<domain>:<unsigned-pd>`, where `<domain>` is a
fixed FastRPC domain enumeration constant (0 ADSP, 1 MDSP, 2 SDSP, 3 CDSP, 4
CDSP1) — not a board-specific PAS/devicetree index — and `<remoteproc-name>`
must match the kernel's `rproc->name` (the PAS driver's `sysmon_name`,
"adsp"/"cdsp" for kodiak's `qcom,sc7280-{adsp,cdsp}-pas` compatibles). Both
are confirmed correct for kodiak by reading the devicetree (`kodiak.dtsi`,
`qcs6490-rb3gen2.dts`, `kodiak-el2.dtso`) and the PAS driver source
(`qcom_q6v5_pas.c`). kodiak exposes more DSP nodes than lemans — cDSP1, sDSP,
gDSP0, gDSP1 (see `kodiak/overlay/etc/init.d/S60fastrpc`) — only the
adsp/cdsp pair both boards share is wired; extend `TESTS:` to the rest once
their remoteproc names are confirmed on a live board. `modem`/`mpss` is
intentionally out of scope (not supported on this open boot stack), matching
`remoteproc-smoke.yaml`'s default `SKIP: "modem wpss"`.

## Validated on hardware

**`flash-lava-test` — job 489920, device `rb3g2-05`, 2026-10-15: health
`Complete`.** Flashing (ukify-rebuild-in-postprocess + qdl) and booting to a
login prompt both succeeded for the first time on a lab `qcs6490-rb3gen2`
board, confirming the UKI-overlay pattern ported from lemans works
unchanged on kodiak. Per-suite results:

| Suite | Result |
|---|---|
| `boot-handoff` | 6 pass, 2 skip |
| `remoteproc-smoke` | 3 pass, 2 skip, 2 fail (`remoteproc-adsp-running`, `remoteproc-cdsp-running`) |
| `fastrpc` | 2 fail (`fastrpc-adsp`, `fastrpc-cdsp`) |
| `optee-xtest` | 122 pass |

The `remoteproc-smoke`/`fastrpc` failures were **not** a devicetree or
`TESTS:` parameter problem (both independently confirmed correct — see
above). The job's kernel log shows the real cause: `request_firmware`
failing with `-ENOENT` for `qcom/qcm6490/{adsp,cdsp}.mbn`, at exactly the
paths the devicetree requests. The `rootfs.cpio.gz` packaged into that run's
`kodiak-ukify-ingredients.tar.gz` was stale — built before the DSP firmware
blobs were staged into the buildroot overlay, so it never had them baked in.
Boot handoff and OP-TEE xtest are fully green, so the UKI/flash/boot
pipeline itself is solid; a rebuild from a fresh rootfs (with firmware
staged first) is expected to pass once resubmitted.

`flash-lava`/`flash-lava-yocto` (flash-only, no test suite) remain not yet
run on a lab board.
