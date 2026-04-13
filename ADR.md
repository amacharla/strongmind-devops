# ADR-001: Identity Server Migration from Azure to AWS

| Field       | Value                                    |
|-------------|------------------------------------------|
| **Status**  | Proposed                                 |
| **Date**    | 2026-04-13                               |
| **Author**  | Staff DevOps Engineer                    |
| **Reviewers** | Platform Engineering, Security, SRE    |

---

## Context

StrongMind's Identity Server is the sole authentication and token issuance service for all platform products. It currently runs on Azure infrastructure that is isolated from the rest of our production workloads, which have already been consolidated onto AWS ECS Fargate.

**Current State:**
- **.NET 6** application deployed as an Azure App Service (Linux)
- **Azure SQL Database** (SQL Server 2019 compatibility) for identity persistence (users, tokens, grants)
- **Azure Key Vault** storing connection strings, token-signing certificates, and API keys
- **Azure AD Domain Services** used for directory lookups (group membership, user attributes)
- **Traffic profile:** ~400 req/min sustained, peaking to ~1,200 req/min during morning school start (7–9 AM MT)
- **Downstream consumers:** Rails LMS, PowerSchool integration, and other internal services

**Why migrate now:**
1. **Operational fragmentation** — The on-call team must context-switch between Azure and AWS consoles, alerting systems, and IAM models. This increases MTTR and cognitive load.
2. **Cost consolidation** — Running a single service on Azure incurs a separate support agreement, networking costs (cross-cloud egress), and duplicated secrets management tooling.
3. **Observability gap** — The current Azure deployment is not covered by our AWS-centric monitoring stack (CloudWatch, X-Ray). The on-call engineer "can't tell if something is wrong until a customer calls."
4. **Security posture** — Centralizing IAM, network policies, and secrets into one cloud provider reduces the attack surface and simplifies audit scope (FERPA compliance).

---

## Decision

We will perform a **lift-and-containerize migration** of the Identity Server from Azure to AWS ECS Fargate, migrating the database to Amazon RDS for SQL Server and secrets to AWS Secrets Manager. The Azure AD Domain Services dependency will be maintained temporarily via an AWS-to-Azure site-to-site VPN, with a follow-up workstream to evaluate AWS Managed Microsoft AD.

We chose lift-and-containerize over a full re-architecture because:
- The .NET 6 application is already Linux-based and can be containerized without code changes.
- A rewrite or re-platform to a different auth system (e.g., Cognito) would introduce unnecessary risk for a critical-path service.
- Containerization gives us deployment consistency with our existing ECS fleet and enables future portability.

---

## Migration Architecture

### Target Architecture Diagram (Logical)

```
                        ┌─────────────────────────────────────────────────┐
                        │               AWS VPC (10.0.0.0/16)             │
                        │                                                 │
  Internet ──► Route 53 │   ┌──────────────────────────────────────┐      │
              (weighted) │   │  Public Subnets (2 AZs)             │      │
                        │   │  ┌──────────────────────────────┐    │      │
                        │   │  │  Application Load Balancer   │    │      │
                        │   │  │  (HTTPS :443, TLS 1.2+)     │    │      │
                        │   │  └────────────┬─────────────────┘    │      │
                        │   └───────────────┼──────────────────────┘      │
                        │                   │                             │
                        │   ┌───────────────▼──────────────────────┐      │
                        │   │  Private App Subnets (2 AZs)         │      │
                        │   │  ┌────────────────────────────────┐  │      │
                        │   │  │  ECS Fargate Service            │  │      │
                        │   │  │  identity-server                │  │      │
                        │   │  │  Tasks: 3 (min) → 8 (max)      │  │      │
                        │   │  │  1 vCPU / 2 GB per task         │  │      │
                        │   │  └────────────┬───────────────────┘  │      │
                        │   └───────────────┼──────────────────────┘      │
                        │                   │                             │
                        │   ┌───────────────▼──────────────────────┐      │
                        │   │  Private Data Subnets (2 AZs)        │      │
                        │   │  ┌────────────────────────────────┐  │      │
                        │   │  │  RDS SQL Server 2019            │  │      │
                        │   │  │  db.r6i.large, Multi-AZ         │  │      │
                        │   │  │  100 GB gp3, encrypted (KMS)    │  │      │
                        │   │  └────────────────────────────────┘  │      │
                        │   └──────────────────────────────────────┘      │
                        │                                                 │
                        │   Site-to-Site VPN ◄──► Azure AD DS             │
                        │   (for directory lookups during transition)      │
                        └─────────────────────────────────────────────────┘
```

