#!/bin/bash
# PostToolUse Hook: TypeScript Type Checking with Debounce
# Runs tsc --noEmit but debounced to avoid spamming on rapid edits

set -euo pipefail

input=$(cat)

event=$(echo "$input" | jq -r '.hook_event_name // empty')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only process PostToolUse on Edit/Write
if [ "$event" != "PostToolUse" ] || [ "$tool_name" != "Edit" ] && [ "$tool_name" != "Write" ]; then
  exit 0
fi

# Only validate TypeScript files
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
STATE_DIR="$PROJECT_ROOT/.claude/state"
mkdir -p "$STATE_DIR"

# Early exit: no tsconfig = not a TS project
[ ! -f "$PROJECT_ROOT/tsconfig.json" ] && \
[ ! -f "$PROJECT_ROOT/tsconfig.app.json" ] && exit 0

# Check TypeScript available
[ ! -f "$PROJECT_ROOT/node_modules/.bin/tsc" ] && ! command -v tsc &>/dev/null && exit 0

# Find tsconfig
tsconfig="$PROJECT_ROOT/tsconfig.json"
[ -f "$PROJECT_ROOT/tsconfig.app.json" ] && tsconfig="$PROJECT_ROOT/tsconfig.app.json"

# Debounce: don't run if ran recently (within 30 seconds)
TIMESTAMP_FILE="$STATE_DIR/last-typecheck"
COOLDOWN_SECONDS=30

if [ -f "$TIMESTAMP_FILE" ]; then
  # Get current time and last run time
  current_time=$(date +%s 2>/dev/null || echo "0")

  # Try to read last timestamp (handle different date commands)
  if [ -n "$BASH_VERSION" ]; then
    last_run=$(cat "$TIMESTAMP_FILE" 2>/dev/null || echo "0")
  else
    last_run=$(stat -c %Y "$TIMESTAMP_FILE" 2>/dev/null || stat -f %m "$TIMESTAMP_FILE" 2>/dev/null || echo "0")
  fi

  # Calculate elapsed
  elapsed=$((current_time - last_run))

  if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
    # Skip - ran too recently
    exit 0
  fi
fi

# Detect package manager
PM="npm"
[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ] && PM="pnpm"
[ -f "$PROJECT_ROOT/yarn.lock" ] && PM="yarn"

tsc_cmd="npx tsc"
[ "$PM" != "npm" ] && tsc_cmd="$PM exec tsc"

# Update timestamp before running (prevent race conditions)
date +%s > "$TIMESTAMP_FILE" 2>/dev/null || touch "$TIMESTAMP_FILE"

# Run tsc (full project check - needed for imports/types from other files)
if output=$($tsc_cmd --noEmit --skipLibCheck --project "$tsconfig" 2>&1); then
  # Success - silent (no message = no noise)
  exit 0
fi

# Filter errors for this file only
normalized_path=$(echo "$file_path" | sed 's|\\|/|g')
file_basename=$(basename "$file_path")

# Try to match by full path or just filename
relevant_errors=$(echo "$output" | grep -E "(${normalized_path}|${file_basename})\(" | head -8 || true)

if [ -z "$relevant_errors" ]; then
  # No errors in this specific file, errors are in dependencies
  # Don't spam Claude with dependency errors
  exit 0
fi

# Format errors nicely
error_msg="⚠️ TypeScript errors in $(basename "$file_path"):\n"
error_msg+=$(echo "$relevant_errors" | sed 's/^/  /')

echo "{\"systemMessage\": \"$error_msg\"}"
exit 0
