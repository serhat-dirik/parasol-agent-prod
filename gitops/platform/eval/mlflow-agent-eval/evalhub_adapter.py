#!/usr/bin/env python3
"""TrustyAI EvalHub adapter for the release gate: provider parasol-agent-gate, benchmark golden-set.

The job runs agent_eval.py (the same gate the agent-eval Tekton task runs) and reports the result to EvalHub:
metric gate_passed (1 or 0) is the benchmark's primary score, pass_criteria threshold 1.0, so a blocked release
fails the job's test. system_pass_rate, model_only_passed and the case count are reported as metrics; the
strings the pipeline needs (gate, score, MLflow run id and URL, gate reason, released prompt version and sha256)
travel in additional_info, and the MLflow run id is the job's mlflow_run_id.

Benchmark parameters (set by gitops/platform/eval/mlflow-agent-eval/evalhub_gate.py):
  candidate        agent version evaluated (production | candidate-shortened), the run's variant
  prompt_text      the prompt the release ships (the text of prompt-file at the release revision)
  prompt_file_rel  its path in the repository (recorded on the registry version)
  prompt_ref       name@alias: the release registers prompt_text behind that alias (empty: no registration)
  golden_set, fixtures  raw text of golden-set.json / fixtures.json at the release revision (default: the image's)
  cases            optional list of case ids (a subset run; default all)
  attempts, release_run, mlflow_uri, mlflow_workspace, experiment, baseline_experiment, eval_kind, run_suffix

Credentials: EvalHub mounts into the adapter container only the hf-token and ca_cert keys of the job's
model.auth.secret_ref Secret (api-key goes to the sidecar). The gate's Secret is created per job by
evalhub_gate.py and deleted after it; its hf-token key holds a JSON object with the agent and judge MaaS
endpoints, models and keys and a short-lived token of ServiceAccount parasol-eval/parasol-agent-gate (MLflow
workspace parasol-secured, read of the env-secured Application). ca_cert is the cluster service CA.
"""
import json
import os
import pathlib
import time

from evalhub.adapter import (DefaultCallbacks, EvaluationResult, FrameworkAdapter, JobCallbacks, JobPhase,
                             JobResults, JobSpec, JobStatus, JobStatusUpdate, MessageInfo, read_model_auth_key)

HERE = pathlib.Path(__file__).resolve().parent
MODEL_DIR = pathlib.Path("/var/run/secrets/model")
SERVICE_CA = pathlib.Path("/etc/pki/ca-trust/source/anchors/service-ca.crt")


def setup_env(p, creds):
    """The environment agent_eval.run_full reads (see its docstring), from the job's parameters and credentials."""
    env = {
        "AGENT_ENDPOINT": creds["agent_endpoint"], "AGENT_KEY": creds["agent_key"], "AGENT_MODEL": creds["agent_model"],
        "JUDGE_ENDPOINT": creds.get("judge_endpoint", ""), "JUDGE_KEY": creds.get("judge_key", ""),
        "JUDGE_MODEL": creds.get("judge_model", ""),
        "MLFLOW_TRACKING_TOKEN": creds["token"], "KUBE_TOKEN": creds["token"],
        "MLFLOW_TRACKING_URI": p.get("mlflow_uri", "https://mlflow.redhat-ods-applications.svc:8443/mlflow"),
        "MLFLOW_WORKSPACE": p.get("mlflow_workspace", "parasol-secured"),
        "MLFLOW_EXPERIMENT": p.get("experiment", "parasol-agent-eval"),
        "MLFLOW_TRACKING_INSECURE_TLS": "true",
        "EVAL_ATTEMPTS": str(p.get("attempts", 3)),
        "RELEASE_RUN": p.get("release_run", "an EvalHub job"),
    }
    for k in ("baseline_experiment", "eval_kind", "run_suffix"):
        if p.get(k):
            env[k.upper()] = str(p[k])
    if not (env["JUDGE_ENDPOINT"] and env["JUDGE_KEY"]):
        env["NO_JUDGE"] = "1"   # as the Tekton task: no judge key, deterministic-only gate
    # the in-cluster MaaS gateway, guardrails proxy and judge are served with the service CA; the judge client
    # reads SSL_CERT_FILE (public CA + service CA, as the Tekton task builds it)
    ca = MODEL_DIR / "ca_cert" if (MODEL_DIR / "ca_cert").is_file() else SERVICE_CA
    import certifi
    bundle = pathlib.Path("/tmp/judge-ca.pem")
    bundle.write_text(pathlib.Path(certifi.where()).read_text() + "\n" + ca.read_text())
    env.update({"SERVICE_CA_FILE": str(ca), "SSL_CERT_FILE": str(bundle)})
    os.environ.update({k: v for k, v in env.items() if v})


