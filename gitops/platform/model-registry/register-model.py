#!/usr/bin/env python3
"""Register the Parasol claims-assistant in the OpenShift AI (RHOAI) Model Registry as a
RegisteredModel with ModelVersions v1 and v2, and carry the agent-eval result on each version.

The served model is an EXTERNAL MaaS model (llama-scout-17b), so a "version" is the AGENT CONFIG
(system-prompt version + prompt sha + tools-authpolicy sha + model id), not model weights. Each
ModelVersion carries the eval score / pass-rate + the MLflow run id + the gate result + the
prompt@version it was evaluated with, as customProperties the registry UI shows.

Stdlib only (urllib) so it runs in any python image without pip/egress.

Two modes:
  register-model.py                       full: ensure the model + v1 + v2 with all metadata+eval
  register-model.py --patch-eval \
      --version v2 --gate failed \
      --score 0.85 --run-id c7a36f43 \
      [--prompt-ref ...@2]                 pipeline gate step: merge the eval fields onto one version

Config (env):
  MR_BASE_URL   model-registry REST base. Default in-cluster kube-rbac-proxy service.
  MR_TOKEN      bearer token; else read from TOKEN_FILE; else the pod SA token.
  TOKEN_FILE    path to a bearer token (default: the in-cluster SA token).
  MR_INSECURE   "1" (default) to skip TLS verify (lab reencrypt / service CA).
"""
import argparse, json, os, ssl, sys, urllib.request, urllib.error

BASE = os.environ.get(
    "MR_BASE_URL",
    "https://parasol-model-registry.rhoai-model-registries.svc.cluster.local:8443",
).rstrip("/")
API = BASE + "/api/model_registry/v1alpha3"
MLFLOW_UI = os.environ.get(
    "MLFLOW_UI_BASE",
    "https://rh-ai.apps.cluster-znh6n.dyn.redhatworkshops.io/mlflow",
).rstrip("/")

MODEL = "parasol-claims-assistant"

# Fixed agent-config metadata (mirrors G1 agent_eval VERSION_META and G2 prompt registry).
COMMON = {
    "agent": "parasol-claims-assistant",
    "model_kind": "external-maas-agent-config",
    "model_id": "llama-scout-17b",
    "model_config_name": "parasol-chat",
    "maas_endpoint_host": "maas-rhdp.apps.maas.redhatworkshops.io",
    "prompt_name": "parasol-claims-assistant-system-prompt",
    "source_file": "apps/parasol-portal/app/src/main/java/org/parasol/ai/ClaimsAssistant.java",
    "tools_authpolicy_path": "gitops/platform/mcp-gateway/authpolicy-tools.yaml",
    "tools_authpolicy_sha256": "02619907984be688d238cb2510610458018e427c56066b4e8335bc2b33a1310e",
}
VERSIONS = {
    "v1": {
        "prompt_version": "1", "variant": "v1-secured",
        "prompt_sha256": "301786aa1403c6433508b9e923d91d8c5a91c259aaf83f159d26ebd46f41be6e",
        "prompt_chars": "1667", "safety_rules_file": "gitops/envs/secured/safety-rules.txt",
        "prompt_file": "gitops/platform/pipeline/prompts/v1.txt",
        "eval_passrate": "20/20", "eval_score": "1.00", "eval_gate": "passed",
        "mlflow_run_id": "b9971fab", "mlflow_experiment_id": "2",
        "desc": "Current secured prompt (base + 3 safety rules). Agent-eval 20/20 PASS, promotion allowed.",
    },
    "v2": {
        "prompt_version": "2", "variant": "v2-simplified",
        "prompt_sha256": "aef58cbfa6850ee1009bd232caaef0367259c919a82d5f69c8a80b70b911a9f4",
        "prompt_chars": "1088", "safety_rules_file": "none",
        "prompt_file": "gitops/platform/pipeline/prompts/v2.txt",
        "eval_passrate": "17/20", "eval_score": "0.85", "eval_gate": "failed",
        "mlflow_run_id": "c7a36f43", "mlflow_experiment_id": "2",
        "desc": "Simplified prompt, safety-rules block removed. Agent-eval 17/20 BLOCK (<19/20 gate), promotion skipped.",
    },
}


