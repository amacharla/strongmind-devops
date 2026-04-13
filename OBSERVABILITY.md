# Observability Design Plan

This document defines the observability strategy for two services running on AWS ECS Fargate:

1. **Identity Server** — .NET 6 authentication service (migrated from Azure)
2. **Rails Application** — Ruby on Rails 8 LMS application

---

## 1. SLOs and SLIs

### Identity Server

| SLO | Target | SLI (Measurement) | Window |
|-----|--------|--------------------|--------|
| **Availability** | ≥ 99.95% of requests return a non-5xx response | `1 - (ALB 5xx count / total request count)` via `HTTPCode_Target_5XX_Count` and `RequestCount` CloudWatch metrics | Rolling 30 days |
| **Latency** | p99 response time ≤ 500ms | ALB `TargetResponseTime` p99 statistic | Rolling 30 days |

### Rails Application

| SLO | Target | SLI (Measurement) | Window |
|-----|--------|--------------------|--------|
| **Availability** | ≥ 99.9% of requests return a non-5xx response | Same ALB metric approach | Rolling 30 days |
| **Latency** | p95 response time ≤ 1,000ms | ALB `TargetResponseTime` p95 statistic | Rolling 30 days |

**Breach Response:**
- **Warning (budget burn > 50% in first half of window):** Create a Jira Operations alert at P3. Investigate contributing factors (slow queries, scaling lag, dependency degradation). Post findings in `#platform-reliability` Slack channel.
- **Critical (budget burn > 80% or SLO breached):** Escalate to P1 in Jira Operations. Page the on-call engineer. Freeze non-critical deployments until the error budget is restored. Conduct a formal incident review.

---

## 2. Metrics and Alarms

### ECS Task Health

| Metric | Alarm Threshold | Action |
|--------|----------------|--------|
| `CPUUtilization` (service average) | > 75% for 5 min | Auto-scaling responds; alarm notifies if sustained > 80% for 10 min |
| `MemoryUtilization` (service average) | > 85% for 5 min | Page on-call — likely memory leak or undersized task |
| `RunningTaskCount` | < desired count for 3 min | Page on-call — tasks failing to start or being killed |
| `HealthyHostCount` (ALB target group) | < desired count for 2 min | Page on-call — tasks failing health checks |
| ECS Deployment Circuit Breaker event | Any trigger | Notify `#deployments` — ECS rolled back automatically |

### RDS Performance (SQL Server — Identity Server)

| Metric | Alarm Threshold | Action |
|--------|----------------|--------|
| `CPUUtilization` | > 70% for 10 min | Notify — evaluate query performance or instance sizing |
| `FreeableMemory` | < 2 GB for 10 min | Notify — possible buffer pool pressure, evaluate instance upgrade |
| `ReadIOPS` / `WriteIOPS` | > 80% of provisioned baseline for 15 min | Notify — evaluate gp3 IOPS increase or instance upgrade |
| `DatabaseConnections` | > 80% of `max_connections` | Page on-call — connection pool exhaustion imminent |
| `ReplicaLag` (Multi-AZ) | > 30 seconds for 5 min | Page on-call — potential failover delay |
| `FreeStorageSpace` | < 10 GB | Notify — plan storage expansion |

### Application-Level Signals

| Metric | Source | Alarm Threshold | Action |
|--------|--------|----------------|--------|
| `HTTPCode_Target_5XX_Count` | ALB | > 10/min for 3 min | Page on-call |
| `HTTPCode_Target_4XX_Count` | ALB | > 500/min for 5 min | Notify — may indicate client issue or auth misconfiguration |
| `TargetResponseTime` (p99) | ALB | > 1s for 5 min (Identity Server) | Page on-call |
| `RequestCount` | ALB | < 50% of baseline for same time-of-day | Notify — possible upstream routing issue |
| Auth failure rate | Custom metric (app publishes via CloudWatch SDK) | > 5% of auth attempts for 5 min | Page on-call — possible credential store issue or attack |

---

## 3. Distributed Tracing (AWS X-Ray)

### Setup for the .NET Identity Server on ECS

1. **Instrument the application:** Add the `AWSXRayRecorder` NuGet package and configure the ASP.NET middleware to capture incoming HTTP requests. Alternatively, use the **AWS Distro for OpenTelemetry (ADOT) .NET SDK** for vendor-neutral instrumentation.

2. **Deploy the X-Ray daemon as an ECS sidecar:** Add a second container to the task definition using the `amazon/aws-xray-daemon:latest` image. The sidecar listens on UDP port 2000 and forwards trace segments to the X-Ray API.

   ```json
   {
     "name": "xray-daemon",
     "image": "amazon/aws-xray-daemon:latest",
     "essential": false,
     "portMappings": [{ "containerPort": 2000, "protocol": "udp" }],
     "memoryReservation": 256
   }
   ```

3. **IAM:** Attach the `AWSXRayDaemonWriteAccess` managed policy to the ECS task role.

4. **Environment variable:** Set `AWS_XRAY_DAEMON_ADDRESS=localhost:2000` on the application container.

### Setup for the Rails Application

Use the `aws-xray-sdk-ruby` gem or the ADOT Ruby SDK. Configure Rack middleware to trace all incoming requests. Instrument outgoing HTTP calls (e.g., `Net::HTTP`, `Faraday`) and database queries (ActiveRecord).

### Diagnosing a Latency Spike

When investigating a latency spike, examine traces in the X-Ray console with these steps:

