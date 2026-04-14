# ==============================================================================
# Base image choice: ruby:3.3-slim (Debian Bookworm)
#
# Tradeoff: slim vs alpine
# - alpine is ~30 MB smaller but uses musl libc, which causes subtle issues
#   with native gem extensions (nokogiri, pg, grpc) and .so linking at runtime.
# - slim provides glibc compatibility, faster gem installs, and fewer runtime
#   surprises in production — worth the ~30 MB tradeoff for a team-wide standard.
# ==============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder — install gems, precompile assets
# ---------------------------------------------------------------------------
FROM ruby:3.3-slim AS builder

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libpq-dev \
      pkg-config \
      nodejs \
      yarn && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH="/usr/local/bundle"

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs=$(nproc) && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

# Precompile assets. SECRET_KEY_BASE is required by the Rails initializer but
# the real value is injected at runtime via Secrets Manager / ECS task env.
RUN SECRET_KEY_BASE=precompile_placeholder \
    bin/rails assets:precompile && \
    rm -rf tmp/cache vendor/assets lib/assets node_modules

# ---------------------------------------------------------------------------
# Stage 2: Runtime — lean production image
# ---------------------------------------------------------------------------
FROM ruby:3.3-slim AS runtime

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libpq5 \
      curl && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for security (UID 1000 avoids permission issues with volumes)
RUN groupadd --gid 1000 rails && \
    useradd --uid 1000 --gid rails --shell /bin/bash --create-home rails

WORKDIR /app

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH="/usr/local/bundle" \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1 \
    PORT=3000

# Copy gems from builder
COPY --from=builder --chown=rails:rails /usr/local/bundle /usr/local/bundle

# Copy application code and precompiled assets
COPY --from=builder --chown=rails:rails /app /app

USER rails

EXPOSE 3000

# Health check: hit the Rails health endpoint every 30s.
# start-period gives the app time to boot before checks begin.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3000/up || exit 1

# db:prepare handles both db:create (if needed) and db:migrate, making the
# entrypoint safe for first deploy and subsequent deploys alike.
CMD ["sh", "-c", "bin/rails db:prepare && exec bin/rails server -b 0.0.0.0 -p ${PORT}"]