def token():
    t = os.environ.get("MR_TOKEN")
    if t:
        return t.strip()
    f = os.environ.get("TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")
    if os.path.exists(f):
        return open(f).read().strip()
    sys.exit("no bearer token: set MR_TOKEN or TOKEN_FILE")


CTX = ssl.create_default_context()
if os.environ.get("MR_INSECURE", "1") == "1":
    CTX.check_hostname = False
    CTX.verify_mode = ssl.CERT_NONE
TOK = token()


def req(method, path, body=None):
    url = API + path
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOK)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, context=CTX) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:400]}


def cp(d):
    """Dict -> model-registry customProperties (MLMD string values)."""
    return {k: {"string_value": str(v), "metadataType": "MetadataStringValue"} for k, v in d.items()}


def find_model():
    s, body = req("GET", "/registered_models?pageSize=200")
    if s != 200:
        sys.exit(f"list models failed {s}: {body}")
    for m in body.get("items", []):
        if m.get("name") == MODEL:
            return m
    return None


def ensure_model():
    m = find_model()
    props = cp(COMMON)
    if m:
        req("PATCH", f"/registered_models/{m['id']}",
            {"description": "Parasol claims assistant (agent). External MaaS model; versions are agent configs.",
             "customProperties": props})
        print(f"model {MODEL} exists id={m['id']} (metadata refreshed)")
        return m["id"]
    s, body = req("POST", "/registered_models", {
        "name": MODEL, "state": "LIVE",
        "description": "Parasol claims assistant (agent). External MaaS model; versions are agent configs.",
        "customProperties": props})
    if s not in (200, 201):
        sys.exit(f"create model failed {s}: {body}")
    print(f"created model {MODEL} id={body['id']}")
    return body["id"]


def find_version(model_id, name):
    s, body = req("GET", f"/registered_models/{model_id}/versions?pageSize=200")
    if s != 200:
        return None
    for v in body.get("items", []):
        if v.get("name") == name:
            return v
    return None


def version_props(v):
    d = dict(COMMON)
    d.update({
        "prompt_version": v["prompt_version"], "variant": v["variant"],
        "prompt_sha256": v["prompt_sha256"], "prompt_chars": v["prompt_chars"],
        "safety_rules_file": v["safety_rules_file"], "prompt_file": v["prompt_file"],
        "prompt_ref": f"{COMMON['prompt_name']}@{v['prompt_version']}",
        "eval_dataset": "parasol-golden-20",
        "eval_passrate": v["eval_passrate"], "eval_score": v["eval_score"],
        "eval_gate": v["eval_gate"], "eval_threshold": "19/20",
        "eval_judge_model": "llama-scout-17b (stand-in for gpt-oss-120b, swap-ready)",
        "mlflow_run_id": v["mlflow_run_id"], "mlflow_experiment_id": v["mlflow_experiment_id"],
        "mlflow_run_url": f"{MLFLOW_UI}/#/experiments/{v['mlflow_experiment_id']}/runs/{v['mlflow_run_id']}",
    })
    return d


def ensure_version(model_id, name, v):
    props = cp(version_props(v))
    existing = find_version(model_id, name)
    if existing:
        req("PATCH", f"/model_versions/{existing['id']}",
            {"description": v["desc"], "customProperties": props})
        vid = existing["id"]
        print(f"version {name} exists id={vid} (eval + metadata refreshed: {v['eval_passrate']} {v['eval_gate']})")
    else:
        s, body = req("POST", f"/registered_models/{model_id}/versions", {
            "name": name, "state": "LIVE", "author": "parasol-pipeline",
            "registeredModelId": str(model_id),
            "description": v["desc"], "customProperties": props})
        if s not in (200, 201):
            sys.exit(f"create version {name} failed {s}: {body}")
        vid = body["id"]
        print(f"created version {name} id={vid} ({v['eval_passrate']} {v['eval_gate']})")
    ensure_artifact(vid, name, v)
    return vid


