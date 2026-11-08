#!/usr/bin/env python3
"""Record this release's claims agent as an MLflow agent version (LoggedModel, type agent) in the release experiment.

The agent is not a model: a version is the agent CONFIG the gate evaluated (system prompt version + sha256, tool
policy sha256, model id, portal image digest) plus its evaluation (gate, score, the eval run it came from). Every
release records one, passed or not, so the history shows what was refused too. Versions are semantic and count up per
release: parasol-claims-agent 1.0.0, 1.1.0, 1.2.0, ... A re-run of the same release (same eval run id) reuses its
version. Best-effort: the gate alone decides promotion; this step only records provenance.

Stdlib only. Env: MLFLOW_TRACKING_URI, MLFLOW_WORKSPACE, MLFLOW_EXPERIMENT (default parasol-agent-eval),
TOKEN_FILE (the pipeline SA token). The model id is the eval run's param agent_model. Writes "<name>@<version>" and the MLflow model id to --out-version and
--out-id (both always written, "unrecorded" when MLflow cannot be reached, so the pipeline result is never missing).
"""
import argparse, hashlib, json, os, pathlib, ssl, sys, urllib.error, urllib.request

NAME = "parasol-claims-agent"
CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE   # in-cluster service CA; the SA token is what authenticates


def api(method, path, body=None):
    base = os.environ.get("MLFLOW_TRACKING_URI", "https://mlflow.redhat-ods-applications.svc:8443/mlflow").rstrip("/")
    r = urllib.request.Request(f"{base}/api/2.0/mlflow/{path}", data=json.dumps(body).encode() if body is not None else None,
                               method=method)
    r.add_header("Authorization", "Bearer " + open(os.environ.get("TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")).read().strip())
    r.add_header("X-MLFLOW-WORKSPACE", os.environ.get("MLFLOW_WORKSPACE", "parasol-secured"))
    r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, context=CTX, timeout=30) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}


def read(p):
    try:
        return pathlib.Path(p).read_text().strip()
    except OSError:
        return ""


def next_version(models):
    """1.0.0 for the first release, then the next minor: one version per release."""
    minors = [int(v.split(".")[1]) for v in (m.get("tags_d", {}).get("version", "") for m in models)
              if v.count(".") == 2 and v.split(".")[1].isdigit()]
    return f"1.{max(minors) + 1}.0" if minors else "1.0.0"


def main():
    ap = argparse.ArgumentParser()
    for a in ("variant", "gate", "score", "run-id", "prompt-ref", "release-dir", "tools-policy", "image-digest",
              "out-version", "out-id"):
        ap.add_argument("--" + a, default="")
    a = ap.parse_args()
    out = lambda ver, mid: (pathlib.Path(a.out_version).write_text(ver), pathlib.Path(a.out_id).write_text(mid))
    try:
        exp = api("GET", "experiments/get-by-name?experiment_name=" + os.environ.get("MLFLOW_EXPERIMENT", "parasol-agent-eval"))
        eid = exp["experiment"]["experiment_id"]
        found = api("POST", "logged-models/search", {"experiment_ids": [eid], "filter": f"name = '{NAME}'", "max_results": 200})
        models = [m["info"] for m in found.get("models", [])]
        for m in models:
            m["tags_d"] = {t["key"]: t["value"] for t in m.get("tags", [])}
        same = next((m for m in models if a.run_id and m["tags_d"].get("eval_run_id") == a.run_id), None)
        if same:
            ver, mid = same["tags_d"].get("version", "?"), same["model_id"]
            print(f"agent version {NAME} {ver} already records eval run {a.run_id} ({mid})")
            return out(f"{NAME}@{ver}", mid)
        ver = next_version(models)
        R = a.release_dir
        run_params = {}
        if a.run_id:
            run = api("GET", f"runs/get?run_id={a.run_id}")
            run_params = {p["key"]: p["value"] for p in run["run"]["data"].get("params", [])}
        tools = pathlib.Path(a.tools_policy)
        params = {
            "variant": a.variant, "prompt_ref": a.prompt_ref,
            "prompt_version": read(f"{R}/released-prompt/promptVersion"), "prompt_sha256": read(f"{R}/prompt-sha256"),
            "tools_policy": a.tools_policy, "tools_policy_sha256": hashlib.sha256(tools.read_bytes()).hexdigest() if tools.is_file() else "",
            "model_id": run_params.get("agent_model") or run_params.get("model_id") or "unknown", "served_by": "OpenShift AI Models-as-a-Service",
            "portal_image_digest": a.image_digest,
        }
        tags = {"version": ver, "variant": a.variant, "eval_gate": a.gate, "eval_score": a.score,
                "eval_reason": read(f"{R}/gate-reason"), "eval_run_id": a.run_id,
                "mlflow.note.content": f"Claims agent {ver} ({a.variant}): evaluation {a.gate}, score {a.score}. "
                                       f"Prompt {params['prompt_ref']} sha256 {params['prompt_sha256'][:12]}, model {params['model_id']}."}
        created = api("POST", "logged-models", {
            "experiment_id": eid, "name": NAME, "model_type": "agent", "source_run_id": a.run_id or None,
            "params": [{"key": k, "value": str(v)} for k, v in params.items() if v],
            "tags": [{"key": k, "value": str(v)} for k, v in tags.items() if v != ""]})
        mid = created["model"]["info"]["model_id"]
        api("PATCH", f"logged-models/{mid}", {"model_id": mid, "status": "LOGGED_MODEL_READY"})
        print(f"agent version {NAME} {ver} recorded: {mid} (gate {a.gate}, score {a.score}, eval run {a.run_id})")
        out(f"{NAME}@{ver}", mid)
    except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
        print(f"agent version not recorded (non-fatal): {e}")
        out("unrecorded", "unrecorded")


if __name__ == "__main__":
    main()
