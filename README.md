# devops-task

End-to-end Go web service (`app/`) containerized with Docker, validated and deployed through GitHub Actions, provisioned on AWS with Terraform, packaged for Kubernetes + Helm, monitored with Prometheus/Grafana/Loki/Alloy/Node Exporter/cAdvisor, and paired with host hardening and health-check automation.

Final container image size: **26.7 MB (25.5 MiB)** (`golang:1.25.7-alpine3.23` builder -> `alpine:3.23.8` runtime).

---

## Architecture

### CI/CD & AWS EC2 Flow

```text
+-------------------+      PR / Push       +---------------------------------------+
|  Developer / Git  | -------------------> |            GitHub Actions             |
| (feat/* -> main)  |                      | 1. golangci-lint v2.15 & Go tests     |
+-------------------+                      | 2. Hadolint & ShellCheck (0 warnings) |
                                           | 3. Trivy scan (fail on CRITICAL)      |
                                           | 4. Multi-arch build -> GHCR / ECR     |
                                           +-------------------+-------------------+
                                                               |
                                                      AWS SSM RunCommand
                                                               |
                                                               v
+----------------------------------------------------------------------------------+
| AWS VPC (10.0.0.0/16 across 2 AZs)                                               |
|  +------------------------------------+   +------------------------------------+ |
|  | Public Subnets (10.0.1.0/24, .2.0) |   | Private Subnets (10.0.11.0/24,.12) | |
|  |  - Internet Gateway & NAT Gateway  |   |  - Ready for private workloads/DB  | |
|  |  - EC2 Host (t3.micro, Ubuntu 24)  |   +------------------------------------+ |
|  |    * IMDSv2 required, encrypted gp3|                                          |
|  |    * IAM Role (SSM + ECR + CW Logs)|   +------------------------------------+ |
|  |    * Docker + awslogs driver       |   | Amazon ECR & CloudWatch Logs (14d) | |
|  +------------------------------------+   +------------------------------------+ |
+----------------------------------------------------------------------------------+
```

### Kubernetes Flow

```text
Client -> Ingress (nginx: devops-task.local) -> Service (ClusterIP :80 -> :8080)
                                                   |
                                                   v
                                      Deployment (2+ pods, RollingUpdate)
                                       - UID 10001, readOnlyRootFilesystem
                                       - /health liveness & readiness probes
                                       - ConfigMap + Secret + /tmp emptyDir
                                                   ^
                                                   |
                                      HPA (autoscaling/v2: CPU 70%, 2-5 pods)
```

### Observability Stack Flow

```text
+-----------------------------------------------------------------------------------+
| Internal Bridge Network: devops-internal (only Grafana :3000 exposed on host)     |
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
|  |  Node Exporter  | <----------------- |   cAdvisor   | <---- scraped by Prom    |
|  +-----------------+                    +--------------+                          |
+-----------------------------------------------------------------------------------+
```

---

## Prerequisites & Local Setup

You will need **Docker** (with Compose v2) to run everything cleanly, plus **Go 1.25+**, **Terraform >= 1.6**, **kubectl**, **Helm v3**, **kubeconform**, and **ShellCheck** if running those tools directly outside containers.

### 1. Run the App & Observability Stack Locally

Start just the application on port `8080`:

```bash
docker compose config -q
docker compose up -d --build
```

Verify the endpoints:

```bash
curl -s http://localhost:8080/
# {"message":"Hello from DevOps Task!","status":"running","version":"1.0.0"}

curl -s http://localhost:8080/health
# {"environment":"local","status":"healthy","version":"1.0.0"}

curl -s http://localhost:8080/metrics | head -n 20
```

Start the full 6-component observability stack alongside the app (Prometheus, Grafana, Loki, Grafana Alloy, Node Exporter, cAdvisor, plus Alertmanager):

```bash
export GRAFANA_ADMIN_USER=admin
export GRAFANA_ADMIN_PASSWORD=ChangeMeStrong123!

docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

Open Grafana at `http://localhost:3000` and log in with the credentials you exported above. Both datasources (`Prometheus`, `Loki`) and all three dashboards under **Dashboards -> DevOps Assessment** are provisioned automatically from `monitoring/grafana/provisioning/`:

- **Application Metrics & Logs** (`application-dashboard.json`)
- **Host System Metrics (Node Exporter)** (`host-dashboard.json`)
- **Container Resource Metrics (cAdvisor)** (`containers-dashboard.json`)

To tear everything down including volumes:

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down -v
```

### 2. App Configuration & Unit Tests

All runtime configuration comes from environment variables:

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `PORT` | `8080` | HTTP listen port |
| `LOG_LEVEL` | `info` | JSON log level (`debug`, `info`, `warn`, `error`) |
| `APP_ENV` | `production` | Environment name reported in logs and `/health` |
| `APP_VERSION` | `1.0.0` | Version string returned by `/` and `/health` |

Run Go checks locally:

```bash
cd app
go mod tidy
go vet ./...
go test -v -race -cover ./...
```

Build and verify the container image locally:

```bash
docker build -t devops-task-app:local .
docker images devops-task-app:local
docker run --rm -i hadolint/hadolint hadolint - < Dockerfile
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:0.69.3 image --exit-code 1 --ignore-unfixed --pkg-types os,library --severity CRITICAL devops-task-app:local
```

---

## CI/CD Workflows & Required Secrets

Two workflows live under `.github/workflows/`:

- `pr-check.yml`: Runs `golangci-lint` (`v2.15.0` with Go `1.25.7`), `go test -v -race -coverprofile=coverage.out ./...`, Hadolint, ShellCheck, and Trivy (`aquasec/trivy:0.69.3`), failing if any fixed `CRITICAL` OS or Go vulnerability is present.
- `deploy.yml`: On pushes to `main` (ignoring `*.md`), builds multi-arch images (`linux/amd64`, `linux/arm64`) with GitHub Actions layer cache (`type=gha`), tags them with both `sha-<short_sha>` and semantic version `1.0.<run_number>`, pushes to GHCR (and ECR when AWS OIDC is configured), and triggers an SSM deployment with a 30-second `/health` smoke test and automatic rollback to `PREV_IMAGE` on failure.

### Required Repository Variables & Secrets

No static AWS access keys are used anywhere. Configure the following under **GitHub Repository Settings -> Secrets and variables -> Actions**:

| Name | Type | Required | How it is configured |
| :--- | :--- | :--- | :--- |
| `GITHUB_TOKEN` | Built-in Secret | Automatic | Uses `packages: write` and `id-token: write` workflow permissions for GHCR push and OIDC JWT issuance. |
| `AWS_ROLE_ARN` | Repository Variable | For AWS deploy | ARN of an IAM role trusting `token.actions.githubusercontent.com` (`sub: repo:jubayedHdipu/devops-task:ref:refs/heads/main`), granting ECR push and `ssm:SendCommand` / `ssm:GetCommandInvocation`. |
| `AWS_REGION` | Repository Variable | Optional | AWS region (defaults to `ap-southeast-1` when unset). |
| `EC2_INSTANCE_ID` | Repository Variable | For EC2 deploy | Output `ec2_instance_id` from `terraform output` so SSM targets the instance. |

---

## Terraform Infrastructure (`terraform/`)

The Terraform configuration provisions a 2-AZ VPC (`10.0.0.0/16`) with public and private subnets, an EC2 Ubuntu 24.04 host (`t3.micro`, IMDSv2 enforced, encrypted `gp3` volume), a least-privilege security group (`80`, `443`, `8080`, and restricted SSH CIDR), an IAM instance profile (`AmazonSSMManagedInstanceCore`, `AmazonEC2ContainerRegistryReadOnly`, and CloudWatch Logs scoped to `/aws/ec2/<project>-<env>-app:*`), an immutable ECR repository (`scan_on_push = true`), and a 14-day CloudWatch Log Group.

### Remote State Bootstrap

The S3 + DynamoDB backend block is commented out in `terraform/versions.tf` so `terraform validate` and local reviews work without pre-existing AWS state infrastructure. Before running in a shared environment, create the bucket and lock table once, uncomment the `backend "s3"` block in `terraform/versions.tf`, and re-run `terraform init -migrate-state`:

```bash
aws s3api create-bucket --bucket jubayedhdipu-devops-task-tfstate --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1
aws s3api put-bucket-versioning --bucket jubayedhdipu-devops-task-tfstate --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name devops-task-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region ap-southeast-1
```

### Running Terraform (Staging & Production)

```bash
cd terraform
terraform init
terraform fmt -check -recursive
terraform validate

