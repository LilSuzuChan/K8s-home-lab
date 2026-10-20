import { CfnOutput, Duration, RemovalPolicy, SecretValue, Stack, type StackProps, Validations } from 'aws-cdk-lib';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import type { Construct } from 'constructs';

export interface BackupStackProps extends StackProps {
  readonly budgetEmail: string;
  readonly monthlyBudgetUsd: number;
}

export const NONCURRENT_VERSION_RETENTION_DAYS = 90;
export const MANIFEST_RETENTION_DAYS = 400;
export const KFP_DB_BACKUP_RETENTION_DAYS = 30;
export const KFP_DB_BACKUP_NONCURRENT_DAYS = 7;
export const BACKUP_PREFIXES = ['seaweedfs', 'manifests', 'status'] as const;

export class BackupStack extends Stack {
  public readonly bucket: s3.Bucket;
  public readonly writer: iam.User;
  public readonly reader: iam.User;

  constructor(scope: Construct, id: string, props: BackupStackProps) {
    super(scope, id, props);

    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(props.budgetEmail)) {
      throw new Error('budgetEmail must be an email address');
    }
    if (!Number.isFinite(props.monthlyBudgetUsd) || props.monthlyBudgetUsd <= 0) {
      throw new Error('monthlyBudgetUsd must be a positive number');
    }

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: `homelab-seaweedfs-backup-${this.account}-${this.region}`,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      enforceSSL: true,
      minimumTLSVersion: 1.2,
      removalPolicy: RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          id: 'expire-noncurrent-versions',
          noncurrentVersionExpiration: Duration.days(NONCURRENT_VERSION_RETENTION_DAYS),
          abortIncompleteMultipartUploadAfter: Duration.days(7),
        },
        {
          id: 'remove-expired-delete-markers',
          expiredObjectDeleteMarker: true,
        },
        {
          id: 'expire-manifests',
          prefix: 'manifests/',
          expiration: Duration.days(MANIFEST_RETENTION_DAYS),
        },
        {
          id: 'expire-kfp-db-backups',
          prefix: 'seaweedfs/kfp-db-backup/',
          expiration: Duration.days(KFP_DB_BACKUP_RETENTION_DAYS),
          noncurrentVersionExpiration: Duration.days(KFP_DB_BACKUP_NONCURRENT_DAYS),
        },
      ],
    });

    this.writer = new iam.User(this, 'WriterUser', {
      userName: 'homelab-backup-writer',
      path: '/homelab/',
    });
    this.writer.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'ListBackupBucket',
      actions: ['s3:ListBucket', 's3:ListBucketMultipartUploads'],
      resources: [this.bucket.bucketArn],
    }));
    this.writer.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'WriteBackupObjects',
      actions: ['s3:GetObject', 's3:PutObject', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts'],
      resources: BACKUP_PREFIXES.map((prefix) => this.bucket.arnForObjects(`${prefix}/*`)),
    }));

    this.reader = new iam.User(this, 'ReaderUser', {
      userName: 'homelab-backup-reader',
      path: '/homelab/',
    });
    this.reader.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'ListBackupBucketVersions',
      actions: ['s3:ListBucket', 's3:ListBucketVersions'],
      resources: [this.bucket.bucketArn],
    }));
    this.reader.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'ReadBackupObjectVersions',
      actions: ['s3:GetObject', 's3:GetObjectVersion'],
      resources: [this.bucket.arnForObjects('*')],
    }));

    this.bucket.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'DenyBucketDeletion',
      effect: iam.Effect.DENY,
      principals: [new iam.AnyPrincipal()],
      actions: ['s3:DeleteBucket'],
      resources: [this.bucket.bucketArn],
    }));
    this.bucket.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'DenyDestructiveActionsByBackupUsers',
      effect: iam.Effect.DENY,
      principals: [new iam.ArnPrincipal(this.writer.userArn), new iam.ArnPrincipal(this.reader.userArn)],
      actions: [
        's3:DeleteObject',
        's3:DeleteObjectVersion',
        's3:DeleteBucket',
        's3:DeleteBucketPolicy',
        's3:PutBucket*',
        's3:PutLifecycleConfiguration',
        's3:PutEncryptionConfiguration',
        's3:PutReplicationConfiguration',
        's3:PutObjectAcl',
        's3:PutObjectVersionAcl',
        's3:PutObjectRetention',
        's3:PutObjectLegalHold',
        's3:BypassGovernanceRetention',
      ],
      resources: [this.bucket.bucketArn, this.bucket.arnForObjects('*')],
    }));

    const writerKey = new iam.AccessKey(this, 'WriterAccessKey', { user: this.writer, serial: 1 });
    const writerSecret = new secretsmanager.Secret(this, 'WriterCredentials', {
      secretName: 'homelab/backup-writer',
      description: 'Access key of homelab-backup-writer for the SeaweedFS backup CronJob',
      secretObjectValue: {
        AWS_ACCESS_KEY_ID: SecretValue.unsafePlainText(writerKey.accessKeyId),
        AWS_SECRET_ACCESS_KEY: writerKey.secretAccessKey,
      },
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const readerKey = new iam.AccessKey(this, 'ReaderAccessKey', { user: this.reader, serial: 1 });
    const readerSecret = new secretsmanager.Secret(this, 'ReaderCredentials', {
      secretName: 'homelab/backup-reader',
      description: 'Access key of homelab-backup-reader for restores and restore drills',
      secretObjectValue: {
        AWS_ACCESS_KEY_ID: SecretValue.unsafePlainText(readerKey.accessKeyId),
        AWS_SECRET_ACCESS_KEY: readerKey.secretAccessKey,
      },
      removalPolicy: RemovalPolicy.RETAIN,
    });

    new budgets.CfnBudget(this, 'MonthlyCostBudget', {
      budget: {
        budgetName: 'homelab-monthly-cost',
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        budgetLimit: { amount: props.monthlyBudgetUsd, unit: 'USD' },
      },
      notificationsWithSubscribers: [{
        notification: {
          notificationType: 'ACTUAL',
          comparisonOperator: 'GREATER_THAN',
          threshold: 100,
          thresholdType: 'PERCENTAGE',
        },
        subscribers: [{ subscriptionType: 'EMAIL', address: props.budgetEmail }],
      }],
    });

    new CfnOutput(this, 'BucketName', { value: this.bucket.bucketName });
    new CfnOutput(this, 'WriterSecretName', { value: 'homelab/backup-writer' });
    new CfnOutput(this, 'ReaderSecretName', { value: 'homelab/backup-reader' });

    Validations.of(this.bucket).acknowledge({
      id: 'AwsSolutions-S1',
      reason: 'Backup-only bucket without public or shared access; server access logs would need a second bucket and cost without a consumer.',
    });
    const bucketArn = `<${this.getLogicalId(this.bucket.node.defaultChild as s3.CfnBucket)}.Arn>`;
    for (const prefix of BACKUP_PREFIXES) {
      Validations.of(this.writer).acknowledge({
        id: `AwsSolutions-IAM5[Resource::${bucketArn}/${prefix}/*]`,
        reason: 'Object keys are not known in advance; access is limited to one backup prefix of the backup bucket.',
      });
    }
    Validations.of(this.reader).acknowledge({
      id: `AwsSolutions-IAM5[Resource::${bucketArn}/*]`,
      reason: 'Restores need read access to every object version in the backup bucket; the user has no write or delete permissions.',
    });
    for (const secret of [writerSecret, readerSecret]) {
      Validations.of(secret).acknowledge({
        id: 'AwsSolutions-SMG4',
        reason: 'The value is an IAM access key managed by CDK; it is rotated by bumping the AccessKey serial, which replaces the secret value.',
      });
    }
  }
}