def stage_inputs(p):
    """Golden set and fixtures of the release revision replace the image's copies; the prompt goes to a file."""
    if p.get("golden_set"):
        golden = json.loads(p["golden_set"])
        if p.get("cases"):
            golden["cases"] = [c for c in golden["cases"] if c["id"] in set(p["cases"])]
            (HERE / "golden-set.json").write_text(json.dumps(golden, indent=2))
        else:
            (HERE / "golden-set.json").write_text(p["golden_set"])
    if p.get("fixtures"):
        (HERE / "fixtures.json").write_text(p["fixtures"])
    if p.get("prompt_text"):
        f = pathlib.Path("/tmp/prompt.txt")
        f.write_text(p["prompt_text"])
        os.environ.update({"PROMPT_FILE": str(f), "PROMPT_FILE_REL": p.get("prompt_file_rel", "")})
        if p.get("prompt_ref"):
            os.environ["PROMPT_REF"] = p["prompt_ref"]


def read_results(rd):
    r = lambda name: (rd / name).read_text().strip() if (rd / name).is_file() else ""
    return {"gate": r("gate"), "score": r("score"), "mlflow_run_id": r("run-id"), "mlflow_run_url": r("run-url"),
            "gate_reason": r("gate-reason"), "model_only_passed": r("model-only-passed"),
            "prompt_sha256": r("prompt-sha256"), "prompt_version": r("released-prompt/promptVersion"),
            "released_prompt_sha256": r("released-prompt/promptSha256")}


class GateAdapter(FrameworkAdapter):
    def run_benchmark_job(self, config: JobSpec, callbacks: JobCallbacks) -> JobResults:
        t0 = time.time()
        p = config.parameters
        creds = json.loads(read_model_auth_key("hf-token") or "{}")
        if not creds.get("token") or not creds.get("agent_key"):
            raise RuntimeError("gate credentials missing: the job's model.auth.secret_ref must carry key hf-token "
                               "(created by evalhub_gate.py)")
        setup_env(p, creds)
        stage_inputs(p)
        candidate = p.get("candidate", "production")
        callbacks.report_status(JobStatusUpdate(status=JobStatus.RUNNING, phase=JobPhase.RUNNING_EVALUATION,
                                                message=MessageInfo(message=f"golden set: {candidate}, live generation",
                                                                    message_code="gate_running")))
        import agent_eval   # after the environment is set: it reads JUDGE_PARALLEL at import
        agent_eval.NO_FAIL = True
        rd = pathlib.Path("/tmp/release")
        agent_eval.run_full([candidate], candidate, str(rd))
        info = read_results(rd)
        total = len(json.loads((HERE / "golden-set.json").read_text())["cases"])
        passed = info["gate"] == "passed"
        metrics = [EvaluationResult(metric_name="gate_passed", metric_value=1.0 if passed else 0.0),
                   EvaluationResult(metric_name="system_pass_rate", metric_value=float(info["score"] or 0)),
                   EvaluationResult(metric_name="model_only_passed", metric_value=float(info["model_only_passed"] or 0)),
                   EvaluationResult(metric_name="cases", metric_value=float(total))]
        print("GATE_RESULT " + json.dumps(info))
        return JobResults(id=config.id, benchmark_id=config.benchmark_id, benchmark_index=config.benchmark_index,
                          model_name=config.model.name, results=metrics, num_examples_evaluated=total,
                          duration_seconds=time.time() - t0, mlflow_run_id=info["mlflow_run_id"] or None,
                          additional_info={**info, "candidate": candidate, "prompt_ref": p.get("prompt_ref", "")})


if __name__ == "__main__":
    adapter = GateAdapter()
    cb = DefaultCallbacks.from_adapter(adapter)
    try:
        results = adapter.run_benchmark_job(adapter.job_spec, cb)
    except BaseException as e:   # agent_eval may sys.exit (e.g. the portal's correction rule differs)
        cb.report_status(JobStatusUpdate(status=JobStatus.FAILED, error_message=MessageInfo(
            message=f"{type(e).__name__}: {str(e)[:400]}", message_code="gate_error")))
        raise
    cb.report_results(results)
