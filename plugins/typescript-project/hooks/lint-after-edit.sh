#!/bin/bash
# PostToolUse Hook: ESLint Check (warn-only, no auto-fix)
# Reports lint issues to Claude without modifying files

set -euo pipefail

input=$(cat)

event=$(echo "$input" | jq -r '.hook_event_name // empty')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only process PostToolUse on Edit/Write
if [ "$event" != "PostToolUse" ] || [ "$tool_name" != "Edit" ] && [ "$tool_name" != "Write" ]; then
  exit 0
fi

# Only validate TS/TSX files (skip JS - this is a TypeScript plugin)
if ! [[ "$file_path" =~ \.(ts|tsx)$ ]]; then
  exit 0
fi

[ ! -f "$file_path" ] && exit 0

# Find project root
find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    [ -f "$dir/package.json" ] && echo "$dir" && return 0
    dir=$(dirname "$dir")
  done
  echo "$PWD"
}

PROJECT_ROOT=$(find_project_root)

# Early exit: no ESLint config = skip
[ ! -f "$PROJECT_ROOT/.eslintrc.js" ] && \
[ ! -f "$PROJECT_ROOT/.eslintrc.json" ] && \
[ ! -f "$PROJECT_ROOT/.eslintrc.cjs" ] && \
[ ! -f "$PROJECT_ROOT/eslint.config.js" ] && \
[ ! -f "$PROJECT_ROOT/eslint.config.mjs" ] && exit 0

# Check ESLint available
[ ! -f "$PROJECT_ROOT/node_modules/.bin/eslint" ] && ! command -v eslint &>/dev/null && exit 0

# Detect package manager
PM="npm"
[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ] && PM="pnpm"
[ -f "$PROJECT_ROOT/yarn.lock" ] && PM="yarn"

eslint_cmd="npx eslint"
[ "$PM" != "npm" ] && eslint_cmd="$PM exec eslint"

# Run ESLint (NO --fix, just check)
result=$($eslint_cmd "$file_path" --format json 2>/dev/null || echo "[]")

# Parse results
error_count=$(echo "$result" | jq -r '.[0].errorCount // 0')
warning_count=$(echo "$result" | jq -r '.[0].warningCount // 0')

# Build response
if [ "$error_count" -gt 0 ]; then
  # Errors - inform Claude (don't block, let Claude decide)
  error_details=$(echo "$result" | jq -r '.[0].messages[] | select(.severity == 2) | "  L\(.line): \(.message) (\(.ruleId))"' | head -8)

  msg="⚠️ ESLint errors in $(basename "$file_path"):\n$error_details"

  echo "{\"systemMessage\": \"$msg\"}"
  exit 0

elif [ "$warning_count" -gt 0 ]; then
  # Warnings only - inform
  warning_details=$(echo "$result" | jq -r '.[0].messages[] | select(.severity == 1) | "  L\(.line): \(.message) (\(.ruleId))"' | head -5)

  msg="⚠️ ESLint warnings in $(basename "$file_path"):\n$warning_details"

  echo "{\"systemMessage\": \"$msg\"}"
  exit 0
fi

# Clean - silent (no output = no resource waste)
exit 0
