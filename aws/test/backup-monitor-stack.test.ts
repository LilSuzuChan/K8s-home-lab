import { App, Validations } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { AwsSolutionsChecks } from 'cdk-nag';
import { BackupMonitorStack, MONITOR_NAMESPACE, STALE_AFTER_HOURS } from '../lib/backup-monitor-stack';
import { BackupStack } from '../lib/backup-stack';

const EMAIL = 'alerts@example.com';
const ENV = { account: '123456789012', region: 'ap-northeast-1' };
const BUCKET = 'homelab-seaweedfs-backup-123456789012-ap-northeast-1';

function synth() {
  const app = new App();
  const stack = new BackupMonitorStack(app, 'TestMonitorStack', { env: ENV, alertEmail: EMAIL });
  return { app, stack, template: Template.fromStack(stack) };
}

function alarms(template: Template) {
  return Object.values(template.findResources('AWS::CloudWatch::Alarm')).map((r) => r.Properties);
}

describe('monitor function', () => {
  const { template } = synth();

  test('runs Python 3.14 on arm64 with the backup bucket name and a short timeout', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'python3.14',
      Architectures: ['arm64'],
      Handler: 'index.handler',
      Timeout: 30,
      MemorySize: 128,
      Environment: { Variables: { BACKUP_BUCKET: BUCKET } },
    });
  });

  test('is invoked every hour without retries', () => {
    template.hasResourceProperties('AWS::Events::Rule', {
      ScheduleExpression: 'rate(1 hour)',
      Targets: [Match.objectLike({ RetryPolicy: { MaximumRetryAttempts: 0 } })],
    });
  });

  test('writes logs to a dedicated log group with retention', () => {
    template.hasResourceProperties('AWS::Logs::LogGroup', { LogGroupName: '/homelab/backup-monitor', RetentionInDays: 30 });
  });
});

describe('monitor permissions', () => {
  const { template } = synth();
  const statements = Object.values(template.findResources('AWS::IAM::Policy'))
    .flatMap((p) => p.Properties.PolicyDocument.Statement as Array<Record<string, any>>);
  const bySid = (sid: string) => statements.find((s) => s.Sid === sid)!;

  test('has only the expected actions', () => {
    const actions = statements.flatMap((s) => (Array.isArray(s.Action) ? s.Action : [s.Action])).sort();
    expect(actions).toEqual(['cloudwatch:PutMetricData', 'logs:CreateLogStream', 'logs:PutLogEvents', 's3:GetObject', 's3:ListBucket']);
    expect(statements.every((s) => s.Effect === 'Allow')).toBe(true);
  });

  test('reads only the status objects and the MySQL dump prefix', () => {
    expect(bySid('ReadBackupStatus').Resource).toEqual([
      `arn:aws:s3:::${BUCKET}/status/last-success.json`,
      `arn:aws:s3:::${BUCKET}/seaweedfs/kfp-db-backup/status/last-success.json`,
      `arn:aws:s3:::${BUCKET}/seaweedfs/kfp-db-backup/mysql/*`,
    ]);
    expect(bySid('DistinguishMissingStatus')).toMatchObject({
      Resource: `arn:aws:s3:::${BUCKET}`,
      Condition: { StringLike: { 's3:prefix': ['status/last-success.json', 'seaweedfs/kfp-db-backup/status/last-success.json', 'seaweedfs/kfp-db-backup/mysql/*'] } },
    });
  });

  test('publishes metrics only to its namespace', () => {
    expect(bySid('PublishFreshnessMetrics').Condition).toEqual({ StringEquals: { 'cloudwatch:namespace': MONITOR_NAMESPACE } });
  });

  test('uses no managed policies', () => {
    template.hasResourceProperties('AWS::IAM::Role', { ManagedPolicyArns: Match.absent() });
  });
});

