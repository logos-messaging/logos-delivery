#!/usr/bin/env bash
# Check that build configuration reaches the compiler.
#
# Usage:
#
#   scripts/check_build_health.sh
#
# The cases check four things:
#
#   the Nim flags a make variable produces
#   the commands make would run for a target
#   the generated constraints against nimble.lock
#   the command a Nimble task emits
#
# A failed case prints the expected and the actual value.
#
# Examples:
#
#   Variable          Effect
#   ----------------  ------------------------------------------------
#   NIMFLAGS=-d:x     adds -d:x, after the defines it may conflict with
#   NIM_PARAMS=-d:x   from the environment, the caller's own contribution,
#                     kept across recursion; on the make command line it
#                     replaces the whole set, project flags and NIMFLAGS too
#   V=0               adds --verbosity:0 --hints:off, sets HANDLE_OUTPUT
#   V=1               adds --verbosity:1, clears HANDLE_OUTPUT
#   LOG_LEVEL=INFO    adds -d:chronicles_log_level="INFO"
#   LOG_LEVEL empty   nothing
#   DEBUG=0           adds -d:release -d:lto_incremental -d:strip
#   DEBUG unset       adds -d:debug
#   POSTGRES=1        adds -d:postgres
#   DEBUG_DISCV5=1    adds -d:debugDiscv5

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0
fail=0

ok() {
  printf '  PASS  %s\n' "$1"
  pass=$((pass + 1))
}

no() {
  printf '  FAIL  %s\n' "$1"
  shift
  local line
  for line in "$@"; do
    printf '          %s\n' "${line}"
  done
  fail=$((fail + 1))
}

# name, python program. The program prints "ok" or the reason it failed.
expect_python() {
  local name=$1 prog=$2
  local got
  got=$(python3 -c "${prog}" 2>&1)
  if [ "${got}" = "ok" ]; then
    ok "${name}"
  else
    no "${name}" "${got}"
  fi
}

# Return the commands make would run for a target. -B ignores timestamps.
recipe_of() {
  make -Bn "$@" 2>/dev/null
}

# name, needle, make args...
expect_recipe() {
  local name=$1 needle=$2
  shift 2
  local got
  got=$(recipe_of "$@")
  case "${got}" in
    *"${needle}"*) ok "${name}" ;;
    *) no "${name}" "expected the recipe to contain: ${needle}" ;;
  esac
}

# name, needle, make args...
reject_recipe() {
  local name=$1 needle=$2
  shift 2
  local got
  got=$(recipe_of "$@")
  case "${got}" in
    *"${needle}"*) no "${name}" "expected the recipe NOT to contain: ${needle}" ;;
    *) ok "${name}" ;;
  esac
}

# Return the resolved NIM_PARAMS.
nim_params() {
  make -pn "$@" 2>/dev/null | grep -E '^NIM_PARAMS :?=' | head -1
}

# Return the value of a variable. Remove the name and the spaces.
value_of() {
  local name=$1
  shift
  make -pn "$@" 2>/dev/null \
    | grep -E "^${name} :?=" | head -1 \
    | sed -E "s/^${name} :?=[[:space:]]*//; s/[[:space:]]+\$//"
}

# Return a variable from a recipe environment. "make -pn" does not show
# export directives.
exported_value() {
  local name=$1
  shift
  printf 'include Makefile\n_health_probe:\n\t@echo "$$%s"\n' "${name}" \
    | make -s -f - "$@" _health_probe 2>/dev/null
}

# name, needle, make args...
expect_flag() {
  local name=$1 needle=$2
  shift 2
  local got
  got=$(nim_params "$@")
  case "${got}" in
    *"${needle}"*) ok "${name}" ;;
    *) no "${name}" "expected to contain: ${needle}" "actual: ${got:-<no NIM_PARAMS>}" ;;
  esac
}

