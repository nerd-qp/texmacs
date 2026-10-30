#!/bin/bash
#
# Build a self-contained macOS distribution of the Chez-backed TeXmacs.
#
#   ./packages/macos/make-bundle.sh              # .app only, in dist/
#   ./packages/macos/make-bundle.sh --dmg        # .app + .dmg
#   ./packages/macos/make-bundle.sh --dmg --bundle-qt
#   ./packages/macos/make-bundle.sh --bundle-qt --sign "Developer ID Application: ..."
#
# Layout produced (matches the lookup paths already compiled into the binary):
#
#   dist/TeXmacs-<version>/TeXmacs.app/Contents/
#     MacOS/TeXmacs                        the executable
#     Info.plist                           icon + document types + URL scheme
#     Resources/TeXmacs.icns
#     Resources/share/TeXmacs/progs/       Scheme sources  -> $TEXMACS_PATH
#     Resources/share/TeXmacs/boot/        compiled .so    -> $TEXMACS_PATH/boot
#     Resources/share/TeXmacs/plugins/
#
# Why boot/ lives there: src/Texmacs/Texmacs/texmacs.cpp sets
#   TEXMACS_PATH = <exe>/../Resources/share/TeXmacs
# and boot-chez.scm:843 falls back to
#   (string-append tm-path "/boot/" so-name)
# so no C++ change and no TEXMACS_BOOT_PATH wrapper is required.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build-texmacos"
SRC_APP="$BUILD/TeXmacs.app"
SRC_BOOT="$BUILD/boot"
DIST="$ROOT/dist"

MAKE_DMG=0
BUNDLE_QT=0
FULL_PROGS=0
SIGN_ID=""
VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)        MAKE_DMG=1 ;;
    --bundle-qt)  BUNDLE_QT=1 ;;
    --full-progs) FULL_PROGS=1 ;;
    --sign)       shift; SIGN_ID="${1:-}" ;;
    --version)    shift; VERSION="${1:-}" ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say () { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- preflight
[ -x "$SRC_APP/Contents/MacOS/TeXmacs" ] || {
  echo "error: $SRC_APP not built. Run 'make -j\$(sysctl -n hw.ncpu)' in build-texmacos first." >&2
  exit 1
}
[ -d "$SRC_BOOT" ] || {
  echo "error: $SRC_BOOT missing. Run the module compiler (-compile-modules) first." >&2
  exit 1
}

SO_COUNT=$(find "$SRC_BOOT" -name '*.so' | wc -l | tr -d ' ')
[ "$SO_COUNT" -gt 0 ] || {
  echo "error: no compiled modules in $SRC_BOOT" >&2
  exit 1
}

if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$SRC_APP/Contents/Info.plist" 2>/dev/null || true)
  case "$VERSION" in
    ""|*"Error"*) VERSION=$(sed -n 's/^.*TEXMACS_VERSION "\([0-9.]*\)".*/\1/p' \
                              "$ROOT/CMakeLists.txt" 2>/dev/null | head -1) ;;
  esac
  [ -n "$VERSION" ] || VERSION="2.1.5"
fi

say "packaging TeXmacs $VERSION ($SO_COUNT compiled modules)"

# Versioned output directory: this script never deletes anything. If the target
# already exists you are told to move it aside rather than having it removed.
STAGE_ROOT="$DIST/TeXmacs-chez-$VERSION"
APP="$STAGE_ROOT/TeXmacs-chez.app"
RES="$APP/Contents/Resources"
SHARE="$RES/share/TeXmacs"

if [ -e "$STAGE_ROOT" ]; then
  echo "error: $STAGE_ROOT already exists." >&2
  echo "       move it aside, or package a different version with --version X.Y.Z" >&2
  exit 1
fi

# ---------------------------------------------------------------- fresh app
mkdir -p "$APP/Contents/MacOS" "$RES" "$SHARE"

cp "$SRC_APP/Contents/MacOS/TeXmacs" "$APP/Contents/MacOS/TeXmacs"
chmod +x "$APP/Contents/MacOS/TeXmacs"