# Staging plan (single public tier, NAT Gateway disabled to save cost)
cp staging.tfvars.example staging.tfvars
terraform plan -var-file=staging.tfvars

# Production plan (full NAT Gateway enabled for private subnets)
cp prod.tfvars.example prod.tfvars
terraform plan -var-file=prod.tfvars

# Apply and clean up after verification
terraform apply -var-file=staging.tfvars
terraform destroy -var-file=staging.tfvars
```

---

## Kubernetes & Helm Deployment (`k8s/`, `helm/`)

### Raw Manifests

Validate and apply the manifests on a local cluster (`kind`, `minikube`, `k3d`, or Docker Desktop):

```bash
kubeconform -strict -summary k8s/

kubectl apply -f k8s/namespace.yaml
kubectl create secret generic devops-task-secret -n devops-task \
  --from-literal=API_AUTH_TOKEN='replace-with-random-token' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/
```

`k8s/secret.example.yaml` is only a template with a placeholder string (`REPLACE_WITH_EXTERNAL_OR_SEALED_SECRET`)—never commit real base64 secrets to Git. If you do not have an Ingress controller installed locally, reach the service directly via port-forward:

```bash
kubectl -n devops-task port-forward svc/devops-task-service 8080:80
curl -s http://localhost:8080/health
```

### Zero-Downtime Rolling Update & Rollback Demo

Because `RollingUpdate` is configured with `maxSurge: 1` and `maxUnavailable: 0` alongside `/health` readiness probes, Kubernetes waits until each new pod passes readiness before terminating an old pod:

```bash
# Trigger a rolling update to a new tag
kubectl -n devops-task set image deployment/devops-task-app app=ghcr.io/jubayedhdipu/devops-task-app:1.0.1
kubectl -n devops-task rollout status deployment/devops-task-app

# Verify rollout history and roll back to the previous revision
kubectl -n devops-task rollout history deployment/devops-task-app
kubectl -n devops-task rollout undo deployment/devops-task-app
kubectl -n devops-task rollout status deployment/devops-task-app
```

### Helm Chart (Staging & Production)

```bash
helm lint helm/devops-task -f helm/devops-task/values-staging.yaml
helm lint helm/devops-task -f helm/devops-task/values-prod.yaml

helm upgrade --install devops-task-staging helm/devops-task -n devops-staging --create-namespace \
  -f helm/devops-task/values-staging.yaml

helm upgrade --install devops-task-prod helm/devops-task -n devops-prod --create-namespace \
  -f helm/devops-task/values-prod.yaml
```

### Adapting This Setup for Production EKS

Moving from a local single-node cluster to Amazon EKS changes four main pieces:

- **Ingress Controller:** Replace `nginx` Ingress annotations with the **AWS Load Balancer Controller**, provisioning an Internet-facing ALB with an ACM TLS certificate (`alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'`) and ExternalDNS for Route 53 records.
- **Secrets Management:** Replace imperative `kubectl create secret` commands with **AWS Secrets Manager** synced into the cluster via **External Secrets Operator** or the Secrets Store CSI Driver.
- **Node Autoscaling:** Pair the pod-level HPA with **Karpenter** (or Cluster Autoscaler) on private subnet node groups so pods hitting node capacity trigger new EC2 instances automatically.
- **Pod IAM Permissions:** Use **IRSA (IAM Roles for Service Accounts)** or **EKS Pod Identity** with a dedicated ServiceAccount whenever the app needs AWS API access, rather than relying on node-level instance profile permissions.

---

## Observability Details

