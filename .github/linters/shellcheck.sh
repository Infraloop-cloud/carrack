#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs ShellCheck on every shell script in the repository: tracked files
# with an sh or bash shebang (diskimage-builder element hooks have no
# extension), and *.bash files, which are sourced and have no shebang.
#
# Usage: .github/linters/shellcheck.sh   (from anywhere in the repository)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# shellcheck disable=SC2016 # $0 is awk's, not the shell's
mapfile -t scripts < <(git ls-files -z | xargs -0 awk '
    FNR == 1 { if ($0 ~ /^#!.*[\/ ](ba)?sh([[:space:]]|$)/) print FILENAME; nextfile }
')
mapfile -t sourced < <(git ls-files '*.bash')

printf 'ShellCheck %s\n' "$(shellcheck --version | sed -n 's/^version: //p')"
printf '  %s\n' "${scripts[@]}" "${sourced[@]}"

rc=0
shellcheck --external-sources "${scripts[@]}" || rc=1
if [ "${#sourced[@]}" -gt 0 ]; then
    shellcheck --external-sources --shell=bash "${sourced[@]}" || rc=1
fi
exit "${rc}"
