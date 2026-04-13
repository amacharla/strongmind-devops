# StrongMind Staff DevOps Engineer — Technical Exercise

## Overview

This repository contains deliverables for the StrongMind Staff DevOps Engineer technical exercise. It addresses two parallel workstreams:

1. **Identity Server Migration** (Azure → AWS) — Architecture planning, database migration, traffic cutover, and risk management for a critical authentication service.
2. **Rails CI/CD Standardization** — A production-grade GitHub Actions pipeline and Dockerfile for standardized deployment of Rails services to ECS Fargate.

**AI assistants (Cursor, Claude Code, Codex, etc.):** See [`AGENTS.md`](AGENTS.md). It summarizes repo purpose, where each deliverable lives, fixed assumptions (workflow, Dockerfile), and safe-edit conventions so tools can onboard quickly and stay aligned with the exercise.

## Repository Structure

```
.
├── README.md                              ← You are here
├── AGENTS.md                              ← Context for AI coding agents (file map, assumptions, conventions)
├── ADR.md                                 ← Part 1: Identity Server Migration ADR (35 pts)
├── .github/workflows/rails-deploy.yml     ← Part 2: GitHub Actions CI/CD Pipeline (35 pts)
├── Dockerfile                             ← Part 3: Multi-stage Rails Dockerfile (15 pts)
├── OBSERVABILITY.md                       ← Part 4: Observability Design Plan (15 pts)
├── Makefile                               ← Local Docker / Postgres / test shortcuts (`make help`)
└── StrongMind_DevOps_Exercise.pdf         ← Exercise prompt (reference)
```

## Approach

### Part 1: ADR — Identity Server Migration

I chose a **lift-and-containerize** migration strategy over a re-architecture because the Identity Server is a critical-path service where risk minimization outweighs the appeal of modernization. The .NET 6 app is already Linux-based and containerizes cleanly.

Key design decisions:
- **Gradual traffic cutover** via Route 53 weighted routing (5 phases over ~2 days) rather than a big-bang DNS switch — gives us real production signal at each stage with easy rollback.
- **AWS DMS with CDC** for near-zero-downtime database migration — both environments share the same data during the parallel-run window, making rollback safe at any point.
- **Site-to-site VPN** for the Azure AD DS dependency rather than migrating directory services simultaneously — reduces blast radius by keeping the migration scope focused.

### Part 2: GitHub Actions Pipeline

The pipeline is designed to be **adoptable as-is** by any Rails service in the org:
- OIDC authentication (no long-lived AWS keys)
- Concurrency controls prevent simultaneous deploys to the same environment
- Automated rollback captures the current task definition revision before deploying, then reverts if the new deployment fails to stabilize
- Slack notifications provide visibility without requiring engineers to watch the Actions UI

### Part 3: Dockerfile

I chose `ruby:3.3-slim` over Alpine for **glibc compatibility** — native gem extensions (pg, nokogiri) are more reliable and the ~30 MB size difference is negligible for a production deployment. The two-stage build keeps the runtime image clean of compilers and build caches.

### Part 4: Observability

Structured around **SLOs as the primary signal** — rather than a wall of dashboards, the plan ties every metric and alarm to a specific service level objective. The alerting pipeline uses severity-based routing to avoid alert fatigue (page for P1/P2, notify for P3/P4).

## Assumptions

These assumptions are documented throughout each deliverable. Consolidated here for reference:

| # | Assumption | Rationale |
|---|-----------|-----------|
| 1 | Identity Server has no Azure-specific SDK dependencies beyond Key Vault and AD DS | Standard .NET 6 apps can be containerized with minimal changes |
| 2 | DNS for the Identity Server is managed in Route 53 (or can be delegated) | Required for weighted routing cutover strategy |
| 3 | An AWS-to-Azure VPN exists or can be established | Needed for Azure AD DS directory lookups during transition |
| 4 | FERPA compliance applies (K-12 education platform) | Drives encryption at rest/in transit, PII log redaction, audit logging (CloudTrail + VPC Flow Logs), and data retention policies |
| 5 | The Identity Server serves stateless REST APIs (no WebSocket/SignalR) | Simplifies ALB configuration and horizontal scaling |
| 6 | Existing AWS VPC has available CIDR space for new subnets | Standard for an org already running production on AWS |
| 7 | The .NET source code is accessible for containerization | Required to build Docker image and adjust config to env vars |
| 8 | The Rails app uses the standard `/up` health check endpoint (Rails 7.1+) | Standard Rails convention used in the Dockerfile HEALTHCHECK |
| 9 | ECR repository and ECS cluster already exist (as stated in exercise) | Pipeline references these as secrets/constants |
| 10 | Slack is used for team notifications | Notification steps use Slack webhooks; easily swapped for other providers |

## Scoped Out (What I Would Do With More Time)

- **Infrastructure as Code:** Terraform modules for the VPC, ECS service, ALB, RDS, and Secrets Manager resources described in the ADR. The ADR intentionally focuses on architecture decisions rather than IaC to respect the time scope.
- **GitHub Actions reusable workflows:** The current pipeline is a single workflow file. In a real org, I would extract the CI, build, and deploy jobs into reusable workflows (`.github/workflows/ci.yml`, `.github/workflows/deploy-ecs.yml`) that other repos can call.
- **Load testing plan:** A k6 or Locust script simulating the 1,200 req/min morning peak against the AWS Identity Server before cutover.
- **Disaster recovery:** Cross-region RDS read replica and Route 53 failover routing for the Identity Server.
- **Cost analysis:** Detailed AWS cost comparison vs. current Azure spend to validate the consolidation business case.
- **Azure AD DS replacement:** Detailed evaluation of AWS Managed Microsoft AD vs. AWS IAM Identity Center as a follow-up workstream to fully eliminate Azure dependency.