# The generated plist in build-texmacos was malformed (a bare <array> where
# CFBundleURLTypes should be), so we render it from the template ourselves.
say "generating Info.plist"
sed -e "s|@DEVEL_VERSION@|$VERSION|g" \
    -e "s|@APPCAST@||g" \
    -e "s|@OSXVERMIN@|11.0|g" \
    "$ROOT/packages/macos/Info.plist.in" > "$APP/Contents/Info.plist"
if ! plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: generated Info.plist is malformed; check packages/macos/Info.plist.in" >&2
  exit 1
fi

# Finder / About box name. The executable itself stays "TeXmacs" because
# CFBundleExecutable and the file in MacOS/ must agree.
/usr/libexec/PlistBuddy -c "Set :CFBundleName TeXmacs-chez" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

# CFBundleIconFile is "AppIcon" in the template, CFBundleTypeIconFile is
# "TeXmacs-document.icns"; ship both under the names the plist asks for.
[ -f "$ROOT/packages/macos/TeXmacs.icns" ] && \
  cp "$ROOT/packages/macos/TeXmacs.icns" "$RES/AppIcon.icns"
[ -f "$ROOT/packages/macos/TeXmacs-document.icns" ] && \
  cp "$ROOT/packages/macos/TeXmacs-document.icns" "$RES/TeXmacs-document.icns"
[ -f "$ROOT/packages/macos/PkgInfo" ] && \
  cp "$ROOT/packages/macos/PkgInfo" "$APP/Contents/PkgInfo"

# ------------------------------------------------------------ scheme sources
# Almost everything is already compiled into boot/*.so. Only these paths are
# read as SOURCE at runtime, so only these are shipped:
#
#   progs/init-texmacs-chez.scm   interpreter bootstrap (tm_server.cpp:145)
#   progs/kernel/boot/boot-chez.scm  primitive-loaded by the init file itself
#                                 (init-texmacs-chez.scm:39-42)
#   progs/tm-mode.el              read by utils/misc/tm-keywords.scm:16
#   progs/forms, progs/client,    server/account templates and preference
#   progs/server                  forms, loaded on demand
#
# Pass --full-progs to ship all of progs/ (5.8 MB) instead.
say "copying Scheme sources"
if [ "$FULL_PROGS" = 1 ]; then
  rsync -a --exclude '.git*' --exclude '*.o' --exclude '*.so' \
        "$ROOT/TeXmacs/progs" "$SHARE/"
else
  mkdir -p "$SHARE/progs/kernel/boot"
  rsync -a "$ROOT/TeXmacs/progs/init-texmacs-chez.scm" \
           "$ROOT/TeXmacs/progs/init-texmacs.scm" \
           "$ROOT/TeXmacs/progs/tm-mode.el" "$SHARE/progs/"
  rsync -a "$ROOT/TeXmacs/progs/kernel/boot/boot-chez.scm" \
           "$SHARE/progs/kernel/boot/"
  for sub in forms client/forms server; do
    [ -d "$ROOT/TeXmacs/progs/$sub" ] || continue
    mkdir -p "$SHARE/progs/$sub"
    rsync -a "$ROOT/TeXmacs/progs/$sub/" "$SHARE/progs/$sub/"
  done
fi

for d in fonts styles texts langs misc doc examples; do
  [ -d "$ROOT/TeXmacs/$d" ] || continue
  rsync -a --exclude '.git*' --exclude '*.o' --exclude '*.so' \
        "$ROOT/TeXmacs/$d" "$SHARE/"
done

# REQUIRED. src/System/Boot/init_texmacs.cpp:551 test_texmacs_path() rejects the
# tree unless SVNREV exists AND its contents equal ALTERNATIVE_VERSION
# (CMakeLists.txt:396). Without this file the app aborts at startup with
# "does not contain a valid TeXmacs installation".
if [ -f "$ROOT/TeXmacs/SVNREV" ]; then
  cp "$ROOT/TeXmacs/SVNREV" "$SHARE/SVNREV"
else
  echo "error: TeXmacs/SVNREV missing; the bundle would fail its own validation" >&2
  exit 1
fi

# ------------------------------------------------------------ compiled modules
say "copying compiled modules"
mkdir -p "$SHARE/boot"
rsync -a --include '*/' --include '*.so' --include 'module-deps.scm' --exclude '*' \
      "$SRC_BOOT/" "$SHARE/boot/"

