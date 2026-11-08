#!/usr/bin/env python3
"""Register the models the demo uses in the OpenShift AI Model Registry parasol-model-registry.

The registry holds MODELS only. The three are external (AGENT_MODEL, GUARD_MODEL, JUDGE_MODEL), served by OpenShift
AI Models-as-a-Service: one RegisteredModel each (labels external, MaaS, <role>) with one version named after the
model's own release (qwen3-14b 3.0.0, gpt-oss-120b 1.0.0, granite-guardian-3-1-8b 3.1.0; <ROLE>_MODEL_VERSION
overrides), whose artifact URI is the model's MaaS endpoint. No weights: the provider serves the model, MaaS governs
access (subscription, rate limit, key), the registry records what runs and where.

The claims agent is not a model: its versions (prompt, tool policy, model id, evaluation) are MLflow agent versions,
written by the release pipeline (gitops/platform/pipeline/register-agent-version.py). An earlier layout registered the
agent here as parasol-claims-assistant; it is archived, as are the former version names ("maas").

Stdlib only (urllib). Config (env):
  MR_BASE_URL   model-registry REST base. Default in-cluster kube-rbac-proxy service.
  MR_TOKEN      bearer token; else read from TOKEN_FILE; else the pod SA token.
  MR_INSECURE   "1" (default) to skip TLS verify (lab reencrypt / service CA).
  MAAS_BASE_URL, <ROLE>_MODEL, <ROLE>_MODEL_NAME, <ROLE>_ENDPOINT, <ROLE>_MODEL_VERSION   (ROLE = AGENT, GUARD, JUDGE)
"""
import json, os, ssl, sys, urllib.error, urllib.parse, urllib.request

BASE = os.environ.get("MR_BASE_URL", "https://parasol-model-registry.rhoai-model-registries.svc.cluster.local:8443").rstrip("/")
API = BASE + "/api/model_registry/v1alpha3"
FORMER_AGENT_MODEL = "parasol-claims-assistant"
# The model's own release, in semantic form; a model not listed here is registered as 1.0.0.
MODEL_VERSIONS = {"qwen3-14b": "3.0.0", "gpt-oss-120b": "1.0.0", "granite-guardian-3-1-8b": "3.1.0"}


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
    r = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method)
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


def versions_of(mid):
    s, body = req("GET", f"/registered_models/{mid}/versions?pageSize=200")
    return body.get("items", []) if s == 200 else []


def archive_former_agent(existing):
    """The agent is not a model: archive the former parasol-claims-assistant record and its versions."""
    m = existing.get(FORMER_AGENT_MODEL)
    if not m or m.get("state") == "ARCHIVED":
        return
    for v in versions_of(m["id"]):
        if v.get("state") != "ARCHIVED":
            req("PATCH", f"/model_versions/{v['id']}", {"state": "ARCHIVED"})
    s, _ = req("PATCH", f"/registered_models/{m['id']}", {"state": "ARCHIVED"})
    print(f"archived {FORMER_AGENT_MODEL} (agent versions are MLflow agent versions now) -> {s}")


def maas_models():
    """The external models, each served through MaaS (ExternalModel + MaaSModelRef in models-as-a-service). Keyed by
    the MaaS object name; one model can serve several roles."""
    base = os.environ.get("MAAS_BASE_URL", "").rstrip("/")  # https://maas.apps.<domain>
    out = {}
    for role, uses in (("agent", "claims assistant in both portals (secured: through the guardrails proxy)"),
                       ("guard", "guard MaaS tier"),
                       ("judge", "LLM judge of the release evaluation and the sampled online judge")):
        model = os.environ.get(f"{role.upper()}_MODEL", "")
        if not model:
            continue
        name = os.environ.get(f"{role.upper()}_MODEL_NAME") or model.lower()
        m = out.setdefault(name, {"model": model, "roles": [], "uses": [],
                                  "version": os.environ.get(f"{role.upper()}_MODEL_VERSION") or MODEL_VERSIONS.get(name, "1.0.0"),
                                  "host": urllib.parse.urlparse(os.environ.get(f"{role.upper()}_ENDPOINT", "")).hostname or "unset"})
        m["roles"].append(role)
        m["uses"].append(f"{role}: {uses}")
        m["endpoint"] = f"{base}/models-as-a-service/{name}/v1"
    return out