# name, needle, make args...
reject_flag() {
  local name=$1 needle=$2
  shift 2
  local got
  got=$(nim_params "$@")
  case "${got}" in
    *"${needle}"*) no "${name}" "expected NOT to contain: ${needle}" "actual: ${got}" ;;
    *) ok "${name}" ;;
  esac
}

# name, make args... The invocation must fail. -n so nothing is built.
expect_make_fails() {
  local name=$1
  shift
  if make -n "$@" >/dev/null 2>&1; then
    no "${name}" "make -n $* exited 0"
  else
    ok "${name}"
  fi
}

# name, make args... The invocation must parse.
expect_make_parses() {
  local name=$1
  shift
  if make -n "$@" >/dev/null 2>&1; then
    ok "${name}"
  else
    no "${name}" "make -n $* failed"
  fi
}

# name, expected, actual
expect_eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    no "$1" "expected: $2" "actual:   $3"
  fi
}

echo "build health"
echo

# --------------------------------------------------------------------------
# Callers set NIMFLAGS. The README, the workflows, the Jenkins jobs and the
# Dockerfiles use it. Make computes NIM_PARAMS from it.
# --------------------------------------------------------------------------
expect_flag "NIMFLAGS reaches the compiler" \
  "-d:health_sentinel" NIMFLAGS=-d:health_sentinel

# Nim uses the last definition of a define. NIMFLAGS must come after the
# project defines it may conflict with.
ordering=$(nim_params NIMFLAGS=-d:health_sentinel)
if [ -z "${ordering}" ]; then
  no "NIMFLAGS wins over project defaults" "NIM_PARAMS did not resolve"
elif [ "${ordering%%-d:health_sentinel*}" = "${ordering}" ]; then
  no "NIMFLAGS wins over project defaults" "sentinel absent: ${ordering}"
else
  before=${ordering%%-d:health_sentinel*}
  case "${before}" in
    *git_version*) ok "NIMFLAGS wins over project defaults" ;;
    *) no "NIMFLAGS wins over project defaults" \
         "the caller's flag must come after the project defaults" \
         "actual: ${ordering}" ;;
  esac
fi

# NIM_PARAMS is exported and several targets recurse, so a sub-make must not
# append the project's flags a second time.
rec=$(mktemp)
{
  printf 'include Makefile\n'
  printf '_outer:\n'
  printf '\t@echo "OUTER $(NIM_PARAMS)"\n'
  printf '\t@$(MAKE) -s -f %s _inner\n' "${rec}"
  printf '_inner:\n'
  printf '\t@echo "INNER $(NIM_PARAMS)"\n'
} > "${rec}"
rec_out=$(make -s -f "${rec}" _outer NIMFLAGS=-d:health_sentinel 2>/dev/null)
rm -f "${rec}"
expect_eq "a sub-make gets the same NIM_PARAMS" \
  "$(printf '%s\n' "${rec_out}" | sed -n 's/^OUTER //p')" \
  "$(printf '%s\n' "${rec_out}" | sed -n 's/^INNER //p')"

# NIM_PARAMS on the make command line is not part of the assembly at all. Make
# gives it precedence over every assignment in the Makefile, so neither the
# project's flags nor NIMFLAGS are added to it.
expect_eq "a command line NIM_PARAMS replaces the whole list" \
  "-d:health_cli" \
  "$(value_of NIM_PARAMS NIM_PARAMS=-d:health_cli NIMFLAGS=-d:health_sentinel)"

# NIM_PARAMS from the environment is the caller's contribution and is kept.
# NIMFLAGS is applied after the project's flags, so it still wins.
env_base=$(NIM_PARAMS=-d:health_base nim_params NIMFLAGS=-d:health_sentinel)
case "${env_base}" in
  *-d:health_base*) ok "an environment NIM_PARAMS reaches the build" ;;
  *) no "an environment NIM_PARAMS reaches the build" \
       "expected to contain: -d:health_base" \
       "actual: ${env_base:-<no NIM_PARAMS>}" ;;