# Plugins ship as sources; the binary compiles nothing at runtime, but the
# plugin loader still resolves $TEXMACS_PATH/plugins.
if [ -d "$ROOT/plugins" ]; then
  say "copying plugins"
  rsync -a --exclude '.git*' "$ROOT/plugins" "$SHARE/"
fi

# ------------------------------------------------------------- Chez heap images
# Chez cannot start without petite.boot / scheme.boot. The binary sets
# SCHEMEHEAPDIRS to <bundle>/Resources/share/chez when the variable is unset
# (src/Texmacs/Texmacs/texmacs.cpp, macOS bundle branch). Without this the boot
# fails and init_texmacs() falls back to Guile -> "guile could not be found".
CHEZ_HEAP="${CHEZ_HEAP_DIR:-}"
if [ -z "$CHEZ_HEAP" ]; then
  for d in /opt/homebrew/opt/chezscheme/lib/csv*/tarm64osx \
           /opt/homebrew/opt/chezscheme/lib/csv*/tarm64le \
           /usr/lib/csv*/tarm64le /usr/lib/csv*/ta6le; do
    [ -f "$d/scheme.boot" ] && CHEZ_HEAP="$d" && break
  done
fi
if [ -n "$CHEZ_HEAP" ] && [ -f "$CHEZ_HEAP/scheme.boot" ]; then
  say "copying Chez heap images from $CHEZ_HEAP"
  mkdir -p "$RES/share/chez"
  cp "$CHEZ_HEAP/petite.boot" "$CHEZ_HEAP/scheme.boot" "$RES/share/chez/" 2>/dev/null || true
else
  echo "warning: could not find petite.boot/scheme.boot; the bundle will not start" >&2
  echo "         set CHEZ_HEAP_DIR to the directory containing them" >&2
fi

# ------------------------------------------------------------------ Qt libs
if [ "$BUNDLE_QT" = 1 ]; then
  if command -v macdeployqt >/dev/null 2>&1; then
    say "bundling Qt frameworks (macdeployqt)"
    macdeployqt "$APP" -always-overwrite >/dev/null
  else
    echo "warning: macdeployqt not found; the app will depend on the build machine's Qt" >&2
    echo "         install it with 'brew install qt' or drop --bundle-qt" >&2
  fi
fi

# ------------------------------------------------------------------- signing
if [ -n "$SIGN_ID" ]; then
  say "signing as: $SIGN_ID"
  codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"
else
  # Ad-hoc signature keeps Gatekeeper from rejecting the bundle outright on
  # the local machine. It is NOT sufficient for distribution.
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

say "bundle ready: $APP"
du -sh "$APP" | awk '{print "    size: " $1}'

# ---------------------------------------------------------------------- dmg
if [ "$MAKE_DMG" = 1 ]; then
  DMG="$DIST/TeXmacs-chez-$VERSION.dmg"
  if [ -e "$DMG" ]; then
    echo "error: $DMG already exists; move it aside first." >&2
    exit 1
  fi
  say "building $DMG"
  # Staging dir lives inside the versioned output dir; nothing is deleted.
  DMG_STAGE="$STAGE_ROOT/dmg"
  mkdir -p "$DMG_STAGE"
  # ditto, not cp -R: the Chez heap images are copied read-only and cp refuses
  # to overwrite them on a second pass.
  ditto "$APP" "$DMG_STAGE/$(basename "$APP")"
  ln -sfn /Applications "$DMG_STAGE/Applications"
  hdiutil create -volname "TeXmacs-chez $VERSION" -srcfolder "$DMG_STAGE" \
                 -format UDZO "$DMG" >/dev/null
  say "dmg ready: $DMG"
  du -sh "$DMG" | awk '{print "    size: " $1}'
fi

cat <<EOF

Next:
  1. Smoke test without any environment:
       env -u TEXMACS_PATH -u TEXMACS_BOOT_PATH "$APP/Contents/MacOS/TeXmacs"
  2. For real distribution add: --bundle-qt --sign "Developer ID Application: ..."
     then notarize with:
       xcrun notarytool submit "$DIST/TeXmacs-$VERSION.dmg" --wait \\
             --apple-id <id> --team-id <team> --password <app-specific-password>
EOF
