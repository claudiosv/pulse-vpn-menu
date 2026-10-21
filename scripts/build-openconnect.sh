#!/usr/bin/env bash
# Build openconnect from a pinned source tarball into vendor/openconnect/
# (bin/openconnect + vpnc-script), for build.sh to bundle into the app.
#
# The result links OpenSSL statically and otherwise only uses system libs
# (libz, libxml2, libSystem), so it runs on any Mac without Homebrew.
# Build-time dep: `brew install openssl@3` (static libs only).
set -euo pipefail
cd "$(dirname "$0")/.."

OC_VERSION="9.21"
OC_SHA256="5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58"
OC_URL="https://www.infradead.org/openconnect/download/openconnect-${OC_VERSION}.tar.gz"
# vpnc-scripts has no releases; pin a commit.
VPNC_COMMIT="ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101"
VPNC_SHA256="f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742"
VPNC_URL="https://gitlab.com/openconnect/vpnc-scripts/-/raw/${VPNC_COMMIT}/vpnc-script"

OUT="$PWD/vendor/openconnect"
CACHE="$PWD/vendor/.cache"
SSL="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
ARCHS="${OC_ARCHS:-$(uname -m)}"   # e.g. OC_ARCHS="arm64 x86_64" for universal

if [[ -x "$OUT/bin/openconnect" && "$(cat "$OUT/.version" 2>/dev/null)" == "$OC_VERSION $ARCHS" ]]; then
    echo "==> openconnect ${OC_VERSION} already built"
    exit 0
fi

fetch() { # url sha256 dest
    [[ -f "$3" ]] || curl -fsSL "$1" -o "$3"
    echo "$2  $3" | shasum -a 256 -c - >/dev/null || { rm -f "$3"; echo "checksum mismatch: $1" >&2; exit 1; }
}

mkdir -p "$CACHE"
fetch "$OC_URL" "$OC_SHA256" "$CACHE/openconnect-${OC_VERSION}.tar.gz"
fetch "$VPNC_URL" "$VPNC_SHA256" "$CACHE/vpnc-script"

SDK="$(xcrun --show-sdk-path)"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
slices=()
for arch in $ARCHS; do
    echo "==> Building openconnect ${OC_VERSION} (${arch})"
    SRC="$CACHE/build-$arch"
    rm -rf "$SRC"; mkdir -p "$SRC"
    mkdir -p "$SRC/static-ssl"   # only .a files, so -lssl can't resolve to a dylib
    ln -s "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" "$SRC/static-ssl/"
    tar -xzf "$CACHE/openconnect-${OC_VERSION}.tar.gz" -C "$SRC" --strip-components=1
    (
        cd "$SRC"
        export CFLAGS="-arch $arch -O2 -mmacosx-version-min=14.0 -isysroot $SDK"
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
echo "$OC_VERSION $ARCHS" > "$OUT/.version"

echo "==> Linked libraries (should be system-only):"
otool -L "$OUT/bin/openconnect" | tail -n +2
"$OUT/bin/openconnect" --version | head -3
