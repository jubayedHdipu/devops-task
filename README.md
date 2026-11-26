
# Production-Ready DevOps Pipeline & AWS Infrastructure (`devops-task`)

A containerized Go web service paired with an end-to-end DevSecOps CI/CD pipeline (GitHub Actions + Trivy + Hadolint + ShellCheck), modular AWS Infrastructure as Code (Terraform), zero-downtime canary deployment automation, and Prometheus observability.

---

## Architecture Overview

```text
+-------------------+      PR / Push       +---------------------------------------+
|  Developer / Git  | -------------------> |            GitHub Actions             |
| (feat/* -> main)  |                      | 1. Go Lint (golangci-lint v2.15)    |
+-------------------+                      | 2. Unit Tests (-race + coverage)    |
                                           | 3. Hadolint & ShellCheck            |
                                           | 4. Trivy Scan (Fail on CRITICAL)    |
                                           | 5. Multi-Arch Build -> GHCR / ECR   |
                                           +-------------------+-------------------+
                                                               |
                                                      AWS SSM RunCommand
                                                               |
                                                               v
+----------------------------------------------------------------------------------+
| AWS VPC (10.0.0.0/16 across 2 AZs)                                               |
|  +------------------------------------+   +------------------------------------+ |
|  | Public Subnets (10.0.1.0/24, .2.0) |   | Private Subnets (10.0.11.0/24,.12) | |
|  |  - Internet Gateway & NAT Gateway  |   |  - Isolated Backend Tier Ready     | |
|  |  - EC2 Host (t3.micro, Ubuntu 24)  |   +------------------------------------+ |
|  |    * IMDSv2 Enforced, gp3 Encrypted|                                          |
|  |    * IAM Role (SSM + ECR ReadOnly) |   +------------------------------------+ |
|  |    * scripts/deploy.sh (Canary)    |   | Amazon ECR (Immutable Tags + Scan) | |
|  +------------------------------------+   +------------------------------------+ |
+----------------------------------------------------------------------------------+
```
