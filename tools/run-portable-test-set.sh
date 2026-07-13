#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -euo pipefail

host=${CONSENT_PORTABLE_HOST:?CONSENT_PORTABLE_HOST is required}
set_name=${CONSENT_PORTABLE_GROUP_SET:-direct}
root=$(cd "$(dirname "$0")/.." && pwd)
log_root=${CONSENT_CI_LOG_DIR:-}
temporary_log_root=
shard_prefix=${CONSENT_CI_SHARD_PREFIX:-Portable R7RS $host}
shard_suffix=${CONSENT_CI_SHARD_SUFFIX:-}
log_prefix=${CONSENT_CI_LOG_PREFIX:-portable-$host}
log_suffix=${CONSENT_CI_LOG_SUFFIX:-local}

case $set_name in
  direct)
    groups=(integration evaluator random property library agent runtime)
    ;;
  compiled)
    groups=(compiled-random compiled-property compiled-library
            compiled-agent compiled-runtime compiled-integration)
    ;;
  *)
    printf 'unknown portable group set: %s\n' "$set_name" >&2
    exit 2
    ;;
esac

if [[ -z $log_root ]]; then
  temporary_log_root=$(mktemp -d "${TMPDIR:-/tmp}/consent-portable-set.XXXXXX")
  log_root=$temporary_log_root
else
  mkdir -p "$log_root"
fi

cleanup() {
  if [[ -n $temporary_log_root && -d $temporary_log_root ]]; then
    rm -rf "$temporary_log_root"
  fi
}
trap cleanup EXIT

group_label() {
  case $1 in
    integration|compiled-integration) printf '%s' 'integration/REPL' ;;
    evaluator) printf '%s' 'evaluator' ;;
    random|compiled-random) printf '%s' 'random-data libraries' ;;
    property|compiled-property) printf '%s' 'property-testing libraries' ;;
    library|compiled-library) printf '%s' 'standard libraries' ;;
    agent|compiled-agent) printf '%s' 'agent libraries' ;;
    runtime|compiled-runtime) printf '%s' 'runtime/testing infrastructure' ;;
  esac
}

pids=()
logs=()
for group in "${groups[@]}"; do
  log=$log_root/$log_prefix-$group-$log_suffix.log
  logs+=("$log")
  (
    group_started=$SECONDS
    set +e
    CONSENT_PORTABLE_GROUP=$group "$root/tools/run-portable-tests.sh" \
      >"$log" 2>&1
    group_status=$?
    group_wall=$((SECONDS - group_started))
    {
      printf 'CONSENT_CI_SHARD_NAME=%s %s%s\n' \
        "$shard_prefix" "$(group_label "$group")" "$shard_suffix"
      printf 'CONSENT_CI_SHARD_SELECTOR=(testing-plan-shard %s)\n' "$group"
      printf 'CONSENT_CI_WALL_SECONDS=%d\n' "$group_wall"
    } >>"$log"
    exit "$group_status"
  ) &
  pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    status=1
  fi
done

for log in "${logs[@]}"; do
  cat "$log"
done

exit "$status"
