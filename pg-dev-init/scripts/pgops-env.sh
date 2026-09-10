#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${HERE}/../../shared/pgops-env.sh" "$@"
