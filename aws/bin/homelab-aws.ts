#!/usr/bin/env node
import { App, Tags, Validations } from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { BackupMonitorStack } from '../lib/backup-monitor-stack';
import { BackupStack } from '../lib/backup-stack';

const app = new App();

const budgetEmail = app.node.tryGetContext('budgetEmail') ?? process.env.HOMELAB_BUDGET_EMAIL;
if (!budgetEmail) {
  throw new Error('budgetEmail is required: pass "-c budgetEmail=<address>" or set HOMELAB_BUDGET_EMAIL');
}
const monthlyBudgetUsd = Number(app.node.tryGetContext('monthlyBudgetUsd') ?? process.env.HOMELAB_MONTHLY_BUDGET_USD ?? 13);

new BackupStack(app, 'HomelabBackupStack', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'ap-northeast-1' },
  terminationProtection: true,
  description: 'Off-site backup bucket and least-privilege IAM users for the K8s-home-lab SeaweedFS object storage',
  budgetEmail,
  monthlyBudgetUsd,
});

const alertEmail = app.node.tryGetContext('alertEmail') ?? process.env.HOMELAB_ALERT_EMAIL ?? budgetEmail;

new BackupMonitorStack(app, 'HomelabBackupMonitorStack', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'ap-northeast-1' },
  description: 'Hourly freshness checks and email alerts for the K8s-home-lab MySQL dump and AWS backup copy',
  alertEmail,
});

Tags.of(app).add('Project', 'k8s-home-lab');
Tags.of(app).add('ManagedBy', 'aws-cdk');
Validations.of(app).addPlugins(new AwsSolutionsChecks(app, { verbose: true }));
