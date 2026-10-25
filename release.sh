#!/usr/bin/env bash
# Runs `ipvault release publish` (seal here, register with the key service) or, with a package,
# `ipvault release verify`, and turns the result into step outputs and a job summary.
#
# Publishing is refused, by name, where a credential must never be: a pull request from a fork,
# and pull_request_target, which runs with the base repository's secrets and identity beside code
# it did not review. The credential is the CI token, or else the job's OIDC token, which the
# runner hands out when the workflow grants `id-token: write`. Names inside a verified package
# are untrusted, so its report is printed with workflow commands suspended.
set -euo pipefail

out="$RUNNER_TEMP/ipvault-release"
mkdir -p "$out"

if [[ -n "$VERIFY_PACKAGE" ]]; then
  args=(release verify --manifest "$MANIFEST" --package "$VERIFY_PACKAGE" --max-bytes "$MAX_BYTES"
    --json-out "$out/verify.json" --markdown-out "$out/verify.md" --junit-out "$out/verify.junit.xml")
  [[ -n "$RECEIPT" ]] && args+=(--receipt "$RECEIPT")
  stop="ipvault-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  echo "::stop-commands::$stop"
  set +e
  "$IPVAULT_BIN" "${args[@]}"
  code=$?
  set -e
  echo "::$stop::"
  [[ -f "$out/verify.md" ]] && cat "$out/verify.md" >> "$GITHUB_STEP_SUMMARY"
  {
    echo "exit-code=$code"
    echo "passed=$([[ $code == 0 ]] && echo true || echo false)"
    echo "report=$out/verify.json"
    echo "junit=$out/verify.junit.xml"
  } >> "$GITHUB_OUTPUT"
  [[ $code == 1 ]] && echo "::error::the package check failed: plaintext input, missing sealed output, or incomplete archive inspection; see the job summary"
  exit "$code"
fi

refuse() { echo "::error::$1"; echo "exit-code=2" >> "$GITHUB_OUTPUT"; exit 2; }
case "$EVENT_NAME" in
  pull_request_target)
    refuse "refusing to publish from pull_request_target: it runs with this repository's secrets and identity next to code from the pull request. Publish on push to a protected branch or tag." ;;
  pull_request | pull_request_review | pull_request_review_comment)
    [[ -n "$HEAD_REPO" && "$HEAD_REPO" != "$BASE_REPO" ]] \
      && refuse "refusing to publish from a pull request opened from the fork $HEAD_REPO: forks never receive a credential. Run the scan on pull requests and publish on push to a protected branch or tag." ;;
esac
if [[ -n "$IPVAULT_TOKEN" ]]; then
  echo "::add-mask::$IPVAULT_TOKEN"
elif [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  refuse "no credential: grant the job 'permissions: id-token: write' to publish with its OIDC identity (bind this repository to the app first), or set token from a repository or environment secret (e.g. secrets.IPVAULT_TOKEN). Pull requests from forks receive neither."
fi

args=(release publish --manifest "$MANIFEST" --server "$IPVAULT_SERVER" --state-dir "$RUNNER_TEMP/ipvault-state"
  --json-out "$out/receipt.json" --markdown-out "$out/release.md" --junit-out "$out/release.junit.xml")
[[ -n "$OPERATION_ID" ]] && args+=(--operation-id "$OPERATION_ID")
set +e
IPVAULT_TOKEN="$IPVAULT_TOKEN" "$IPVAULT_BIN" "${args[@]}"
code=$?
set -e
echo "exit-code=$code" >> "$GITHUB_OUTPUT"
[[ $code == 0 ]] || exit "$code"

release_id="$(sed -n 's/^ *"release_id": "\(rel_[0-9a-f]*\)",*$/\1/p' "$out/receipt.json" | head -n 1)"
{
  echo "release-id=$release_id"
  echo "receipt=$out/receipt.json"
  echo "report=$out/receipt.json"
  echo "junit=$out/release.junit.xml"
} >> "$GITHUB_OUTPUT"
cat "$out/release.md" >> "$GITHUB_STEP_SUMMARY"
