#!/usr/bin/env bash
# lemans/lava/connect.sh — open an interactive LAVA board session, flash the
# board from inside the device-attached container, and drop you on its serial
# console. The interactive counterpart to submit.sh.
#
# Why this exists: `make flash-lava` flashes a THROWAWAY board (a qdl deploy+boot
# job that releases the board when it finishes) — you can watch the logs but you
# can never log in. To get a shell/console on the board you flashed, the flash
# has to happen inside a session that STAYS open. That is what the LAVA MCP's
# interactive board session gives us: a Debian container running next to a
# reserved board with the board's USB + serial mapped in. We stage the same
# flash tarball into that container, qdl it onto the board over USB, then attach
# to the board's UART. The board is held until you exit (then auto-released).
#
#   1. open_board_session(lemans-evk, console=true, downloads=[tarball]) — reserve
#      a board + container, pre-stage the tarball at /lava-downloads.
#   2. run_device_command qdl_enter — force the board into EDL (qdl mode).
#   3. run_in_session "tar -xzf … && qdl …" — flash over USB from the container.
#      The qdl argument list is parsed from the SAME job YAML submit.sh uses, so
#      flat (flash-lava) vs nested (flash-lava-yocto) `path:` is handled per-file.
#   4. attach_console — ssh -W to the board's UART through the gateway; run it
#      under socat for a raw interactive tty.
#   5. on exit, close_board_session — release the board immediately.
#
# MCP calls go straight to the LAVA MCP over JSON-RPC with curl (the server
# reads the per-request token from the X-Lava-Token header). We talk the protocol
# directly rather than through `claude -p`, which is non-deterministic for
# scripting. Needs the token (from $LAVA_TOKEN or ~/.claude.json), curl, and jq.
#
# Usage:
#   connect.sh <tarball> <job-yaml> [<get_url> <artifact_token>]
# Called automatically by submit.sh (which passes the already-uploaded get_url +
# token so the tarball is not re-uploaded). Run by hand WITHOUT the url/token and
# it uploads the tarball itself (minting a URL via the MCP, like submit.sh).
set -euo pipefail

TARBALL="${1:?usage: connect.sh <tarball> <job-yaml> [<get_url> <artifact_token>]}"
JOB_YAML="${2:?usage: connect.sh <tarball> <job-yaml> [<get_url> <artifact_token>]}"
GET_URL="${3:-}"
UP_TOK="${4:-}"

LAVA_URL="${LAVA_URL:-https://lava.infra.foundries.io}"
MCP_URL="${LAVA_MCP_URL:-$LAVA_URL/mcp}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
DEVICE_TYPE="${FLASH_LAVA_DEVICE_TYPE:-lemans-evk}"
# A full Yocto flash (~924 MB rootfs) runs well past run_in_session's 120s
# default; give the in-container qdl room.
FLASH_TIMEOUT="${FLASH_LAVA_FLASH_TIMEOUT:-1200}"
CONNECT_MAX="${FLASH_LAVA_CONNECT_MAX:-24}"   # 24 * 10s = 4 min for the session to connect

[ -f "$TARBALL" ]  || { echo "ERROR: tarball not found: $TARBALL"  >&2; exit 1; }
[ -f "$JOB_YAML" ] || { echo "ERROR: job yaml not found: $JOB_YAML" >&2; exit 1; }
command -v curl   >/dev/null || { echo "ERROR: 'curl' not found" >&2; exit 1; }
command -v jq     >/dev/null || { echo "ERROR: 'jq' not found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- LAVA token: $LAVA_TOKEN, else the lava MCP header in ~/.claude.json --------
# Accept X-Lava-Token (what this server reads) or the older C-Lava-Token name.
TOK="${LAVA_TOKEN:-}"
if [ -z "$TOK" ]; then
  [ -f "$CLAUDE_JSON" ] || { echo "ERROR: $CLAUDE_JSON not found and \$LAVA_TOKEN unset" >&2; exit 1; }
  TOK="$(python3 - "$CLAUDE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cands = [d.get("mcpServers", {})]
cands += [p.get("mcpServers", {}) for p in d.get("projects", {}).values()]
for m in cands:
    lava = m.get("lava")
    if lava:
        h = lava.get("headers", {})
        t = h.get("X-Lava-Token") or h.get("C-Lava-Token")
        if t:
            print(t); break
PY
)"
fi
[ -n "$TOK" ] || { echo "ERROR: no LAVA token (set \$LAVA_TOKEN or add a lava MCP X-Lava-Token to $CLAUDE_JSON)" >&2; exit 1; }

