#!/usr/bin/env bash
# This Source Code Form is licensed MPL-2.0: http://mozilla.org/MPL/2.0
set -Eeuo pipefail #-x

# Default values
DOCKER_IMAGE="ghcr.io/tim-janik/anklang-ci:ci-latest"
FORCE=0
KEEP=0
SHOW_HELP=0
VERBOSE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a release by tagging, running distcheck in Docker, and publishing to GitHub.

Options:
  -f, --force           Skip confirmation prompt when publishing release
  --docker-image IMAGE  Docker image to use for distcheck (default: $DOCKER_IMAGE)
  --keep, -k            Reuse existing artifacts/ if valid (local tag + recent distcheck)
  --verbose, -v         Show live output from Docker during distcheck
  --help                Show this help message and exit

The script:
  1. Extracts version tag from NEWS.md
  2. Deletes existing tag or checks for conflicts
  3. Creates a git tag
  4. Runs distcheck in the specified Docker container
  5. Creates a draft GitHub release with assets
  6. Pushes the tag and publishes the release

Example:
  $(basename "$0") --docker-image my-custom-ci:latest
  $(basename "$0") --force
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)		SHOW_HELP=1 ;;
    -f|--force)		FORCE=1 ;;
    --keep|-k)		KEEP=1 ;;
    --verbose|-v)	VERBOSE=1 ;;
    --docker-image)	shift ; DOCKER_IMAGE="$1" ;;
    -x)			set -x ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Use --help for usage information." >&2
      exit 1
      ;;
  esac
  shift
done

if [[ $SHOW_HELP -eq 1 ]]; then
  usage
fi

# == Setup, Discovery ==
setup_and_discovery()
{
  # Get package name from git remote
  echo -n "  PACKAGE   "
  PKG=$(git config --get remote.origin.url | xargs -I{} basename {} .git)
  echo "$PKG"

  # Extract version from NEWS.md (first ## heading with version number)
  echo -n "  VERSION   "
  TAG=$(sed -nr '1{ /^\#\#/{ s/.*\bv?([0-9]+\.[0-9]+\.[0-9]+[_a-z.0-9+-]*)\b.*/\1/; tPRNT; q; :PRNT p } }' NEWS.md)
  echo "$TAG"

  if [[ -z "$TAG" ]]; then
    echo "ERROR: Failed to extract version tag from NEWS.md" >&2
    exit 1
  fi

  echo -n "  HEAD      "
  HEADSHA=$(git rev-parse HEAD)
  echo "$HEADSHA"

  # Check if tag already exists on remote - ABORT if so (only resume local-only work)
  if git ls-remote --exit-code origin "refs/tags/v${TAG}" 2>/dev/null; then
    echo "ERROR: tag v${TAG} already exists on remote" >&2
    exit 1
  fi
}

# == Local Tag Creation ==
tag_creation()
(
  echo "  TAG       HEAD as v${TAG} # ${HEADSHA}"
  # Delete local tag if exists
  git tag -d "v${TAG}" >/dev/null 2>&1 || true
  git tag -m "${PKG} ${TAG}" "v${TAG}" "${HEADSHA}"
)

# == Build artifacts/ ==
build_artifacts()
(
  echo "  DISTCHECK > artifacts/.distcheck.log"
  rm -rf artifacts/
  mkdir -p artifacts/
  # Use tee for live output, redirect for silent logging
  redirect()
  (
    if [[ $VERBOSE -eq 1 ]] ; then
      tee "$1"
    else
      cat > "$1"
    fi
  )
  (
    make clean
    docker run -ti --rm -v "$PWD:/${PKG}" -w "/${PKG}" "${DOCKER_IMAGE}" \
           make distcheck
    echo "  DISTCHECK  exit_status: $?"
  ) 2>&1 | redirect artifacts/.distcheck.log
)

# == Reuse artifacts/ ==
artifacts_reuse()
(
  # Check if local tag exists with correct hash
  # Use ^{commit} to dereference annotated tags to their target commit
  TAG_HEAD=$(git rev-parse "v${TAG}^{commit}" 2>&1) &&
    [[ "$TAG_HEAD" == "$HEADSHA" ]] ||
      return 1

  # Check artifacts: log exists, <24h old
  [[ -f artifacts/.distcheck.log ]] &&
    LOG_AGE=$(( $(date +%s) - $(stat -c %Y artifacts/.distcheck.log) )) &&
    [[ $LOG_AGE -lt 86400 ]] ||
      return 1

  # Check artifacts succeeded last time
  LAST_LINE=$(tail -n1 artifacts/.distcheck.log)
  [[ "$LAST_LINE" = "  DISTCHECK  exit_status: 0" ]] ||
    return 1

  # Tag and artifacts already in place
  return 0
)

# == artifacts/.notes ==
notes_and_checks()
(
  # Extract release notes from NEWS.md
  echo "  MK-NOTES  > artifacts/.notes"
  sed -rn '/^##? / { p; :BEGIN ; n ; /^##? /q ; p ; bBEGIN ; }' NEWS.md > artifacts/.notes

  # Check that HEAD is on origin
  echo "  CHECK     HEAD @ origin"
  if ! git branch -r --contains "${HEADSHA}" | grep -qE ' origin/'; then
    echo "ERROR: HEAD diverged from origin/" >&2
    exit 1
  fi
)

# == Publish to Github ==
publish_github()
(
  # Create draft release
  echo "  UPLOAD    Draft release ${TAG}"
  gh release create -F artifacts/.notes --draft --target="${HEADSHA}" "v${TAG}" artifacts/* < /dev/null

  # Confirm publish or use -f to skip prompt
  if [[ $FORCE -eq 0 ]]; then
    read -i y -p "Push and publish \`HEAD\` tagged as ${PKG} v${TAG} ? [y/N] " Y || true
    if [[ "y${Y}" != "yy" ]]; then
      echo "Aborted. Cleaning up draft release..."
      gh release delete "v${TAG}" --cleanup-tag -y < /dev/null || true
      return 1
    fi
  fi

  # Push the tag
  echo "  PUSH      v${TAG}@origin"
  git push origin "v${TAG}"

  # Publish the release
  RELEASE_URL=$(gh release view "v${TAG}" --json url | grep -oE 'https://[^"]+')
  echo "  PUBLISH   ${RELEASE_URL}"
  gh release edit "v${TAG}" --verify-tag --draft=false
)

# == Main execution ==

setup_and_discovery

if [[ $KEEP -eq 1 ]] && artifacts_reuse ; then
  echo "  SKIP      TAG creation (local tag exists at HEAD)"
  echo "  SKIP      DISTCHECK build (valid distcheck log)"
else
  tag_creation
  build_artifacts
fi

notes_and_checks
publish_github

echo "TODO: pkg --help '>>' wiki/cli-help.md"
