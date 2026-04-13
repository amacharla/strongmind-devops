# Agent context — StrongMind DevOps exercise repo

Use this file as the first stop for **what this repository is**, **where things live**, and **how to change it safely**. Intended for Cursor, Claude Code, Codex, and similar tools.

## What this repo is

- **Interview / assessment deliverables** for a Staff DevOps Engineer exercise (StrongMind).
- **No application runtime** is required here: the prompt says focus on design and config, not a working local Rails app.
- Deliverables are **documentation + GitHub Actions + Dockerfile** aligned to `StrongMind_DevOps_Exercise.pdf` (if present locally).

## File map

| Path | Purpose |
|------|---------|
| `README.md` | Human overview, assumptions table, scoped-out items |
| `ADR.md` | Part 1: Identity Server Azure→AWS migration ADR (architecture, cutover, DMS, risks, DoD, FERPA notes) |
| `.github/workflows/rails-deploy.yml` | Part 2: Rails CI → test, build, ECR push (OIDC), ECS deploy, rollback, notifications |
| `Dockerfile` | Part 3: Multi-stage Rails 8 / Ruby 3.3 production image for ECS |
| `OBSERVABILITY.md` | Part 4: SLOs, metrics, X-Ray, logs, alerting, FERPA / PII logging |
| `Makefile` | Local shortcuts: Docker build/run, Postgres in Docker, `test`/`brakeman` when a Rails app exists, `lint-actions` |
| `StrongMind_DevOps_Exercise.pdf` | Source prompt (may be untracked; do not assume it is in git) |

## Fixed assumptions from the exercise (workflow)

When editing `.github/workflows/rails-deploy.yml`, keep these unless the user explicitly changes them:

- **Region:** `us-east-1`
- **ECS cluster:** `strongmind-production`
- **ECS service:** `rails-app`
- **Task definition family:** `rails-app`
- **GitHub secrets:** `AWS_ACCOUNT_ID`, `ECR_REPOSITORY`; optional `SLACK_WEBHOOK_URL`
- **OIDC:** IAM role ARN pattern `arn:aws:iam::<AWS_ACCOUNT_ID>:role/github-actions-deploy` (org must create trust policy for the repo)
- **Migrations:** Exercise states Rails runs migrations at **startup** (entrypoint) — do not add a separate migration job unless the user asks

## Workflow design notes (for debugging)

- **Triggers:** push to `main` (deploy path), push to any branch (CI + local Docker build only), `workflow_dispatch` with optional `environment` (`production` | `staging`).
- **Concurrency:** Scoped to the **`deploy` job** only (`group: deploy-<env>`), so CI/build on feature branches are not serialized globally.
- **Rollback:** Deploy step records **previous task definition revision** before register/update; on stability failure, service is pointed back at that revision.
- **Brakeman:** Fails the job on **High** confidence findings; JSON parsed with `jq` (runner must have `jq` — `ubuntu-latest` does).

## Dockerfile notes (for debugging)

- **Base:** `ruby:3.3-slim` — deliberate **glibc** choice vs Alpine for native gems (`pg`, etc.).
- **Healthcheck:** `GET /up` on port `3000` — assumes Rails 7.1+ default health endpoint; change only if the target app differs.
- **CMD:** `db:prepare` then `rails server` — matches exercise assumption about migrations at startup.

## ADR / observability (for agents)

- **ADR** is opinionated and specific on purpose (sizing, cutover phases, DMS CDC). Trim only if the user wants less verbosity; do not strip required sections from the PDF rubric.
- **FERPA** is intentionally woven into encryption, audit logging, log/PII discipline, and migration risk — preserve unless the user says to remove.

## Conventions for AI edits

1. **Match the exercise:** After substantive changes, mentally check against the PDF sections (triggers, jobs, OIDC, rollback, concurrency, Dockerfile requirements, ADR sections, observability bullets).
2. **Avoid scope creep:** No full Rails app, no Terraform, no extra workflows unless requested.
3. **Prefer clarity over volume:** StrongMind explicitly rewards clear thinking over exhaustive docs.
4. **Secrets:** Never hardcode AWS keys, tokens, or real account IDs. Use placeholders or GitHub/AWS secret references only.
5. **Keep README + AGENTS in sync** if you add new top-level deliverables or rename workflow files.

## Quick “user asked for X” routing

| Request | Likely files |
|---------|----------------|
| Migration / Azure / RDS / cutover | `ADR.md` |
| CI/CD, ECS, ECR, rollback | `.github/workflows/rails-deploy.yml` |
| Container image, prod hardening | `Dockerfile` |
| Metrics, alarms, tracing, logs | `OBSERVABILITY.md` |
| Assumptions, repo tour | `README.md` |

## Verification hints (no mandatory local run)

- **Workflow YAML:** Valid structure, job graph (`test` → `build` → `deploy`), correct `if:` guards, OIDC `permissions: id-token: write`.
- **Dockerfile:** Multi-stage, non-root, `HEALTHCHECK`, production env defaults.

If something fails in real GitHub Actions, the first checks are: OIDC trust policy (repo + ref), IAM role permissions (ECR/ECS/task definition), and whether the ECS service name/cluster match the workflow env vars.