# --- MCP over raw JSON-RPC (streamable-http) ------------------------------------
# We talk to the LAVA MCP directly with curl rather than through `claude -p`:
# the headless agent is non-deterministic for scripting (it editorialises,
# refuses base64 blobs, or fires extra calls), whereas the protocol returns the
# exact tool payload every time. One initialised session is reused for all calls.
MCP_HDRS=(-H "X-Lava-Token: $TOK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
MCP_SID=""; MCP_RPC_ID=0

mcp_init() {
  local hf="$TMP/mcp.hdr"
  curl -fsS -D "$hf" -o "$TMP/mcp.init" -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"connect.sh","version":"1"}}}' \
    || { echo "ERROR: MCP initialize failed (is $MCP_URL reachable, token valid?)" >&2; return 1; }
  MCP_SID="$(grep -i '^mcp-session-id:' "$hf" | tr -d '\r' | awk '{print $2}')"
  [ -n "$MCP_SID" ] || { echo "ERROR: MCP returned no session id" >&2; return 1; }
  curl -fsS -X POST "$MCP_URL" "${MCP_HDRS[@]}" -H "Mcp-Session-Id: $MCP_SID" \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true
}

# mcp <tool> <args-json> : call one MCP tool, print its raw text payload. <args-json>
# is a real JSON object ({} for none). Deterministic — no agent in the loop.
# The streamable-http endpoint may answer as a text/event-stream, so we strip any
# "data: " SSE prefixes before parsing the JSON-RPC envelope.
mcp() {
  local tool="$1" args="${2:-{\}}"
  [ -n "$MCP_SID" ] || mcp_init || return 1
  MCP_RPC_ID=$((MCP_RPC_ID+1))
  local req
  req="$(jq -nc --arg n "$tool" --argjson a "$args" --argjson id "$MCP_RPC_ID" \
          '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$n,arguments:$a}}')"
  curl -fsS --max-time "$((FLASH_TIMEOUT+120))" -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
       -H "Mcp-Session-Id: $MCP_SID" --data "$req" 2>/dev/null \
    | sed -e 's/^data: //' \
    | jq -rs '[ .[] | select(.result) | .result.content[]? | select(.type=="text") | .text ] | last // ""' 2>/dev/null \
    || true
}

# jq_field <json-text> <jq-filter> : run a jq filter over a tool payload, never
# aborting the script.
jq_field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null || true; }
# sessions_field <json-text> <jq-filter-over-the-array> : normalise a payload
# (single object OR array of session objects) into an array, then apply filter.
sessions_field() {
  printf '%s' "$1" | jq -rs "[ .[] | (if type==\"array\" then .[] else . end) ] | $2" 2>/dev/null || true
}

# --- parse qdl args from the job YAML (single source of truth) ------------------
# firehose_program / rawprogram / patch (space-separated lists) and an optional
# `path:` prefix (nested tarball). Comment lines (leading #) are ignored.
# `|| true`: a missing key (e.g. no `path:` in the flat case) must yield "" under
# set -e, not abort — grep exits non-zero when it matches nothing.
yaml_val() { { grep -E "^[[:space:]]*$1:" "$JOB_YAML" | grep -v '^[[:space:]]*#' | head -1 | sed -E "s/^[[:space:]]*$1:[[:space:]]*//"; } || true; }
FIREHOSE="$(yaml_val firehose_program)"; FIREHOSE="${FIREHOSE:-prog_firehose_ddr.elf}"
RAWPROGRAM="$(yaml_val rawprogram)"
PATCH="$(yaml_val patch)"
SUBPATH="$(yaml_val path)"   # empty for the flat `make` tarballs; set for Yocto's own
[ -n "$RAWPROGRAM" ] || { echo "ERROR: no 'rawprogram:' found in $JOB_YAML" >&2; exit 1; }