def ensure_external_models(existing):
    for name, m in maas_models().items():
        labels = {k: "" for k in ["external", "MaaS", *m["roles"]]}  # empty string values = labels in the UI
        props = cp({**labels, "serving": "external", "served_by": "OpenShift AI Models-as-a-Service",
                    "maas_model_ref": f"models-as-a-service/{name}", "maas_endpoint": m["endpoint"],
                    "upstream_model": m["model"], "upstream_host": m["host"], "roles": ",".join(m["roles"]),
                    "used_by": "; ".join(m["uses"])})
        desc = (f"External model {m['model']} ({', '.join(m['roles'])}), served by OpenShift AI Models-as-a-Service "
                f"at {m['endpoint']}. No weights in the cluster: MaaS holds the provider key and meters each subscription.")
        if name in existing:
            mid = existing[name]["id"]
            req("PATCH", f"/registered_models/{mid}", {"description": desc, "customProperties": props})
        else:
            s, b = req("POST", "/registered_models", {"name": name, "state": "LIVE", "description": desc, "customProperties": props})
            if s not in (200, 201):
                sys.exit(f"create external model {name} failed {s}: {b}")
            mid = b["id"]
        vbody = {"description": f"{m['model']} {m['version']}, served by MaaS: {m['endpoint']} (OpenAI-compatible).",
                 "customProperties": props}
        vers = versions_of(mid)
        ver = next((v for v in vers if v.get("name") == m["version"]), None)
        if ver:
            req("PATCH", f"/model_versions/{ver['id']}", {**vbody, "state": "LIVE"})
            vid = ver["id"]
        else:
            s, b = req("POST", f"/registered_models/{mid}/versions",
                       {"name": m["version"], "state": "LIVE", "author": "parasol-bootstrap", "registeredModelId": str(mid), **vbody})
            if s not in (200, 201):
                sys.exit(f"create version {m['version']} of {name} failed {s}: {b}")
            vid = b["id"]
        for v in vers:   # former version names (e.g. "maas") are archived, not deleted
            if v.get("name") != m["version"] and v.get("state") != "ARCHIVED":
                req("PATCH", f"/model_versions/{v['id']}", {"state": "ARCHIVED"})
                print(f"  archived former version {v['name']} of {name}")
        s, arts = req("GET", f"/model_versions/{vid}/artifacts?pageSize=100")
        art = {"name": f"{name}-{m['version']}-maas-endpoint", "artifactType": "model-artifact", "uri": m["endpoint"],
               "modelFormatName": "openai-compatible-api", "modelFormatVersion": "v1",
               "description": "External model endpoint on the MaaS gateway, no weights.",
               "customProperties": cp({"maas_model_ref": f"models-as-a-service/{name}", "upstream_model": m["model"]})}
        old = next((a for a in arts.get("items", []) if a.get("name") == art["name"]), None) if s == 200 else None
        if old:
            req("PATCH", f"/artifacts/{old['id']}", {k: v for k, v in art.items() if k != "name"})
        else:
            req("POST", f"/model_versions/{vid}/artifacts", art)
        print(f"external model {name} {m['version']} ({','.join(m['roles'])}) -> {m['endpoint']}")


def main():
    print(f"model-registry base: {BASE}")
    s, body = req("GET", "/registered_models?pageSize=200")
    if s != 200:
        sys.exit(f"list models failed {s}: {body}")
    existing = {m["name"]: m for m in body.get("items", [])}
    ensure_external_models(existing)
    archive_former_agent(existing)


if __name__ == "__main__":
    main()
