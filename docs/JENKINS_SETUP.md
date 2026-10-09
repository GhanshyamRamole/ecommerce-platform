# Jenkins CI/CD Setup Guide

## Overview
This document describes the required Jenkins configuration for the AI E-Commerce platform CI/CD pipelines.

---

## 1. Required Jenkins Plugins

Install the following plugins via **Manage Jenkins → Plugins → Available Plugins**:

| Plugin | Purpose |
|--------|---------|
| Pipeline | Core pipeline support |
| Pipeline: Stage View | Visual pipeline stages |
| Pipeline: Declarative | Declarative pipeline syntax |
| Pipeline: GitHub | GitHub integration |
| Git | Git SCM support |
| Credentials Binding | Credential injection in pipelines |
| Docker Pipeline | Docker agent support (legacy - now using docker run) |
| Docker Commons | Docker utilities |
| Kubernetes | Kubernetes agent support (future) |
| Email Extension | Rich email notifications |
| HTML Publisher | Publish HTML reports (Trivy, SonarQube, etc.) |
| JUnit | Test result publishing |
| Cobertura | Coverage reporting |
| OWASP Dependency-Check | SCA reporting |
| SonarQube Scanner | SAST integration |
| Timestamper | Build timestamps |

---

## 2. Jenkins Credentials Configuration

Go to **Jenkins → Credentials → System → Global credentials (unrestricted) → Add Credentials**

### 2.1 GitHub HTTPS Token
| Field | Value |
|-------|-------|
| Kind | Username with password |
| Scope | Global |
| Username | `GhanshyamRamole` (your GitHub username) |
| Password | **GitHub Personal Access Token** (classic, `repo` scope) |
| ID | `github-https-token` |
| Description | `GitHub HTTPS Token for pipeline checkout` |

**To create PAT**: GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token → Select `repo` scope

### 2.2 AWS Credentials
| Credential ID | Kind | Description |
|---------------|------|-------------|
| `aws-account-id` | Secret text | 12-digit AWS Account ID |
| `aws-access-key-id` | Secret text | IAM Access Key with ECR/EKS permissions |
| `aws-secret-access-key` | Secret text | IAM Secret Access Key |

### 2.3 ECR Credentials (NO LONGER USED)
> The pipelines now run `aws ecr get-login-password` on every build, because a stored ECR token expires after 12 hours. Delete `ecr-credentials` if it exists. See `Jenkins/README.md` for the current setup.

| Credential ID | Kind | Description |
|---------------|------|-------------|
| `ecr-credentials` | Username with password | Username: `AWS`, Password: `aws ecr get-login-password --region ap-south-1` |

### 2.4 SonarQube Token
| Credential ID | Kind | Description |
|---------------|------|-------------|
| `sonarqube-token` | Secret text | SonarQube authentication token for SAST analysis |
| `sonarqube-host-url` | Secret text | SonarQube server URL (e.g., `http://<ec2-ip>:9000` or `https://sonar.yourdomain.com`) |

### 2.5 Email Recipients (Optional)
| Credential ID | Kind | Description |
|---------------|------|-------------|
| `default-recipients` | Secret text | Comma-separated email list (e.g., `dev@company.com,ops@company.com`) |

---

## 3. Multibranch Pipeline Jobs

Create **4 Multibranch Pipeline jobs** with these exact names:

| Job Name | Repository | Jenkinsfile Path | Branches |
|----------|------------|------------------|----------|
| `nexvion-orchestrator` | `https://github.com/GhanshyamRamole/ecommerce-platform` | `Jenkins/orchestrator/Jenkinsfile` | `main`, `develop` |
| `nexvion-backend` | `https://github.com/GhanshyamRamole/ecommerce-platform` | `Jenkins/backend/Jenkinsfile` | `main`, `develop`, `release/*` |
| `nexvion-frontend` | `https://github.com/GhanshyamRamole/ecommerce-platform` | `Jenkins/frontend/Jenkinsfile` | `main`, `develop`, `release/*` |
| `nexvion-ai-analyzer` | `https://github.com/GhanshyamRamole/ecommerce-platform` | `Jenkins/ai-analyzer/Jenkinsfile` | `main`, `develop`, `release/*` |

### Job Configuration:
1. **Branch Sources**: GitHub → Owner: `GhanshyamRamole` → Repository: `ecommerce-platform`
2. **Credentials**: Select `github-https-token`
3. **Behaviors**:
   - Discover branches: All branches
   - Discover pull requests: All PRs (optional)
   - Filter by name: `main`, `develop`, `release/*` (for service jobs)
4. **Build Configuration**: Script Path → as per table above
5. **Scan Repository Triggers**: Periodically if not otherwise run → 5 minutes

---

## 4. Email/SMTP Configuration

Go to **Manage Jenkins → Configure System → Extended E-mail Notification**

| Setting | Value |
|---------|-------|
| SMTP Server | `smtp.gmail.com` (or your SMTP server) |
| SMTP Port | `587` (TLS) or `465` (SSL) |
| Credentials | Add `smtp-credentials` (Username/Password) in Jenkins credentials |
| Default Recipients | `${DEFAULT_RECIPIENTS}` (uses credential or defaults to `devops@company.com`) |
| Default Subject | `Jenkins Build ${BUILD_STATUS}: ${PROJECT_NAME} #${BUILD_NUMBER}` |
| Default Content Type | `text/plain` |

