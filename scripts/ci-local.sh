#!/usr/bin/env bash
# Reproduce the GitHub Actions CI locally, in the same shape as `.github/workflows/ci.yml`.
#
# Runs each job in a **fresh** `python:3.11-slim` container so the environment
# starts cold — no cached deps, no pre-warmed monotonic clock, no leftover
# `.venv` state. That's how we catch the class of bug (test that only passes on
# machines with a long uptime) that hit us on `test_substep_reporter_always_flushes_final_frame`.
#
# Usage:
#   scripts/ci-local.sh                # all three jobs
#   scripts/ci-local.sh video-api      # only the video-api job
#   scripts/ci-local.sh tts-server     # only the tts-server job
#   scripts/ci-local.sh compose        # only the compose validation
#
# Exit codes:
#   0 = every requested job passed
#   1 = at least one job failed (details printed inline)

set -u
set -o pipefail

RUFF_VERSION="0.15.19"
PYTHON_IMAGE="python:3.11-slim"

# The workflow lists these two values in env: at the top; keep them in sync.
readonly RUFF_VERSION PYTHON_IMAGE

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# Terminal colours degrade gracefully on non-TTY output.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold)"; DIM="$(tput dim)"; RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; RESET="$(tput sgr0)"
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

log()   { printf '%s\n' "${BLUE}${BOLD}▸ $*${RESET}"; }
warn()  { printf '%s\n' "${YELLOW}${BOLD}⚠ $*${RESET}"; }
ok()    { printf '%s\n' "${GREEN}${BOLD}✓ $*${RESET}"; }
fail()  { printf '%s\n' "${RED}${BOLD}✗ $*${RESET}"; }

need_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        fail "docker is required (install docker + start the daemon)"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "docker daemon is not reachable"
        exit 1
    fi
}

# Run a Python job (video-api / tts-server) in a throw-away container, matching
# the CI steps 1:1. Args: <job-label> <working-subdir>
run_python_job() {
    local job_label="$1"; shift
    local workdir="$1"; shift

    log "job: ${BOLD}${job_label}${RESET} ${DIM}(fresh ${PYTHON_IMAGE} container)${RESET}"

    # Source mounted read-only under /src, then copied into /work so pip can
    # create egg-info and pytest can drop caches without touching the host.
    # We copy the WHOLE repo (not just the sub-project) because some tests
    # reference sibling paths like `../../docs/boilerplate/...` and
    # `../../videos/linux-fondamentaux/...`. That's how GitHub Actions sees
    # the tree after actions/checkout@v4.
    docker run --rm \
        --workdir "/work/${workdir}" \
        --volume "${REPO_ROOT}:/src:ro" \
        --env "PIP_DISABLE_PIP_VERSION_CHECK=1" \
        --env "PIP_ROOT_USER_ACTION=ignore" \
        --env "RUFF_VERSION=${RUFF_VERSION}" \
        --env "WORKDIR=${workdir}" \
        "${PYTHON_IMAGE}" \
        bash -eu -o pipefail -c '
            printf "%s\n" "-- python: $(python --version 2>&1)"
            printf "%s\n" "-- uptime (host-shared kernel clock, informational):"
            cat /proc/uptime 2>/dev/null || true
            echo
            # Copy the versioned tree only — skip .git and .venv/node_modules
            # so the container is fast to start and its cache doesnt drift
            # from a stray file. Rsync with --exclude is safer than a bare cp
            # because it wont chase symlinks out of tree.
            apt-get update -qq >/dev/null && apt-get install -y --no-install-recommends -qq rsync >/dev/null
            mkdir -p /work
            # Match what actions/checkout sees: tracked files only, no local
            # ignored artefacts (.env with real API keys, .venv, node_modules,
            # etc.). Env-sensitive tests otherwise pick up the operators
            # OPENAI_BASE_URL / OPENAI_API_KEY and fail.
            rsync -a --delete \
                --exclude ".git" \
                --exclude ".env" \
                --exclude ".env.*" \
                --exclude "**/.env" \
                --exclude "**/.env.*" \
                --exclude "**/.venv" \
                --exclude "**/node_modules" \
                --exclude "**/__pycache__" \
                --exclude "**/.pytest_cache" \
                --exclude "**/dist" \
                --exclude "**/build" \
                --exclude "**/*.egg-info" \
                --exclude "**/uv.lock" \
                /src/ /work/
            cd "/work/${WORKDIR}"
            python -m pip install --quiet --upgrade pip
            pip install --quiet -e ".[test]" "ruff==${RUFF_VERSION}"
            echo "-- ruff check src tests"
            ruff check src tests
            echo "-- py_compile"
            python -m py_compile $(find src tests -name "*.py" -print)
            echo "-- pytest"
            pytest -q tests
        '
}

# `compose · validation` in the workflow: docker compose config on both stacks.
run_compose_job() {
    log "job: ${BOLD}compose${RESET} ${DIM}(local docker compose)${RESET}"
    (
        cd "${REPO_ROOT}"
        docker compose config --quiet
    )
    (
        cd "${REPO_ROOT}"
        docker compose -f apps/tts-server/compose.yaml config --quiet
    )
}

# Run one job, catching its exit code so we always attempt the rest.
run_one() {
    local job="$1"
    local rc=0
    case "$job" in
        video-api)   run_python_job "video-api"  "apps/video-api"  || rc=$? ;;
        tts-server)  run_python_job "tts-server" "apps/tts-server" || rc=$? ;;
        compose)     run_compose_job                                 || rc=$? ;;
        *)
            fail "unknown job: ${job}"
            printf 'available: video-api, tts-server, compose\n'
            exit 2
            ;;
    esac
    if [[ $rc -eq 0 ]]; then
        ok "${job} passed"
    else
        fail "${job} failed (exit ${rc})"
    fi
    return $rc
}

main() {
    need_docker

    local -a jobs
    if [[ $# -eq 0 ]]; then
        jobs=(compose video-api tts-server)
    else
        jobs=("$@")
    fi

    local overall=0
    local job
    for job in "${jobs[@]}"; do
        printf '\n'
        run_one "$job" || overall=1
    done

    printf '\n'
    if [[ $overall -eq 0 ]]; then
        ok "all requested jobs passed"
    else
        fail "one or more jobs failed"
    fi
    exit $overall
}

main "$@"
