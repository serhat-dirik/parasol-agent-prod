#!/usr/bin/env python3
"""Register the Parasol claims-assistant system prompt in the MLflow Prompt Registry, in the
parasol-secured workspace: the production prompt (alias `production`) and the candidate shortened prompt
(alias `candidate`). APPEND-ONLY and idempotent: nothing is ever deleted. When the alias already points to
a version with the file's text (same sha256) nothing changes; else a version holding that text is reused,
else a new version is registered; then the alias moves. Every version carries its prompt_sha256 tag.

Runs in-cluster. Auth: the pod's own ServiceAccount token (must have the
mlflow-operator-mlflow-edit ClusterRole bound in namespace parasol-secured).
Workspace routing: the x-mlflow-workspace request header (= namespace)."""
import hashlib, os, sys, pathlib, mlflow
from mlflow.tracking.request_header.abstract_request_header_provider import (
    RequestHeaderProvider,
)

WORKSPACE = os.environ.get("MLFLOW_WORKSPACE", "parasol-secured")
PROMPT = os.environ.get("PROMPT_NAME", "parasol-claims-assistant-system-prompt")
HERE = pathlib.Path(__file__).parent


class WorkspaceHeader(RequestHeaderProvider):
    def in_context(self):
        return True

    def request_headers(self):
        return {"x-mlflow-workspace": WORKSPACE}


# register the workspace header on every MLflow REST call
try:
    from mlflow.tracking.request_header.registry import _request_header_provider_registry
    _request_header_provider_registry.register(WorkspaceHeader)
except Exception as e:  # pragma: no cover - API name drift guard
    print(f"header-provider registration failed: {e}", file=sys.stderr)
    raise

# bearer token = the pod SA token
tok_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
if os.path.exists(tok_path):
    os.environ["MLFLOW_TRACKING_TOKEN"] = pathlib.Path(tok_path).read_text().strip()
os.environ.setdefault("MLFLOW_TRACKING_INSECURE_TLS", "true")

common = {
    "agent": "parasol-claims-assistant",
    "source_file": "apps/parasol-portal/app/src/main/java/org/parasol/ai/ClaimsAssistant.java",
    "tools_authpolicy_path": "gitops/platform/mcp-gateway/authpolicy-tools.yaml",
    "tools_authpolicy_sha256": "02619907984be688d238cb2510610458018e427c56066b4e8335bc2b33a1310e",
    "model_id": "qwen3-14b",
    "model_config_name": "parasol-chat",
}
versions = [
    {
        "file": "system-prompt.txt",   # gitops/envs/secured/system-prompt.txt: what the secured portal runs
        "alias": "production",
        "commit": "production prompt: base + safety rules. Passes the golden-set gate (answers generated live).",
        "tags": {**common, "variant": "production",
                 "prompt_file": "gitops/envs/secured/system-prompt.txt",
                 "expected_golden_pass": "passes the gate"},
    },
    {
        "file": "v2.txt",
        "alias": "candidate",
        "commit": "candidate: the shortened prompt (the base as written on the laptop, without the production rules). Below the 0.95 gate: blocked.",
        "tags": {**common, "variant": "candidate-shortened",
                 "prompt_file": "gitops/platform/pipeline/prompts/v2.txt",
                 "expected_golden_pass": "below gate"},
    },
]

CANDIDATE_URIS = [
    os.environ.get("MLFLOW_TRACKING_URI"),
    "https://mlflow.redhat-ods-applications.svc:8443",
    "https://mlflow.redhat-ods-applications.svc:8443/mlflow",
]


def pick_uri():
    for uri in [u for u in CANDIDATE_URIS if u]:
        try:
            mlflow.set_tracking_uri(uri)
            mlflow.set_registry_uri(uri)
            mlflow.search_experiments(max_results=1)
            print(f"tracking uri OK: {uri}")
            return uri
        except Exception as e:
            print(f"tracking uri {uri} -> {type(e).__name__}: {str(e)[:160]}")
    raise SystemExit("no working MLflow tracking URI")


def register_fn():
    for name in ("register_prompt",):
        fn = getattr(mlflow, name, None)
        if fn:
            return fn
    import mlflow.genai as g  # mlflow 3.x
    return g.register_prompt


def version_with(text):
    """The registry version holding exactly this text: the one behind an alias first, else a scan."""
    for alias in ("production", "candidate"):
        try:
            p = mlflow.load_prompt(f"prompts:/{PROMPT}@{alias}")
            if p.template == text:
                return p
        except Exception:
            pass
    v, found = 1, None
    while True:   # ponytail: linear scan of a handful of versions
        try:
            p = mlflow.load_prompt(f"prompts:/{PROMPT}/{v}")
        except Exception:
            return found
        if p.template == text:
            found = p
        v += 1


def main():
    pick_uri()
    reg = register_fn()
    set_alias = getattr(mlflow, "set_prompt_alias", None) or __import__("mlflow.genai").genai.set_prompt_alias
    for v in versions:
        template = (HERE / v["file"]).read_text()
        # the runtime proof: the secured portal stamps sha256(prompt it runs) on every chat trace
        sha = hashlib.sha256(template.encode()).hexdigest()
        pv = version_with(template)
        if pv is None:
            pv = reg(name=PROMPT, template=template, commit_message=v["commit"],
                     tags={**v["tags"], "prompt_sha256": sha, "prompt_chars": str(len(template))})
            how = "registered new"
        else:
            how = "reused"
        set_alias(PROMPT, alias=v["alias"], version=int(pv.version))
        print(f"{how} {PROMPT}@{v['alias']} (registry version {pv.version}) <- {v['file']} "
              f"(variant={v['tags']['variant']}, sha256 {sha})")
    # read back by alias
    for v in versions:
        try:
            p = mlflow.load_prompt(f"prompts:/{PROMPT}@{v['alias']}")
            print(f"loaded {PROMPT}@{v['alias']}: registry version {p.version}, {len(p.template)} chars, "
                  f"variant={p.tags.get('variant')}")
        except Exception as e:
            print(f"load {PROMPT}@{v['alias']} failed: {e}")


if __name__ == "__main__":
    main()
