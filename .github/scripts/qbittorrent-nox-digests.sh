#!/usr/bin/env bash
# Compare the Dockerfile's qBittorrent-nox SHA-256 pins with the assets
# userdocs publishes for that same release tag.
#
# check              exit 0 when they match, 2 when they differ
# release-preflight  check, and on a mismatch dispatch the updater workflow
# verify             download the assets, check digests, attest, and --version
# update             verify, then open or update a pull request with new pins
#
# The updater runs with GITHUB_TOKEN. Pull requests opened that way do not
# trigger pull_request workflows, so update dispatches CI explicitly.
set -euo pipefail

upstream_repo=userdocs/qbittorrent-nox-static
bot_branch=update-qbittorrent-nox-digests
updater_workflow=update-qbittorrent-digests.yml
ci_workflow=ci.yml

tmp=

cleanup() {
  if [[ -n "${tmp:-}" && -d "${tmp}/wt" ]]; then
    git worktree remove --force "${tmp}/wt" >/dev/null 2>&1 || true
  fi
  if [[ -n "${tmp:-}" ]]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

usage() {
  echo "usage: $0 check|release-preflight|verify|update" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "${script_dir}/../.."

make_tmp() {
  if [[ -z "$tmp" ]]; then
    tmp=$(mktemp -d)
  fi
}

read_pins() {
  local file=$1
  release=$(sed -nE 's/^ARG QBITTORRENT_NOX_RELEASE=([[:graph:]]+)$/\1/p' "$file")
  release_arm=$(sed -nE 's/^ARG QBITTORRENT_NOX_RELEASE_ARM64=([[:graph:]]+)$/\1/p' "$file")
  pin_amd64=$(sed -nE 's/^ARG QBITTORRENT_NOX_SHA256_AMD64=([a-f0-9]+)$/\1/p' "$file")
  pin_arm64=$(sed -nE 's/^ARG QBITTORRENT_NOX_SHA256_ARM64=([a-f0-9]+)$/\1/p' "$file")
  if [[ -z "$release" || -z "$release_arm" || -z "$pin_amd64" || -z "$pin_arm64" ]]; then
    echo "Could not parse qBittorrent pins from ${file}" >&2
    exit 1
  fi
  if [[ "$release" != "$release_arm" ]]; then
    echo "qBittorrent release pins diverged: amd64=${release} arm64=${release_arm}" >&2
    exit 1
  fi
}

normalize_digest() {
  local value=${1#sha256:}
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

require_digest() {
  local label=$1 value=$2
  if [[ ! "$value" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Unexpected ${label} digest from GitHub: ${value}" >&2
    exit 1
  fi
}

fetch_release() {
  local release_json digest_amd64 digest_arm64
  release_json=$(gh api "repos/${upstream_repo}/releases/tags/${release}")
  digest_amd64=$(jq -er '.assets[] | select(.name == "x86_64-qbittorrent-nox") | .digest' <<<"$release_json") \
    || { echo "Release ${release} is missing x86_64-qbittorrent-nox" >&2; exit 1; }
  digest_arm64=$(jq -er '.assets[] | select(.name == "aarch64-qbittorrent-nox") | .digest' <<<"$release_json") \
    || { echo "Release ${release} is missing aarch64-qbittorrent-nox" >&2; exit 1; }
  updated_amd64=$(jq -er '.assets[] | select(.name == "x86_64-qbittorrent-nox") | .updated_at' <<<"$release_json")
  updated_arm64=$(jq -er '.assets[] | select(.name == "aarch64-qbittorrent-nox") | .updated_at' <<<"$release_json")
  published_amd64=$(normalize_digest "$digest_amd64")
  published_arm64=$(normalize_digest "$digest_arm64")
  require_digest x86_64 "$published_amd64"
  require_digest aarch64 "$published_arm64"
}

print_mismatch() {
  cat >&2 <<EOF
Pinned SHA-256 for ${upstream_repo} ${release} does not match the published release assets.
The ${updater_workflow} workflow opens a pull request with the new pins.
Re-run Release after that pull request merges.

x86_64 pin:        ${pin_amd64}
x86_64 published:  ${published_amd64} (asset updated ${updated_amd64})
aarch64 pin:       ${pin_arm64}
aarch64 published: ${published_arm64} (asset updated ${updated_arm64})
EOF
}

pins_match() {
  [[ "$pin_amd64" == "$published_amd64" && "$pin_arm64" == "$published_arm64" ]]
}

check() {
  read_pins "${DOCKERFILE:-Dockerfile}"
  fetch_release
  if pins_match; then
    echo "qBittorrent-nox digests match ${release}"
    return 0
  fi
  print_mismatch
  return 2
}

release_preflight() {
  local code=0
  check || code=$?
  if [[ "$code" -eq 0 ]]; then
    return 0
  fi
  if [[ "$code" -ne 2 ]]; then
    exit "$code"
  fi
  echo "Dispatching ${updater_workflow}." >&2
  gh workflow run "$updater_workflow" --ref main
  echo "Dispatched ${updater_workflow}. Re-run Release after its pull request merges." >&2
  exit 1
}

download_asset() {
  local name=$1
  curl -fsSL -o "${tmp}/${name}" \
    "https://github.com/${upstream_repo}/releases/download/${release}/${name}"
}

check_attestation() {
  local digest=$1 file=$2 label=$3
  local err code
  attest_result=
  err=${tmp}/attest.err
  set +e
  gh api "repos/${upstream_repo}/attestations/sha256:${digest}" >"${tmp}/attest.json" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 0 ]]; then
    gh attestation verify "$file" --owner userdocs
    attest_result=verified
    return 0
  fi
  if grep -Eq 'HTTP 404|Not Found' "$err" || grep -Eq '"status": *"404"' "${tmp}/attest.json"; then
    echo "No GitHub artifact attestations published for ${label}; skipping verification."
    attest_result=skipped
    return 0
  fi
  echo "Failed to read artifact attestations for ${label}" >&2
  cat "$err" >&2
  exit 1
}

verify_assets() {
  local checksums qbt_from_tag
  make_tmp
  download_asset x86_64-qbittorrent-nox
  download_asset aarch64-qbittorrent-nox
  download_asset dependency-version.json
  checksums=$(
    printf '%s  %s\n' "$published_amd64" "${tmp}/x86_64-qbittorrent-nox"
    printf '%s  %s\n' "$published_arm64" "${tmp}/aarch64-qbittorrent-nox"
  )
  sha256sum -c <<<"$checksums"

  check_attestation "$published_amd64" "${tmp}/x86_64-qbittorrent-nox" x86_64-qbittorrent-nox
  attest_amd64=$attest_result
  check_attestation "$published_arm64" "${tmp}/aarch64-qbittorrent-nox" aarch64-qbittorrent-nox
  attest_arm64=$attest_result

  chmod +x "${tmp}/x86_64-qbittorrent-nox"
  version_output=$("${tmp}/x86_64-qbittorrent-nox" --version)
  printf '%s\n' "$version_output"
  qbt_from_tag=$(sed -nE 's/^release-([0-9]+\.[0-9]+\.[0-9]+)_v.*/\1/p' <<<"$release")
  if [[ -z "$qbt_from_tag" || "$version_output" != *"$qbt_from_tag"* ]]; then
    echo "x86_64-qbittorrent-nox --version does not report ${qbt_from_tag:-the pinned release}" >&2
    exit 1
  fi
}

verify() {
  read_pins "${DOCKERFILE:-Dockerfile}"
  fetch_release
  verify_assets
  echo "Verified ${release}: amd64 attestation ${attest_amd64}, arm64 attestation ${attest_arm64}"
}

required_check_count() {
  gh api "repos/${GITHUB_REPOSITORY}/branches/main" --jq '
    [ (.protection.required_status_checks.checks // [])[].context ] | unique | length
  '
}

write_pr_body() {
  local fence='```'
  if grep -q '```' "${tmp}/dependency-version.json"; then
    fence='````'
  fi
  {
    echo "## Summary"
    echo
    echo "The published \`${upstream_repo}\` assets for \`${release}\` were replaced under the same tag. This updates the Dockerfile SHA-256 pins."
    echo
    echo "| Arch | Previous pin | Published digest | Asset updated at |"
    echo "| --- | --- | --- | --- |"
    echo "| x86_64 | \`${old_amd64}\` | \`${published_amd64}\` | \`${updated_amd64}\` |"
    echo "| aarch64 | \`${old_arm64}\` | \`${published_arm64}\` | \`${updated_arm64}\` |"
    echo
    echo "## Verification"
    echo
    echo "- Downloaded each asset and checked sha256 against the GitHub release asset digest."
    echo "- \`x86_64-qbittorrent-nox --version\` reported \`${version_output}\`."
    echo "- GitHub artifact attestation for x86_64: ${attest_amd64}."
    echo "- GitHub artifact attestation for aarch64: ${attest_arm64}."
    echo
    echo "## dependency-version.json"
    echo
    echo "GitHub replaces this release asset in place, so the previous file is not available to diff. Upstream merges every libtorrent track into this one file."
    echo
    echo "${fence}json"
    cat "${tmp}/dependency-version.json"
    echo
    echo "${fence}"
    echo
    if [[ "$required_checks" -gt 0 ]]; then
      echo "Squash auto-merge is enabled. It merges after the required CI checks pass."
    else
      echo "Auto-merge was not enabled. \`main\` has no required status checks, so squash auto-merge would merge this pull request before CI finishes."
      echo "Add the CI jobs as required status checks and keep Allow auto-merge enabled. The next run enables squash auto-merge."
    fi
  } >"${tmp}/pr-body.md"
}

sync_branch() {
  local work=$1
  git fetch origin main
  if git ls-remote --exit-code --heads origin "$bot_branch" >/dev/null; then
    git fetch origin "+refs/heads/${bot_branch}:refs/remotes/origin/${bot_branch}"
    git worktree add -B "$bot_branch" "$work" "origin/${bot_branch}"
    git -C "$work" merge origin/main --no-edit
  else
    git worktree add -b "$bot_branch" "$work" origin/main
  fi

  sed -i -E "s/^(ARG QBITTORRENT_NOX_SHA256_AMD64=)[a-f0-9]+$/\\1${published_amd64}/" "${work}/Dockerfile"
  sed -i -E "s/^(ARG QBITTORRENT_NOX_SHA256_ARM64=)[a-f0-9]+$/\\1${published_arm64}/" "${work}/Dockerfile"
  read_pins "${work}/Dockerfile"
  if ! pins_match; then
    echo "Failed to write the published digests into the Dockerfile" >&2
    exit 1
  fi

  git -C "$work" add Dockerfile
  if git -C "$work" diff --cached --quiet; then
    echo "Branch already has the published digests"
  else
    git -C "$work" \
      -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit -m "Update qBittorrent-nox digests for ${release}"
  fi
  git -C "$work" push origin "HEAD:refs/heads/${bot_branch}"
}

upsert_pr() {
  local title pr
  title="Update qBittorrent-nox digests for ${release}"
  pr=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$bot_branch" --base main --state open --json number --jq '.[0].number // empty')
  if [[ -z "$pr" ]]; then
    gh pr create \
      --repo "$GITHUB_REPOSITORY" \
      --base main \
      --head "$bot_branch" \
      --title "$title" \
      --body-file "${tmp}/pr-body.md" >&2
    pr=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$bot_branch" --base main --state open --json number --jq '.[0].number')
  else
    gh pr edit "$pr" --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "${tmp}/pr-body.md" >&2
  fi
  printf '%s\n' "$pr"
}

dispatch_ci() {
  local sha count
  sha=$(git -C "$1" rev-parse HEAD)
  count=$(gh run list \
    --repo "$GITHUB_REPOSITORY" \
    --workflow "$ci_workflow" \
    --branch "$bot_branch" \
    --limit 20 \
    --json headSha \
    --jq "[.[] | select(.headSha == \"${sha}\")] | length")
  if [[ "$count" -eq 0 ]]; then
    gh workflow run "$ci_workflow" --repo "$GITHUB_REPOSITORY" --ref "$bot_branch"
    echo "Dispatched ${ci_workflow} for ${sha}"
  else
    echo "CI already exists for ${sha}"
  fi
}

enable_automerge() {
  local pr=$1 enabled
  if [[ "$required_checks" -eq 0 ]]; then
    echo "Skipped auto-merge because main has no required status checks"
    return 0
  fi
  if gh pr merge "$pr" --repo "$GITHUB_REPOSITORY" --auto --squash; then
    echo "Enabled squash auto-merge on pull request ${pr}"
    return 0
  fi
  enabled=$(gh pr view "$pr" --repo "$GITHUB_REPOSITORY" --json autoMergeRequest --jq '.autoMergeRequest != null')
  if [[ "$enabled" == "true" ]]; then
    echo "Squash auto-merge was already enabled on pull request ${pr}"
    return 0
  fi
  echo "Could not enable squash auto-merge on pull request ${pr}" >&2
  exit 1
}

update() {
  local work pr
  if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "update requires GITHUB_REPOSITORY" >&2
    exit 1
  fi
  make_tmp
  git fetch origin main
  git show origin/main:Dockerfile >"${tmp}/main.Dockerfile"
  read_pins "${tmp}/main.Dockerfile"
  old_amd64=$pin_amd64
  old_arm64=$pin_arm64
  fetch_release
  if pins_match; then
    echo "qBittorrent-nox digests on main already match ${release}"
    return 0
  fi
  verify_assets
  required_checks=$(required_check_count)
  required_checks=${required_checks:-0}
  write_pr_body
  work=${tmp}/wt
  sync_branch "$work"
  pr=$(upsert_pr)
  dispatch_ci "$work"
  enable_automerge "$pr"
}

case "${1:-}" in
  check) check ;;
  release-preflight) release_preflight ;;
  verify) verify ;;
  update) update ;;
  *) usage ;;
esac
