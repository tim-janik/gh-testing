#!/usr/bin/env bash
# This Source Code Form is licensed MPL-2.0: http://mozilla.org/MPL/2.0
set -Eeuo pipefail #-x
die() { echo "${BASH_SOURCE[0]##*/}: **ERROR**: ${*:-aborting}" >&2; exit 127 ; }
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      cat "${SCRIPT_DIR}/.version"
      exit 0
      ;;
    --help)
      echo "Usage: script.sh [OPTIONS]"
      echo "Options:"
      echo "  --version   Print version number"
      echo "  --help      Show this help message"
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done


