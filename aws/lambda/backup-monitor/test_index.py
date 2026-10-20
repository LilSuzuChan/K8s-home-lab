import contextlib
import io
import json
import os
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone

try:
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:
    class BotoCoreError(Exception):
        pass

    class ClientError(Exception):
        def __init__(self, error_response, operation_name):
            super().__init__(operation_name)
            self.response = error_response

    exceptions = types.ModuleType("botocore.exceptions")
    exceptions.BotoCoreError = BotoCoreError
    exceptions.ClientError = ClientError
    sys.modules["botocore"] = types.ModuleType("botocore")
    sys.modules["botocore.exceptions"] = exceptions
    sys.modules["boto3"] = types.ModuleType("boto3")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import index  # noqa: E402

NOW = datetime(2026, 10, 21, 12, 0, 0, tzinfo=timezone.utc)
BUCKET = "homelab-seaweedfs-backup-000000000000-ap-northeast-1"
SHA = "a" * 64


def client_error(code):
    return ClientError({"Error": {"Code": code, "Message": "x"}}, "op")


class FakeBody:
    def __init__(self, data):
        self.data = data

    def read(self, size=-1):
        return self.data if size < 0 else self.data[:size]


class FakeS3:
    def __init__(self, objects, errors=None):
        self.objects = objects
        self.errors = errors or {}

    def _lookup(self, key, missing_code):
        if key in self.errors:
            raise self.errors[key]
        if key not in self.objects:
            raise client_error(missing_code)
        return self.objects[key]

    def get_object(self, Bucket, Key):
        return {"Body": FakeBody(self._lookup(Key, "NoSuchKey"))}

    def head_object(self, Bucket, Key):
        self._lookup(Key, "404")
        return {}


class FakeCloudWatch:
    def __init__(self, fail=False):
        self.calls = []
        self.fail = fail

    def put_metric_data(self, **kwargs):
        if self.fail:
            raise client_error("ThrottlingException")
        self.calls.append(kwargs)


def mysql_objects(started, sha=SHA, with_dump=True, with_checksum=True, recorded_sha=None):
    run_id = started.strftime("%Y%m%dT%H%M%SZ")
    status = {"runId": run_id, "startedEpoch": int(started.timestamp()), "databases": "mlpipeline metadb", "bytes": 61988, "sha256": sha}
    base = f"seaweedfs/kfp-db-backup/mysql/{started:%Y/%m/%d}/{run_id}/dump.sql.gz"
    objects = {index.MYSQL_STATUS_KEY: json.dumps(status).encode()}
    if with_dump:
        objects[base] = b"\x1f\x8b dump"
    if with_checksum:
        objects[base + ".sha256"] = ((recorded_sha or sha) + "\n").encode()
    return objects


def sync_objects(finished):
    status = {"runId": finished.strftime("%Y%m%dT%H%M%SZ"), "startedAt": "x", "finishedAt": finished.strftime("%Y-%m-%dT%H:%M:%SZ")}
    return {index.AWS_SYNC_STATUS_KEY: json.dumps(status).encode()}


def healthy(mysql_age=timedelta(hours=9, minutes=30), sync_age=timedelta(hours=9)):
    return {**mysql_objects(NOW - mysql_age), **sync_objects(NOW - sync_age)}


def results_for(objects, errors=None):
    return {r["check"]: r for r in index.run_checks(FakeS3(objects, errors), BUCKET, NOW)}


class NormalCase(unittest.TestCase):
    def test_both_checks_report_hours_since_success(self):
        r = results_for(healthy())
        self.assertEqual(r["mysql-dump"]["result"], "ok")
        self.assertAlmostEqual(r["mysql-dump"]["hours"], 9.5, places=2)
        self.assertEqual(r["aws-sync"]["result"], "ok")
        self.assertAlmostEqual(r["aws-sync"]["hours"], 9.0, places=2)


class Boundary26Hours(unittest.TestCase):
    def test_just_below_26_hours(self):
        r = results_for(healthy(mysql_age=timedelta(hours=25, minutes=59), sync_age=timedelta(hours=25, minutes=59)))
        self.assertLess(r["mysql-dump"]["hours"], 26)
        self.assertLess(r["aws-sync"]["hours"], 26)

    def test_exactly_26_hours(self):
        r = results_for(healthy(mysql_age=timedelta(hours=26), sync_age=timedelta(hours=26)))
        self.assertEqual(r["mysql-dump"]["hours"], 26.0)
        self.assertEqual(r["aws-sync"]["hours"], 26.0)


class StoppedBackups(unittest.TestCase):
    def test_mysql_backup_stopped_is_independent_of_sync(self):
        r = results_for(healthy(mysql_age=timedelta(hours=50)))
        self.assertGreaterEqual(r["mysql-dump"]["hours"], 26)
        self.assertLess(r["aws-sync"]["hours"], 26)

    def test_aws_sync_stopped_is_independent_of_mysql(self):
        r = results_for(healthy(sync_age=timedelta(hours=27)))
        self.assertLess(r["mysql-dump"]["hours"], 26)
        self.assertGreaterEqual(r["aws-sync"]["hours"], 26)