esac
case "${env_base%%-d:health_sentinel*}" in
  *-d:health_base*) ok "NIMFLAGS is applied after an environment NIM_PARAMS" ;;
  *) no "NIMFLAGS is applied after an environment NIM_PARAMS" \
       "actual: ${env_base:-<no NIM_PARAMS>}" ;;
esac

# The Nimble tasks read NIM_PARAMS with getEnv. Make must export it.
seen=$(exported_value NIM_PARAMS NIMFLAGS=-d:health_sentinel)
case "${seen}" in
  *-d:health_sentinel*) ok "nimble tasks receive NIM_PARAMS in the environment" ;;
  *) no "nimble tasks receive NIM_PARAMS in the environment" \
       "a recipe saw: ${seen:-<empty>}" \
       "getEnv(\"NIM_PARAMS\") in logos_delivery.nimble would not see the flags" ;;
esac

# --------------------------------------------------------------------------
# V selects verbosity. The workflows pass V=1.
# --------------------------------------------------------------------------
expect_flag "V=1 sets --verbosity:1"           "--verbosity:1" V=1
expect_flag "V=0 sets --verbosity:0"           "--verbosity:0" V=0
expect_flag "V=0 quiets hints"                 "--hints:off"   V=0
reject_flag "V=1 keeps hints"                  "--hints:off"   V=1

# V also sets HANDLE_OUTPUT. Nat.mk uses it to silence the sub-makes.
expect_eq "V=0 sets HANDLE_OUTPUT for Nat.mk" ">/dev/null" "$(value_of HANDLE_OUTPUT V=0)"
expect_eq "V=1 clears HANDLE_OUTPUT"          ""            "$(value_of HANDLE_OUTPUT V=1)"

# --------------------------------------------------------------------------
# LOG_LEVEL is a Jenkins parameter. The image builds pass it to make.
# --------------------------------------------------------------------------
expect_flag "LOG_LEVEL selects the chronicles level" \
  '-d:chronicles_log_level="INFO"' LOG_LEVEL=INFO
reject_flag "an empty LOG_LEVEL is a no-op" \
  "chronicles_log_level" LOG_LEVEL=

# --------------------------------------------------------------------------
# DEBUG is active at 0, not at 1. An unset DEBUG and DEBUG=0 differ.
# --------------------------------------------------------------------------
expect_flag "DEBUG=0 selects release"          "-d:release"          DEBUG=0
expect_flag "DEBUG=0 keeps link-time optimisation" "-d:lto_incremental" DEBUG=0
expect_flag "DEBUG=0 strips the binary"        "-d:strip"            DEBUG=0
expect_flag "an unset DEBUG stays a debug build" "-d:debug"
reject_flag "an unset DEBUG does not strip"    "-d:strip"

# --------------------------------------------------------------------------
# These knobs are one word in a different case.
# --------------------------------------------------------------------------
expect_flag "POSTGRES=1 enables the postgres driver" "-d:postgres"    POSTGRES=1
reject_flag "POSTGRES unset leaves it out"           "-d:postgres"
expect_flag "DEBUG_DISCV5=1 enables discv5 tracing"  "-d:debugDiscv5" DEBUG_DISCV5=1

# --------------------------------------------------------------------------
# `make test <file> [name]` passes the file and the name as extra goals, which
# the catch-all absorbs. Every other unknown target must fail, or a stale
# invocation succeeds while doing nothing.
# --------------------------------------------------------------------------
expect_make_fails  "an unknown target fails"            update
expect_make_fails  "an arbitrary unknown target fails"  definitely-not-a-target
expect_make_parses "make test <file> still parses"      test tests/all_tests_waku.nim

# --------------------------------------------------------------------------
# Nimble reads the constraints only from an attached --requires:<value>. A
# separate argument leaves the value empty and Nimble discards nimble.lock.
# --------------------------------------------------------------------------
expect_recipe "setup attaches the constraints" \
  '--requires:"$(cat requires.generated)"' nimbledeps/.nimble-setup
