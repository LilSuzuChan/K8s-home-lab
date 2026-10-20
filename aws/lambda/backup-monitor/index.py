import json
import os
import re
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

NAMESPACE = "Homelab/Backup"
METRIC_NAME = "HoursSinceLastSuccess"
FAILURE_HOURS = 9999.0
MAX_CLOCK_SKEW_HOURS = 0.25
STATUS_MAX_BYTES = 16384
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
RUN_ID_PATTERN = re.compile(r"^(\d{4})(\d{2})(\d{2})T\d{6}Z$")

AWS_SYNC_STATUS_KEY = "status/last-success.json"
MYSQL_PREFIX = "seaweedfs/kfp-db-backup/"
MYSQL_STATUS_KEY = MYSQL_PREFIX + "status/last-success.json"


class CheckFailure(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _read(s3, bucket, key, max_bytes=STATUS_MAX_BYTES):
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code", "")
        if code in ("NoSuchKey", "404"):
            raise CheckFailure("missing:" + key) from None
        raise CheckFailure("access_error:" + code) from None
    except BotoCoreError as error:
        raise CheckFailure("access_error:" + type(error).__name__) from None
    body = response["Body"].read(max_bytes + 1)
    if len(body) > max_bytes:
        raise CheckFailure("too_large:" + key)
    return body


def _read_json(s3, bucket, key):
    try:
        value = json.loads(_read(s3, bucket, key).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise CheckFailure("invalid_json:" + key) from None
    if not isinstance(value, dict):
        raise CheckFailure("invalid_json:" + key)
    return value


def _age_hours(timestamp, now):
    age = (now - timestamp).total_seconds() / 3600
    if age < -MAX_CLOCK_SKEW_HOURS:
        raise CheckFailure("invalid_time:future")
    return max(age, 0.0)


def check_mysql_dump(s3, bucket, now):
    status = _read_json(s3, bucket, MYSQL_STATUS_KEY)
    started = status.get("startedEpoch")
    if not isinstance(started, int) or isinstance(started, bool) or started <= 0:
        raise CheckFailure("invalid_time:startedEpoch")
    run_id = status.get("runId")
    match = RUN_ID_PATTERN.match(run_id) if isinstance(run_id, str) else None
    if not match:
        raise CheckFailure("invalid_json:runId")
    expected = status.get("sha256")
    if not isinstance(expected, str) or not SHA256_PATTERN.match(expected):
        raise CheckFailure("invalid_json:sha256")
    started_at = datetime.fromtimestamp(started, tz=timezone.utc)
    if started_at.strftime("%Y%m%dT%H%M%SZ") != run_id:
        raise CheckFailure("invalid_time:runId_mismatch")
    year, month, day = match.groups()
    dump_key = f"{MYSQL_PREFIX}mysql/{year}/{month}/{day}/{run_id}/dump.sql.gz"
    try:
        s3.head_object(Bucket=bucket, Key=dump_key)
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code", "")
        if code in ("NoSuchKey", "404", "NotFound"):
            raise CheckFailure("missing_dump") from None
        raise CheckFailure("access_error:" + code) from None
    except BotoCoreError as error:
        raise CheckFailure("access_error:" + type(error).__name__) from None
    recorded = _read(s3, bucket, dump_key + ".sha256", 256).decode("utf-8", "replace").strip()
    if recorded != expected:
        raise CheckFailure("checksum_mismatch")
    return _age_hours(started_at, now), run_id


def check_aws_sync(s3, bucket, now):
    status = _read_json(s3, bucket, AWS_SYNC_STATUS_KEY)
    finished = status.get("finishedAt")
    if not isinstance(finished, str):
        raise CheckFailure("invalid_time:finishedAt")
    try:
        finished_at = datetime.strptime(finished, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        raise CheckFailure("invalid_time:finishedAt") from None
    run_id = status.get("runId") if isinstance(status.get("runId"), str) else ""
    return _age_hours(finished_at, now), run_id


CHECKS = (("mysql-dump", check_mysql_dump), ("aws-sync", check_aws_sync))


def run_checks(s3, bucket, now):
    results = []
    for name, check in CHECKS:
        try:
            hours, run_id = check(s3, bucket, now)
            results.append({"check": name, "result": "ok", "hours": round(hours, 3), "runId": run_id})
        except CheckFailure as failure:
            results.append({"check": name, "result": "failed", "hours": FAILURE_HOURS, "reason": failure.reason})
    return results


def publish(cloudwatch, results, now):
    cloudwatch.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {
                "MetricName": METRIC_NAME,
                "Dimensions": [{"Name": "Check", "Value": result["check"]}],
                "Timestamp": now,
                "Value": result["hours"],
                "Unit": "None",
            }
            for result in results
        ],
    )


def handler(event, context, s3=None, cloudwatch=None, now=None):
    bucket = os.environ["BACKUP_BUCKET"]
    s3 = s3 or boto3.client("s3")
    cloudwatch = cloudwatch or boto3.client("cloudwatch")
    now = now or datetime.now(timezone.utc)
    results = run_checks(s3, bucket, now)
    for result in results:
        print(json.dumps(result, sort_keys=True))
    publish(cloudwatch, results, now)
    return {"results": results}