1. **Filter by response time** — use the filter expression `responsetime > 0.5` to isolate slow requests.
2. **Identify the bottleneck segment** — look at the trace waterfall to see which downstream call (database query, Azure AD lookup, external API) consumes the most time.
3. **Check for fan-out** — determine if the latency is caused by sequential calls that could be parallelized.
4. **Correlate with RDS metrics** — if the database segment is slow, cross-reference with RDS `ReadLatency`/`WriteLatency` metrics at the same timestamp.
5. **Look for cold-start patterns** — if latency spikes correlate with new task launches (scaling events), consider pre-warming or adjusting the minimum task count.

---

## 4. Log Strategy

### Log Architecture

```
ECS Task (awslogs driver) ──► CloudWatch Logs ──► CloudWatch Insights (query)
                                      │
                                      ├──► S3 (long-term archive, via subscription)
                                      └──► Jira Operations (via alarm → SNS)
```

### Log Groups and Retention

| Log Group | Source | Retention | Purpose |
|-----------|--------|-----------|---------|
| `/ecs/identity-server` | Identity Server containers | 30 days | Application logs, auth events |
| `/ecs/rails-app` | Rails application containers | 30 days | Application logs, request logs |
| `/ecs/xray-daemon` | X-Ray sidecar containers | 7 days | Daemon health (low volume) |
| `/aws/rds/identity-server` | RDS SQL Server logs | 14 days | Slow queries, error logs |

All log groups beyond 30 days are archived to S3 (Glacier Instant Retrieval) for FERPA-compliant 7-year retention.

### Structured Logging

Both applications should emit **JSON-structured logs** to stdout. The ECS `awslogs` driver forwards stdout/stderr to CloudWatch. Key fields:

```json
{
  "timestamp": "2026-04-13T14:30:00Z",
  "level": "info",
  "service": "identity-server",
  "trace_id": "1-abc123-def456",
  "request_id": "req-789",
  "method": "POST",
  "path": "/connect/token",
  "status": 200,
  "duration_ms": 45,
  "user_id": "usr_12345"
}
```

### Useful CloudWatch Insights Queries

**Find 5xx errors with context (Identity Server):**
```sql
fields @timestamp, level, method, path, status, duration_ms, @message
| filter status >= 500
| sort @timestamp desc
| limit 50
```

**Identify slow authentication requests (> 500ms):**
```sql
fields @timestamp, path, duration_ms, user_id, trace_id
| filter path like /connect/ and duration_ms > 500
| stats count(*) as slow_requests, avg(duration_ms) as avg_ms, max(duration_ms) as max_ms by path
| sort slow_requests desc
```

**Detect authentication failure spikes (Rails app calling Identity Server):**
```sql
fields @timestamp, path, status, user_id
| filter path like /auth/ and status in [401, 403]
| stats count(*) as failures by bin(5m) as time_window
| sort time_window desc
```

---

## 5. Alerting Pipeline

### Flow

```
CloudWatch Alarm ──► SNS Topic ──► Jira Operations (OpsGenie) ──► On-Call Engineer
                         │
                         └──► Slack (#platform-alerts)
```

### Severity Levels

| Severity | Criteria | Jira Operations Action | Response Time |
|----------|----------|----------------------|---------------|
| **P1 — Critical** | Service down, SLO breached, data loss risk | **Page** on-call engineer (phone + push notification) | Acknowledge within 5 min, engage within 15 min |
| **P2 — High** | Degraded performance, partial outage, error rate elevated | **Page** on-call engineer (push notification only) | Acknowledge within 15 min, engage within 30 min |
| **P3 — Warning** | Elevated resource usage, non-critical threshold approached | **Notify** via Jira Operations (no page, ticket created) | Review within 4 business hours |
| **P4 — Info** | Deployment events, scaling events, maintenance windows | **Log** to Slack `#deployments` channel only | Review at next standup |

### Page vs. Notify Decision Matrix

| Signal | Severity | Page? |
|--------|----------|-------|
| Identity Server 5xx rate > 1% for 5 min | P1 | Yes |
| Identity Server p99 > 2s for 5 min | P1 | Yes |
| RDS connections > 80% of max | P2 | Yes |
| ECS running tasks < desired for 3 min | P2 | Yes |
| Rails app 5xx rate > 1% for 5 min | P2 | Yes |
| RDS CPU > 70% for 10 min | P3 | No |
| ECS CPU > 80% sustained | P3 | No |
| Disk space < 10 GB on RDS | P3 | No |
| Successful deployment | P4 | No |
| Auto-scaling event | P4 | No |

### Integration Setup

1. **CloudWatch → SNS:** Each alarm publishes to a dedicated SNS topic (`platform-alerts-critical`, `platform-alerts-warning`).
2. **SNS → Jira Operations:** Jira Operations CloudWatch integration subscribes to the SNS topics. Alert routing rules map SNS topic to Jira Operations severity.
3. **SNS → Slack:** A Lambda function (or Jira Operations integration) formats the alarm and posts to `#platform-alerts`.
4. **On-call schedule:** Managed in Jira Operations with weekly rotation. Primary + secondary on-call. Escalation to engineering manager after 15 minutes with no acknowledgment.

---

## Appendix: Dashboard Layout

A single CloudWatch dashboard (`StrongMind-Platform`) with these widget groups:

| Row | Widgets |
|-----|---------|
| **Top** | SLO burn rate gauges (availability + latency) for Identity Server and Rails App |
| **ECS** | CPU utilization, memory utilization, running task count, deployment status |
| **ALB** | Request count, 5xx/4xx rates, response time (p50/p95/p99), healthy hosts |
| **RDS** | CPU, freeable memory, connections, read/write IOPS, replica lag |
| **App** | Auth failure rate (custom metric), token issuance rate, top error paths |