reject_recipe "setup does not pass them as a separate argument" \
  '--requires "' nimbledeps/.nimble-setup
expect_recipe "custom tasks attach the constraints" \
  '--requires:"$(cat requires.generated)"' wakunode2
reject_recipe "custom tasks do not pass them as a separate argument" \
  '--requires "' wakunode2

# The constraints come from nimble.lock through the generator, and the audit
# checks the result against the same lock.
expect_recipe "setup regenerates the constraints first" \
  "gen_requires.nims" nimbledeps/.nimble-setup
expect_recipe "setup audits the result" \
  "audit-deps" nimbledeps/.nimble-setup

# --------------------------------------------------------------------------
# The constraints are generated from nimble.lock. A named constraint must
# give the locked version, a URL constraint the locked revision.
# --------------------------------------------------------------------------
expect_python "the constraints agree with nimble.lock" "import json
lock = json.load(open(\"nimble.lock\"))[\"packages\"]
gen = [c.strip() for c in open(\"requires.generated\").read().split(\";\") if c.strip()]
def norm(u): return u.lower().rstrip(\"/\").removesuffix(\".git\")
byurl = {norm(v[\"url\"]): v for v in lock.values() if \"url\" in v}
bad = []
for c in gen:
    if \" == \" in c:
        n, v = c.split(\" == \")
        if lock.get(n, {}).get(\"version\") != v:
            bad.append(c + \" (lock has \" + str(lock.get(n, {}).get(\"version\")) + \")\")
    elif c.startswith(\"http\") and \"#\" in c:
        u, rev = c.rsplit(\"#\", 1)
        if byurl.get(norm(u), {}).get(\"vcsRevision\") != rev:
            bad.append(c)
    else:
        bad.append(\"unrecognised form: \" + c)
print(\"ok\" if not bad else \"constraints disagree with nimble.lock: \" + \"; \".join(bad[:3]))"

# --------------------------------------------------------------------------
# The Nimble tasks concatenate their own defaults with NIM_PARAMS. The
# caller's value has to come last. An invalid flag stops Nim before it
# compiles, and the command is printed before it runs.
# --------------------------------------------------------------------------
emitted=$(make wakunode2 \
  NIMFLAGS="-d:chronicles_log_level=HEALTHSENTINEL --nonexistent-flag-xyz" 2>&1 \
  | grep -oE 'nim c [^|]*' | head -1)
if [ -z "${emitted}" ]; then
  no "the task puts the caller's flags after its own" "no nim command was emitted"
else
  before=${emitted%%-d:chronicles_log_level=HEALTHSENTINEL*}
  case "${before}" in
    *chronicles_log_level=*) ok "the task puts the caller's flags after its own" ;;
    *) no "the task puts the caller's flags after its own" \
         "the task default did not appear before the caller's value" ;;
  esac
fi

# --------------------------------------------------------------------------
# The build installs a pinned Nimble revision and puts it first on PATH. The
# release with the same version number is a different build and reports the
# same version, so check the revision. The case above already ran a build,
# which installs it.
# --------------------------------------------------------------------------
# print-nimble-path is what the README tells a developer to use, so test that,
# not a second way of finding the same binary.
tooldir=$(make print-nimble-path 2>/dev/null)
expect_eq "print-nimble-path names the pinned revision" \
  "$(value_of REQUIRED_NIMBLE_REVISION)" \
  "$("${tooldir}/nimble" --version 2>/dev/null | sed -n 's/^git hash: //p')"

# ~/.nimble/bin/nimble is a link that `nimble setup` rewrites. It must not
# shadow the pinned binary.
expect_eq "the pinned Nimble is the one make runs" \
  "${tooldir}/nimble" \
  "$(printf 'include Makefile\n_p:\n\t@command -v nimble\n' | make -s -f - _p 2>/dev/null)"

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