### ECS Fargate Task Definition

| Parameter               | Value                                                          |
|-------------------------|----------------------------------------------------------------|
| **Family**              | `identity-server`                                              |
| **CPU**                 | 1024 (1 vCPU)                                                  |
| **Memory**              | 2048 MB                                                        |
| **Network Mode**        | `awsvpc`                                                       |
| **Runtime Platform**    | Linux/X86_64                                                   |
| **Container Image**     | `<account>.dkr.ecr.us-east-1.amazonaws.com/identity-server:sha-<commit>` |
| **Container Port**      | 8080 (Kestrel HTTP, TLS terminated at ALB)                     |
| **Health Check**        | `CMD-SHELL, curl -f http://localhost:8080/health \|\| exit 1`    |
| **Log Driver**          | `awslogs` → CloudWatch log group `/ecs/identity-server`        |
| **Secrets (from SM)**   | `DB_CONNECTION_STRING`, `TOKEN_SIGNING_CERT`, `API_KEYS`       |
| **Task Role**           | `identity-server-task-role` (Secrets Manager read, X-Ray write, S3 read for certs) |
| **Execution Role**      | `identity-server-execution-role` (ECR pull, CloudWatch Logs, Secrets Manager read) |

**Sizing rationale:** At 1,200 req/min peak, each request averaging ~50ms, a single vCPU task can handle roughly 600-800 req/min. With 3 minimum tasks we have 1,800-2,400 req/min capacity — providing 50-100% headroom at peak. The 2 GB memory allocation provides comfortable overhead for the .NET runtime's working set and GC pressure.

**Auto Scaling:**
- Target tracking policy on `ECSServiceAverageCPUUtilization` at **60%**
- Min tasks: **3**, Max tasks: **8**
- Scale-in cooldown: 300s, Scale-out cooldown: 60s
- The asymmetric cooldowns prevent flapping while allowing rapid response to traffic surges (morning school start)

### Application Load Balancer

