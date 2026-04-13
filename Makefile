# StrongMind Rails / DevOps — local shortcuts
# Requires: Docker. Optional for Ruby targets: Ruby 3.3 + Bundler on the host.

.DEFAULT_GOAL := help

# --- Docker image ---
IMAGE       ?= strongmind-rails:local
DOCKERFILE  ?= Dockerfile

# --- Local “stack” (Postgres in Docker + app container) ---
NETWORK ?= strongmind-dev
POSTGRES_CONTAINER ?= strongmind-postgres
POSTGRES_IMAGE     ?= postgres:16-alpine
POSTGRES_PORT      ?= 5432
POSTGRES_USER      ?= rails
POSTGRES_PASSWORD ?= rails_dev_password
POSTGRES_DB        ?= rails_development

# App listens on 3000 inside the container; map to host
APP_PORT          ?= 3000
# dev-only; use a real secret in shared envs (min ~32 chars for Rails)
SECRET_KEY_BASE   ?= dev_secret_key_base_change_me_32chars_min________

# Database URL from app container → Postgres container (same Docker network)
DATABASE_URL ?= postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_CONTAINER):5432/$(POSTGRES_DB)

.PHONY: help check-docker network-create network-rm postgres-up postgres-down postgres-wait \
	docker-build docker-run docker-run-detach docker-shell docker-clean \
	test brakeman lint-actions workflow-lint \
	local-deploy clean

help:
	@echo "StrongMind — local Makefile"
	@echo ""
	@echo "Docker (image matches $(DOCKERFILE)):"
	@echo "  make docker-build       Build production image tag $(IMAGE)"
	@echo "  make docker-shell       Interactive shell in $(IMAGE) (debug)"
	@echo "  make docker-clean       Remove local image $(IMAGE)"
	@echo ""
	@echo "Local Postgres (Docker) — for future Rails app:"
	@echo "  make postgres-up        Start Postgres on Docker network $(NETWORK)"
	@echo "  make postgres-wait      Block until Postgres accepts connections"
	@echo "  make postgres-down      Stop/remove Postgres container"
	@echo "  make network-rm         Remove Docker network $(NETWORK)"
	@echo ""
	@echo "Run app container (needs: make docker-build, make postgres-up):"
	@echo "  make docker-run         Foreground; http://localhost:$(APP_PORT)"
	@echo "  make docker-run-detach  Background; same port mapping"
	@echo "  make local-deploy       postgres-up + wait + docker-build + docker-run"
	@echo ""
	@echo "Host Ruby tests (when Gemfile exists):"
	@echo "  make test               bundle exec rspec"
	@echo "  make brakeman           bundle exec brakeman (no-pager)"
	@echo ""
	@echo "CI workflow sanity:"
	@echo "  make lint-actions       Run actionlint on .github/workflows if installed"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean              Stop local app + Postgres, remove image + network"

check-docker:
	@command -v docker >/dev/null 2>&1 || (echo "error: docker not found in PATH" >&2 && exit 1)

network-create: check-docker
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || docker network create $(NETWORK)

network-rm: check-docker
	-docker network rm $(NETWORK) 2>/dev/null || true

postgres-up: network-create check-docker
	@if docker ps -a --format '{{.Names}}' | grep -qx '$(POSTGRES_CONTAINER)'; then \
		echo "Postgres container '$(POSTGRES_CONTAINER)' already exists; starting..."; \
		docker start $(POSTGRES_CONTAINER) 2>/dev/null || true; \
	else \
		docker run -d \
			--name $(POSTGRES_CONTAINER) \
			--network $(NETWORK) \
			-e POSTGRES_USER=$(POSTGRES_USER) \
			-e POSTGRES_PASSWORD=$(POSTGRES_PASSWORD) \
			-e POSTGRES_DB=$(POSTGRES_DB) \
			-p $(POSTGRES_PORT):5432 \
			$(POSTGRES_IMAGE); \
	fi

postgres-wait: check-docker
	@echo "Waiting for Postgres ($(POSTGRES_CONTAINER))..."
	@for i in $$(seq 1 30); do \
		if docker exec $(POSTGRES_CONTAINER) pg_isready -U $(POSTGRES_USER) -d $(POSTGRES_DB) >/dev/null 2>&1; then \
			echo "Postgres is ready."; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "error: Postgres did not become ready in time" >&2; \
	exit 1

postgres-down: check-docker
	-docker stop $(POSTGRES_CONTAINER) 2>/dev/null || true
	-docker rm $(POSTGRES_CONTAINER) 2>/dev/null || true

docker-build: check-docker
	docker build -t $(IMAGE) -f $(DOCKERFILE) .

# Run production-mode container against Dockerized Postgres (same network).
docker-run: check-docker
	docker run --rm -it \
		--network $(NETWORK) \
		-p $(APP_PORT):3000 \
		-e RAILS_ENV=production \
		-e SECRET_KEY_BASE=$(SECRET_KEY_BASE) \
		-e DATABASE_URL="$(DATABASE_URL)" \
		$(IMAGE)

docker-run-detach: check-docker
	docker run -d \
		--name strongmind-rails-local \
		--network $(NETWORK) \
		-p $(APP_PORT):3000 \
		-e RAILS_ENV=production \
		-e SECRET_KEY_BASE=$(SECRET_KEY_BASE) \
		-e DATABASE_URL="$(DATABASE_URL)" \
		$(IMAGE)
	@echo "Running in background as strongmind-rails-local — logs: docker logs -f strongmind-rails-local"

docker-shell: check-docker
	@if [ -z "$$(docker images -q $(IMAGE) 2>/dev/null)" ]; then \
		echo "error: image $(IMAGE) not built; run: make docker-build" >&2; \
		exit 1; \
	fi
	docker run --rm -it --user root --entrypoint /bin/bash $(IMAGE)

docker-clean: check-docker
	-docker rmi $(IMAGE) 2>/dev/null || true

# One-shot local bring-up (blocks on docker-run).
local-deploy: postgres-up postgres-wait docker-build docker-run

test:
	@if [ ! -f Gemfile ]; then \
		echo "No Gemfile in repo yet — add the Rails app, then: bundle install && make test"; \
	else \
		bundle install && bundle exec rspec; \
	fi

brakeman:
	@if [ ! -f Gemfile ]; then \
		echo "No Gemfile in repo yet — add the Rails app first"; \
	else \
		bundle exec brakeman --no-pager; \
	fi

lint-actions workflow-lint:
	@command -v actionlint >/dev/null 2>&1 || (echo "Install actionlint: https://github.com/rhysd/actionlint#installation" >&2 && exit 1)
	actionlint -color .github/workflows/*.yml

clean: check-docker
	-docker stop strongmind-rails-local 2>/dev/null || true
	-docker rm strongmind-rails-local 2>/dev/null || true
	$(MAKE) postgres-down
	$(MAKE) docker-clean
	$(MAKE) network-rm
