#!/usr/bin/env bash
# kodiak/lava/submit-test.sh — upload the flash + ukify-ingredients tarballs,
# submit flash-lava-test.yaml, and monitor it to completion.
#
# Called automatically by `make flash-lava-test` right after both tarballs are
# packaged. A two-artifact variant of submit.sh: flash-lava-test.yaml needs
# TWO uploaded tarballs (the flat flash payload AND the ukify ingredients the
# job's postprocess step rebuilds the UKI from) and four placeholders
# substituted, not one of each. There is no interactive/console mode here —
# unlike flash-lava, this job runs the whole flash+boot+test-suite sequence
# headlessly end to end, so there is nothing for connect.sh to attach to.
#
#   1. Mint upload URLs for both tarballs via the LAVA MCP (mint_lava.py — a
#      direct MCP streamable-HTTP create_artifact_upload call, no `claude` CLI
#      needed; see mint_lava.py for why).
#   2. Upload both tarballs (plain curl PUT).
#   3. Substitute all four placeholders, validate, and submit over the LAVA
#      REST API.
#   4. Poll the job to completion, print its health, and (if Complete) print
#      a pass/fail summary per test suite — health alone doesn't say whether
#      e.g. fastrpc or optee-xtest actually passed.
#
# The LAVA API token is read from ~/.claude.json (the same token the lava MCP
# server is configured with — the X-Lava-Token header, or the older
# C-Lava-Token; either is accepted) — override with $CLAUDE_JSON, or set
# $LAVA_TOKEN to bypass the file entirely.
#
# Usage: submit-test.sh <flash-tarball> <ingredients-tarball> <job-yaml>
set -euo pipefail

FLASH_TARBALL="${1:?usage: submit-test.sh <flash-tarball> <ingredients-tarball> <job-yaml>}"
INGREDIENTS_TARBALL="${2:?usage: submit-test.sh <flash-tarball> <ingredients-tarball> <job-yaml>}"
JOB_YAML="${3:?usage: submit-test.sh <flash-tarball> <ingredients-tarball> <job-yaml>}"

LAVA_URL="${LAVA_URL:-https://lava.infra.foundries.io}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
POLL_SECONDS="${LAVA_POLL_SECONDS:-20}"
POLL_MAX="${LAVA_POLL_MAX:-180}"   # 180 * 20s = 60 min cap

