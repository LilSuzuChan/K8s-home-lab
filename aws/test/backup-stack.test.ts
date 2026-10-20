import { App, Validations } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { AwsSolutionsChecks } from 'cdk-nag';
import { BackupStack, NONCURRENT_VERSION_RETENTION_DAYS } from '../lib/backup-stack';

const EMAIL = 'budget@example.com';

function synth(monthlyBudgetUsd = 13) {
  const app = new App();
  const stack = new BackupStack(app, 'TestBackupStack', {
    env: { account: '123456789012', region: 'ap-northeast-1' },
    budgetEmail: EMAIL,
    monthlyBudgetUsd,
  });
  return { app, stack, template: Template.fromStack(stack) };
}

type Statement = { Effect: string; Action: string | string[]; Resource?: unknown; Principal?: unknown; Sid?: string };

function statementsOf(policy: { [key: string]: any }): Statement[] {
  return policy.Properties.PolicyDocument.Statement;
}

function actionsOf(statement: Statement): string[] {
  return Array.isArray(statement.Action) ? statement.Action : [statement.Action];
}

function userPolicyActions(template: Template, userLogicalIdPrefix: string): string[] {
  const policies = template.findResources('AWS::IAM::Policy');
  return Object.entries(policies)
    .filter(([, policy]) => JSON.stringify(policy.Properties.Users).includes(userLogicalIdPrefix))
    .flatMap(([, policy]) => statementsOf(policy).flatMap(actionsOf));
}

describe('backup bucket', () => {
  const { template } = synth();

  test('is versioned, encrypted with SSE-S3, private and owner-enforced', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      VersioningConfiguration: { Status: 'Enabled' },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [{ ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' } }],
      },
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
      OwnershipControls: { Rules: [{ ObjectOwnership: 'BucketOwnerEnforced' }] },
    });
  });

  test('is retained on stack deletion and replacement', () => {
    template.hasResource('AWS::S3::Bucket', { DeletionPolicy: 'Retain', UpdateReplacePolicy: 'Retain' });
  });

  test('never auto-deletes objects', () => {
    expect(Object.keys(template.findResources('Custom::S3AutoDeleteObjects'))).toHaveLength(0);
    expect(Object.keys(template.findResources('AWS::Lambda::Function'))).toHaveLength(0);
  });

  test('keeps noncurrent versions for the agreed period and never expires current backup objects', () => {
    const bucket = Object.values(template.findResources('AWS::S3::Bucket'))[0];
    const rules = bucket.Properties.LifecycleConfiguration.Rules as Array<Record<string, unknown>>;
    expect(rules).toEqual(expect.arrayContaining([
      expect.objectContaining({ Id: 'expire-noncurrent-versions', NoncurrentVersionExpiration: { NoncurrentDays: NONCURRENT_VERSION_RETENTION_DAYS }, AbortIncompleteMultipartUpload: { DaysAfterInitiation: 7 } }),
      expect.objectContaining({ Id: 'remove-expired-delete-markers', ExpiredObjectDeleteMarker: true }),
      expect.objectContaining({ Id: 'expire-manifests', Prefix: 'manifests/', ExpirationInDays: 400 }),
    ]));
    expect(NONCURRENT_VERSION_RETENTION_DAYS).toBe(90);
    for (const rule of rules) {
      if (rule.ExpirationInDays !== undefined) {
        expect(rule.Prefix).toBe('manifests/');
      }
    }
  });

  test('requires TLS 1.2 and denies bucket deletion and destructive actions by backup users', () => {
    const policy = Object.values(template.findResources('AWS::S3::BucketPolicy'))[0];
    const statements = statementsOf(policy);
    const denies = statements.filter((s) => s.Effect === 'Deny');
    expect(denies).toEqual(expect.arrayContaining([
      expect.objectContaining({ Action: 's3:*', Condition: { Bool: { 'aws:SecureTransport': 'false' } } }),
      expect.objectContaining({ Action: 's3:*', Condition: { NumericLessThan: { 's3:TlsVersion': 1.2 } } }),
      expect.objectContaining({ Sid: 'DenyBucketDeletion', Action: 's3:DeleteBucket', Principal: { AWS: '*' } }),
    ]));
    const destructive = denies.find((s) => s.Sid === 'DenyDestructiveActionsByBackupUsers');
    expect(destructive).toBeDefined();
    expect(actionsOf(destructive!)).toEqual(expect.arrayContaining(['s3:DeleteObject', 's3:DeleteObjectVersion', 's3:PutBucket*', 's3:PutLifecycleConfiguration']));
    expect(statements.filter((s) => s.Effect === 'Allow')).toHaveLength(0);
  });
});

