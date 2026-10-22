#!/usr/bin/env bash
# Build OpenSSL and libopenconnect from the git submodules in third_party/
# into vendor/openconnect/, for build.sh to link into the helper (and bundle
# the vpnc-script).
#
#   third_party/openssl        OpenSSL (a release tag)
#   third_party/openconnect    libopenconnect
#   third_party/vpnc-scripts   the vpnc-script bundled in the app
#
# The pin for each is the commit the submodule points at, so a version bump
# is an ordinary reviewable diff:
#   git -C third_party/openconnect fetch --tags
#   git -C third_party/openconnect checkout v9.22     # or a sha
#   git add third_party/openconnect
# scripts/check-updates.sh reports what is newer upstream.
#
# Usage: scripts/build-openconnect.sh
#   OC_ARCHS="arm64 x86_64" builds a universal binary (default: host arch).
#
# The result links OpenSSL statically and otherwise only uses system libs
# (libz, libxml2, libSystem), so it runs on any Mac without Homebrew. OpenSSL
# is configured with a CA path that matches macOS: /etc/ssl/cert.pem.
# Build-time deps: `brew install autoconf automake libtool` (and perl, which
# macOS ships). `ccache` is used when installed.
#
# Caches under vendor/.cache: a static OpenSSL per arch, keyed on its pin and
# flags (so an openconnect bump doesn't rebuild it), and the autogen'd
# openconnect tree, keyed on its pin.
set -euo pipefail
cd "$(dirname "$0")/.."

OPENSSL_SRC="$PWD/third_party/openssl"
OC_SRC="$PWD/third_party/openconnect"
VPNC_SRC="$PWD/third_party/vpnc-scripts"

OUT="$PWD/vendor/openconnect"
CACHE="$PWD/vendor/.cache"
ARCHS="${OC_ARCHS:-$(uname -m)}"

# A fresh clone without --recurse-submodules has these empty. Only missing
# ones are initialised: `submodule update` would reset a pin you've just
# checked out to try. (Not --recursive: OpenSSL's own submodules are test
# corpora we don't need.)
for dep in openssl openconnect vpnc-scripts; do
    [[ -e third_party/$dep/.git ]] && continue
    if [[ $dep == openssl ]]; then   # shallow: its full history is ~400 MB
        git submodule update --init --depth 1 third_party/$dep
    else
        git submodule update --init third_party/$dep
    fi
done

pinned() { git -C "$1" rev-parse HEAD; }
OPENSSL_SHA="$(pinned "$OPENSSL_SRC")"
OC_SHA="$(pinned "$OC_SRC")"
VPNC_SHA="$(pinned "$VPNC_SRC")"

# Building from a modified submodule is allowed (it's how you try a patch),
# but never treated as cached.
dirty="" ssl_dirty=""
for dep in "$OPENSSL_SRC" "$OC_SRC" "$VPNC_SRC"; do
    if [[ -n "$(git -C "$dep" status --porcelain)" ]]; then
        echo "warning: ${dep#"$PWD/"} has local changes; building with them" >&2
        dirty="+dirty-$(date +%s)"
        [[ $dep == "$OPENSSL_SRC" ]] && ssl_dirty=1
    fi
done

# Static OpenSSL with our deployment target. DTLS stays on (openconnect's ESP
# fallback needs it); the engine API, legacy provider and compression are
# unused. no-shared means lib/ holds only .a files, so -lssl can't resolve to
# a dylib.
OPENSSL_OPTS=(no-shared no-tests no-apps no-docs no-module no-legacy no-engine no-comp no-ssl3
              --openssldir=/etc/ssl --libdir=lib -mmacosx-version-min=27.0)
OC_CFLAGS="-O3 -mmacosx-version-min=27.0"

STAMP="openssl@${OPENSSL_SHA:0:12} openconnect@${OC_SHA:0:12} vpnc-scripts@${VPNC_SHA:0:12}+${OPENSSL_OPTS[*]// /,}+$OC_CFLAGS$dirty $ARCHS"

if [[ -f "$OUT/lib/libopenconnect.a" && "$(cat "$OUT/.version" 2>/dev/null)" == "$STAMP" ]]; then
    echo "==> libopenconnect ($(git -C "$OC_SRC" describe --tags)) already built"
    exit 0
fi

SDK="$(xcrun --show-sdk-path)"
CC_BIN="clang"
if command -v ccache >/dev/null; then
    CC_BIN="ccache clang"
    export CCACHE_BASEDIR="$PWD"
fi

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include" "$CACHE"

# autogen'd openconnect tree for this pin, shared by every arch and reused
# until the pin changes. A clone (not a copy of the submodule's files) so
# version.sh can report the real `git describe` version.
GEN="$CACHE/oc-$OC_SHA"
for old in "$CACHE"/oc-*; do [[ $old == "$GEN" ]] || rm -rf "$old"; done
if [[ ! -x "$GEN/configure" ]]; then
    echo "==> Generating openconnect configure ($(git -C "$OC_SRC" describe --tags))"
    rm -rf "$GEN"
    git clone -q "$OC_SRC" "$GEN"
    git -C "$GEN" checkout -q --detach "$OC_SHA"
    (cd "$GEN" && ./autogen.sh >autogen.log 2>&1) || { tail -30 "$GEN/autogen.log" >&2; rm -rf "$GEN"; exit 1; }
