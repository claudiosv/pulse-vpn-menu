#!/usr/bin/env bash
# Build openconnect from its upstream repo into vendor/openconnect/
# (bin/openconnect + vpnc-script), for build.sh to bundle into the app.
#
# Usage: scripts/build-openconnect.sh [REF]
#   REF is a branch, tag, or commit sha (default: master), e.g. v9.21 or
#   70d1e79d. Also settable as OC_REF.
#   OC_ARCHS="arm64 x86_64" builds a universal binary (default: host arch).
#
# The result links OpenSSL statically and otherwise only uses system libs
# (libz, libxml2, libSystem), so it runs on any Mac without Homebrew.
# Build-time deps: `brew install openssl@3 autoconf automake libtool`.
set -euo pipefail
cd "$(dirname "$0")/.."

OC_REPO="https://gitlab.com/openconnect/openconnect.git"
OC_REF="${1:-${OC_REF:-master}}"
# vpnc-scripts has no releases; pin a commit.
VPNC_COMMIT="ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101"
VPNC_SHA256="f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742"
VPNC_URL="https://gitlab.com/openconnect/vpnc-scripts/-/raw/${VPNC_COMMIT}/vpnc-script"

OUT="$PWD/vendor/openconnect"
CACHE="$PWD/vendor/.cache"
REPO="$CACHE/openconnect-src"
SSL="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
ARCHS="${OC_ARCHS:-$(uname -m)}"

mkdir -p "$CACHE"
if [[ -d "$REPO/.git" ]]; then
    git -C "$REPO" fetch -q --tags --force origin '+refs/heads/*:refs/remotes/origin/*'
else
    git clone -q "$OC_REPO" "$REPO"
fi
# Branch names resolve via origin/ so "master" tracks upstream, not a stale local branch.
SHA="$(git -C "$REPO" rev-parse --verify -q "origin/${OC_REF}^{commit}" \
    || git -C "$REPO" rev-parse --verify -q "${OC_REF}^{commit}")" \
    || { echo "unknown openconnect ref: ${OC_REF}" >&2; exit 1; }
STAMP="$SHA $ARCHS"

if [[ -x "$OUT/bin/openconnect" && "$(cat "$OUT/.version" 2>/dev/null)" == "$STAMP" ]]; then
    echo "==> openconnect ${OC_REF} (${SHA:0:10}) already built"
    exit 0
fi

if [[ ! -f "$CACHE/vpnc-script" ]]; then
    curl -fsSL "$VPNC_URL" -o "$CACHE/vpnc-script"
fi
echo "$VPNC_SHA256  $CACHE/vpnc-script" | shasum -a 256 -c - >/dev/null \
    || { rm -f "$CACHE/vpnc-script"; echo "vpnc-script checksum mismatch" >&2; exit 1; }

SDK="$(xcrun --show-sdk-path)"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
slices=()
for arch in $ARCHS; do
    echo "==> Building openconnect ${OC_REF} (${SHA:0:10}, ${arch})"
    SRC="$CACHE/build-$arch"
    rm -rf "$SRC"
    # Keep .git so version.sh reports the real `git describe` version.
    git clone -q "$REPO" "$SRC"
    git -C "$SRC" checkout -q --detach "$SHA"
    mkdir -p "$SRC/static-ssl"   # only .a files, so -lssl can't resolve to a dylib
    ln -s "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" "$SRC/static-ssl/"
    (
        cd "$SRC"
        export CFLAGS="-arch $arch -O2 -mmacosx-version-min=14.0 -isysroot $SDK"
        export LDFLAGS="-arch $arch"
        # Hide Homebrew's .pc files so optional deps (p11-kit, ...) aren't
        # picked up; everything we want is passed explicitly below.
        export PKG_CONFIG_LIBDIR="$SRC/no-pc" PKG_CONFIG_PATH=""
        ./autogen.sh >autogen.log 2>&1 || { tail -30 autogen.log >&2; exit 1; }
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
            OPENSSL_LIBS="-L$SRC/static-ssl -lssl -lcrypto" \
            LIBXML2_CFLAGS="-I$SDK/usr/include/libxml2" \
            LIBXML2_LIBS="-lxml2" \
            ZLIB_CFLAGS="" ZLIB_LIBS="-lz" >configure.log 2>&1 || { tail -30 configure.log >&2; exit 1; }
        make -j"$(sysctl -n hw.ncpu)" openconnect >make.log 2>&1 || { tail -30 make.log >&2; exit 1; }
    )
    slices+=("$SRC/openconnect")
done

if [[ ${#slices[@]} -gt 1 ]]; then
    lipo -create "${slices[@]}" -output "$OUT/bin/openconnect"
else
    cp "${slices[0]}" "$OUT/bin/openconnect"
fi
strip -x "$OUT/bin/openconnect"
install -m 755 "$CACHE/vpnc-script" "$OUT/vpnc-script"
cp "$CACHE/build-${ARCHS%% *}/COPYING.LGPL" "$OUT/COPYING.LGPL"
echo "$STAMP" > "$OUT/.version"

echo "==> Linked libraries (should be system-only):"
otool -L "$OUT/bin/openconnect" | tail -n +2
"$OUT/bin/openconnect" --version | head -3
