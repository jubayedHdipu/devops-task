# End-to-End DevOps Assessment (`devops-task`)

A production-ready, observable, and securely deployed Go web service (`app/`) featuring a multi-stage hardened container, automated DevSecOps CI/CD pipelines (GitHub Actions), modular AWS Infrastructure as Code (Terraform), Kubernetes manifests + multi-environment Helm chart, a 6-component observability stack (Prometheus, Grafana, Loki, Grafana Alloy, Node Exporter, cAdvisor), Ansible server hardening, and automated Linux health monitoring.

---

## Architecture Diagrams

### 1. CI/CD & AWS EC2 Deployment Flow

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
