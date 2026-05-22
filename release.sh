#!/usr/bin/env bash
set -eo pipefail

# ─── Helpers ───────────────────────────────────────────────────────────────────

get_input() {
  local var="INPUT_$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  echo "${!var:-}"
}

get_bool() {
  local val
  val="$(get_input "$1" | tr '[:upper:]' '[:lower:]')"
  case "$val" in
    true|1)  echo "true"  ;;
    false|0) echo "false" ;;
    "")      echo "$2"    ;;  # default
    *)       echo "::error::Input '$1' is not a boolean (got '$val')"; exit 1 ;;
  esac
}

# ─── Validate environment ─────────────────────────────────────────────────────

if [ -z "${SENTRY_ORG:-}" ]; then
  echo "::error::Environment variable SENTRY_ORG is missing an organization slug"
  exit 1
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "::error::Environment variable SENTRY_AUTH_TOKEN is missing an auth token"
  exit 1
fi

# ─── Parse inputs ─────────────────────────────────────────────────────────────

ENVIRONMENT="$(get_input "environment")"
INJECT="$(get_bool "inject" "true")"
SOURCEMAPS="$(get_input "sourcemaps")"
DIST="$(get_input "dist")"
FINALIZE="$(get_bool "finalize" "true")"
IGNORE_MISSING="$(get_bool "ignore_missing" "false")"
IGNORE_EMPTY="$(get_bool "ignore_empty" "false")"
STARTED_AT="$(get_input "started_at")"
URL_PREFIX="$(get_input "url_prefix")"
STRIP_COMMON_PREFIX="$(get_bool "strip_common_prefix" "false")"
WORKING_DIRECTORY="$(get_input "working_directory")"

SET_COMMITS="$(get_input "set_commits" | tr '[:upper:]' '[:lower:]')"
SET_COMMITS="${SET_COMMITS:-auto}"

# ─── Projects ──────────────────────────────────────────────────────────────────

PROJECTS_INPUT="$(get_input "projects")"
PROJECTS=()
if [ -n "$PROJECTS_INPUT" ]; then
  read -ra PROJECTS <<< "$PROJECTS_INPUT"
else
  if [ -z "${SENTRY_PROJECT:-}" ]; then
    echo "::error::Environment variable SENTRY_PROJECT is missing and no projects specified via the 'projects' input"
    exit 1
  fi
  PROJECTS=("$SENTRY_PROJECT")
fi

# ─── Working directory ─────────────────────────────────────────────────────────

if [ -n "$WORKING_DIRECTORY" ]; then
  cd "${GITHUB_WORKSPACE:-$(pwd)}/$WORKING_DIRECTORY"
else
  cd "${GITHUB_WORKSPACE:-$(pwd)}"
fi

# ─── Release version ──────────────────────────────────────────────────────────

RELEASE="$(get_input "release")"
VERSION="$(get_input "version")"           # deprecated
RELEASE_PREFIX="$(get_input "release_prefix")"
VERSION_PREFIX="$(get_input "version_prefix")"  # deprecated

if [ -n "$RELEASE" ]; then
  : # use as-is
elif [ -n "$VERSION" ]; then
  RELEASE="$VERSION"
else
  echo "::debug::Release version not provided, proposing one..."
  RELEASE="$(sentry-cli releases propose-version)"
fi

# Strip refs/tags/ prefix (when users pass ${{ github.ref }})
RELEASE="${RELEASE#refs/tags/}"

# Apply prefix
if [ -n "$RELEASE_PREFIX" ]; then
  RELEASE="${RELEASE_PREFIX}${RELEASE}"
elif [ -n "$VERSION_PREFIX" ]; then
  RELEASE="${VERSION_PREFIX}${RELEASE}"
fi

echo "::debug::Release version is $RELEASE"

# ─── Build project flags ──────────────────────────────────────────────────────

PROJECT_FLAGS=()
for p in "${PROJECTS[@]}"; do
  PROJECT_FLAGS+=(--project "$p")