### Log Parsing & Cardinality Choices

`app/main.go` emits JSON logs using `log/slog` and collapses unrecognized routes via `normalizePath()` into `/other` (`/` , `/health`, `/metrics`, `/other`). In `monitoring/alloy/config.alloy`, Alloy extracts `level`, `method`, `path`, and `status` using `stage.json`, but only promotes `level` and `method` (alongside `service` and `container`) to Loki stream labels.

Keeping `path` and `status` out of indexed stream labels prevents index bloat if high-cardinality fields are ever added later, while still letting you filter precisely in Grafana Explore or dashboard queries using `| json | path="/..." | status >= 500`. Retention is explicitly bounded to `15d` in Prometheus (`--storage.tsdb.retention.time=15d`) and `168h` (7 days) in Loki (`compactor.retention_enabled: true`).

### Alerting Rules & Threshold Rationale

Defined in `monitoring/prometheus/alerts.yml` and routed to `monitoring/alertmanager.yml`:

| Alert | Expression / Threshold | `for` Duration | Why this threshold & duration |
| :--- | :--- | :--- | :--- |
| `AppInstanceDown` | `up{job="devops-task-app"} == 0` | `1m` | Scrapes happen every `15s`, so `1m` covers 4 consecutive missed scrapes—long enough to ignore a brief container restart during deploy without hiding an outage. |
| `HighHttpErrorRate` | 5xx / `clamp_min(total, 1)` > `0.05` | `2m` | Flags sustained >5% server-side failure rate while clamping tiny denominators at 1 req/s so a single isolated 500 during low traffic does not page on-call. |
| `HostDiskUsageHigh` | Real filesystem usage > `80%` | `5m` | Excludes pseudo-filesystems (`tmpfs`, `squashfs`, `vfat`) and gives enough runway to clean logs/images before hitting 95%+ read-only or write failures; `5m` filters transient temp spikes. |
| `ContainerMemoryNearLimit` | Working set / memory limit > `85%` | `2m` | Warns before Linux OOM-kills the container at 100%, while `2m` ignores brief GC spikes. |

### Host Mounts & Privileges (`docker-compose.monitoring.yml`)

| Service | Host Mounts & Privileges | Reason |
| :--- | :--- | :--- |
| `node-exporter` | `/proc:/host/proc:ro`, `/sys:/host/sys:ro`, `/:/rootfs:ro`, `pid: host` | Reads host kernel CPU, memory, network interface, and disk stats rather than the container's isolated `/proc` and namespace. |
| `cadvisor` | `/:/rootfs:ro`, `/var/run:ro`, `/sys:ro`, `/var/lib/docker:ro`, `privileged: true` | Inspects cgroups and Docker container layers/memory limits across all running containers on the host. |
| `alloy` | `/var/run/docker.sock:ro` | Uses read-only Docker socket access for container discovery and streaming JSON stdout logs to Loki. |

### Error-Spike Troubleshooting Walkthrough

If an error spike appears on the **Application Metrics & Logs** dashboard in Grafana:

1. **Confirm impact in Prometheus panels:** Check **HTTP Error Rate (5xx / 4xx)** alongside **HTTP Request Rate** to see whether 5xx errors jumped during a traffic surge or right after a release, and inspect **Request Latency (p50 / p95 / p99)** for tail latency spikes.
2. **Read correlated logs in the same view:** Scroll down to the **Live Application Logs (Loki)** panel (`{service="app"}`) or filter in Explore with `{service="app", level=~"WARN|ERROR"} | json | status >= 500` to inspect the exact routes, status codes, and `duration_ms` during the spike window.
3. **Check container and host saturation:** Switch to **Container Resource Metrics (cAdvisor)** to verify if `devops-app` is hitting CPU throttling or approaching its `128M` memory limit, and check **Host System Metrics (Node Exporter)** (or `/var/log/devops-task/health_log.txt`) for disk exhaustion or competing host processes.
4. **Mitigate:** If correlated with a new release, roll back via `kubectl rollout undo deployment/devops-task-app`, `./scripts/deploy.sh <previous-sha-tag>`, or re-running the previous image via SSM.

