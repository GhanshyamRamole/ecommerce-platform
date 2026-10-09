# Jenkins CI/CD

Four self-contained declarative pipelines. No shared library is required.

```
Jenkins/
├── orchestrator/Jenkinsfile   # detects changed services, triggers the service jobs (same branch)
├── backend/Jenkinsfile        # FastAPI backend
├── frontend/Jenkinsfile       # static frontend + nginx
└── ai-analyzer/Jenkinsfile    # ai/incident-analysis worker
```

## Jenkins jobs

Create four **Multibranch Pipeline** jobs as siblings in the same folder (names are fixed; the orchestrator
addresses them as `../<name>/<branch>`):

| Job | Script path |
|-----|-------------|
| `nexvion-orchestrator` | `Jenkins/orchestrator/Jenkinsfile` |
| `nexvion-backend` | `Jenkins/backend/Jenkinsfile` |
| `nexvion-frontend` | `Jenkins/frontend/Jenkinsfile` |
| `nexvion-ai-analyzer` | `Jenkins/ai-analyzer/Jenkinsfile` |

Branch source: this repo, credentials `github-https-token`. Discover `main`, `develop`, `release/*` (and PRs, on
**all four** jobs, if you want PR validation). Only the orchestrator needs the periodic scan / webhook; the service
Jenkinsfiles set `overrideIndexTriggers(false)` so a commit never builds twice.

## Pipeline flow (service jobs)

```
Checkout → Detect Changes → [ Lint & Test | Secrets Scan | Dependency Audit | Filesystem Scan ] (parallel)
         → SonarQube (quality gate) → Build image → Scan image → Push to ECR
         → Deploy staging (develop, automatic) | Approve → Deploy production (main)
```

| Branch | CI checks | Image pushed | Deploy |
|--------|-----------|--------------|--------|
| `develop` | yes | yes | staging, automatic |
| `main` | yes | yes (+ `latest`) | production, after manual approval |
| `release/*` | yes | yes | none |
| PR / other | yes | no | none |

* **Change detection** compares with the last *successful* build of the job (`GIT_PREVIOUS_SUCCESSFUL_COMMIT`), so
  a failed build is retried automatically. A service runs when `<service dir>/` or `helm/` changed, when
  started manually, or with `FORCE_RUN`. `FORCE_RUN` never overrides the branch rules for deploys.
* **Images** are tagged `<8-char-sha>-<build number>` and scanned *before* the push. Trivy fails the build on
  `CRITICAL` fixed vulnerabilities (`TRIVY_FAIL_SEVERITY`); `HIGH` is reported only.
* **Blocking checks:** lint, type check, tests, migrations apply to a fresh DB, secrets scan (gitleaks), Trivy
  filesystem + image (`CRITICAL`), SonarQube quality gate (disable per run with `RUN_SONAR=false`).
* **UNSTABLE (non-blocking) checks:** `pip-audit` findings, Alembic model/migration drift, and ruff/mypy findings
  in the AI analyzer. Reports are archived under `reports/`.
* **Deploys** use one Helm release per environment (`nexvion-staging` / `nexvion`), update only this service's image
  tag (`--reuse-values`), wait for this service's rollout, run a smoke test and **`helm rollback` on failure**.
  Services therefore deploy independently, and concurrent deploys on the same release retry automatically.
* The production approval stage holds no executor and times out after 2 hours. Restrict who can approve with
  `PROD_APPROVERS` in the Jenkinsfile.

## Jenkins requirements

**Credentials** (global): `github-https-token` (user/password), `aws-account-id`, `aws-access-key-id`,
`aws-secret-access-key`, `sonarqube-token`, `sonarqube-host-url` (all *Secret text*), and optionally
`default-recipients` (Secret text, comma-separated emails). `ecr-credentials` and `staging-database-url` are
**no longer used**: the ECR login token is created on every run, and migrations are checked on a throw-away DB.

**Plugins:** Pipeline (declarative + multibranch), Git, GitHub Branch Source, Credentials Binding, Timestamper,
JUnit, Coverage, Email Extension, Workspace Cleanup. (Docker Pipeline and HTML Publisher are no longer needed.)

**Agent** (`agent any`; add a label in the Jenkinsfile if you have dedicated agents): `docker` (the Jenkins user
must be able to use it), `aws` CLI v2, `helm` 3, `kubectl`, `git`, `curl`, `bash`, `awk`. The workspace must be
bind-mountable into containers at the same path (true for Jenkins on a host/VM; for Jenkins-in-Docker the
workspace volume must be mounted at an identical host path). Build containers run as the Jenkins user, so
workspaces stay deletable. Caches live in `~/.cache/nexvion-ci`.

**Kubernetes:** the IAM user behind the AWS keys needs ECR push and access to the `nexvion-cluster` EKS cluster
(EKS access entry / `aws-auth`). The chart's `ingress-nginx` dependency is fetched with `helm dependency build`
on every deploy, so the agent needs internet access to `kubernetes.github.io`.

**First deployment of an environment:** the chart creates postgres, ingress and all three apps. Until a service
pipeline has pushed its image, that component runs the chart default (`latest`) from ECR and may sit in
`ImagePullBackOff`; this does not block other services. Run all three pipelines once (orchestrator with
`FORCE_ALL`) to bootstrap.

## Tool image versions

Pinned in each Jenkinsfile's `environment` block (`PYTHON_IMAGE`, `SONAR_IMAGE`, `TRIVY_IMAGE`, ...). Bump them
deliberately; if a pinned tag does not exist on your registry mirror, change that one line.