FN="$(basename "$TARBALL")"

# --- 0. upload the tarball if submit.sh did not already hand us a URL -----------
if [ -z "$GET_URL" ] || [ -z "$UP_TOK" ]; then
  SZ="$(stat -c%s "$TARBALL")"
  echo ">> uploading $FN ($(( SZ/1024/1024 )) MB) — no url passed in ..."
  MINT="$(mcp create_artifact_upload "$(jq -nc --arg f "$FN" --argjson s "$SZ" '{filename:$f,size_bytes:$s}')")"
  GET_URL="$(jq_field "$MINT" '.get_url')"
  UP_TOK="$(jq_field  "$MINT" '.token')"
  [ -n "$GET_URL" ] && [ "$GET_URL" != null ] || { echo "ERROR: mint returned no get_url: $MINT" >&2; exit 1; }
  curl -fsS -T "$TARBALL" -H "Authorization: $UP_TOK" "$GET_URL" >/dev/null
  echo "   stored at $GET_URL"
fi

# --- tool bootstrap: websocat (required) + socat (nice-to-have) -----------------
export PATH="$HOME/.local/bin:$PATH"
if ! command -v websocat >/dev/null; then
  echo ">> websocat not found — fetching the static binary to ~/.local/bin ..."
  mkdir -p "$HOME/.local/bin"
  WURL=""
  command -v gh >/dev/null && WURL="$(gh api repos/vi/websocat/releases/latest \
    --jq '.assets[] | select(.name|test("x86_64-unknown-linux-musl$")) | .browser_download_url' 2>/dev/null | head -1)"
  [ -n "$WURL" ] || WURL="https://github.com/vi/websocat/releases/download/v1.14.1/websocat.x86_64-unknown-linux-musl"
  curl -fsSL "$WURL" -o "$HOME/.local/bin/websocat" && chmod +x "$HOME/.local/bin/websocat" \
    || { echo "ERROR: could not install websocat (needed for the SSH gateway tunnel). Install it manually." >&2; exit 1; }
  echo "   installed $(websocat --version 2>/dev/null || echo websocat)"
fi

# --- 1. open the board session (container + console) with the tarball staged ----
echo ">> [1/4] opening an interactive $DEVICE_TYPE session (console + staged tarball) ..."
# Note the newest existing job id first, so after opening we can pick OUR session
# (highest job_id) and ignore any stale/pending sessions left by cancelled jobs.
PREOPEN="$(mcp list_board_sessions '{}')"
PREMAX="$(sessions_field "$PREOPEN" 'map(.job_id // 0) | max // 0')"; PREMAX="${PREMAX:-0}"

# open_board_session creates BOTH the container and console sessions up front
# (the console session is allocated before the job is even submitted) and returns
# session_id + console_session_id directly. It blocks up to wait_seconds for the
# container to dial back, then returns. downloads stages the tarball into the
# container at /lava-downloads (the container can't fetch the token-guarded URL).
OPEN_ARGS="$(jq -nc --arg dt "$DEVICE_TYPE" --arg u "$GET_URL" --arg a "$UP_TOK" \
  '{device_type:$dt, console:true, wait_seconds:90, downloads:[{url:$u, headers:{Authorization:$a}}]}')"
OPEN="$(mcp open_board_session "$OPEN_ARGS")"
SESSION_ID="$(jq_field "$OPEN" '.session_id // empty')"
CONSOLE_ID="$(jq_field "$OPEN" '.console_session_id // empty')"
JOB_ID="$(jq_field "$OPEN" '.job_id // empty')"

