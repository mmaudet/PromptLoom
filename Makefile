.DEFAULT_GOAL := help

.PHONY: help doctor config start up down status health logs test test-tts ci ci-video-api ci-tts-server ci-compose

help:
	@echo "PromptLoom"
	@echo "  make doctor    Check Docker and validate the Compose stack (no build)"
	@echo "  make start     Build and start PromptLoom in the background"
	@echo "  make up        Build and run PromptLoom in the foreground"
	@echo "  make status    Show service state"
	@echo "  make health    Query the API health endpoint"
	@echo "  make logs      Follow API and worker logs"
	@echo "  make down      Stop the stack without deleting volumes"
	@echo "  make test      Run video-api tests"
	@echo "  make test-tts  Run the optional TTS server tests"
	@echo "  make ci        Reproduce the GitHub Actions CI locally (fresh containers)"

# `make ci` is a local mirror of .github/workflows/ci.yml — runs ruff, py_compile
# and pytest inside a fresh python:3.11-slim container so cold-CI regressions
# (fresh venv, small monotonic clock, no local caches) are caught before push.
ci:
	@bash scripts/ci-local.sh
ci-video-api:
	@bash scripts/ci-local.sh video-api
ci-tts-server:
	@bash scripts/ci-local.sh tts-server
ci-compose:
	@bash scripts/ci-local.sh compose

doctor:
	@command -v docker >/dev/null || { echo "Docker is not installed or not in PATH"; exit 1; }
	@version="$$(docker compose version --short | sed 's/^v//')"; \
	major="$${version%%.*}"; rest="$${version#*.}"; minor="$${rest%%.*}"; \
	if [ "$$major" -lt 2 ] || { [ "$$major" -eq 2 ] && [ "$$minor" -lt 20 ]; }; then \
		echo "Docker Compose >= 2.20 is required (found $$version)"; exit 1; \
	fi; \
	echo "Docker Compose $$version"
	@docker compose config --quiet
	@echo "PromptLoom preflight: OK"

config:
	docker compose config --quiet

start:
	docker compose up --build -d

up:
	docker compose up --build

down:
	docker compose down

status:
	docker compose ps

health:
	@curl -fsS http://localhost:8080/healthz
	@echo

logs:
	docker compose logs -f worker api

test:
	docker compose run --rm test

test-tts:
	docker compose -f apps/tts-server/compose.yaml run --rm test