**Test**: Use "Test configuration by sending test e-mail" button.

---

## 5. Docker Host Requirements

Since Jenkins runs in a container, the pipelines use `docker run` directly on the host. Ensure:

1. **Docker daemon** is accessible on the Jenkins host
2. **Jenkins user** is in `docker` group:
   ```bash
   sudo usermod -aG docker jenkins
   sudo systemctl restart jenkins
   ```
3. **Required images** will be pulled automatically:
   - `python:3.11-slim`
   - `node:20-alpine`
   - `sonarsource/sonar-scanner-cli:latest`
   - `owasp/dependency-check:latest`
   - `aquasec/trivy:latest`
   - `zricethezav/gitleaks:latest`
   - `docker:26-dind` (for build stages)

---

## 6. Kubernetes Cluster Access

For deployment stages, ensure the Jenkins host has:

1. **AWS CLI** configured with EKS permissions
2. **kubectl** installed and configured
3. **helm** installed
4. **EKS cluster access**:
   ```bash
   aws eks update-kubeconfig --name nexvion-cluster --region ap-south-1
   ```

The pipelines use IAM roles or AWS credentials for EKS authentication.

---

## 7. ECR Repository Setup

Create these repositories in AWS ECR (region: `ap-south-1`):

| Repository Name | Purpose |
|-----------------|---------|
| `nexvion` | Shared prefix (used as `${ECR_REPOSITORY}`) |
| `nexvion-frontend` | Frontend images |
| `nexvion-backend` | Backend images |
| `nexvion-ai-analyzer` | AI Analyzer images |

Or use a single repo `nexvion` with image tags like `nexvion-frontend:tag`.

---

## 8. Helm Chart Values Files

Ensure these files exist in `helm/ecommerce/`:
- `values-staging.yaml` - Staging environment config
- `values-prod.yaml` - Production environment config

The pipelines reference these for deployments.

---

## 9. SonarCloud Projects

Create projects in SonarCloud:
- `nexvion-backend`
- `nexvion-frontend` (if needed)
- `nexvion-ai-analyzer`

Generate tokens and add as `sonarqube-token` credential.

---

## 10. Pipeline Execution Flow

```
┌─────────────────────────────────────┐
│     nexvion-orchestrator            │  (Polls GitHub every 5 min)
│  1. Checkout                        │
│  2. Detect Changes                  │
│  3. Trigger Pipelines (parallel)    │
└──────────────┬──────────────────────┘
               │
    ┌──────────┼──────────┬──────────────┐
    ▼          ▼          ▼              ▼
┌────────┐ ┌─────────┐ ┌────────────┐  (Only triggered if changes detected)
│Backend │ │Frontend │ │ AI Analyzer│
└────────┘ └─────────┘ └────────────┘
    │          │          │
    ▼          ▼          ▼
┌─────────────────────────────────────┐
│  Stages (per service):              │
│  • Lint & Test                      │
│  • SAST (SonarQube)                 │
│  • SCA (Dependency Check)           │
│  • Security Scans (Trivy, Gitleaks) │
│  • Build & Push Docker Image        │
│  • Docker Image Scan (Trivy)        │
│  • Deploy Staging (develop branch)  │
│  • Deploy Production (main branch)  │
│  • Post-Deploy Verification         │
└─────────────────────────────────────┘
```

---

## 11. First Build Behavior

On first build (no previous commit):
- All change detection returns `"first-build"`
- All stages execute (not skipped)
- Subsequent builds use incremental detection

---

## 12. Troubleshooting

### "No item named nexvion-backend found"
- Create the multibranch job with exact name `nexvion-backend`
- Ensure job name matches `build job: 'nexvion-backend'` in orchestrator

### "No credentials specified" during checkout
- Add `github-https-token` credential
- Configure in Multibranch job → Branch Sources → Credentials

### Docker workspace mounting errors
- Pipelines now use `docker run -v "$(pwd)":/workspace` instead of Docker agent
- Ensure Jenkins user in `docker` group

### SMTP connection failed
- Configure Extended E-mail Notification in Jenkins
- Check firewall/network allows SMTP port

### SonarQube analysis fails
- Verify `sonarqube-token` credential exists
- Check SonarCloud project keys match (`nexvion-backend`, `nexvion-ai-analyzer`)

---

## 13. Security Notes

- All credentials stored in Jenkins Credentials Store (encrypted)
- Never hardcode secrets in Jenkinsfiles
- Use `credentials()` binding for runtime injection
- Rotate GitHub PAT and AWS keys periodically
- Use IAM roles for EKS access where possible

---

## 14. Monitoring & Maintenance

| Task | Frequency |
|------|-----------|
| Check pipeline health | Daily |
| Rotate credentials | Quarterly |
| Update Docker base images | Monthly |
| Review security scan results | Per build |
| Clean old builds | Weekly (handled by `buildDiscarder`) |
| Update plugins | Monthly |

---

## 15. Support Contacts

- **DevOps Team**: devops@company.com
- **Jenkins Admin**: jenkins-admin@company.com
- **AWS Admin**: aws-admin@company.com