describe('IAM users', () => {
  const { template } = synth();

  test('backup writer can only list, read and write backup prefixes', () => {
    const actions = userPolicyActions(template, 'WriterUser');
    expect(actions.sort()).toEqual([
      's3:AbortMultipartUpload',
      's3:GetObject',
      's3:ListBucket',
      's3:ListBucketMultipartUploads',
      's3:ListMultipartUploadParts',
      's3:PutObject',
    ]);
    const policy = Object.values(template.findResources('AWS::IAM::Policy'))
      .find((p) => JSON.stringify(p.Properties.Users).includes('WriterUser'))!;
    const objectResources = JSON.stringify(statementsOf(policy).find((s) => s.Sid === 'WriteBackupObjects')!.Resource);
    for (const prefix of ['seaweedfs/*', 'manifests/*', 'status/*']) {
      expect(objectResources).toContain(prefix);
    }
    expect(objectResources).not.toMatch(/"\/\*"/);
  });

  test('backup reader is read-only', () => {
    const actions = userPolicyActions(template, 'ReaderUser');
    expect(actions.sort()).toEqual(['s3:GetObject', 's3:GetObjectVersion', 's3:ListBucket', 's3:ListBucketVersions']);
  });

  test('no backup user can delete, change bucket settings or use wildcards', () => {
    for (const user of ['WriterUser', 'ReaderUser']) {
      for (const action of userPolicyActions(template, user)) {
        expect(action).not.toMatch(/Delete|PutBucket|PutLifecycle|Bypass|\*/);
      }
    }
  });
});

describe('credentials', () => {
  const { template } = synth();

  test('secrets are retained and only reference the access key secret via GetAtt', () => {
    const secrets = template.findResources('AWS::SecretsManager::Secret');
    expect(Object.keys(secrets)).toHaveLength(2);
    for (const secret of Object.values(secrets)) {
      expect(secret.DeletionPolicy).toBe('Retain');
      expect(secret.UpdateReplacePolicy).toBe('Retain');
      const value = JSON.stringify(secret.Properties.SecretString);
      expect(value).toContain('"Fn::GetAtt"');
      expect(value).toContain('SecretAccessKey');
    }
    template.resourceCountIs('AWS::IAM::AccessKey', 2);
  });

  test('outputs never expose access keys', () => {
    const outputs = JSON.stringify(template.findOutputs('*'));
    expect(outputs).not.toMatch(/SecretAccessKey|AccessKey/);
    expect(outputs).not.toContain(EMAIL);
  });
});

describe('budget', () => {
  test('notifies the configured email when actual monthly cost exceeds the limit', () => {
    const { template } = synth(13);
    template.hasResourceProperties('AWS::Budgets::Budget', {
      Budget: Match.objectLike({
        BudgetType: 'COST',
        TimeUnit: 'MONTHLY',
        BudgetLimit: { Amount: 13, Unit: 'USD' },
      }),
      NotificationsWithSubscribers: [{
        Notification: { NotificationType: 'ACTUAL', ComparisonOperator: 'GREATER_THAN', Threshold: 100, ThresholdType: 'PERCENTAGE' },
        Subscribers: [{ SubscriptionType: 'EMAIL', Address: EMAIL }],
      }],
    });
  });

  test('rejects invalid parameters', () => {
    const app = new App();
    expect(() => new BackupStack(app, 'BadEmail', { budgetEmail: 'not-an-email', monthlyBudgetUsd: 13 })).toThrow(/budgetEmail/);
    expect(() => new BackupStack(app, 'BadBudget', { budgetEmail: EMAIL, monthlyBudgetUsd: 0 })).toThrow(/monthlyBudgetUsd/);
  });
});

describe('cdk-nag AwsSolutions', () => {
  test('synthesizes without unacknowledged findings', () => {
    const app = new App();
    new BackupStack(app, 'NagBackupStack', {
      env: { account: '123456789012', region: 'ap-northeast-1' },
      budgetEmail: EMAIL,
      monthlyBudgetUsd: 13,
    });
    Validations.of(app).addPlugins(new AwsSolutionsChecks(app));
    expect(() => app.synth()).not.toThrow();
  });
});
