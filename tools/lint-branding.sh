#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

# Assistant/tool/vendor branding gate.
#
# Enforces the AGENTS.md rule that no assistant, tool, vendor, or workflow
# branding may appear in branch names, pull request titles or bodies, commit
# messages, documentation, or generated artifacts. The rule is checked into the
# repository, so it is enforced by CI rather than left to contributor (or agent)
# diligence -- the same stance the byte-compile (#415) and portable (#421) lint
# gates take for their concerns.
#
# Two pattern tiers keep false positives near zero on this repository's own
# domain language, which legitimately mentions some of these words:
#
#   * Self-attribution markers (TIER A) are scanned everywhere -- tracked file
#     contents, commit messages, the PR title/body, and the branch name. These
#     are unambiguous "made by a tool" signals (a `Co-authored-by:` trailer
#     naming a model/tool, a "Generated with/by <tool>" line, a session URL, the
#     robot emoji). They have no legitimate use and are verified absent from the
#     tree.
#
#   * Bare vendor/tool slugs (TIER B) are scanned ONLY in metadata contexts
#     (commit messages, PR title/body, branch name), never in file contents,
#     because the repository legitimately writes some vendor words in prose:
#     `CLAUDE.md` is a checked-in tool-config file, `docs/references.md` cites
#     Anthropic's published papers, and "cursor" is this project's own word for
#     the shared stdin cursor. The slug set is therefore deliberately narrow
#     (claude, codex, copilot, chatgpt, devin) and excludes words with a
#     legitimate technical use here (notably "openai", as in the shipped
#     OpenAI-compatible transport, "anthropic", "cursor", and bare model words).
#
# This script's own source is excluded from the file-content scan because it
# necessarily spells the patterns out. Inputs from the CI event are passed in
# through the environment:
#
#   CONSENT_BRANDING_BASE    base ref/sha for the commit range (default origin/main)
#   CONSENT_BRANDING_HEAD    head ref/sha for the commit range (default HEAD)
#   CONSENT_BRANDING_BRANCH  branch name to scan (default: current branch)
#   CONSENT_PR_TITLE         pull request title to scan (optional)
#   CONSENT_PR_BODY          pull request body to scan (optional)

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_root"

# TIER A -- self-attribution markers (ASCII), scanned in files and metadata.
attribution_re='co-authored-by:.*(claude|anthropic|codex|copilot|chatgpt|openai|gpt|gemini|llama|devin|cursor)|generated[ _-]+(with|by).*(claude|anthropic|codex|copilot|chatgpt|cursor|gpt|gemini|devin)|claude\.(ai|com)|claude[-_]session'

# TIER B -- bare vendor/tool slugs (ASCII), scanned in metadata contexts only.
slug_re='\b(claude|codex|copilot|chatgpt|devin)\b|claude[ ._-]?(code|opus|sonnet|haiku)'

# The robot emoji is checked as a fixed string so the scan never depends on the
# grep locale handling multibyte regex classes.
robot_emoji='🤖'

# Violations are accumulated in a shared file rather than a variable so counts
# survive the pipeline subshells the scanners run in (POSIX sh runs each side of
# a pipe in a subshell, so a piped `report` cannot mutate a parent counter).
violations=$(mktemp)
trap 'rm -f "$violations"' EXIT INT TERM

report() {
  # report CONTEXT < matches-on-stdin
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'branding violation [%s]: %s\n' "$1" "$line" >> "$violations"
  done
}

scan_text() {
  # scan_text CONTEXT TEXT REGEX -- flag REGEX or the robot emoji in TEXT.
  context=$1
  text=$2
  regex=$3
  printf '%s\n' "$text" | grep -niE "$regex" | report "$context" || true
  printf '%s\n' "$text" | grep -nF "$robot_emoji" | report "$context" || true
}

# --- Tracked file contents (TIER A only) ----------------------------------
file_matches=$(
  git grep -nIiE -e "$attribution_re" -- \
    ':!tools/lint-branding.sh' ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.svg' \
    2>/dev/null || true
)
if [ -n "$file_matches" ]; then
  printf '%s\n' "$file_matches" | report "tracked file"
fi
emoji_matches=$(
  git grep -nIF -e "$robot_emoji" -- \
    ':!tools/lint-branding.sh' ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.svg' \
    2>/dev/null || true
)
if [ -n "$emoji_matches" ]; then
  printf '%s\n' "$emoji_matches" | report "tracked file"
fi

# --- Commit messages on the branch (TIER A + TIER B) ----------------------
base=${CONSENT_BRANDING_BASE:-}
head=${CONSENT_BRANDING_HEAD:-HEAD}
if [ -z "$base" ] && git rev-parse --verify --quiet origin/main >/dev/null 2>&1
then
  base=origin/main
fi
if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
  range="$base..$head"
else
  range=""
fi
if [ -n "$range" ]; then
  for sha in $(git rev-list "$range" 2>/dev/null || true); do
    message=$(git log -1 --format='%B' "$sha")
    scan_text "commit $sha" "$message" "$attribution_re|$slug_re"
  done
fi

# --- Branch name (TIER A + TIER B) ----------------------------------------
branch=${CONSENT_BRANDING_BRANCH:-}
if [ -z "$branch" ]; then
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi
if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
  scan_text "branch name" "$branch" "$attribution_re|$slug_re"
fi

# --- Pull request title and body (TIER A + TIER B) ------------------------
if [ -n "${CONSENT_PR_TITLE:-}" ]; then
  scan_text "PR title" "$CONSENT_PR_TITLE" "$attribution_re|$slug_re"
fi
if [ -n "${CONSENT_PR_BODY:-}" ]; then
  scan_text "PR body" "$CONSENT_PR_BODY" "$attribution_re|$slug_re"
fi

if [ -s "$violations" ]; then
  sort -u "$violations" >&2
  count=$(sort -u "$violations" | wc -l | tr -d ' ')
  printf '\nbranding gate failed: %s match(es). See AGENTS.md: no assistant, tool, vendor, or workflow branding in branch names, PR titles/bodies, commit messages, docs, or artifacts.\n' \
    "$count" >&2
  exit 1
fi

printf 'branding gate passed: no assistant/tool/vendor branding found.\n'
