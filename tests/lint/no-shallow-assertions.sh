#!/usr/bin/env bash
set -euo pipefail

status=0
files=(
  tests/smoke/run.sh
  tests/integration/run.sh
)

for file in "${files[@]}"; do
  while IFS=: read -r line_no line; do
    [[ -n "$line_no" ]] || continue
    if [[ "$line" == *assert_* || "$line" == *record_* || "$line" == *check_start* ]]; then
      continue
    fi
    printf 'shallow assertion pattern in %s:%s: %s\n' "$file" "$line_no" "$line" >&2
    status=1
  done < <(
    grep -En 'grep -[EF]*q|(^|[;&|[:space:]])![[:space:]]+(docker|grep|curl)|test "\$\(|docker exec .* (grep|test) ' "$file" || true
  )
done

if (( status != 0 )); then
  printf 'Use tests/lib/testlib.sh logged assertion helpers instead of silent shell checks.\n' >&2
fi

exit "$status"
