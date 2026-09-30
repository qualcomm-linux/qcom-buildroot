#!/usr/bin/env bash
# lemans/lava/submit.sh — upload a flash tarball and submit + monitor a LAVA job.
#
# Called automatically by `make flash-lava` / `make flash-lava-yocto` right
# after the tarball is packaged. Does the four steps `make` cannot do on its
# own:
#
#   1. Mint a lab-reachable upload URL via the LAVA MCP. `make` cannot speak the
#      MCP protocol, so this shells out to headless `claude -p`, which calls the
#      MCP tool create_artifact_upload and returns a get_url + token. (This is
#      the ONE step that needs the MCP; the LAVA REST API has no upload of its
#      own and the MCP mint endpoint does not answer plain curl.)
#   2. Upload the tarball to that URL (plain curl PUT).
#   3. Fill the job YAML's <ARTIFACT_URL> / <ARTIFACT_TOKEN> and submit it to
#      the LAVA REST API (Authorization: Token — the header the REST API wants).
#   4. Poll the job to completion and print its health.
#
# The LAVA API token is read from ~/.claude.json (the same C-Lava-Token the
# lava MCP server is configured with) — override with $CLAUDE_JSON, or set
# $LAVA_TOKEN to bypass the file entirely.
#
# Usage: submit.sh <tarball> <job-yaml>
set -euo pipefail

TARBALL="${1:?usage: submit.sh <tarball> <job-yaml>}"
JOB_YAML="${2:?usage: submit.sh <tarball> <job-yaml>}"

LAVA_URL="${LAVA_URL:-https://lava.infra.foundries.io}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
POLL_SECONDS="${LAVA_POLL_SECONDS:-20}"
POLL_MAX="${LAVA_POLL_MAX:-180}"   # 180 * 20s = 60 min cap

[ -f "$TARBALL" ]  || { echo "ERROR: tarball not found: $TARBALL"  >&2; exit 1; }
[ -f "$JOB_YAML" ] || { echo "ERROR: job yaml not found: $JOB_YAML" >&2; exit 1; }
command -v claude  >/dev/null || { echo "ERROR: 'claude' CLI not found (needed to mint the upload URL via the LAVA MCP)" >&2; exit 1; }
command -v jq      >/dev/null || { echo "ERROR: 'jq' not found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- LAVA token: $LAVA_TOKEN, else the lava MCP C-Lava-Token in ~/.claude.json -
TOK="${LAVA_TOKEN:-}"
if [ -z "$TOK" ]; then
  [ -f "$CLAUDE_JSON" ] || { echo "ERROR: $CLAUDE_JSON not found and \$LAVA_TOKEN unset" >&2; exit 1; }
  TOK="$(python3 - "$CLAUDE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# a top-level mcpServers.lava, or under any projects[*].mcpServers.lava
cands = [d.get("mcpServers", {})]
cands += [p.get("mcpServers", {}) for p in d.get("projects", {}).values()]
for m in cands:
    lava = m.get("lava")
    if lava:
        t = lava.get("headers", {}).get("C-Lava-Token")
        if t:
            print(t); break
PY
)"
fi
[ -n "$TOK" ] || { echo "ERROR: no LAVA token (set \$LAVA_TOKEN or add a lava MCP C-Lava-Token to $CLAUDE_JSON)" >&2; exit 1; }

FN="$(basename "$TARBALL")"
SZ="$(stat -c%s "$TARBALL")"

# --- 1. mint an upload slot via the LAVA MCP, using headless claude ------------
# Build a one-server MCP config from ~/.claude.json so the headless session has
# the lava server regardless of cwd/project.
python3 - "$CLAUDE_JSON" > "$TMP/mcp.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cands = [d.get("mcpServers", {})]
cands += [p.get("mcpServers", {}) for p in d.get("projects", {}).values()]
for m in cands:
    if "lava" in m:
        print(json.dumps({"mcpServers": {"lava": m["lava"]}})); break
PY
[ -s "$TMP/mcp.json" ] || { echo "ERROR: could not build a lava MCP config from $CLAUDE_JSON" >&2; exit 1; }

echo ">> [1/4] minting upload URL via LAVA MCP (claude -p create_artifact_upload) ..."
MINT="$(claude -p "Call the lava MCP tool create_artifact_upload with filename=\"$FN\" and size_bytes=$SZ. Output ONLY a compact JSON object with keys get_url and token. No prose, no code fence." \
  --mcp-config "$TMP/mcp.json" --strict-mcp-config \
  --allowedTools "mcp__lava__create_artifact_upload" \
  --output-format text 2>/dev/null | grep -o '{.*}' | head -1)"
[ -n "$MINT" ] || { echo "ERROR: could not mint an upload URL via the MCP (is the lava server reachable / token valid?)" >&2; exit 1; }
GET_URL="$(echo "$MINT" | jq -r '.get_url')"
UP_TOK="$(echo  "$MINT" | jq -r '.token')"
[ -n "$GET_URL" ] && [ "$GET_URL" != null ] || { echo "ERROR: MCP returned no get_url: $MINT" >&2; exit 1; }

# --- 2. upload the tarball -----------------------------------------------------
echo ">> [2/4] uploading $FN ($(( SZ/1024/1024 )) MB) ..."
curl -fsS -T "$TARBALL" -H "Authorization: $UP_TOK" "$GET_URL" >/dev/null
echo "   stored at $GET_URL"

# --- 3. fill the YAML and submit ----------------------------------------------
# Substitute the placeholders; use a non-/ delimiter since the URL has slashes.
sed -e "s|<ARTIFACT_URL>|$GET_URL|g" -e "s|<ARTIFACT_TOKEN>|$UP_TOK|g" \
    "$JOB_YAML" > "$TMP/job.yaml"
jq -Rs '{definition: .}' "$TMP/job.yaml" > "$TMP/payload.json"

echo ">> [3/4] validating + submitting to $LAVA_URL ..."
VAL="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/validate/")"
echo "   validate: $VAL"
echo "$VAL" | grep -q '"Job valid."' || { echo "ERROR: job did not validate" >&2; exit 1; }

SUB="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/")"
JOB_ID="$(echo "$SUB" | jq -r '.job_ids[0]')"
[ -n "$JOB_ID" ] && [ "$JOB_ID" != null ] || { echo "ERROR: submit failed: $SUB" >&2; exit 1; }
echo "   submitted job $JOB_ID  ($LAVA_URL/scheduler/job/$JOB_ID)"

# --- 4. monitor ----------------------------------------------------------------
echo ">> [4/4] monitoring job $JOB_ID ..."
last=""
for _ in $(seq 1 "$POLL_MAX"); do
  J="$(curl -fsS -H "Authorization: Token $TOK" "$LAVA_URL/api/v0.3/jobs/$JOB_ID/")"
  state="$(echo "$J" | jq -r '.state')"; health="$(echo "$J" | jq -r '.health')"
  dev="$(echo "$J" | jq -r '.actual_device // "-"')"
  now="$state/$health@$dev"
  [ "$now" != "$last" ] && { echo "   $now"; last="$now"; }
  if [ "$state" = "Finished" ]; then
    echo ">> job $JOB_ID finished: health=$health"
    [ "$health" = "Complete" ] && exit 0 || exit 2
  fi
  sleep "$POLL_SECONDS"
done
echo "WARNING: job $JOB_ID still running after poll cap; check $LAVA_URL/scheduler/job/$JOB_ID" >&2
exit 0
