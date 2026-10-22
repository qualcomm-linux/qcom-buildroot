#!/usr/bin/env bash
# qcom/lava/submit-test.sh: upload the flash-lava-test artifacts, submit the
# job and follow it to the end.
#
# Usage: submit-test.sh <job-yaml> <NAME>=<file> [<NAME>=<file> ...]
#
# Called by 'make flash-lava-test' with the job qcom/lava/flash-lava-test.py
# wrote and the tarballs it references (FLASH, and INGREDIENTS for the
# initramfs overlay). For each NAME=file it:
#   1. mints an upload slot through the LAVA MCP (mint_lava.py, a direct
#      streamable-HTTP create_artifact_upload call) and uploads the file;
#   2. replaces <NAME_URL> in the job with the upload URL and <NAME_TOKEN>
#      with the name of the LAVA remote artifact token that holds the
#      upload secret. LAVA substitutes the secret at download time, so it
#      never appears in the job, which stays public.
# Then it validates and submits the job over the LAVA REST API, polls it to
# the end and prints a pass/fail/skip count per test suite.
#
# The LAVA API token is $LAVA_TOKEN, or the X-Lava-Token (or C-Lava-Token)
# of the lava MCP server in ~/.claude.json ($CLAUDE_JSON).
set -euo pipefail

usage="usage: submit-test.sh <job-yaml> <NAME>=<file> [<NAME>=<file> ...]"
JOB_YAML="${1:?$usage}"; shift
[ $# -ge 1 ] || { echo "$usage" >&2; exit 1; }
[ -f "$JOB_YAML" ] || { echo "ERROR: job yaml not found: $JOB_YAML" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LAVA_URL="${LAVA_URL:-https://lava.infra.foundries.io}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
POLL_SECONDS="${LAVA_POLL_SECONDS:-20}"
POLL_MAX="${LAVA_POLL_MAX:-540}"   # 540 * 20 s = 3 h

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

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

cp "$JOB_YAML" "$TMP/job.yaml"
n=0
for arg in "$@"; do
  name="${arg%%=*}"; file="${arg#*=}"
  n=$((n + 1))
  [ -f "$file" ] || { echo "ERROR: $name: file not found: $file" >&2; exit 1; }
  grep -q "<${name}_URL>" "$TMP/job.yaml" || { echo "ERROR: the job has no <${name}_URL>" >&2; exit 1; }
  echo ">> [$n/$#] uploading $(basename "$file") ($name) ..."
  mint="$(LAVA_URL="$LAVA_URL" CLAUDE_JSON="$CLAUDE_JSON" ${LAVA_TOKEN:+LAVA_TOKEN="$LAVA_TOKEN"} \
          python3 "$HERE/mint_lava.py" "$(basename "$file")" "$(stat -c%s "$file")")"
  get_url="$(printf %s "$mint" | python3 -c 'import json,sys;print(json.load(sys.stdin)["get_url"])')"
  secret="$(printf %s "$mint" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
  token_name="$(printf %s "$mint" | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')"
  [ -n "$get_url" ] && [ -n "$token_name" ] || {
    echo "ERROR: $name: the MCP returned no URL or no remote artifact token name" >&2; exit 1; }
  curl -fsS -T "$file" -H "Authorization: $secret" "$get_url" >/dev/null
  sed -i -e "s|<${name}_URL>|$get_url|g" -e "s|<${name}_TOKEN>|$token_name|g" "$TMP/job.yaml"
  echo "   $get_url"
done
if grep -q '<[A-Z_]*_\(URL\|TOKEN\)>' "$TMP/job.yaml"; then
  echo "ERROR: placeholders left in the job:" >&2
  grep -o '<[A-Z_]*_\(URL\|TOKEN\)>' "$TMP/job.yaml" | sort -u >&2
  exit 1
fi
python3 -c 'import json,sys;open(sys.argv[2],"w").write(json.dumps({"definition":open(sys.argv[1]).read()}))' \
  "$TMP/job.yaml" "$TMP/payload.json"

echo ">> validating and submitting to $LAVA_URL ..."
VAL="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/validate/")"
echo "$VAL" | grep -q '"Job valid."' || { echo "ERROR: job did not validate: $VAL" >&2; exit 1; }
SUB="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/")"
JOB_ID="$(printf %s "$SUB" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_ids"][0])')"
echo "   job $JOB_ID: $LAVA_URL/scheduler/job/$JOB_ID"

echo ">> following job $JOB_ID ..."
last=""; HEALTH=""
for _ in $(seq 1 "$POLL_MAX"); do
  J="$(curl -fsS -H "Authorization: Token $TOK" "$LAVA_URL/api/v0.3/jobs/$JOB_ID/")"
  now="$(printf %s "$J" | python3 -c 'import json,sys;j=json.load(sys.stdin);print("%s/%s@%s"%(j["state"],j["health"],j.get("actual_device") or "-"))')"
  [ "$now" != "$last" ] && { echo "   $now"; last="$now"; }
  case $now in Finished/*) HEALTH="${now#Finished/}"; HEALTH="${HEALTH%@*}"; break ;; esac
  sleep "$POLL_SECONDS"
done
if [ -z "$HEALTH" ]; then
  echo "WARNING: job $JOB_ID still running; see $LAVA_URL/scheduler/job/$JOB_ID" >&2
  exit 0
fi

# Health Complete only means the job ran to the end, not that every case passed.
echo ">> job $JOB_ID: $HEALTH"
curl -fsS -H "Authorization: Token $TOK" "$LAVA_URL/api/v0.3/jobs/$JOB_ID/tests/?limit=5000" | python3 -c '
import json, re, sys
from collections import Counter
data = json.load(sys.stdin)
results = data.get("results", data)
by_suite = {}
for r in results:
    m = re.search(r"^definition:\s*(\S+)", r.get("metadata") or "", re.M)
    suite = m.group(1) if m else "lava"
    by_suite.setdefault(suite, Counter())[r.get("result", "unknown")] += 1
total = Counter()
for suite, counts in sorted(by_suite.items()):
    total.update(counts)
    print("   %-34s %s" % (suite, dict(counts)))
print("   %-34s %s" % ("total", dict(total)))
'
[ "$HEALTH" = Complete ]
