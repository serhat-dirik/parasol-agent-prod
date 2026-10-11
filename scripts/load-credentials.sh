#!/usr/bin/env bash
# Source this (bash or zsh): `source scripts/load-credentials.sh [path]`
# PRIVATE LAB HELPER. Reads the RHDP credentials file and exports what bootstrap and the demo scripts
# need. The file stays outside the repository and its values are never printed. Two layouts are read:
#   - a label line, then its value on the next non-empty line ("OpenShift API", "Username", "Password",
#     or the older snake_case labels such as openshift_api_server_url);
#   - a "MAAS keys" section of curl samples, each pairing a model with its own URL and Bearer key.
# The install contract is per model: <ROLE>_ENDPOINT + <ROLE>_KEY (see README, Quick install). Each
# endpoint is taken from that model's own curl sample, so models may sit behind different providers.
_f="${1:-${CREDENTIALS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)/../../credentials.txt}}"
[ -r "$_f" ] || { echo "credentials file not found: $_f (set CREDENTIALS_FILE)"; return 1 2>/dev/null || exit 1; }
eval "$(python3 -I - "$_f" <<'PY'
import re, shlex, sys
lines = [l.rstrip("\n") for l in open(sys.argv[1])]
out = {}
labels = {  # label (lower-case) -> variable
    "openshift api": "OCP_API", "openshift_api_server_url": "OCP_API",
    "username": "OCP_ADMIN_USER", "openshift_cluster_admin_username": "OCP_ADMIN_USER",
    "password": "OCP_ADMIN_PASSWORD", "openshift_cluster_admin_password": "OCP_ADMIN_PASSWORD",
    "keycloak_admin_console": "KEYCLOAK_ADMIN_URL", "keycloak_admin_user": "KEYCLOAK_ADMIN_USER",
    "keycloak_admin_password": "KEYCLOAK_ADMIN_PASSWORD",
}
for i, l in enumerate(lines):
    var = labels.get(l.strip().lower())
    if var and var not in out:
        nxt = next((x.strip() for x in lines[i + 1:] if x.strip()), "")
        out[var] = nxt
url = key = None
models = {}
for l in lines:
    m = re.search(r"(https?://\S+?)/v1/chat/completions", l)
    if m: url = m.group(1) + "/v1"
    m = re.search(r"Bearer\s+(sk-[A-Za-z0-9_-]+)", l)
    if m: key = m.group(1)
    m = re.search(r'"model"\s*:\s*"([^"]+)"', l)
    if m and key and url:
        models[m.group(1).lower()] = (url, key); key = None
roles = {"AGENT": None, "GUARD": "granite-guardian-3-1-8b", "JUDGE": "gpt-oss-120b",
         "LLAMAGUARD": "llama-guard-3-1b"}
for role, model in roles.items():
    if role == "AGENT": continue
    if model in models:
        out[role + "_ENDPOINT"], out[role + "_KEY"] = models[model]
out["_MODELS"] = " ".join(models)
out["_MODEL_PAIRS"] = ";".join("%s=%s|%s" % (m, u, k) for m, (u, k) in models.items())
for k, v in out.items():
    print("export %s=%s" % (k, shlex.quote(v)))
PY
)"
export AGENT_MODEL="${AGENT_MODEL:-qwen3-14b}"
# agent endpoint/key follow AGENT_MODEL, so another model from the file can be chosen at source time
_pair="$(printf '%s' "$_MODEL_PAIRS" | tr ';' '\n' | grep -i "^${AGENT_MODEL}=" | head -1)"
[ -n "$_pair" ] && export AGENT_ENDPOINT="$(printf '%s' "$_pair" | cut -d= -f2- | cut -d'|' -f1)" AGENT_KEY="$(printf '%s' "$_pair" | cut -d'|' -f2)"
# legacy names some scripts still read
export MAAS_ENDPOINT="${AGENT_ENDPOINT:-}" MAAS_API_KEY="${AGENT_KEY:-}" MAAS_MODEL="$AGENT_MODEL"
echo "loaded: api=${OCP_API:-<missing>} agent=$AGENT_MODEL@${AGENT_ENDPOINT:-<missing>} models in file: $_MODELS (secrets not shown)"
_set=""; for _v in AGENT_KEY GUARD_KEY JUDGE_KEY LLAMAGUARD_KEY; do [ -n "$(eval "printf '%s' \"\${$_v:-}\"")" ] && _set="$_set $_v"; done
echo "model keys set:$_set"
unset _f _pair _set _v _MODEL_PAIRS