[ -f "$FLASH_TARBALL" ]       || { echo "ERROR: flash tarball not found: $FLASH_TARBALL" >&2; exit 1; }
[ -f "$INGREDIENTS_TARBALL" ] || { echo "ERROR: ingredients tarball not found: $INGREDIENTS_TARBALL" >&2; exit 1; }
[ -f "$JOB_YAML" ]            || { echo "ERROR: job yaml not found: $JOB_YAML" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- LAVA token: $LAVA_TOKEN, else the lava MCP token in ~/.claude.json -------
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

# --- mint + upload one artifact; prints "GET_URL TOKEN" on success -----------
mint_and_upload() {
  local tarball="$1" fn sz mint get_url up_tok
  fn="$(basename "$tarball")"
  sz="$(stat -c%s "$tarball")"
  mint="$(LAVA_URL="$LAVA_URL" CLAUDE_JSON="$CLAUDE_JSON" ${LAVA_TOKEN:+LAVA_TOKEN="$LAVA_TOKEN"} python3 "$(dirname "$0")/../../qcom/lava/mint_lava.py" "$fn" "$sz")"
  [ -n "$mint" ] || { echo "ERROR: could not mint an upload URL for $fn via the MCP" >&2; exit 1; }
  get_url="$(printf %s "$mint" | python3 -c 'import json,sys;print(json.load(sys.stdin)["get_url"])')"
  up_tok="$(printf %s "$mint" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
  [ -n "$get_url" ] && [ "$get_url" != null ] || { echo "ERROR: MCP returned no get_url for $fn: $mint" >&2; exit 1; }
  curl -fsS -T "$tarball" -H "Authorization: $up_tok" "$get_url" >/dev/null
  echo "$get_url $up_tok"
}

echo ">> [1/5] minting + uploading $(basename "$FLASH_TARBALL") ..."
read -r FLASH_URL FLASH_TOK < <(mint_and_upload "$FLASH_TARBALL")
echo "   stored at $FLASH_URL"

echo ">> [2/5] minting + uploading $(basename "$INGREDIENTS_TARBALL") ..."
read -r INGREDIENTS_URL INGREDIENTS_TOK < <(mint_and_upload "$INGREDIENTS_TARBALL")
echo "   stored at $INGREDIENTS_URL"

# --- fill the YAML and submit --------------------------------------------------
sed -e "s|<FLASH_URL>|$FLASH_URL|g" -e "s|<FLASH_TOKEN>|$FLASH_TOK|g" \
    -e "s|<INGREDIENTS_URL>|$INGREDIENTS_URL|g" -e "s|<INGREDIENTS_TOKEN>|$INGREDIENTS_TOK|g" \
    "$JOB_YAML" > "$TMP/job.yaml"
python3 -c 'import json,sys;open(sys.argv[2],"w").write(json.dumps({"definition":open(sys.argv[1]).read()}))' "$TMP/job.yaml" "$TMP/payload.json"

echo ">> [3/5] validating + submitting to $LAVA_URL ..."
VAL="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/validate/")"
echo "   validate: $VAL"
echo "$VAL" | grep -q '"Job valid."' || { echo "ERROR: job did not validate" >&2; exit 1; }

SUB="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/")"
JOB_ID="$(printf %s "$SUB" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_ids"][0])')"
[ -n "$JOB_ID" ] && [ "$JOB_ID" != null ] || { echo "ERROR: submit failed: $SUB" >&2; exit 1; }
echo "   submitted job $JOB_ID  ($LAVA_URL/scheduler/job/$JOB_ID)"

# --- monitor until the board flashes, boots, and the test suite finishes ------
echo ">> [4/5] monitoring job $JOB_ID (flashing, booting, running tests) ..."
last=""; HEALTH=""
for _ in $(seq 1 "$POLL_MAX"); do
  J="$(curl -fsS -H "Authorization: Token $TOK" "$LAVA_URL/api/v0.3/jobs/$JOB_ID/")"
  state="$(printf %s "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')"
  health="$(printf %s "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["health"])')"
  dev="$(printf %s "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("actual_device") or "-")')"
  now="$state/$health@$dev"
  [ "$now" != "$last" ] && { echo "   $now"; last="$now"; }
  if [ "$state" = "Finished" ]; then
    echo ">> job $JOB_ID finished: health=$health"
    HEALTH="$health"; break
  fi
  sleep "$POLL_SECONDS"
done
if [ -z "$HEALTH" ]; then
  echo "WARNING: job $JOB_ID still running after poll cap; check $LAVA_URL/scheduler/job/$JOB_ID" >&2
  exit 0
fi

# --- 5. per-suite pass/fail summary (health=Complete only means the job ran
# to completion, not that every test case passed) -----------------------------
echo ">> [5/5] test results:"
curl -fsS -H "Authorization: Token $TOK" "$LAVA_URL/api/v0.3/jobs/$JOB_ID/tests/?limit=1000" | python3 -c '
import json, re, sys
from collections import Counter
data = json.load(sys.stdin)
results = data.get("results", data)
by_suite = {}
for r in results:
    m = re.search(r"^definition:\s*(\S+)", r.get("metadata") or "", re.M)
    suite = m.group(1) if m else "lava"
    by_suite.setdefault(suite, Counter())[r.get("result", "unknown")] += 1
for suite, counts in sorted(by_suite.items()):
    print("   %-24s %s" % (suite, dict(counts)))
'

[ "$HEALTH" = "Complete" ] && exit 0 || exit 2