class BrokenStatus(unittest.TestCase):
    def assertFailed(self, result, reason_prefix):
        self.assertEqual(result["result"], "failed")
        self.assertEqual(result["hours"], index.FAILURE_HOURS)
        self.assertTrue(result["reason"].startswith(reason_prefix), result["reason"])

    def test_missing_mysql_status(self):
        objects = healthy()
        del objects[index.MYSQL_STATUS_KEY]
        self.assertFailed(results_for(objects)["mysql-dump"], "missing:")

    def test_missing_sync_status(self):
        objects = healthy()
        del objects[index.AWS_SYNC_STATUS_KEY]
        self.assertFailed(results_for(objects)["aws-sync"], "missing:")

    def test_invalid_json(self):
        for body in (b"{not json", b"[1,2]", b"\xff\xfe", b"x" * (index.STATUS_MAX_BYTES + 1)):
            objects = healthy()
            objects[index.AWS_SYNC_STATUS_KEY] = body
            r = results_for(objects)["aws-sync"]
            self.assertEqual(r["result"], "failed")
            self.assertTrue(r["reason"].startswith(("invalid_json", "too_large")), r["reason"])

    def test_invalid_times(self):
        future = NOW + timedelta(hours=2)
        objects = {**mysql_objects(future), **sync_objects(future)}
        r = results_for(objects)
        self.assertFailed(r["mysql-dump"], "invalid_time:future")
        self.assertFailed(r["aws-sync"], "invalid_time:future")
        for value in ("2026/10/20 18:00:00", 1792519055, None):
            objects = healthy()
            status = json.loads(objects[index.AWS_SYNC_STATUS_KEY])
            status["finishedAt"] = value
            objects[index.AWS_SYNC_STATUS_KEY] = json.dumps(status).encode()
            self.assertFailed(results_for(objects)["aws-sync"], "invalid_time:finishedAt")
        for value in ("1792519055", True, -1, 0):
            objects = healthy()
            status = json.loads(objects[index.MYSQL_STATUS_KEY])
            status["startedEpoch"] = value
            objects[index.MYSQL_STATUS_KEY] = json.dumps(status).encode()
            self.assertFailed(results_for(objects)["mysql-dump"], "invalid_time:startedEpoch")

    def test_run_id_must_match_started_epoch(self):
        objects = healthy()
        status = json.loads(objects[index.MYSQL_STATUS_KEY])
        status["runId"] = "20200101T000000Z"
        objects[index.MYSQL_STATUS_KEY] = json.dumps(status).encode()
        self.assertFailed(results_for(objects)["mysql-dump"], "invalid_time:runId_mismatch")

    def test_dump_and_checksum_must_exist_and_match(self):
        started = NOW - timedelta(hours=3)
        self.assertFailed(results_for({**mysql_objects(started, with_dump=False), **sync_objects(NOW)})["mysql-dump"], "missing_dump")
        self.assertFailed(results_for({**mysql_objects(started, with_checksum=False), **sync_objects(NOW)})["mysql-dump"], "missing:")
        self.assertFailed(results_for({**mysql_objects(started, recorded_sha="b" * 64), **sync_objects(NOW)})["mysql-dump"], "checksum_mismatch")


class AccessFailures(unittest.TestCase):
    def test_access_denied_and_network_errors(self):
        errors = {index.MYSQL_STATUS_KEY: client_error("AccessDenied"), index.AWS_SYNC_STATUS_KEY: BotoCoreError()}
        r = results_for(healthy(), errors)
        self.assertEqual(r["mysql-dump"]["reason"], "access_error:AccessDenied")
        self.assertTrue(r["aws-sync"]["reason"].startswith("access_error:"))
        self.assertEqual(r["aws-sync"]["hours"], index.FAILURE_HOURS)


class HandlerAndMetrics(unittest.TestCase):
    def setUp(self):
        os.environ["BACKUP_BUCKET"] = BUCKET

    def test_publishes_one_datapoint_per_check(self):
        cloudwatch = FakeCloudWatch()
        with contextlib.redirect_stdout(io.StringIO()):
            index.handler({}, None, s3=FakeS3(healthy()), cloudwatch=cloudwatch, now=NOW)
        call = cloudwatch.calls[0]
        self.assertEqual(call["Namespace"], "Homelab/Backup")
        values = {d["Dimensions"][0]["Value"]: d["Value"] for d in call["MetricData"]}
        self.assertEqual(set(values), {"mysql-dump", "aws-sync"})
        self.assertTrue(all(d["MetricName"] == "HoursSinceLastSuccess" for d in call["MetricData"]))

    def test_failed_checks_still_publish_failure_value(self):
        cloudwatch = FakeCloudWatch()
        with contextlib.redirect_stdout(io.StringIO()):
            index.handler({}, None, s3=FakeS3({}), cloudwatch=cloudwatch, now=NOW)
        self.assertEqual({d["Value"] for d in cloudwatch.calls[0]["MetricData"]}, {index.FAILURE_HOURS})

    def test_metric_publish_failure_raises_so_lambda_errors_alarm(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(ClientError):
                index.handler({}, None, s3=FakeS3(healthy()), cloudwatch=FakeCloudWatch(fail=True), now=NOW)

    def test_logs_do_not_contain_status_contents(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            index.handler({}, None, s3=FakeS3(healthy()), cloudwatch=FakeCloudWatch(), now=NOW)
        log = output.getvalue()
        self.assertNotIn(SHA, log)
        self.assertNotIn("mlpipeline metadb", log)
        self.assertNotIn("61988", log)
        for line in log.strip().splitlines():
            self.assertEqual(set(json.loads(line)) - {"check", "result", "hours", "runId", "reason"}, set())


if __name__ == "__main__":
    unittest.main()