done

# ─── Create release ───────────────────────────────────────────────────────────

sentry-cli releases new "$RELEASE" "${PROJECT_FLAGS[@]}"

# ─── Set commits ───────────────────────────────────────────────────────────────

if [ "$SET_COMMITS" != "skip" ]; then
  echo "::debug::Setting commits with option '$SET_COMMITS'"

  if [ "$SET_COMMITS" = "auto" ]; then
    COMMIT_ARGS=(--auto)
    [ "$IGNORE_MISSING" = "true" ] && COMMIT_ARGS+=(--ignore-missing)
    [ "$IGNORE_EMPTY" = "true" ] && COMMIT_ARGS+=(--ignore-empty)
    sentry-cli releases set-commits "$RELEASE" "${COMMIT_ARGS[@]}"

  elif [ "$SET_COMMITS" = "manual" ]; then
    REPO="$(get_input "repo")"
    COMMIT="$(get_input "commit")"
    PREV_COMMIT="$(get_input "previous_commit")"

    if [ -z "$REPO" ] || [ -z "$COMMIT" ]; then
      echo "::error::Inputs 'repo' and 'commit' are required when set_commits is 'manual'"
      exit 1
    fi

    if [ -n "$PREV_COMMIT" ]; then
      sentry-cli releases set-commits "$RELEASE" --commit "${REPO}@${PREV_COMMIT}..${COMMIT}"
    else
      sentry-cli releases set-commits "$RELEASE" --commit "${REPO}@${COMMIT}"
    fi

  else
    echo "::error::set_commits must be 'auto', 'skip', or 'manual'"
    exit 1
  fi
fi

# ─── Source maps ───────────────────────────────────────────────────────────────

if [ -n "$SOURCEMAPS" ]; then
  read -ra SOURCEMAP_PATHS <<< "$SOURCEMAPS"

  # Inject debug IDs
  if [ "$INJECT" = "true" ]; then
    echo "::debug::Injecting Debug IDs"
    sentry-cli sourcemaps inject "${SOURCEMAP_PATHS[@]}"
  fi

  # Build shared upload flags
  UPLOAD_FLAGS=()
  [ -n "$DIST" ] && UPLOAD_FLAGS+=(--dist "$DIST")
  [ -n "$URL_PREFIX" ] && UPLOAD_FLAGS+=(--url-prefix "$URL_PREFIX")
  [ "$STRIP_COMMON_PREFIX" = "true" ] && UPLOAD_FLAGS+=(--strip-common-prefix)

  # Upload for each project (sentry-cli only uploads for one project at a time)
  echo "::debug::Uploading sourcemaps"
  for project in "${PROJECTS[@]}"; do
    for sm in "${SOURCEMAP_PATHS[@]}"; do
      sentry-cli releases files "$RELEASE" upload-sourcemaps "$sm" \
        --project "$project" \
        "${UPLOAD_FLAGS[@]}"
    done
  done
fi

# ─── Deploy ────────────────────────────────────────────────────────────────────

if [ -n "$ENVIRONMENT" ]; then
  echo "::debug::Creating deploy for environment '$ENVIRONMENT'"
  DEPLOY_ARGS=(-e "$ENVIRONMENT")
  [ -n "$STARTED_AT" ] && DEPLOY_ARGS+=(--started "$STARTED_AT")
  sentry-cli releases deploys "$RELEASE" new "${DEPLOY_ARGS[@]}"
fi

# ─── Finalize ──────────────────────────────────────────────────────────────────

if [ "$FINALIZE" = "true" ]; then
  echo "::debug::Finalizing release"
  sentry-cli releases finalize "$RELEASE"
fi

# ─── Outputs ───────────────────────────────────────────────────────────────────

echo "version=$RELEASE" >> "$GITHUB_OUTPUT"
echo "release=$RELEASE" >> "$GITHUB_OUTPUT"

echo "::debug::Done"