# If open returned nothing parseable (agent/transport hiccup), recover the ids
# from list_board_sessions: our job is the one with job_id > the pre-open max.
if [ -z "$SESSION_ID" ]; then
  echo "   open returned no ids; recovering via list_board_sessions ..."
  for _ in $(seq 1 12); do
    LST="$(mcp list_board_sessions '{}')"
    JOB_ID="$(sessions_field "$LST" "map(.job_id // 0) | map(select(. > $PREMAX)) | max // empty")"
    if [ -n "$JOB_ID" ]; then
      SESSION_ID="$(sessions_field "$LST" "map(select(.kind==\"container\" and .job_id==$JOB_ID)) | last.session_id // empty")"
      CONSOLE_ID="$(sessions_field "$LST" "map(select(.kind==\"console\"   and .job_id==$JOB_ID)) | last.session_id // empty")"
    fi
    [ -n "$SESSION_ID" ] && [ -n "$CONSOLE_ID" ] && break
    sleep 5
  done
fi
[ -n "$SESSION_ID" ] || { echo "ERROR: could not find a board session (open_board_session failed? check the X-Lava-Token header)" >&2; exit 1; }
echo "   container session $SESSION_ID  console ${CONSOLE_ID:-<none>}  job ${JOB_ID:-?}"

# --- auto-close on exit: release the board the moment we leave ------------------
cleanup() {
  echo ""
  echo ">> closing board session $SESSION_ID (releasing the board) ..."
  mcp close_board_session "$(jq -nc --arg s "$SESSION_ID" '{session_id:$s}')" >/dev/null 2>&1 || \
    echo "   WARNING: close failed — release it with close_board_session($SESSION_ID) or cancel job ${JOB_ID:-?}"
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- wait for the container to connect to the gateway ---------------------------
# open_board_session already waited (wait_seconds) and may have reported it;
# otherwise poll the session status until it flips to "connected".
connected=0
[ "$(jq_field "$OPEN" '.connected // empty')" = "true" ] && connected=1
if [ "$connected" = 0 ]; then
  echo ">> waiting for the session container to connect ..."
  for _ in $(seq 1 "$CONNECT_MAX"); do
    LST="$(mcp list_board_sessions '{}')"
    st="$(sessions_field "$LST" "map(select(.session_id==\"$SESSION_ID\")) | last.status // empty")"
    [ "$st" = "connected" ] && { connected=1; break; }
    sleep 10
  done
fi
[ "$connected" = 1 ] || { echo "ERROR: session $SESSION_ID did not connect in time" >&2; exit 1; }
echo "   connected."

# --- 2. force EDL so the board enumerates as qdl --------------------------------
# lemans-evk enters EDL via the device's `qdl_enter` user command (runs
# tac-api bootToEDL); there is no generic recovery_mode on this device. Override
# with FLASH_LAVA_EDL_CMD if a given board names it differently.
EDL_CMD="${FLASH_LAVA_EDL_CMD:-qdl_enter}"
echo ">> [2/4] forcing the board into EDL ($EDL_CMD) ..."
EDL="$(mcp run_device_command "$(jq -nc --arg s "$SESSION_ID" --arg n "$EDL_CMD" '{session_id:$s,name:$n}')")"
echo "   $EDL_CMD: ok=$(jq_field "$EDL" '.ok') rc=$(jq_field "$EDL" '.exit_status')"
# Give the board a few seconds to re-enumerate as QDL (05c6:9008).
sleep 8

# --- 3. flash from inside the container -----------------------------------------
# Extract the tarball under /lava-downloads, cd into the (optional) nested path,
# and run qdl against the board's USB — same arg list the LAVA qdl boot action
# would use. --storage ufs matches the YAML's `storage: ufs`. Wait for the board
# to enumerate in EDL (05c6:9008) first.
#
# The flash script is base64-encoded and run as `echo <b64> | base64 -d | bash`
# so the exact multi-line script is carried verbatim as one argument value. A
# QDL_EXIT=<rc> sentinel carries the real qdl exit code back in the captured text.
CDPATH_CMD=""; [ -n "$SUBPATH" ] && CDPATH_CMD="cd '$SUBPATH' && "
FLASH_SCRIPT="echo '--- waiting for EDL (05c6:9008) ---'
for i in \$(seq 1 30); do lsusb | grep -q 05c6:9008 && break; sleep 2; done
lsusb | grep 05c6 || true
cd /lava-downloads && tar -xzf '$FN' && ${CDPATH_CMD}qdl --debug --storage ufs $FIREHOSE $RAWPROGRAM $PATCH
echo QDL_EXIT=\$?"
FLASH_B64="$(printf '%s' "$FLASH_SCRIPT" | base64 -w0)"
RUN_CMD="echo $FLASH_B64 | base64 -d | bash"
echo ">> [3/4] flashing in-container (timeout ${FLASH_TIMEOUT}s) ..."
echo "   qdl --storage ufs $FIREHOSE $RAWPROGRAM $PATCH${SUBPATH:+   (path: $SUBPATH)}"
FLASH_OUT="$(mcp run_in_session "$(jq -nc --arg s "$SESSION_ID" --argjson t "$FLASH_TIMEOUT" --arg c "$RUN_CMD" '{session_id:$s,timeout:$t,command:$c}')")"
FLASH_TXT="$(jq_field "$FLASH_OUT" '.output // .stdout // .')"
printf '%s\n' "$FLASH_TXT" | tail -30
# The QDL_EXIT=<rc> sentinel is authoritative: our script always echoes it as its
# last line, so if it is present it reflects qdl's real exit code — trust it over
# anything else (run_in_session sometimes returns a truncated body even though the
# flash ran to completion). Fall back to the tool's own exit_status, then treat a
# totally empty result as "the flash never ran" (board likely never entered EDL).
RC="$(printf '%s' "$FLASH_TXT" | sed -n 's/.*QDL_EXIT=\([0-9][0-9]*\).*/\1/p' | tail -1)"
[ -n "$RC" ] || RC="$(jq_field "$FLASH_OUT" '.exit_status // empty')"
if [ -z "$RC" ]; then
  if [ -z "$FLASH_TXT" ] || [ "$FLASH_TXT" = null ]; then
    echo "ERROR: in-container flash produced no output — the board likely never entered EDL (check '$EDL_CMD')." >&2
  else
    echo "ERROR: could not determine the flash result (no QDL_EXIT sentinel and no exit_status) — see output above." >&2
  fi
  exit 1
fi
if [ "$RC" != 0 ]; then
  echo "ERROR: in-container qdl exited $RC (see output above; wrong path:/firehose, or board not in EDL)." >&2
  exit 1
fi
echo "   flash complete."

# --- 4. attach to the board's serial console ------------------------------------
[ -n "$CONSOLE_ID" ] || { echo "ERROR: no console session was opened; cannot attach to the UART" >&2; exit 1; }
echo ">> [4/4] attaching to the board console ($CONSOLE_ID) ..."
AC="$(mcp attach_console "$(jq -nc --arg s "$CONSOLE_ID" '{session_id:$s}')")"
SSH_W="$(jq_field "$AC" '.ssh_W_command')"
[ -n "$SSH_W" ] && [ "$SSH_W" != null ] || { echo "ERROR: attach_console returned no ssh command: $AC" >&2; exit 1; }
KEY="$TMP/console.key"
jq_field "$AC" '.private_key' > "$KEY"; chmod 600 "$KEY"
# attach_console returns a command string referencing its own key filename; point
# it at the key we just wrote.
SSH_W_LOCAL="$(printf '%s' "$SSH_W" | sed -E "s#-i [^ ]+\.key#-i $KEY#")"
# socat's EXEC splits the command on whitespace itself and does NOT honour the
# shell quoting around the `'ProxyCommand=websocat …'` arg, so handing it the raw
# ssh string fails with "wrong number of parameters". Wrap the command in a tiny
# script and EXEC that single path instead — the script's shell parses the quotes.
CONSOLE_RUN="$TMP/console-run.sh"
printf '#!/usr/bin/env bash\nexec %s\n' "$SSH_W_LOCAL" > "$CONSOLE_RUN"
chmod +x "$CONSOLE_RUN"

echo ""
echo "   Board is flashed and booting. Opening the serial console."
echo "   (raw tty escape is Ctrl-] ; exit the console to release the board.)"
echo ""
if command -v socat >/dev/null; then
  socat -,raw,echo=0,escape=0x1d "EXEC:$CONSOLE_RUN,pty" || true
else
  echo "   NOTE: 'socat' not found — using line-buffered ssh -W instead of a raw tty."
  echo "         For a proper interactive console: sudo apt-get install -y socat"
  echo ""
  "$CONSOLE_RUN" || true
fi

# EXIT trap closes the session + releases the board.
