#!/bin/bash

# Install what ext4magic needs to build, in a Claude Code on the web container.
#
# A session container starts from a plain Ubuntu image, which is missing three of
# the development packages the Tests workflow installs. Without them ./configure
# stops at
#
#   You must install the develop packages "ext2fs , blkid , e2p , uuid"
#
# so neither the build nor the test suite can run at all. The package list below
# is the one in .github/workflows/tests.yml, which is the source of truth : keep
# the two in step rather than letting this file grow its own idea of the
# dependencies. Issue #47 is about whether that should stay a convention.
#
# This hook is best effort by design. Its failure must not stop a session from
# starting -- a session that cannot build is still a session that can read the
# code, write a test case or answer a question -- so every path here ends in
# exit 0, and a failure is reported on stderr with what to run by hand.
#
# It does nothing outside a remote session : a contributor's own machine already
# has these packages, or has them under different names, and a hook that
# installs distribution packages behind their back would be a rude surprise.

set -u

# Ubuntu package names, from the workflow's install step. Already installed ones
# are a no-op for apt-get, so the whole list is passed rather than only what the
# probe below found missing : one apt-get invocation, and no second list to
# maintain
readonly REQUIRED_PACKAGES=(
  build-essential autoconf automake libtool
  libext2fs-dev comerr-dev libmagic-dev libblkid-dev uuid-dev
  zlib1g-dev libbz2-dev e2fsprogs
)

# What configure.ac checks for, one header per library ext4magic links against
readonly REQUIRED_HEADERS=(
  ext2fs/ext2fs.h e2p/e2p.h blkid/blkid.h uuid/uuid.h zlib.h bzlib.h magic.h
)

# The programs the build and the test suite call. mke2fs, debugfs and dumpe2fs
# are what tests/lib/images.sh builds and fills its images with
readonly REQUIRED_COMMANDS=(gcc make mke2fs debugfs dumpe2fs)

# Ask the compiler rather than looking under /usr/include, so that a header
# installed somewhere else on the include path still counts as present
function header_is_available() {
  local -r HEADER="$1"

  printf '#include <%s>\n' "$HEADER" | gcc -E -x c - > /dev/null 2>&1
}

# Print what is missing, one line each, and nothing at all when the container
# already has everything. This is what makes the hook idempotent : a resumed
# session finds nothing missing and returns without touching apt
function missing_requirements() {
  local COMMAND HEADER

  for COMMAND in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$COMMAND" > /dev/null 2>&1 || printf '%s\n' "$COMMAND"
  done

  # Every header probe needs the compiler, so report them as missing wholesale
  # rather than reporting that gcc cannot answer the question
  if ! command -v gcc > /dev/null 2>&1; then
    printf '%s\n' "${REQUIRED_HEADERS[@]}"
    return 0
  fi

  for HEADER in "${REQUIRED_HEADERS[@]}"; do
    header_is_available "$HEADER" || printf '%s\n' "$HEADER"
  done
}

# The container runs as root, but a self hosted runner may not. sudo is asked to
# be non interactive : a hook that stopped on a password prompt would hang the
# session start rather than fail it
function as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo > /dev/null 2>&1; then
    sudo --non-interactive "$@"
  else
    printf 'no way to become root\n' >&2
    return 1
  fi
}

function install_the_packages() {
  local -r LOG_FILE="$(mktemp)"

  # apt-get update is allowed to fail : a container whose package lists are
  # still usable, or one behind a proxy refusing a third party repository, can
  # often install anyway. The install below is the step whose outcome matters
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update \
    > "$LOG_FILE" 2>&1 ||
    printf 'session-start: apt-get update did not succeed, installing anyway\n' >&2

  if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get install --yes \
    --no-install-recommends "${REQUIRED_PACKAGES[@]}" > "$LOG_FILE" 2>&1; then
    printf 'session-start: could not install the build dependencies. apt-get said :\n' >&2
    tail -n 20 "$LOG_FILE" >&2
    rm -f "$LOG_FILE"
    return 1
  fi

  rm -f "$LOG_FILE"
}

# Only in a remote session
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

MISSING="$(missing_requirements)"
if [ -z "$MISSING" ]; then
  exit 0
fi

printf 'session-start: installing the ext4magic build dependencies (missing: %s)\n' \
  "$(printf '%s' "$MISSING" | tr '\n' ' ')"

install_the_packages || {
  printf 'session-start: build and test will not work until this is installed by hand :\n' >&2
  printf 'session-start:   apt-get install --yes --no-install-recommends %s\n' \
    "${REQUIRED_PACKAGES[*]}" >&2
  exit 0
}

# Say what is still missing rather than reporting a success the tree will
# contradict at the first ./configure
STILL_MISSING="$(missing_requirements)"
if [ -n "$STILL_MISSING" ]; then
  printf 'session-start: installed, but still missing : %s\n' \
    "$(printf '%s' "$STILL_MISSING" | tr '\n' ' ')" >&2
  exit 0
fi

printf 'session-start: build dependencies ready. Build with "./configure && make"\n'
exit 0
