import * as path from 'node:path';
import { Duration, RemovalPolicy, Stack, type StackProps, Token, Validations } from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';
import type { Construct } from 'constructs';

export interface BackupMonitorStackProps extends StackProps {
  readonly alertEmail: string;
}

export const MONITOR_NAMESPACE = 'Homelab/Backup';
export const MONITOR_METRIC = 'HoursSinceLastSuccess';
export const STALE_AFTER_HOURS = 26;
export const MONITOR_CHECKS = ['mysql-dump', 'aws-sync'] as const;
export const MONITORED_KEYS = [
  'status/last-success.json',
  'seaweedfs/kfp-db-backup/status/last-success.json',
  'seaweedfs/kfp-db-backup/mysql/*',
] as const;

export class BackupMonitorStack extends Stack {
  public readonly topic: sns.Topic;
  public readonly function: lambda.Function;

  constructor(scope: Construct, id: string, props: BackupMonitorStackProps) {
    super(scope, id, props);

    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(props.alertEmail)) {
      throw new Error('alertEmail must be an email address');
    }

    const bucketName = `homelab-seaweedfs-backup-${this.account}-${this.region}`;
    const bucketArn = `arn:aws:s3:::${bucketName}`;

    this.topic = new sns.Topic(this, 'AlertTopic', {
      topicName: 'homelab-backup-alerts',
      displayName: 'Homelab backup alerts',
      enforceSSL: true,
    });
    new sns.Subscription(this, 'AlertEmail', {
      topic: this.topic,
      protocol: sns.SubscriptionProtocol.EMAIL,
      endpoint: props.alertEmail,
    });

    const logGroup = new logs.LogGroup(this, 'MonitorLogs', {
      logGroupName: '/homelab/backup-monitor',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    const role = new iam.Role(this, 'MonitorRole', {
      roleName: 'homelab-backup-monitor',
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: 'Reads backup status objects and publishes backup freshness metrics',
    });
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'WriteOwnLogs',
      actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
      resources: [logGroup.logGroupArn],
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'ReadBackupStatus',
      actions: ['s3:GetObject'],
      resources: MONITORED_KEYS.map((key) => `${bucketArn}/${key}`),
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'DistinguishMissingStatus',
      actions: ['s3:ListBucket'],
      resources: [bucketArn],
      conditions: { StringLike: { 's3:prefix': [...MONITORED_KEYS] } },
    }));
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'PublishFreshnessMetrics',
      actions: ['cloudwatch:PutMetricData'],
      resources: ['*'],
      conditions: { StringEquals: { 'cloudwatch:namespace': MONITOR_NAMESPACE } },
    }));

    this.function = new lambda.Function(this, 'MonitorFunction', {
      functionName: 'homelab-backup-monitor',
      description: 'Checks that the MySQL dump and the AWS copy succeeded within the last 26 hours',
      runtime: lambda.Runtime.PYTHON_3_14,
      architecture: lambda.Architecture.ARM_64,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'lambda', 'backup-monitor'), {
        exclude: ['test_*.py', '__pycache__'],
      }),
      memorySize: 128,
      timeout: Duration.seconds(30),
      role,
      logGroup,
      environment: { BACKUP_BUCKET: bucketName },
    });

    new events.Rule(this, 'HourlySchedule', {
      ruleName: 'homelab-backup-monitor-hourly',
      description: 'Runs the backup monitor every hour',
      schedule: events.Schedule.rate(Duration.hours(1)),
      targets: [new targets.LambdaFunction(this.function, { retryAttempts: 0 })],
    });

    const alarmAction = new cloudwatchActions.SnsAction(this.topic);
    const notify = (alarm: cloudwatch.Alarm) => {
      alarm.addAlarmAction(alarmAction);
      alarm.addOkAction(alarmAction);
      return alarm;
    };
    const freshness = (check: string, statistic: string, period: Duration) => new cloudwatch.Metric({
      namespace: MONITOR_NAMESPACE,
      metricName: MONITOR_METRIC,
      dimensionsMap: { Check: check },
      statistic,
      period,
    });

    for (const check of MONITOR_CHECKS) {
      notify(new cloudwatch.Alarm(this, `Stale-${check}`, {
        alarmName: `homelab-backup-${check}-stale`,
        alarmDescription: `${check} has not succeeded for ${STALE_AFTER_HOURS} hours, or its status could not be verified`,
        metric: freshness(check, 'Maximum', Duration.hours(1)),
        threshold: STALE_AFTER_HOURS,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }));
    }

    notify(new cloudwatch.Alarm(this, 'MetricsMissing', {
      alarmName: 'homelab-backup-monitor-metrics-missing',
      alarmDescription: 'The backup monitor has not published freshness metrics for 2 hours',
      metric: new cloudwatch.MathExpression({
        label: 'MinimumSampleCount',
        expression: 'MIN([FILL(mysql, 0), FILL(sync, 0)])',
        usingMetrics: {
          mysql: freshness('mysql-dump', 'SampleCount', Duration.hours(2)),
          sync: freshness('aws-sync', 'SampleCount', Duration.hours(2)),
        },
        period: Duration.hours(2),
      }),
      threshold: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.BREACHING,
    }));

    notify(new cloudwatch.Alarm(this, 'MonitorErrors', {
      alarmName: 'homelab-backup-monitor-errors',
      alarmDescription: 'The backup monitor Lambda function failed',
      metric: this.function.metricErrors({ statistic: 'Sum', period: Duration.hours(1) }),
      threshold: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    }));

    Validations.of(this.topic).acknowledge({
      id: 'AwsSolutions-SNS2',
      reason: 'Alarm notifications contain no backup data; CloudWatch cannot publish to a topic encrypted with the AWS managed key, and a customer managed key would cost more than the whole monitor.',
    });
    Validations.of(role).acknowledge({
      id: `AwsSolutions-IAM5[Resource::arn:aws:s3:::homelab-seaweedfs-backup-${Token.isUnresolved(this.account) ? '<AWS::AccountId>' : this.account}-${this.region}/seaweedfs/kfp-db-backup/mysql/*]`,
      reason: 'Dump keys contain the run id; access is limited to read-only GetObject under the MySQL dump prefix to verify the latest dump and its checksum.',
    });
    Validations.of(role).acknowledge({
      id: 'AwsSolutions-IAM5[Resource::*]',
      reason: 'cloudwatch:PutMetricData does not support resource-level permissions; it is restricted to the Homelab/Backup namespace by condition.',
    });
  }
}
