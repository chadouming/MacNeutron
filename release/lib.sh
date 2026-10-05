# Shared by the release scripts (sourced; they run under set -eu). Messages go to stderr.
set -eu
die() { echo "release: $*" >&2; exit 1; }

# syspolicy_check <mode> <bundle>, its report in <work-dir>/syspolicy-<mode>.txt. Fails on any finding that isn't a
# warning, or on a failure with no findings (a tool error). Warnings are counted, not fatal: wine.app keeps its
# Mach-Os under Resources/ (Wine's layout), which the check flags as warnings; Apple's verdict decides.
syspolicy() {  # syspolicy <mode> <bundle> <work-dir>
  report="$3/syspolicy-$1.txt"
  /usr/bin/syspolicy_check "$1" "$2" > "$report" 2>&1 && return 0
  errors=$(LC_ALL=C /usr/bin/grep 'Severity:' "$report" | LC_ALL=C /usr/bin/grep -cv 'Severity: Warning' || true)
  warnings=$(LC_ALL=C /usr/bin/grep -c 'Severity: Warning' "$report" || true)
  if [ "$errors" -gt 0 ] || [ "$warnings" -eq 0 ]; then cat "$report" >&2; die "syspolicy_check $1 failed for $2"; fi
  echo "syspolicy_check $1: $warnings warnings, no errors: $report"
}

# Notarizes <bundle> and staples its ticket (spec §6.2/§6.3): the zip and the notary output go in <work-dir>.
# Prints `submission <id>`. On a rejection, prints the notary log and fails.
notarize_and_staple() {  # notarize_and_staple <bundle> <work-dir>
  [ -d "$1" ] || die "no bundle at $1"
  mkdir -p "$2"
  profile="${MACNEUTRON_NOTARY_PROFILE:-macneutron}"
  zip="$2/$(basename "$1" .app).zip"
  syspolicy notary-submission "$1" "$2"
  rm -f "$zip"
  ditto -c -k --keepParent "$1" "$zip"
  # An upload error exits non-zero with no JSON: keep whatever it printed and judge by the JSON.
  xcrun notarytool submit "$zip" -p "$profile" --wait --output-format json > "$2/submit.json" || true
  id=$(jq -r -s 'last | .id // empty' "$2/submit.json" 2> /dev/null) || id=
  [ -n "$id" ] || die "notarytool submit gave no submission id: $(cat "$2/submit.json")"
  echo "submission $id"
  status=$(jq -r -s 'last | .status' "$2/submit.json")
  if [ "$status" != Accepted ]; then
    xcrun notarytool log "$id" -p "$profile" >&2 || true
    die "submission $id: $status"
  fi
  xcrun stapler staple "$1" || die "stapler staple failed for $1"
  xcrun stapler validate "$1" || die "stapler validate failed for $1"
  syspolicy distribution "$1" "$2"
}