---

## Linux Health Script & Host Automation (`scripts/`, `ansible/`)

Lint both scripts (0 warnings):

```bash
shellcheck -x scripts/system_health.sh scripts/deploy.sh
```

Run `scripts/system_health.sh` manually:

```bash
./scripts/system_health.sh --help
./scripts/system_health.sh --cpu 90 --mem 85 --disk 80
./scripts/system_health.sh --cpu 90 --mem 85 --disk 80 --json
```

The script uses `set -euo pipefail`, checks CPU, memory, all non-tmpfs mounted filesystems, load average, and top 5 memory processes, rotates `health_log.txt` once it reaches 1 MiB (`.1` and `.2`), returns exit codes `0` (healthy), `1` (warning), or `2` (critical >= 95% or bad usage), and optionally posts to Slack/Discord when `ALERT_WEBHOOK_URL` is exported.

Scheduling files under `scripts/systemd/` run the check every 5 minutes:

- **systemd:** Copy `system-health.service` and `system-health.timer` to `/etc/systemd/system/` and run `systemctl enable --now system-health.timer`.
- **cron:** Add the entry in `scripts/systemd/crontab.example` (`*/5 * * * * ...`).
- **Ansible (Bonus):** `ansible/site.yml` configures a `deploy` user, hardens SSH (`PermitRootLogin no`, `PasswordAuthentication no`), enables UFW + `fail2ban` + `unattended-upgrades`, and installs the 5-minute `system-health.timer`. Validate with:
  ```bash
  ansible-playbook -i ansible/inventory.ini.example ansible/site.yml --syntax-check
  ```

---

## Design Decisions

- **Alpine vs. distroless:** I chose `alpine:3.23.8` over `gcr.io/distroless/static` so `wget` is available for native Docker `HEALTHCHECK` probes and basic live debugging, while still keeping the image small (**26.7 MB**) and running under UID `10001` with a read-only root filesystem in Compose/Kubernetes.
- **EC2 vs. ECS vs. EKS:** Terraform provisions a single EC2 host inside a 2-AZ VPC (with private subnets already carved out) because it stays inside AWS Free Tier limits for an assessment while remaining straightforward to evolve into ECS or EKS later.
- **Tagging & secrets strategy:** Every push to `main` publishes immutable `sha-<7>` and SemVer (`1.0.<run_number>`) tags instead of overwriting `:latest` in ECR (`IMMUTABLE` tags enabled). No secrets are stored in Git: CI uses GitHub OIDC for AWS, Kubernetes ships only `secret.example.yaml`, and Grafana reads credentials from environment variables.
- **Grafana Alloy over Promtail:** Grafana Alloy replaces Promtail (which is in maintenance mode) and cleanly combines Docker target discovery with structured JSON parsing before pushing to Loki.

---

## Deployment & Rollback Strategy

1. Every PR must pass linting (`golangci-lint`, Hadolint, ShellCheck), unit tests (`-race`), and Trivy CVE gating (`CRITICAL`) before merge.
2. Merges to `main` build multi-arch images, push immutable SHA + SemVer tags, and deploy to EC2 via AWS SSM without opening SSH to the internet.
3. Both the CI SSM step and `scripts/deploy.sh` verify `/health` before completing (and `scripts/deploy.sh` validates a canary on `127.0.0.1:8081` before touching port `8080`). On failure, both automatically restore the previous container image. On Kubernetes, `RollingUpdate` (`maxUnavailable: 0`) plus `kubectl rollout undo` handles safe rollouts and instant rollback.

---

## Security Considerations