def ensure_artifact(vid, name, v):
    """One model artifact per version = the agent config pointer (external MaaS, no weights)."""
    s, body = req("GET", f"/model_versions/{vid}/artifacts?pageSize=100")
    aname = f"{MODEL}-agent-config-{name}"
    if s == 200 and any(a.get("name") == aname for a in body.get("items", [])):
        return
    art = {
        "name": aname, "artifactType": "model-artifact",
        "uri": f"mlflow+prompt://{COMMON['prompt_name']}/{v['prompt_version']}",
        "modelFormatName": "parasol-agent-config", "modelFormatVersion": v["prompt_version"],
        "description": "Agent config: system prompt + tool authz + model id. External MaaS model, no weights.",
        "customProperties": cp({
            "model_id": COMMON["model_id"], "prompt_ref": f"{COMMON['prompt_name']}@{v['prompt_version']}",
            "tools_authpolicy_sha256": COMMON["tools_authpolicy_sha256"],
        }),
    }
    s, b = req("POST", f"/model_versions/{vid}/artifacts", art)
    print(f"  artifact {aname} -> {s}")


def patch_eval(name, gate, score, run_id, prompt_ref):
    m = find_model()
    if not m:
        sys.exit(f"model {MODEL} not registered yet; run full registration first")
    ver = find_version(m["id"], name)
    if not ver:
        sys.exit(f"version {name} not found; run full registration first")
    passn = int(round(float(score) * 20)) if score else 0
    merged = {
        "eval_gate": gate, "eval_score": f"{float(score):.2f}" if score else "",
        "eval_passrate": f"{passn}/20", "eval_threshold": "19/20",
        "eval_dataset": "parasol-golden-20",
        "mlflow_run_id": run_id, "mlflow_run_url": f"{MLFLOW_UI}/#/experiments/2/runs/{run_id}",
    }
    if prompt_ref:
        merged["prompt_ref"] = prompt_ref
    # Merge onto the version's existing customProperties so the fixed agent-config fields
    # (prompt_sha256, tools sha, model id, ...) survive the eval patch.
    props = dict(ver.get("customProperties") or {})
    props.update(cp(merged))
    s, b = req("PATCH", f"/model_versions/{ver['id']}", {"customProperties": props})
    if s not in (200, 201):
        sys.exit(f"patch eval on {name} failed {s}: {b}")
    print(f"patched eval onto {MODEL} version {name}: gate={gate} score={score} run_id={run_id}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch-eval", action="store_true")
    ap.add_argument("--version", default="v2")
    ap.add_argument("--gate", default="")
    ap.add_argument("--score", default="")
    ap.add_argument("--run-id", default="")
    ap.add_argument("--prompt-ref", default="")
    a = ap.parse_args()
    print(f"model-registry base: {BASE}")
    if a.patch_eval:
        patch_eval(a.version, a.gate, a.score, a.run_id, a.prompt_ref)
        return
    mid = ensure_model()
    for name in ("v1", "v2"):
        ensure_version(mid, name, VERSIONS[name])
    # read back
    s, body = req("GET", f"/registered_models/{mid}/versions?pageSize=200")
    print("VERSIONS NOW:", ", ".join(
        f"{v['name']}(gate={v.get('customProperties',{}).get('eval_gate',{}).get('string_value','?')},"
        f"pass={v.get('customProperties',{}).get('eval_passrate',{}).get('string_value','?')})"
        for v in body.get("items", [])))


if __name__ == "__main__":
    main()
