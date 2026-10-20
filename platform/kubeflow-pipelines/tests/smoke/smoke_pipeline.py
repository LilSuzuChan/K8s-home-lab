import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

from kfp import Client, dsl

ALPINE = "docker.io/alpine:3.23.6@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0"
PIPELINE_ROOT_PREFIX = "minio://mlpipeline/v2/artifacts/"
HERE = Path(__file__).resolve().parent


@dsl.container_component
def produce(data: dsl.Output[dsl.Dataset], checksum: dsl.Output[dsl.Artifact]):
    return dsl.ContainerSpec(
        image=ALPINE,
        command=["sh", "-ec"],
        args=[
            'mkdir -p "$(dirname "$0")" "$(dirname "$1")"; '
            'head -c 1048576 /dev/urandom > "$0"; '
            'sha256sum "$0" | cut -d" " -f1 > "$1"; '
            'echo "uid=$(id -u) gid=$(id -g) sha256=$(cat "$1")"',
            data.path,
            checksum.path,
        ],
    )


@dsl.container_component
def consume(data: dsl.Input[dsl.Dataset], checksum: dsl.Input[dsl.Artifact], digest: dsl.Output[dsl.Artifact]):
    return dsl.ContainerSpec(
        image=ALPINE,
        command=["sh", "-ec"],
        args=[
            'case "$2" in ' + PIPELINE_ROOT_PREFIX + '*) ;; *) echo "unexpected artifact uri: $2"; exit 1 ;; esac; '
            'mkdir -p "$(dirname "$3")"; '
            'sha256sum "$0" | cut -d" " -f1 > "$3"; '
            'if [ "$(cat "$3")" != "$(cat "$1")" ]; then echo "sha256 mismatch"; exit 1; fi; '
            'echo "uri=$2 sha256=$(cat "$3") matches"',
            data.path,
            checksum.path,
            data.uri,
            digest.path,
        ],
    )


@dsl.pipeline(name="homelab-smoke")
def smoke():
    produced = produce()
    produced.set_caching_options(False)
    consumed = consume(data=produced.outputs["data"], checksum=produced.outputs["checksum"])
    consumed.set_caching_options(False)


def kubectl(*args, stdin=None):
    return subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True, check=True).stdout


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_port_forward():
    port = free_port()
    proc = subprocess.Popen(
        ["kubectl", "-n", "kubeflow", "port-forward", "svc/ml-pipeline-ui", f"{port}:80"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(30):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return proc, f"http://127.0.0.1:{port}"
        except OSError:
            time.sleep(1)
    proc.terminate()
    sys.exit("port-forward to ml-pipeline-ui did not become ready")


def verify_in_seaweedfs(run_id, workflow, keep):
    manifest = (HERE / "verify-job.yaml").read_text()
    name = f"kfp-smoke-verify-{run_id[:8]}"
    manifest = manifest.replace("kfp-smoke-verify", name).replace("RUN_ID_PLACEHOLDER", run_id).replace("WORKFLOW_PLACEHOLDER", workflow)
    kubectl("create", "-f", "-", stdin=manifest)
    try:
        subprocess.run(
            ["kubectl", "-n", "object-storage-backup", "wait", f"job/{name}", "--for=condition=complete", "--timeout=180s"],
            capture_output=True,
            text=True,
        )
        status = json.loads(kubectl("-n", "object-storage-backup", "get", "job", name, "-o", "json"))["status"]
        print(kubectl("-n", "object-storage-backup", "logs", f"job/{name}"), end="")
        return status.get("succeeded", 0) == 1
    finally:
        if not keep:
            kubectl("-n", "object-storage-backup", "delete", "job", name, "--wait=false")


def main():
    parser = argparse.ArgumentParser(description="Run the KFP smoke pipeline and verify its artifacts in SeaweedFS")
    parser.add_argument("--host", default=os.environ.get("KFP_HOST"), help="KFP UI/API URL; a port-forward is started when omitted")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--keep-verify-job", action="store_true")
    args = parser.parse_args()

    port_forward = None
    host = args.host
    if not host:
        port_forward, host = start_port_forward()
    try:
        client = Client(host=host)
        run = client.create_run_from_pipeline_func(
            smoke,
            arguments={},
            enable_caching=False,
            experiment_name="homelab-smoke",
            run_name=f"smoke-{time.strftime('%Y%m%d-%H%M%S')}",
        )
        print(f"run_id={run.run_id}")
        result = client.wait_for_run_completion(run.run_id, timeout=args.timeout)
        print(f"state={result.state}")
        if result.state != "SUCCEEDED":
            sys.exit(1)
        workflows = json.loads(kubectl("-n", "kubeflow", "get", "workflow", "-l", f"pipeline/runid={run.run_id}", "-o", "json"))["items"]
        if len(workflows) != 1:
            sys.exit(f"expected one workflow for run {run.run_id}, found {len(workflows)}")
        if not verify_in_seaweedfs(run.run_id, workflows[0]["metadata"]["name"], args.keep_verify_job):
            sys.exit("artifact verification in SeaweedFS failed")
        print("PASS")
    finally:
        if port_forward:
            port_forward.terminate()


if __name__ == "__main__":
    main()