- **Runtime hardening:** Containers run as non-root (`10001:10001`), mount root filesystems read-only (`read_only: true` / `readOnlyRootFilesystem: true`), drop all Linux capabilities in K8s, use `RuntimeDefault` seccomp, and disable `automountServiceAccountToken`.
- **Vulnerability & lint gates:** Image versions are pinned across Dockerfile and Compose, Hadolint/ShellCheck enforce zero warnings, and Trivy `0.69.3` blocks unfixed-ignored `CRITICAL` CVEs (`golang:1.25.7-alpine3.23` patches `CVE-2025-68121`, `alpine:3.23.8` patches `CVE-2026-31789`).
- **Cloud & network hygiene:** AWS auth relies on short-lived OIDC tokens and an instance profile rather than static keys; EC2 enforces IMDSv2 and encrypted `gp3` storage; SSH ingress is restricted to `var.ssh_allowed_cidr`; and all monitoring backends stay on `devops-internal` with only Grafana exposed on `:3000`.

---

## Monthly AWS Cost Estimate (`ap-southeast-1`)

Rough monthly cost for running the Terraform setup continuously (730 hrs/month):

| Resource | Sizing / Assumption | Est. Monthly Cost (USD) |
| :--- | :--- | ---: |
| **EC2 (`t3.micro`)** | 1x On-Demand Linux (`~$0.0116/hr`, Free Tier eligible first 12 mo) | $8.47 |
| **EBS (`gp3`)** | 20 GB encrypted root volume | $1.92 |
| **NAT Gateway** | 1x NAT Gateway (`~$0.059/hr`) + ~10 GB processed | $43.66 |
| **Amazon ECR** | ~1 GB stored images (15-image lifecycle policy) | $0.10 |
| **CloudWatch Logs** | ~2 GB/month ingested + 14-day retention | $1.45 |
| **S3 + DynamoDB (State)** | <100 MB TF state + minimal lock requests | $0.05 |
| **Data Transfer Out** | ~10 GB outbound (first 100 GB/mo free tier eligible) | $0.90 |
| **Total (Prod w/ NAT)** | Full topology (`enable_nat_gateway = true`) | **~$56.55 / mo** |
| **Total (Staging / Cost-Saved)** | Set `enable_nat_gateway = false` in `staging.tfvars` | **~$12.89 / mo** |

---

## What I Would Improve With More Time

- Replace the single EC2 host with an **ALB (ACM TLS) + Auto Scaling Group** or **Amazon EKS** across both Availability Zones so there is no single point of failure.
- Wire **External Secrets Operator** (backed by AWS Secrets Manager) into the Helm chart and add `tfsec`/`checkov` static checks to `pr-check.yml`.
- Configure **Alertmanager** receivers in `monitoring/alertmanager.yml` to route severity-grouped alerts to Slack/PagerDuty and add an automated `k6` load test step in staging before prod promotion.
- Add **Cosign** image signing and **SBOM** attestation to `deploy.yml`.

---

## Note on AI Tool Usage

I used AI assistance during the assessment for boilerplate scaffolding (initial Grafana dashboard JSON structure, Helm chart templates, and Ansible task syntax) and to speed up debugging toolchain version issues (`golangci-lint` Go version alignment and Alpine CVE base image updates). All application code, pipelines, Terraform resources, scripts, and monitoring configs were reviewed, tested, and verified locally against live tools (`go test -race`, `docker build`, `trivy`, `hadolint`, `terraform validate`, `kubeconform`, `helm lint`, `shellcheck`, and the live Compose observability stack).

---

## Completed Bonus Items

- **Helm Chart (`helm/devops-task/`):** Multi-environment packaging with `values-staging.yaml` and `values-prod.yaml`.
- **Alertmanager (`monitoring/alertmanager.yml`):** Integrated alongside Prometheus alerting rules.
- **Zero-Downtime Canary Deploy Script (`scripts/deploy.sh`):** Pre-cutover health verification on port `8081` with automatic backup container rollback.
- **Webhook & Scheduler Support (`scripts/system_health.sh`, `scripts/systemd/`):** `ALERT_WEBHOOK_URL` Slack/Discord notifications plus 5-minute `systemd` timer and crontab example.
- **CloudWatch Container Log Shipping (`terraform/main.tf`):** Configured `awslogs` Docker driver and scoped IAM log stream permissions.
- **Ansible Hardening Playbook (`ansible/site.yml`, `ansible/inventory.ini.example`):** Server hardening, firewall setup, and `system-health.timer` installation.
