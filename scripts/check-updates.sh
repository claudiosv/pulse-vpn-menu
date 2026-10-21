#!/usr/bin/env bash
# Reports whether the submodules pinned in third_party/ have newer upstream
# releases or commits. Read-only apart from fetching into the (non-shallow)
# submodules' object stores; it never moves a pin.
#
# Usage: scripts/check-updates.sh
# Exit status: 0 everything current, 1 an update is available, 2 couldn't check.
#
# What counts as "an update":
#   OpenSSL        a newer release in the pinned series (3.5.x); a newer series
#                  is listed for information only (3.5 is long-term support)
#   openconnect    if the pin is exactly a release: a newer release;
#                  if the pin is a snapshot past a release: upstream HEAD ahead
#   vpnc-scripts   upstream HEAD ahead (it has no releases)
set -euo pipefail
cd "$(dirname "$0")/.."

SORT="$(command -v gsort || echo sort)"   # needs -V
updates=0

# "tag commit" for every tag of a remote, with annotated tags peeled to the
# commit they point at.
remote_tags() {
    git ls-remote --tags "$1" | gawk '{
        name = $2; sub("refs/tags/", "", name)
        if (name ~ /\^\{\}$/) { sub(/\^\{\}$/, "", name); peeled[name] = $1 } else { sha[name] = $1 }
    } END { for (t in sha) print t, (t in peeled ? peeled[t] : sha[t]) }'
}

url_of() { git config -f .gitmodules "submodule.third_party/$1.url"; }
pin_of() { git -C "third_party/$1" rev-parse HEAD; }

bump_hint() {   # dir tag-or-sha
    local fetch="fetch --tags"
    # OpenSSL is a shallow submodule; fetch just the one tag.
    [[ "$1" == openssl ]] && fetch="fetch --depth 1 origin tag $2"
    echo "      bump:  git -C third_party/$1 $fetch && git -C third_party/$1 checkout $2 && git add third_party/$1"
}

# ---------------------------------------------------------------- OpenSSL --
check_openssl() {
    local dir=openssl pin tags tag series latest newest
    pin="$(pin_of $dir)"
    tags="$(remote_tags "$(url_of $dir)" | grep -E '^openssl-[0-9]+\.[0-9]+\.[0-9]+ ')" || true
    tag="$(echo "$tags" | gawk -v p="$pin" '$2 == p { print $1 }' | head -1)"
    echo "OpenSSL        pinned ${tag:-${pin:0:10} (not a release tag)}"
    if [[ -z "$tag" ]]; then
        echo "      can't tell which release this is; check by hand"
        updates=$((updates + 1)); return
    fi

    series="$(echo "$tag" | gawk -F'[-.]' '{ print $2 "." $3 }')"
    latest="$(echo "$tags" | gawk '{ print $1 }' | grep -E "^openssl-${series//./\\.}\.[0-9]+$" | $SORT -V | tail -1)"
    if [[ "$latest" == "$tag" ]]; then
        echo "      latest in the $series series: $latest   up to date"
    else
        echo "      latest in the $series series: $latest   UPDATE AVAILABLE"
        bump_hint $dir "$latest"
        updates=$((updates + 1))
    fi
    newest="$(echo "$tags" | gawk '{ print $1 }' | $SORT -V | tail -1)"
    if [[ "$newest" != "$latest" && "$newest" != "$tag" ]]; then
        echo "      newer series exists: $newest (informational; $series is what we track)"
    fi
}

# ----------------------------------------------------------- openconnect --
check_openconnect() {
    local dir=openconnect pin url nearest ahead releases latest head behind
    pin="$(pin_of $dir)"
    url="$(url_of $dir)"
    git -C third_party/$dir fetch -q --tags origin HEAD
    head="$(git -C third_party/$dir rev-parse FETCH_HEAD)"
    releases="$(remote_tags "$url" | gawk '{ print $1 }' | grep -E '^v[0-9]+\.[0-9]+$' | $SORT -V)"
    latest="$(echo "$releases" | tail -1)"
    nearest="$(git -C third_party/$dir describe --tags --abbrev=0 "$pin" 2>/dev/null || true)"
    ahead="$(git -C third_party/$dir rev-list --count "${nearest:-$pin}..$pin" 2>/dev/null || echo '?')"
    behind="$(git -C third_party/$dir rev-list --count "$pin..$head")"

    if [[ "$ahead" == "0" ]]; then
        echo "openconnect    pinned $nearest (a release)"
        if [[ "$latest" == "$nearest" ]]; then
            echo "      latest release: $latest   up to date"
        else
            echo "      latest release: $latest   UPDATE AVAILABLE"
            bump_hint $dir "$latest"
            updates=$((updates + 1))
        fi
        [[ "$behind" != 0 ]] && echo "      upstream HEAD is $behind commits ahead (informational)"
    else
        echo "openconnect    pinned $(git -C third_party/$dir describe --tags "$pin") (a snapshot, $ahead commits past ${nearest:-?})"
        [[ "$latest" != "$nearest" ]] && echo "      latest release: $latest"
        if [[ "$behind" == 0 ]]; then
            echo "      upstream HEAD: same commit   up to date"
        else
            echo "      upstream HEAD: ${head:0:10}, $behind commits ahead   UPDATE AVAILABLE"
            bump_hint $dir "${head:0:10}"
            updates=$((updates + 1))
        fi
    fi
}

# ---------------------------------------------------------- vpnc-scripts --
check_vpnc_scripts() {
    local dir=vpnc-scripts pin head behind
    pin="$(pin_of $dir)"
    git -C third_party/$dir fetch -q origin HEAD
    head="$(git -C third_party/$dir rev-parse FETCH_HEAD)"
    behind="$(git -C third_party/$dir rev-list --count "$pin..$head")"
    echo "vpnc-scripts   pinned $(git -C third_party/$dir log -1 --format='%h (%cs)' "$pin")"
    if [[ "$behind" == 0 ]]; then
        echo "      upstream HEAD: same commit   up to date"
    else
        echo "      upstream HEAD: $(git -C third_party/$dir log -1 --format='%h (%cs)' "$head"), $behind commits ahead   UPDATE AVAILABLE"
        bump_hint $dir "${head:0:10}"
        updates=$((updates + 1))
    fi
}

for dep in openssl openconnect vpnc-scripts; do
    [[ -e third_party/$dep/.git ]] || git submodule update --init third_party/$dep >/dev/null 2>&1 \
        || { echo "couldn't initialise third_party/$dep" >&2; exit 2; }
done

check_openssl || exit 2
check_openconnect || exit 2
check_vpnc_scripts || exit 2

echo
if [[ $updates -eq 0 ]]; then
    echo "Everything is current."
else
    echo "$updates update(s) available. After bumping: scripts/build-openconnect.sh, scripts/test-shim.sh, swift test, then connect to a real gateway."
    exit 1
fi
