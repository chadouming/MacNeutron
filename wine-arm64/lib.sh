# Shared by wine-arm64/build.sh, export.sh and tests (sourced). Messages go to stderr.
die() { echo "wine-arm64: $*" >&2; exit 1; }

# Tools the build needs, collected so one run names every missing one (die_if_missing); never installed here.
missing=""
need_tool() {  # need_tool <command> <brew formula> [keg]
  # "keg": the formula is keg-only, so its bin goes first on PATH and only that one counts (macOS ships bison 2.3).
  if [ "${3:-}" = keg ]; then
    keg=$(brew --prefix "$2" 2> /dev/null) || keg=
    if [ -n "$keg" ] && [ -x "$keg/bin/$1" ]; then PATH="$keg/bin:$PATH"; return 0; fi
  elif command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  missing="$missing, $1 (brew install $2)"
}
die_if_missing() { [ -z "$missing" ] || die "missing tools: ${missing#, }"; }

# What a source tree is: pinned (no tree yet: fetch and patch it), applied (HEAD is the commit recorded in the
# applied file, nothing else changed: the patches are the truth), development (anything else, including a stash, a
# second branch or a second worktree: build it as it is) or, when a series file and the current series hash are given,
# reapply (an applied tree that was patched with another series: it holds no work of its own, so build.sh deletes it
# and starts over).
build_mode() {  # build_mode <src-dir> <applied-file> [<series-file> <series>]
  [ -d "$1" ] || { echo pinned; return 0; }
  if [ -n "$(git -C "$1" status --porcelain)" ] || [ "$(git -C "$1" rev-parse HEAD)" != "$(cat "$2" 2> /dev/null)" ] \
    || [ -n "$(git -C "$1" stash list)" ] || [ -n "$(git -C "$1" for-each-ref refs/heads | sed -n 2p)" ] \
    || [ -n "$(git -C "$1" worktree list | sed -n 2p)" ]; then
    echo development
  elif [ $# -ge 4 ] && [ "$(cat "$3" 2> /dev/null)" != "$4" ]; then
    echo reapply
  else
    echo applied
  fi
}

# SHA-256 over the files' contents in order, then the signing identity (a different identity is a different build).
stamp_of() {  # stamp_of <file>...
  for f in "$@"; do [ -f "$f" ] || die "no such build input: $f"; done
  { cat "$@"; printf '%s' "${MACNEUTRON_SIGN_IDENTITY:-}"; } | shasum -a 256 | cut -d ' ' -f 1
}

# What a tree has to be patched with: the pins and the patches, whatever the signing identity.
series_of() {  # series_of <file>...
  ( MACNEUTRON_SIGN_IDENTITY=; stamp_of "$@" )
}

# lsteamclient's series (ship-base spec §7): deps.pins' LSTEAMCLIENT_ lines alone (a tarball pin is no input of that
# tree) and its patches.
lsteamclient_series() {  # lsteamclient_series <deps.pins> <patch>...
  _lsc_pins=$1; shift
  for _lsc_f in "$_lsc_pins" "$@"; do [ -f "$_lsc_f" ] || die "no such build input: $_lsc_f"; done
  { LC_ALL=C /usr/bin/grep -E '^LSTEAMCLIENT_' "$_lsc_pins"; cat "$@"; } | shasum -a 256 | cut -d ' ' -f 1
}

# The App ID the entitled loader is signed for; a provisioning profile has to be for it (spec §7.2).
APP_ID=49QMZXLR8S.net.authspot.macneutron.wine

# A decoded provisioning profile (security cms -D) grants this App ID, the cross-architecture entitlement, and has not
# expired. Messages name what is wrong; the first problem found stops it.
check_profile_plist() {  # check_profile_plist <decoded-plist>
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2> /dev/null; }
  id=$(pb Entitlements:com.apple.application-identifier "$1") || id="(no application identifier)"
  [ "$id" = "$APP_ID" ] || die "profile is for $id, not $APP_ID"
  [ "$(pb Entitlements:com.apple.developer.cross-architecture-support "$1" || true)" = true ] \
    || die "profile lacks com.apple.developer.cross-architecture-support"
  # PlistBuddy prints the date in local time ("Tue Sep 27 22:29:58 EST 2044"): off by hours at worst, fine for expiry.
  # Always in English, so date reads it in English too: LC_ALL=C (under fr_CA the month and day names don't parse).
  exp=$(pb ExpirationDate "$1") || die "profile has no ExpirationDate"
  at=$(LC_ALL=C date -j -f '%a %b %d %T %Z %Y' "$exp" +%s 2> /dev/null) || die "can't read the profile's ExpirationDate: $exp"
  [ "$at" -gt "$(date +%s)" ] || die "profile expired on $exp"
}

# The signing variables are set and name something usable: build.sh checks this before fetching or building (a missing
# variable costs seconds, not a build), bundle.sh before assembling. There is no ad-hoc mode: an unentitled loader can't boot.
check_signing() {
  [ -n "${MACNEUTRON_SIGN_IDENTITY:-}" ] || die "set MACNEUTRON_SIGN_IDENTITY"
  [ -n "${MACNEUTRON_PROVISIONING_PROFILE:-}" ] || die "set MACNEUTRON_PROVISIONING_PROFILE"
  plist=$(mktemp)
  security cms -D -i "$MACNEUTRON_PROVISIONING_PROFILE" > "$plist" 2> /dev/null \
    || { rm -f "$plist"; die "$MACNEUTRON_PROVISIONING_PROFILE is not a provisioning profile"; }
  ( check_profile_plist "$plist" ) || { rm -f "$plist"; exit 1; }  # check_profile_plist already said what is wrong
  rm -f "$plist"
}
