#!/bin/bash
# PostToolUse Hook: Prettier Auto-format
# Runs Prettier --write and only reports if file changed

set -euo pipefail

input=$(cat)

event=$(echo "$input" | jq -r '.hook_event_name // empty')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only process PostToolUse on Edit/Write
if [ "$event" != "PostToolUse" ] || [ "$tool_name" != "Edit" ] && [ "$tool_name" != "Write" ]; then
  exit 0
fi

[ ! -f "$file_path" ] && exit 0

# Only format certain file types
if ! [[ "$file_path" =~ \.(ts|tsx|js|jsx|json|css|scss|md|html)$ ]]; then
  exit 0
fi

# Skip build directories
[[ "$file_path" =~ (node_modules|dist|build|\.next|coverage) ]] && exit 0

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

# Check Prettier available
[ ! -f "$PROJECT_ROOT/node_modules/.bin/prettier" ] && ! command -v prettier &>/dev/null && exit 0

# Detect package manager
PM="npm"
[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ] && PM="pnpm"
[ -f "$PROJECT_ROOT/yarn.lock" ] && PM="yarn"

prettier_cmd="npx prettier"
[ "$PM" = "pnpm" ] && prettier_cmd="pnpm exec prettier"
[ "$PM" = "yarn" ] && prettier_cmd="yarn prettier"

# Save original to compare
original=$(cat "$file_path")

# Format
$prettier_cmd --write "$file_path" &>/dev/null || exit 0

# Only report if changed
if [ "$original" != "$(cat "$file_path")" ]; then
  echo "{\"systemMessage\": \"✅ Formatted: $(basename "$file_path")\"}"
fi

exit 0
