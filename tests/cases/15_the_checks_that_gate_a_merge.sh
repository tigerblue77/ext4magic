#!/bin/bash

# The record of which checks gate a merge.
#
# .github/rulesets/master.json is the ruleset the repository settings are told
# to enforce on master, kept in the tree in the form GitHub imports, so that
# what a pull request has to pass is something the tree states rather than a
# setting nobody can diff. Dependabot's minor and patch updates merge themselves
# once those checks are green, so the file is also the whole of what stands
# between an update and master.
#
# GitHub matches a required check by the display name of the job reporting it,
# never by the workflow's name nor the job's key. Renaming a job without editing
# the ruleset leaves a check no run will ever report : every pull request waits
# for it forever, and every Dependabot update with them, until someone with
# admin rights notices. A ruleset re-exported after a visit to the settings page
# can also come back disabled, aimed at another branch or open to a bypass, and
# still be a file GitHub imports without a word. Both are read here, and neither
# needs root, a filesystem or ext4magic itself.
#
# The workflows and the ruleset are read with grep, sed and a line scanner
# rather than a YAML or a JSON parser, because this suite depends on nothing
# beyond bash, coreutils and e2fsprogs. The scanner only has to find the job
# keys two spaces under the top level "jobs:" and the "name:" four spaces under
# each, which is how every workflow here is written : a job it cannot see is
# reported as missing, so the shortcut can turn this red for nothing but never
# green over a mistake.

# Every check name the workflows can report, one "name<tab>workflow" per line.
# A job with no "name:" reports under its key, so the key is the default rather
# than a job to leave out
# Usage : reported_check_names
function reported_check_names() {
  local -r TOP_LEVEL_JOBS='^jobs:[[:space:]]*(#.*)?$'
  local -r ANY_TOP_LEVEL_KEY='^[^[:space:]#]'
  local -r JOB_KEY='^  ([A-Za-z0-9_-]+):[[:space:]]*(#.*)?$'
  local -r JOB_NAME='^    name:[[:space:]]*(.*[^[:space:]])[[:space:]]*$'

  local WORKFLOW LINE IN_JOBS NAMED NAME
  local -a NAMES
  for WORKFLOW in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
    [ -f "$WORKFLOW" ] || continue
    IN_JOBS=false
    NAMED=true
    NAMES=()

    while IFS= read -r LINE || [ -n "$LINE" ]; do
      if [[ "$LINE" =~ $TOP_LEVEL_JOBS ]]; then
        IN_JOBS=true
        continue
      fi
      $IN_JOBS || continue

      if [[ "$LINE" =~ $ANY_TOP_LEVEL_KEY ]]; then
        IN_JOBS=false
      elif [[ "$LINE" =~ $JOB_KEY ]]; then
        NAMES+=("${BASH_REMATCH[1]}")
        NAMED=false
      elif ! $NAMED && [[ "$LINE" =~ $JOB_NAME ]]; then
        NAME="${BASH_REMATCH[1]}"
        # A quoted name reports without its quotes
        if [ "${#NAME}" -ge 2 ] && [ "${NAME:0:1}" == "${NAME: -1}" ] &&
          [[ "${NAME:0:1}" == [\"\'] ]]; then
          NAME="${NAME:1:${#NAME}-2}"
        fi
        NAMES[${#NAMES[@]} - 1]="$NAME"
        NAMED=true
      fi
    done < "$WORKFLOW"

    for NAME in "${NAMES[@]}"; do
      printf '%s\t%s\n' "$NAME" "${WORKFLOW##*/}"
    done
  done
}

# The contexts the ruleset requires, one per line
# Usage : required_contexts "$RULESET"
function required_contexts() {
  grep -oE '"context"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" |
    sed -E 's/^"context"[[:space:]]*:[[:space:]]*"//; s/"$//'
}


function test_every_check_the_ruleset_requires_is_reported_by_a_job() {
  local -r RULESET="$REPO_ROOT/.github/rulesets/master.json"
  assert_file_exists "$RULESET" "the checks that gate a merge are recorded in the tree" || return 1

  local -r REPORTED="$(reported_check_names)"
  assert_not_empty "$REPORTED" \
    "the workflows report some check at all -- have they moved out of .github/workflows ?" || return 1

  # A ruleset requiring nothing lets "gh pr merge --auto" merge an update on the
  # spot, before a single check has run
  local -r REQUIRED="$(required_contexts "$RULESET")"
  assert_not_empty "$REQUIRED" "the ruleset requires at least one check" || return 1

  local CONTEXT
  while IFS= read -r CONTEXT; do
    if printf '%s\n' "$REPORTED" | cut -f1 | grep -Fxq -- "$CONTEXT"; then
      pass
    else
      fail "the ruleset requires \"$CONTEXT\", which no job reports, so no pull request can ever pass it" \
        "the checks the workflows do report : $(printf '%s\n' "$REPORTED" | cut -f1 |
          sed 's/.*/"&"/' | paste -sd ' ')" \
        "a renamed job has to be renamed in .github/rulesets/master.json too"
    fi
  done <<< "$REQUIRED"
}

function test_the_ruleset_still_gates_the_default_branch() {
  # Every way it can stop gating while still being a file GitHub imports. Read
  # with the whitespace taken out, so that only what it says is compared and not
  # how it is laid out ; none of the values below has a space in it
  local -r RULESET="$REPO_ROOT/.github/rulesets/master.json"
  assert_file_exists "$RULESET" "the checks that gate a merge are recorded in the tree" || return 1
  local -r RECORDED="$(tr -d '[:space:]' < "$RULESET")"

  assert_contains "$RECORDED" '"target":"branch"' "it applies to branches"
  assert_contains "$RECORDED" '"enforcement":"active"' \
    "it is enforced, rather than disabled or only evaluated"
  assert_contains "$RECORDED" '"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}' \
    "it applies to the default branch, whatever it is called, and excludes nothing"
  assert_contains "$RECORDED" '"bypass_actors":[]' "nobody may bypass it"

  # "actor_type" in a bypass entry is not matched : the quote has to come
  # straight before "type"
  local -r RULE_TYPES="$(grep -oE '"type":"[^"]*"' <<< "$RECORDED" | sed 's/^"type":"//; s/"$//')"
  assert_equals "required_status_checks" "$RULE_TYPES" \
    "its one rule is the one requiring the checks, and nothing was added beside it"
}
