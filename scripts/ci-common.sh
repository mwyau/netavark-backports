#!/usr/bin/env bash
# Shared GitHub Actions orchestration. Outputs remain in the workspace.
set -Eeuo pipefail

ci_require() {
  local key
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || { echo "Missing required environment: $key" >&2; exit 2; }
  done
  [[ -d "$GITHUB_WORKSPACE/tests" ]] || {
    echo "Missing checked-out tests in GITHUB_WORKSPACE" >&2; exit 2;
  }
}

ci_container() {
  local mode="$1" image="$2"
  shift 2
  local -a options=(--rm --pull=always -v "$GITHUB_WORKSPACE:/work" -w /work)
  if [[ "$mode" == runtime ]]; then
    options+=(--privileged --security-opt seccomp=unconfined)
  elif [[ "$mode" != build ]]; then
    echo "Invalid container mode: $mode" >&2; return 2
  fi
  # Keep all docker options before IMAGE, then execute bash inside image.
  local -a extra=()
  while [[ $# -gt 0 && "$1" != bash ]]; do extra+=("$1"); shift; done
  [[ "${1:-}" == bash ]] || { echo "Missing bash command" >&2; return 2; }
  docker run "${options[@]}" "${extra[@]}" "$image" "$@"
}

ci_release_upload_if_main() {
  if [[ "${GITHUB_REF:-}" == refs/heads/main &&
        ( "${GITHUB_EVENT_NAME:-}" == push || "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ) ]]; then
    bash "$GITHUB_WORKSPACE/scripts/ci-release.sh" upload "$1"
  else
    echo "PR/non-main build: candidate validated but NOT published"
  fi
}