| Parameter                  | Value                              |
|----------------------------|------------------------------------|
| **Scheme**                 | Internet-facing                    |
| **Listeners**              | HTTPS :443 (redirect HTTP :80 → 443) |
| **TLS Policy**             | `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| **Certificate**            | ACM-managed wildcard for `*.strongmind.com` |
| **Target Group Protocol**  | HTTP :8080                         |
| **Health Check Path**      | `/health`                          |
| **Health Check Interval**  | 15 seconds                         |
| **Healthy Threshold**      | 2 consecutive checks               |
| **Unhealthy Threshold**    | 3 consecutive checks               |
| **Deregistration Delay**   | 30 seconds                         |

### RDS for SQL Server

| Parameter                  | Value                              |
|----------------------------|------------------------------------|
| **Engine**                 | SQL Server 2019 Standard Edition   |
| **Instance Class**         | `db.r6i.large` (2 vCPU, 16 GB RAM) |
| **Storage**                | 100 GB gp3 (3,000 IOPS baseline, burstable) |
| **Multi-AZ**               | Yes (synchronous standby)          |
| **Encryption**             | AWS KMS (customer-managed key)     |
| **Backup Retention**       | 14 days, automated daily snapshots |
| **Maintenance Window**     | Sunday 04:00–05:00 UTC (Sat 9–10 PM MT, low traffic) |
| **Parameter Group**        | Custom: `max_server_memory = 12288 MB`, `cost_threshold_for_parallelism = 25` |
| **Subnet Group**           | Private data subnets only          |
| **Security Group**         | Inbound TCP 1433 from ECS app subnets only |

**Instance sizing rationale:** The `db.r6i.large` provides 2 vCPUs and 16 GB RAM — sufficient for an identity database workload that is read-heavy (token validation, user lookups). We'll monitor `CPUUtilization`, `FreeableMemory`, and `ReadIOPS` for the first 2 weeks post-migration and right-size if utilization is consistently below 30% or above 70%.

### Secrets Manager

Secrets migrated from Azure Key Vault:

| Secret Name                        | Description                        | Rotation    |
|------------------------------------|------------------------------------|-------------|
| `identity-server/db-connection-string` | RDS SQL Server connection string   | Manual (changes with DB endpoint) |
| `identity-server/token-signing-cert`   | X.509 certificate for JWT signing  | 90-day automatic rotation via Lambda |
| `identity-server/api-keys`             | Third-party API keys (PowerSchool) | Manual, audited quarterly |

Secrets are referenced in the ECS task definition via `secrets` block (ARN references), never as plaintext environment variables.

### VPC and Networking

| Component          | Configuration                                         |
|--------------------|-------------------------------------------------------|
| **VPC CIDR**       | `10.0.0.0/16` (existing StrongMind production VPC)    |
| **Public Subnets** | `10.0.1.0/24`, `10.0.2.0/24` (us-east-1a, 1b) — ALB |
| **App Subnets**    | `10.0.10.0/24`, `10.0.11.0/24` — ECS tasks           |
| **Data Subnets**   | `10.0.20.0/24`, `10.0.21.0/24` — RDS                 |
| **NAT Gateway**    | One per AZ for outbound internet (ECR pull, external APIs) |
| **VPC Endpoints**  | ECR (dkr + api), CloudWatch Logs, Secrets Manager, S3 — to reduce NAT costs and improve latency |

### IAM Roles (Least Privilege)

**Task Execution Role** (`identity-server-execution-role`):
```json
{
  "Effect": "Allow",
  "Action": [
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchGetImage",
    "ecr:GetAuthorizationToken",
    "logs:CreateLogStream",
    "logs:PutLogEvents",
    "secretsmanager:GetSecretValue"
  ],
  "Resource": [
    "arn:aws:ecr:us-east-1:<account>:repository/identity-server",
    "arn:aws:logs:us-east-1:<account>:log-group:/ecs/identity-server:*",
    "arn:aws:secretsmanager:us-east-1:<account>:secret:identity-server/*"
  ]
}
```

**Task Role** (`identity-server-task-role`):
```json
{
  "Effect": "Allow",
  "Action": [
    "secretsmanager:GetSecretValue",
    "xray:PutTraceSegments",
    "xray:PutTelemetryRecords"
  ],
  "Resource": [
    "arn:aws:secretsmanager:us-east-1:<account>:secret:identity-server/*",
    "*"
  ]
}
```
Note: X-Ray actions require `Resource: "*"` per AWS documentation. All other permissions are scoped to specific ARNs.

### Azure AD Domain Services — Transition Plan

The Identity Server depends on Azure AD DS for directory lookups (group membership, user attributes). During migration:

1. **Phase 1 (Migration):** Establish an AWS-to-Azure **site-to-site VPN** (or use existing ExpressRoute/VPN if available). ECS tasks in the private app subnets route LDAP/LDAPS traffic (TCP 389/636) to Azure AD DS through the VPN tunnel. Latency adds ~10-20ms per directory call — acceptable for auth flows.
2. **Phase 2 (Post-migration, separate workstream):** Evaluate replacing Azure AD DS with **AWS Managed Microsoft AD** or **AWS IAM Identity Center** + external IdP. This is out of scope for this ADR but tracked as a follow-up.

---

## Traffic Cutover Strategy

We will use a **Route 53 weighted routing** approach for a gradual, zero-downtime cutover:

### Pre-Cutover Preparation
1. Deploy the Identity Server on ECS Fargate behind the new ALB.
2. Complete database migration (see next section) and validate data integrity.
3. Run synthetic traffic tests against the AWS endpoint for 48 hours — validate token issuance, user lookup, and all critical auth flows.
4. Confirm observability stack is operational (dashboards, alarms, on-call routing).

### Cutover Phases

| Phase | Route 53 Weight (Azure) | Route 53 Weight (AWS) | Duration     | Success Criteria                           |
|-------|-------------------------|-----------------------|--------------|--------------------------------------------|
| 0     | 100                     | 0                     | Baseline     | All traffic on Azure                       |
| 1     | 95                      | 5                     | 1 hour       | Error rate < 0.1%, p99 latency < 500ms    |
| 2     | 75                      | 25                    | 2 hours      | Same criteria, no customer-reported issues |
| 3     | 50                      | 50                    | 4 hours      | Same criteria, validate under load          |
| 4     | 10                      | 90                    | 24 hours     | Sustained stability through a full school day cycle |
| 5     | 0                       | 100                   | Permanent    | Migration complete                         |

**DNS TTL:** Set record TTL to **60 seconds** at least 24 hours before starting Phase 1. This ensures clients pick up routing changes within ~1 minute.

**Schedule:** Begin Phase 1 on a **Tuesday at 10 AM MT** (after morning peak, before end-of-day). Avoid Mondays (highest school traffic) and Fridays (reduced staffing for weekend monitoring).

### Rollback Trigger and Procedure

**Automatic rollback triggers (any of these):**
- Error rate exceeds **1%** on the AWS endpoint for 5 consecutive minutes
- p99 latency exceeds **2 seconds** for 5 consecutive minutes
- Any 5xx error rate above **0.5%** on the ALB

**Rollback procedure:**
1. Shift Route 53 weight to 100% Azure / 0% AWS (takes effect within 60s given TTL).
2. Post incident notification in `#platform-incidents` Slack channel.
3. Preserve AWS environment as-is for investigation (do not tear down).
4. Conduct postmortem and address root cause before reattempting cutover.