fi

for arch in $ARCHS; do
    SSL="$CACHE/openssl-$arch"
    SSL_KEY="${OPENSSL_SHA} ${OPENSSL_OPTS[*]}"
    if [[ -z "$ssl_dirty" && -f "$SSL/lib/libcrypto.a" && "$(cat "$SSL/.key" 2>/dev/null)" == "$SSL_KEY" ]]; then
        echo "==> OpenSSL (${arch}) cached"
    else
        echo "==> Building OpenSSL ($(git -C "$OPENSSL_SRC" describe --tags 2>/dev/null || echo "${OPENSSL_SHA:0:10}"), ${arch})"
        rm -rf "$SSL" "$SSL-build"; mkdir -p "$SSL-build"
        (
            cd "$SSL-build"
            case "$arch" in arm64) target=darwin64-arm64-cc ;; x86_64) target=darwin64-x86_64-cc ;; esac
            CC="$CC_BIN" "$OPENSSL_SRC/Configure" "$target" "${OPENSSL_OPTS[@]}" \
                --prefix="$SSL" -isysroot "$SDK" >build.log 2>&1 \
                && make -j"$(sysctl -n hw.ncpu)" build_libs >>build.log 2>&1 \
                && make install_dev >>build.log 2>&1 \
                || { tail -30 build.log >&2; exit 1; }
        )
        rm -rf "$SSL-build"
        echo "$SSL_KEY" > "$SSL/.key"
    fi

    echo "==> Building libopenconnect ($(git -C "$OC_SRC" describe --tags), ${arch})"
    SRC="$CACHE/build-$arch"
    rm -rf "$SRC"
    cp -Rp "$GEN" "$SRC"
    (
        cd "$SRC"
        export CC="$CC_BIN"
        export CFLAGS="-arch $arch $OC_CFLAGS -isysroot $SDK"
        export LDFLAGS="-arch $arch"
        # Hide Homebrew's .pc files so optional deps (p11-kit, ...) aren't
        # picked up; everything we want is passed explicitly below.
        export PKG_CONFIG_LIBDIR="$SRC/no-pc" PKG_CONFIG_PATH=""
        # The compiled-in vpnc-script path is a placeholder: the app always
        # passes `-s` (bundled script unless the profile sets its own).
        # Pre-seeding the pkg-config results points configure at the static
        # archives instead of Homebrew's dylibs.
        ./configure --host="$arch-apple-darwin" \
            --disable-shared --enable-static --disable-nls --disable-docs \
            --with-openssl --without-gnutls --without-stoken --without-libpskc \
            --without-libpcsclite --without-libproxy --without-gssapi --without-lz4 \
            --with-vpnc-script=/etc/vpnc/vpnc-script \
            OPENSSL_CFLAGS="-I$SSL/include" \
            OPENSSL_LIBS="-L$SSL/lib -lssl -lcrypto" \
            LIBXML2_CFLAGS="-I$SDK/usr/include/libxml2" \
            LIBXML2_LIBS="-lxml2" \
            ZLIB_CFLAGS="" ZLIB_LIBS="-lz" >configure.log 2>&1 || { tail -30 configure.log >&2; exit 1; }
        make -j"$(sysctl -n hw.ncpu)" libopenconnect.la >make.log 2>&1 || { tail -30 make.log >&2; exit 1; }
    )
done

# libopenconnect for the in-process shim (Sources/COpenConnectShim). OpenSSL
# is copied alongside so SwiftPM only needs to know about one directory.
libs=(); for arch in $ARCHS; do libs+=("$CACHE/build-$arch/.libs/libopenconnect.a"); done
if [[ ${#libs[@]} -gt 1 ]]; then lipo -create "${libs[@]}" -output "$OUT/lib/libopenconnect.a"; else cp "${libs[0]}" "$OUT/lib/libopenconnect.a"; fi
for lib in libssl.a libcrypto.a; do
    ins=(); for arch in $ARCHS; do ins+=("$CACHE/openssl-$arch/lib/$lib"); done
    if [[ ${#ins[@]} -gt 1 ]]; then lipo -create "${ins[@]}" -output "$OUT/lib/$lib"; else cp "${ins[0]}" "$OUT/lib/$lib"; fi
done
cp "$CACHE/build-${ARCHS%% *}/openconnect.h" "$OUT/include/openconnect.h"
install -m 755 "$VPNC_SRC/vpnc-script" "$OUT/vpnc-script"
cp "$CACHE/build-${ARCHS%% *}/COPYING.LGPL" "$OUT/COPYING.LGPL"
echo "$STAMP" > "$OUT/.version"

lipo -info "$OUT/lib/libopenconnect.a"
