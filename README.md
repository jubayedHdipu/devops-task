# End-to-End DevOps Assessment (`devops-task`)

A production-ready, observable, and securely deployed Go web service (`app/`) featuring a multi-stage hardened container, automated DevSecOps CI/CD pipelines (GitHub Actions), modular AWS Infrastructure as Code (Terraform), Kubernetes manifests + multi-environment Helm chart, a 6-component observability stack (Prometheus, Grafana, Loki, Grafana Alloy, Node Exporter, cAdvisor + Alertmanager), Ansible server hardening, and automated Linux health monitoring.

---

## Table of Contents

1. [Architecture Diagrams](#1-architecture-diagrams)
2. [Local Setup & Verification Commands](#2-local-setup--verification-commands)
3. [Design Decisions](#3-design-decisions)
4. [Deployment & Rollback Strategy](#4-deployment--rollback-strategy)
5. [Security Considerations](#5-security-considerations)
6. [Monthly AWS Cost Estimate](#6-monthly-aws-cost-estimate)
7. [Dashboard Error-Spike Troubleshooting Walkthrough](#7-dashboard-error-spike-troubleshooting-walkthrough)
8. [Potential Improvements](#8-potential-improvements)
9. [AI Usage Disclosure & Completed Bonus Items](#9-ai-usage-disclosure--completed-bonus-items)

---

## 1. Architecture Diagrams

### CI/CD & AWS EC2 Deployment Flow

```text
+-------------------+      PR / Push       +---------------------------------------+
|  Developer / Git  | -------------------> |            GitHub Actions             |
| (feat/* -> main)  |                      | 1. golangci-lint v2.15 & Unit Tests   |
+-------------------+                      | 2. Hadolint & ShellCheck (0 warnings) |
                                           | 3. Trivy Scan (Fail on CRITICAL CVE)  |
                                           | 4. Multi-Arch Build -> GHCR / ECR     |
                                           +-------------------+-------------------+
                                                               |
                                                      AWS SSM RunCommand
                                                               |
                                                               v
+----------------------------------------------------------------------------------+
| AWS VPC (10.0.0.0/16 across 2 AZs)                                               |
|  +------------------------------------+   +------------------------------------+ |
|  | Public Subnets (10.0.1.0/24, .2.0) |   | Private Subnets (10.0.11.0/24,.12) | |
|  |  - Internet Gateway & NAT Gateway  |   |  - Isolated Backend / DB Ready     | |
|  |  - EC2 Host (t3.micro, Ubuntu 24)  |   +------------------------------------+ |
|  |    * IMDSv2 Enforced, gp3 Encrypted|                                          |
|  |    * IAM Role (SSM + ECR + CW Logs)|   +------------------------------------+ |
|  |    * scripts/deploy.sh (Canary)    |   | Amazon ECR & CloudWatch Logs (14d) | |
|  +------------------------------------+   +------------------------------------+ |
+----------------------------------------------------------------------------------+
```

### Observability & Telemetry Pipeline

```text
+-----------------------------------------------------------------------------------+
| Isolated Docker Bridge Network: devops-internal                                   |
|                                                                                   |
|  +-----------------+   /metrics (15s)   +--------------+   Alerts   +-----------+ |
|  |   app (:8080)   | <----------------- |  Prometheus  | ---------> |Alertmanager| |
|  | Go HTTP + slog  |                    |  (15d TSDB)  |            +-----------+ |
|  +--------+--------+                    +------+-------+                          |
|           | stdout JSON                        ^        +-----------------------+ |
|           v                                    |        | Grafana (:3000 Host)  | |
|  +-----------------+   Docker Sock      +------+-------+  - Application Metrics | |
|  |  Grafana Alloy  | -----------------> |     Loki     |  - Host Metrics        | |
|  |  (JSON labels)  |   HTTP Push        |  (168h/7d)   |  - Container Metrics   | |
|  +-----------------+                    +--------------+  - Correlated Logs     | |
|                                                         +-----------------------+ |
|  +-----------------+   /metrics         +--------------+                          |
|  |  Node Exporter  | <----------------- |   cAdvisor   | <---- Prometheus scrapes |
|  +-----------------+                    +--------------+                          |
+-----------------------------------------------------------------------------------+
```

### Kubernetes & Helm Deployment Topology

```text
Internet -> Ingress (nginx: devops-task.local) -> Service (ClusterIP :80 -> :8080)
                                                       |
                                                       v
                                          Deployment (2+ Replicas, RollingUpdate)
                                           - Non-root UID 10001, readOnlyRootFS
                                           - Liveness & Readiness (/health)
                                           - ConfigMap + Secret template + /tmp emptyDir
                                                       ^
                                                       |
                                          HPA (autoscaling/v2: CPU 70%, 2-5 pods)
```

---

## 2. Local Setup & Verification Commands

### Go Application & Unit Tests

```bash
cd app
go mod tidy
go vet ./...
go test -v -race -cover ./...
go run .
```

Verify endpoints once running on port `8080`:

```bash
curl -s http://127.0.0.1:8080/
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/metrics
```

Configuration environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PORT` | `8080` | HTTP server listen port |
| `LOG_LEVEL` | `info` | Structured JSON log threshold (`debug`, `info`, `warn`, `error`) |
| `APP_ENV` | `production` | Runtime environment label exposed in logs and `/health` |
| `APP_VERSION` | `1.0.0` | Application version injected at build or runtime |

### Container Build, Linting, & Local Compose Stack

```bash
# Lint Dockerfile
docker run --rm -i hadolint/hadolint hadolint - < Dockerfile

# Build multi-stage image (verified final size: 26.7 MB / 25.5 MiB)
docker build -t devops-task-app:local .
docker images devops-task-app:local

# Scan image for CRITICAL vulnerabilities
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:0.69.3 image --exit-code 1 --ignore-unfixed --pkg-types os,library --severity CRITICAL devops-task-app:local

# Validate & run app stack
docker compose config -q
docker compose up -d
```

### 6-Component Observability Stack

```bash
# Validate combined application + observability Compose configuration
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml config -q

# Start app + Prometheus, Grafana, Loki, Grafana Alloy, Node Exporter, cAdvisor, Alertmanager
GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD=ChangeMeStrong123! \
  docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d

# Access Grafana UI at http://127.0.0.1:3000 (all other monitoring services stay internal)
```

### Terraform Infrastructure (AWS)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -var="environment=staging" -var="enable_nat_gateway=false"
terraform plan -var="environment=prod"
```

### Kubernetes & Helm

```bash
# Schema-validate raw Kubernetes manifests
kubeconform -strict -summary k8s/

# Apply raw manifests
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

# Lint and render Helm chart across staging and production values
helm lint helm/devops-task -f helm/devops-task/values-staging.yaml
helm lint helm/devops-task -f helm/devops-task/values-prod.yaml
helm template devops-task helm/devops-task -f helm/devops-task/values-prod.yaml | kubeconform -strict -summary
```

### Linux Automation & Ansible Hardening

```bash
# Lint automation scripts (0 warnings)
shellcheck -x scripts/system_health.sh scripts/deploy.sh

# Run health check script
./scripts/system_health.sh --help
./scripts/system_health.sh --cpu 90 --mem 85 --disk 80 --json

# Zero-downtime canary local/host deployment
./scripts/deploy.sh ghcr.io/jubayedhdipu/devops-task-app:latest

# Server hardening via Ansible
ansible-playbook -i ansible/inventory.ini.example ansible/site.yml --syntax-check
```

---

## 3. Design Decisions

- **Go Standard Library + `slog` + Prometheus Client:** Keeps runtime memory tiny (~10 MB RSS), handles `SIGINT`/`SIGTERM` cleanly via `srv.Shutdown(ctx)` with a 15-second drain window, normalizes unknown paths to `/other` to avoid high-cardinality Prometheus label explosion, and outputs structured JSON logs natively parsed by Grafana Alloy.
- **Multi-Stage `golang:1.25.7-alpine3.23` -> `alpine:3.23.8`:** Compiles a static `CGO_ENABLED=0` stripped (`-ldflags="-s -w"`) binary and copies only `/out/server` onto `alpine:3.23.8` (`ca-certificates` + non-root UID `10001`), yielding a **26.7 MB (25.5 MiB)** image free of `CVE-2025-68121` and `CVE-2026-31789`. Alpine was chosen over `scratch` so `HEALTHCHECK` (`wget`) and container troubleshooting remain available while staying minimal.
- **Grafana Alloy over Promtail:** Promtail reached end-of-life/maintenance mode in favor of Grafana Alloy; Alloy (`grafana/alloy:v1.4.3`) provides native Docker discovery, structured JSON label extraction (`level`, `method`), and direct Loki HTTP ingestion.
- **Terraform Single-Host VPC Foundation with Private Subnets Ready:** Provisions a 2-AZ VPC (`10.0.0.0/16`) with public and private subnets, conditional NAT Gateway (`enable_nat_gateway`), IMDSv2 enforcement, encrypted `gp3` EBS, ECR with immutable tags + scan-on-push, and CloudWatch Log Group (14-day retention) so databases or EKS nodes can later be placed in private subnets without redesigning the network.
- **Keyless CI/CD & SSM Execution:** Uses GitHub Actions OIDC (`aws-actions/configure-aws-credentials@v4`) + AWS Systems Manager (`AWS-RunShellScript`) rather than static AWS keys or open SSH ports for deployments.

---

## 4. Deployment & Rollback Strategy

1. **Pull Request Validation ([`.github/workflows/pr-check.yml`](.github/workflows/pr-check.yml)):** Runs `golangci-lint` (`v2.15.0` on Go `1.25.7`), `go test -v -race -coverprofile=coverage.out ./...`, Hadolint (`hadolint-action@v3.1.0`), ShellCheck, and Trivy (`aquasec/trivy:0.69.3`) blocking any `CRITICAL` unfixed CVE.
2. **Continuous Delivery ([`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)):** On merge to `main`, builds multi-arch (`linux/amd64`, `linux/arm64`) images using Buildx + GHA layer cache, pushes immutable `sha-<7>` and SemVer (`1.0.<run_number>`) tags to GHCR (and Amazon ECR when `AWS_ROLE_ARN` is set), and deploys to EC2 via AWS SSM.
3. **Smoke Test & Automatic Rollback:**
   - **CI/SSM Deploy:** Captures the running container image (`PREV_IMAGE`), pulls and starts the new tag on port `8080`, and runs 6 health probes (`curl -sf http://127.0.0.1:8080/health`) spaced 5s apart. On failure, stops the broken container and restarts `PREV_IMAGE`.
   - **Host Canary Script (`scripts/deploy.sh`):** Starts a canary container on `127.0.0.1:8081`, verifies `/health` up to 15 retries before touching live port `8080`, renames the live container to `<name>-backup` during cutover, and restores `<name>-backup` immediately if cutover fails.
   - **Kubernetes (`k8s/deployment.yaml`):** Uses `RollingUpdate` (`maxSurge: 1`, `maxUnavailable: 0`) gated by `readinessProbe` on `/health`, ensuring zero dropped connections and instant `kubectl rollout undo deployment/devops-task-app` rollback.

---

## 5. Security Considerations

- **Least-Privilege Containers:** Non-root user `10001:10001`, `read_only: true` in Compose and `readOnlyRootFilesystem: true` + `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]` + `seccompProfile: RuntimeDefault` + `automountServiceAccountToken: false` in Kubernetes.
- **Supply Chain & Vulnerability Gating:** Pinned tool versions (`aquasec/trivy:0.69.3`, `golang:1.25.7-alpine3.23`, `alpine:3.23.8`), immutable ECR tags, ECR `scan_on_push = true`, and Trivy failing CI builds on any fixed `CRITICAL` OS or Go dependency vulnerability.
- **Zero Plaintext Secrets:** `k8s/secret.example.yaml` contains only a placeholder (`REPLACE_WITH_EXTERNAL_OR_SEALED_SECRET`); Grafana admin credentials use environment variable injection (`GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`); AWS CI authentication uses short-lived OIDC tokens; EC2 uses an IAM Instance Profile with least-privilege CloudWatch log stream permissions scoped to `/aws/ec2/<project>-<env>-app:*`.
- **Host & Network Hardening:** IMDSv2 enforced (`http_tokens = "required"`), encrypted EBS `gp3` root volume, SSH CIDR restricted (`var.ssh_allowed_cidr`), Ansible hardening (`PermitRootLogin no`, `PasswordAuthentication no`, UFW, `fail2ban`, `unattended-upgrades`), and monitoring services isolated on `devops-internal` with only Grafana (`:3000`) exposed on host.

---

## 6. Monthly AWS Cost Estimate

Estimated monthly cost for the Terraform production baseline in `ap-southeast-1` (Singapore), assuming 730 hours/month:

| AWS Resource | Specification / Usage | Estimated Monthly Cost (USD) |
| :--- | :--- | ---: |
| **EC2 Instance** | 1x `t3.micro` Linux On-Demand (~$0.0116/hr x 730 hrs) | $8.47 |
| **EBS Root Volume** | 20 GB `gp3` encrypted (~$0.096/GB-month in `ap-southeast-1`) | $1.92 |
| **NAT Gateway** | 1x NAT Gateway (~$0.059/hr x 730 hrs) + ~10 GB processed ($0.059/GB) | $43.66 |
| **Amazon ECR** | ~1 GB stored container images (15-image lifecycle cap, scan-on-push free) | $0.10 |
| **CloudWatch Logs** | ~2 GB/month ingestion ($0.70/GB) + 14-day storage | $1.45 |
| **S3 + DynamoDB (TF State)** | <100 MB encrypted state + on-demand lock reads/writes | $0.05 |
| **Data Transfer Out** | ~10 GB outbound internet traffic (first 100 GB/month free tier eligible) | $0.90 |
| **Total (Production Baseline)** | **With NAT Gateway enabled** | **~$56.55 / mo** |
| **Cost-Optimized / Staging** | **`enable_nat_gateway = false`** (saves $43.66/mo; Free Tier EC2 further lowers dev) | **~$12.89 / mo** |

---

## 7. Dashboard Error-Spike Troubleshooting Walkthrough

When `HighHttpErrorRate` fires in Prometheus/Alertmanager (or when investigating elevated 4xx/5xx responses in Grafana):

1. **Identify Scope in Grafana (`Application Metrics & Logs` dashboard):**
   - Inspect **HTTP Error Rate (5xx / 4xx)** (`sum(rate(http_requests_total{status=~"5.."}[1m]))`) alongside **HTTP Request Rate** to determine whether errors correlate with a traffic spike or deployment rollout.
   - Check **Request Latency (p50 / p95 / p99)** to spot upstream timeouts or resource saturation (`p99` spike).
2. **Correlate Live Logs in the Same Dashboard (Loki panel):**
   - Look directly at **Live Application Logs (Loki - Correlated View)** (`{service="app"}`) or drill down in Grafana Explore with `{service="app", level=~"WARN|ERROR"} | json | status >= 500` to retrieve exact request paths, durations (`duration_ms`), and error messages for the spike window.
3. **Check Container & Host Saturation:**
   - Switch to **Container Resource Metrics (cAdvisor)** to verify whether `devops-app` hit CPU throttling or approaches its `128M` memory limit (`ContainerMemoryNearLimit` alert).
   - Switch to **Host System Metrics (Node Exporter)** (`CPU Usage`, `Memory Usage`, `Disk Usage`) or inspect `/var/log/devops-task/health_log.txt` (generated every 5 minutes by `scripts/system_health.sh`) to rule out noisy-neighbor processes or disk exhaustion.
4. **Mitigate / Roll Back:**
   - If the spike started immediately after a deployment, execute `kubectl rollout undo deployment/devops-task-app` (Kubernetes) or re-run the previous `sha-<7>` image via `scripts/deploy.sh` / SSM rollback.

---

## 8. Potential Improvements

- **High Availability & Autoscaling on AWS:** Replace the single EC2 instance with an Application Load Balancer (TLS via ACM) fronting an Auto Scaling Group or Amazon EKS cluster in private subnets across both Availability Zones.
- **Automated Secrets Management:** Integrate AWS Secrets Manager + External Secrets Operator (Kubernetes) or AWS SSM Parameter Store (`SecureString`) so application secrets rotate automatically without manual `kubectl create secret` steps.
- **Alertmanager Notification Routing:** Configure Slack, PagerDuty, or Amazon SNS receivers in `monitoring/alertmanager.yml` with environment-specific severity routing and inhibition rules.
- **Multi-Stage Promotion & DAST/Load Testing:** Add automated `k6` load testing and staging soak validation in GitHub Actions between staging deployment and manual approval for production promotion.
- **Terraform State Bootstrap & Policy-as-Code:** Add a bootstrap script for the S3 state bucket + DynamoDB lock table and integrate `tfsec` / `checkov` into PR checks.

---

## 9. AI Usage Disclosure & Completed Bonus Items

### AI Usage Note

AI assistance was used to accelerate boilerplate generation (Go HTTP scaffolding, YAML/HCL templates, Grafana dashboard JSON, and documentation formatting), troubleshoot CI/tooling version incompatibilities (`golangci-lint` Go toolchain alignment and Alpine `CVE-2026-31789` patching), and automate repository-wide validation checks. All code, configurations, security controls, and tests were locally verified against live toolchains (`go test -race`, `docker build`, `trivy`, `hadolint`, `terraform validate`, `kubeconform`, `helm lint`, `shellcheck`, and live container checks).

### Completed Bonus Items

- **Multi-Environment Helm Chart (`helm/devops-task/`):** Packaged Kubernetes manifests with `values.yaml`, `values-staging.yaml`, and `values-prod.yaml`.
- **Zero-Downtime Canary Deployment Script (`scripts/deploy.sh`):** Pre-cutover canary verification on port `8081` with automatic container backup rollback.
- **Systemd Timer & Crontab Automation (`scripts/systemd/`):** Scheduled 5-minute health checks (`system-health.timer`, `system-health.service`, `crontab.example`) plus `--json` output, log rotation (`health_log.txt`), and Slack/Discord webhook alerting (`ALERT_WEBHOOK_URL`).
- **Alertmanager Integration (`monitoring/alertmanager.yml`):** Wired Prometheus alert rules to Alertmanager alongside the 6 mandatory observability services.
- **CloudWatch Container Log Shipping (`terraform/main.tf`):** Configured `awslogs` Docker driver and scoped IAM permissions to `/aws/ec2/<project>-<env>-app`.
- **Ansible Hardening Playbook (`ansible/site.yml`, `ansible/inventory.ini.example`):** Automates SSH hardening, UFW firewall rules, `fail2ban`, `unattended-upgrades`, non-root `deploy` user, and `system-health.timer` installation.
