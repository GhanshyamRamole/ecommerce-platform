# Jenkins Credentials Setup Guide

This document lists all the Jenkins credentials required for the CI/CD pipelines to function properly.

## Required Credentials

### 1. AWS Account ID
- **ID:** `aws-account-id`
- **Type:** Secret text
- **Description:** AWS Account ID (12-digit number) used to construct ECR registry URL
- **Example:** `123456789012`

### 2. SonarQube Token
- **ID:** `sonarqube-token`
- **Type:** Secret text
- **Description:** SonarQube authentication token for SAST analysis
- **Scope:** Both `nexvion-backend` and `nexvion-frontend` projects
- **Get from:** Your SonarQube → My Account → Security → Generate Token

### 2b. SonarQube Host URL
- **ID:** `sonarqube-host-url`
- **Type:** Secret text
- **Description:** SonarQube server URL (e.g., `http://<ec2-ip>:9000` or `https://sonar.yourdomain.com`)
- **Note:** Use this instead of hardcoding URL since EC2 IPs change
- **Update when:** EC2 instance is recreated or IP changes

### 3. AWS Access Credentials
- **ID:** `aws-access-key-id` / `aws-secret-access-key`
- **Type:** Two *Secret text* credentials: `aws-access-key-id` and `aws-secret-access-key` (this is what the pipelines read)
- **Permissions required:**
  - ECR: Full access (push/pull images)
  - EKS: Describe/Update clusters, manage kubectl config
  - IAM: Read access for roles/policies (if using IRSA)

### 4. ECR Registry Credentials (NO LONGER USED)
- **Note:** the pipelines log in to ECR with a fresh token on every run (stored tokens expire after 12h). Delete this credential.
- **ID:** `ecr-credentials`
- **Type:** Username with password
- **Username:** `AWS` (literal string)
- **Password:** Get from `aws ecr get-login-password --region ap-south-1`
- **Note:** This is used for `docker login` to ECR

### 5. Staging Database URL (NO LONGER USED)
- **Note:** migrations are now verified against a throw-away Postgres container in CI. Delete this credential.
- **ID:** `staging-database-url`
- **Type:** Secret text
- **Description:** PostgreSQL connection string for staging environment
- **Format:** `postgresql+asyncpg://user:password@host:5432/dbname`
- **Used in:** Database Migration Check stage
- **Note:** If not configured, the stage will fail gracefully

## Jenkins Credentials Configuration Steps

1. Go to **Jenkins → Credentials → System → Global credentials (unrestricted)**
2. Click **Add Credentials** for each credential above
3. Set the **ID** exactly as specified above (pipelines reference these IDs)
4. For AWS credentials, consider using the **AWS Credentials Plugin** for better integration

## Environment-Specific Overrides

### Production
- Certificate ARN: Set via `CERTIFICATE_ARN` environment variable or `--set global.certificateArn=arn:aws:acm:...`
- Database URL: Should be configured in AWS Secrets Manager and referenced via ExternalSecrets

### Staging
- Certificate ARN: Empty (uses default or self-signed)
- Database URL: Configured in `values-staging.yaml` or via Jenkins credential `staging-database-url`

### Development
- Certificate ARN: Empty
- Database URL: Local development database

## Pipeline-Specific Notes

### Backend Pipeline
- Uses: `aws-account-id`, `sonarqube-token`, `aws-access-key-id`, `aws-secret-access-key`, `ecr-credentials`, `staging-database-url`
- Requires: Python 3.11, PostgreSQL 16, Docker

### Frontend Pipeline
- Uses: `aws-account-id`, `sonarqube-token`, `aws-access-key-id`, `aws-secret-access-key`, `ecr-credentials`
- Requires: Node.js 20, nginx, Docker

## Troubleshooting

| Error | Solution |
|-------|----------|
| `ERROR: sonarqube-token` | Add `sonarqube-token` credential in Jenkins |
| `docker login failed` | Verify `ecr-credentials` and `aws-account-id` |
| `aws eks update-kubeconfig failed` | Check AWS credentials have EKS permissions |
| `helm upgrade failed` | Verify EKS cluster exists and kubectl context is correct |
| `Migration check failed` | Configure `staging-database-url` credential |

## Security Best Practices

1. **Rotate credentials regularly** - Especially AWS keys and SonarQube tokens
2. **Use least privilege** - Create IAM users/roles with minimal required permissions
3. **Audit credential usage** - Jenkins Credentials Binding plugin logs access
4. **Don't hardcode** - All sensitive values should come from Jenkins credentials
5. **Use folders** - Organize credentials in Jenkins folders for better management