**Rollback is safe because:** Both environments share the same database during the transition window (via DMS CDC replication). No data divergence occurs until the Azure database is decommissioned in Phase 5.

---

## Database Migration Plan

### Approach: AWS DMS with Change Data Capture (CDC)

We will use **AWS Database Migration Service (DMS)** with **full-load + CDC** to achieve near-zero-downtime database migration.

### Migration Phases

#### Phase 1: Schema Migration
- Use the **AWS Schema Conversion Tool (SCT)** to analyze and migrate the schema from Azure SQL to RDS SQL Server.
- Since both are SQL Server engines (2019 compatibility), schema conversion is minimal — primarily validating collation settings, stored procedures, and any Azure-specific features (e.g., Azure SQL elastic pool settings won't apply).
- Manually review and test all stored procedures, triggers, and indexed views.

#### Phase 2: Full Load + CDC
1. **Provision DMS replication instance** (`dms.r6i.large`) in the same VPC as the target RDS.
2. **Create source endpoint** pointing to Azure SQL Database (via VPN or public endpoint with TLS + IP whitelisting).
3. **Create target endpoint** pointing to RDS SQL Server.
4. **Enable CDC on Azure SQL** — requires `ALTER DATABASE SET CHANGE_TRACKING = ON` and enabling for each tracked table.
5. **Start DMS task** with `full-load-and-cdc` mode:
   - Full load: bulk copy of all tables (~estimated 20-50 GB for an identity database)
   - CDC: ongoing replication of inserts/updates/deletes after full load completes
6. **Monitor replication lag** via DMS CloudWatch metrics (`CDCLatencySource`, `CDCLatencyTarget`) — target: < 5 seconds.

#### Phase 3: Data Validation
- Run **AWS DMS data validation** (built-in feature) to compare row counts and checksums between source and target.
- Execute application-level validation: run a subset of integration tests against the AWS database — token issuance, user lookup, password validation.
- Compare query results for a sample of 1,000 user records between Azure and AWS.

#### Phase 4: Cutover
- During the traffic cutover (Phase 4 at 90% AWS), the AWS RDS instance is already receiving all writes via CDC.
- At final cutover (Phase 5, 100% AWS):
  1. Stop writes to Azure SQL (set read-only or take app offline on Azure).
  2. Wait for DMS CDC to drain (< 60 seconds).
  3. Run final validation check.
  4. Point the application exclusively to RDS.
  5. Stop DMS replication task.

#### Rollback
- If data issues are found post-cutover, reverse the DMS direction: create a new task replicating RDS → Azure SQL.
- During the parallel-run window (Phases 1–4), Azure SQL remains the source of truth.

### Downtime Estimate
- **Schema migration:** 0 downtime (done before cutover)
- **Full load:** 0 downtime (CDC catches changes during load)
- **Final cutover:** < 2 minutes (drain CDC queue + validation)

---

## Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | **Azure AD DS latency over VPN degrades auth response times** — LDAP calls over the VPN tunnel add 10-20ms, potentially exceeding SLO during peak. | Medium | High | Pre-migration: benchmark LDAP call latency over VPN. Implement an application-level cache (5-minute TTL) for directory lookup results. Set up CloudWatch alarm on p99 latency. If latency is unacceptable, evaluate deploying an Azure AD DS read replica closer to the VPN endpoint. |
| 2 | **DMS replication lag during peak traffic causes stale reads** — At 1,200 req/min peak, CDC may fall behind if the replication instance is undersized. | Low | High | Use a `dms.r6i.large` instance with provisioned IOPS. Monitor `CDCLatencyTarget` with an alarm at > 10 seconds. Perform initial full-load during off-peak hours (Saturday night). Load-test CDC replication at 2x peak rate before cutover. |
| 3 | **Token-signing certificate rotation fails during migration** — If the signing certificate is rotated while both environments are active, JWT validation could break for one environment. | Low | Critical | Freeze certificate rotation during the migration window. Migrate the certificate to Secrets Manager before Phase 1. Both environments must use the same certificate. After migration, configure automatic rotation in AWS Secrets Manager. |
| 4 | **DNS caching causes traffic to Azure after cutover** — Some clients (corporate proxies, ISP resolvers) may ignore short TTLs and continue resolving to Azure. | Medium | Medium | Set DNS TTL to 60s at least 48 hours before cutover. Keep Azure App Service running in read-only mode for 72 hours after Phase 5. Return `301 Redirect` from the Azure endpoint as a backstop. Monitor Azure App Service metrics for residual traffic. |
| 5 | **ECS task startup time causes service instability during scaling events** — .NET cold start + container pull time may exceed ALB health check grace period. | Medium | Medium | Pre-pull the container image by running a minimum of 3 tasks at all times. Set ALB health check grace period to 120 seconds. Use ECS circuit breaker with rollback. Optimize container image size (< 200 MB). Evaluate .NET ReadyToRun compilation for faster startup. |

---

## Definition of Done

The migration is considered **complete and successful** when ALL of the following conditions are met and sustained for **7 consecutive business days**:

### Traffic & Availability
- [ ] 100% of production traffic is served by the AWS ECS deployment (Route 53 weight: 100% AWS)
- [ ] Identity Server availability ≥ 99.95% (measured by ALB healthy host count and synthetic health checks)
- [ ] Zero customer-reported authentication failures attributable to the migration

### Performance
- [ ] p50 latency ≤ 200ms, p99 latency ≤ 500ms (measured at ALB)
- [ ] Error rate (5xx) < 0.1% sustained
- [ ] ECS auto scaling responds correctly to morning peak (7–9 AM MT) without manual intervention

### Data Integrity
- [ ] DMS validation report shows 0 row-count discrepancies and 0 checksum mismatches
- [ ] Application-level integration test suite passes 100% against RDS SQL Server
- [ ] All stored procedures, triggers, and scheduled jobs execute correctly

### Operations
- [ ] CloudWatch dashboards operational for Identity Server (ECS, RDS, ALB metrics)
- [ ] Alerting pipeline verified: test alert successfully routed from CloudWatch → Jira Operations → on-call engineer
- [ ] Runbook published and reviewed by the on-call team
- [ ] X-Ray tracing active and traces visible for end-to-end auth flows

### Decommission Readiness
- [ ] Azure App Service stopped (not deleted — retained for 30 days as final rollback option)
- [ ] Azure SQL Database set to read-only (retained for 30 days, then decommissioned)
- [ ] Azure Key Vault secrets flagged for deletion (90-day soft-delete retention)
- [ ] Cost savings validated: Azure resource spend reduced to $0 for Identity Server components

---

## Appendix: Assumptions

1. The Identity Server .NET 6 application has no hard dependencies on Azure-specific SDKs beyond Key Vault and AD DS (e.g., no Azure Service Bus, Azure Blob Storage).
2. The existing StrongMind AWS VPC has available CIDR space for new subnets.
3. DNS for the Identity Server endpoint is managed in Route 53 (or can be delegated to Route 53).
4. The organization has an existing AWS-to-Azure VPN or is willing to establish one.
5. FERPA compliance requirements are met by encrypting data at rest (KMS) and in transit (TLS 1.2+), with audit logging enabled.
6. The Identity Server does not use WebSockets or SignalR — it serves stateless REST API requests.
7. The development team can access the .NET source code to build a Docker image and make minor configuration changes (e.g., environment variable-based config).