describe('alarms', () => {
  const { template } = synth();
  const all = alarms(template);
  const byName = (name: string) => all.find((a) => a.AlarmName === name)!;

  test('each backup check has its own stale alarm at 26 hours', () => {
    for (const check of ['mysql-dump', 'aws-sync']) {
      expect(byName(`homelab-backup-${check}-stale`)).toMatchObject({
        Namespace: MONITOR_NAMESPACE,
        MetricName: 'HoursSinceLastSuccess',
        Dimensions: [{ Name: 'Check', Value: check }],
        Statistic: 'Maximum',
        Period: 3600,
        Threshold: STALE_AFTER_HOURS,
        ComparisonOperator: 'GreaterThanOrEqualToThreshold',
        EvaluationPeriods: 1,
      });
    }
    expect(STALE_AFTER_HOURS).toBe(26);
  });

  test('missing metrics from either check raise an alarm', () => {
    const alarm = byName('homelab-backup-monitor-metrics-missing');
    expect(alarm).toMatchObject({ Threshold: 1, ComparisonOperator: 'LessThanThreshold', TreatMissingData: 'breaching' });
    const expression = alarm.Metrics.find((m: any) => m.Expression);
    expect(expression.Expression).toBe('MIN([FILL(mysql, 0), FILL(sync, 0)])');
    const inputs = alarm.Metrics.filter((m: any) => m.MetricStat).map((m: any) => m.MetricStat.Metric.Dimensions[0].Value).sort();
    expect(inputs).toEqual(['aws-sync', 'mysql-dump']);
  });

  test('Lambda errors raise an alarm', () => {
    expect(byName('homelab-backup-monitor-errors')).toMatchObject({
      Namespace: 'AWS/Lambda',
      MetricName: 'Errors',
      Statistic: 'Sum',
      Threshold: 1,
      ComparisonOperator: 'GreaterThanOrEqualToThreshold',
    });
  });

  test('every alarm notifies the topic on ALARM and OK', () => {
    expect(all).toHaveLength(4);
    const topic = Object.keys(template.findResources('AWS::SNS::Topic'))[0];
    for (const alarm of all) {
      expect(alarm.AlarmActions).toEqual([{ Ref: topic }]);
      expect(alarm.OKActions).toEqual([{ Ref: topic }]);
    }
  });
});

describe('notifications', () => {
  test('email subscription uses the parameter and the topic requires TLS', () => {
    const { template } = synth();
    template.hasResourceProperties('AWS::SNS::Subscription', { Protocol: 'email', Endpoint: EMAIL });
    const policy = Object.values(template.findResources('AWS::SNS::TopicPolicy'))[0];
    expect(JSON.stringify(policy)).toContain('aws:SecureTransport');
    expect(JSON.stringify(template.findOutputs('*'))).not.toContain(EMAIL);
    const logicalIds = Object.keys(template.toJSON().Resources).join(' ').toLowerCase();
    expect(logicalIds).not.toContain('alerts');
    expect(logicalIds).not.toContain('examplecom');
  });

  test('rejects an invalid email', () => {
    expect(() => new BackupMonitorStack(new App(), 'Bad', { env: ENV, alertEmail: 'nope' })).toThrow(/alertEmail/);
  });
});

describe('isolation from the backup stack', () => {
  test('the backup stack template is identical with or without the monitor', () => {
    const alone = new App();
    const withMonitor = new App();
    const props = { env: ENV, budgetEmail: 'budget@example.com', monthlyBudgetUsd: 13 };
    const a = Template.fromStack(new BackupStack(alone, 'HomelabBackupStack', props)).toJSON();
    const b = Template.fromStack(new BackupStack(withMonitor, 'HomelabBackupStack', props)).toJSON();
    new BackupMonitorStack(withMonitor, 'HomelabBackupMonitorStack', { env: ENV, alertEmail: EMAIL });
    expect(b).toEqual(a);
    expect(JSON.stringify(b)).not.toContain('Export');
  });
});

describe('cdk-nag AwsSolutions', () => {
  test('synthesizes without unacknowledged findings', () => {
    const app = new App();
    new BackupMonitorStack(app, 'NagMonitorStack', { env: ENV, alertEmail: EMAIL });
    Validations.of(app).addPlugins(new AwsSolutionsChecks(app));
    expect(() => app.synth()).not.toThrow();
  });
});
