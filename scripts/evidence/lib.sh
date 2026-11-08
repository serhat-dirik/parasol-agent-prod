# shellcheck shell=bash
# Shared by scripts/evidence/showcase<N>.sh. Every command is printed before it runs ($ ..., cyan, on stderr), so
# each output can be traced to the command that produced it and copied into a terminal. Python or awk after a
# command only formats its output. Tokens are never printed: commands show $(scripts/agent-token.sh <user>).
# NO_COLOR=1 turns colours off.
set -euo pipefail
EV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$EV/../.."   # commands are shown relative to the repository root (scripts/...)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then B=$'\e[1m' C=$'\e[36m' D=$'\e[2m' R=$'\e[0m'; else B='' C='' D='' R=''; fi
DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
GW="https://mcp.apps.$DOMAIN/mcp"
SERVER=parasol-secured/claims-db

title() { printf '\n%s== %s%s\n' "$B" "$*" "$R"; }
note() { printf '%s%s%s\n' "$D" "$*" "$R"; }
run() { printf '%s$ %s%s\n' "$C" "$1" "$R" >&2; eval "$1"; }   # run '<command>': show it, then run it

usage() {  # the topic list: the comment block at the top of the calling script
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1
}

claims() {  # claims <token> [server]: decode a JWT: who, which client, groups, tool roles on one server
  python3 -c '
import sys, json, base64
p = sys.argv[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
roles = sorted(r.removeprefix("tool:") for r in c.get("resource_access", {}).get(sys.argv[2], {}).get("roles", []))
print("    user   :", c.get("preferred_username"))
print("    client :", c.get("azp"))
print("    groups :", ", ".join(c.get("groups", [])) or "-")
print("    tools  :", ", ".join(roles) or "-", "  (roles on " + sys.argv[2] + ")")' "$1" "${2:-$SERVER}"
}

text() {  # text <mcp-call.sh output>: the tool's text answer (first content item)
  python3 -c '
import sys, json
body = sys.argv[1].rsplit("|", 1)[0]
body = body.split("data: ", 1)[-1] if body.startswith(("event:", "data:")) else body
print(json.loads(body)["result"]["content"][0]["text"])' "$1"
}
