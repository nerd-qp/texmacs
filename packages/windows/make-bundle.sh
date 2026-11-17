#!/usr/bin/env bash
# Build a distributable Windows bundle of the Chez-backed TeXmacs.
#
# Modelled on packages/macos/make-bundle.sh, with the Windows packaging
# skeleton from slowphil/mingw-w64-texmacs (PKGBUILD:package()) and the
# one-click wrapper idea from slowphil/texmacs-win-builder.
#
#   ./packages/windows/make-bundle.sh                       # slim AOT bundle + installer
#   ./packages/windows/make-bundle.sh --full-progs          # all 453 .so modules, TEXMACS_NO_BOOT=1
#   ./packages/windows/make-bundle.sh --no-qt               # skip windeployqt (Qt on PATH)
#   ./packages/windows/make-bundle.sh --no-installer        # stage only, no ISCC.exe
#   ./packages/windows/make-bundle.sh --verify              # headless smoke test of the staged tree
#
# Layout (STAGE = ../distr/TeXmacs-chez-<version>):
#   STAGE/bin/texmacs.exe        plus Qt/MinGW DLLs, platforms/qwindows.dll, TeXmacs-chez.bat
#   STAGE/progs ...              data tree (SVNREV at the root)
#   STAGE/boot/                  texmacs.boot + module-deps.scm (slim) or all .so (full)
#   STAGE/chez/                  petite.boot, scheme.boot
#
# The .iss adds TEXMACS_PATH, SCHEMEHEAPDIRS and TEXMACS_BOOT_PATH to the
# user environment, so an installed build needs no launcher. TeXmacs.bat is
# still shipped for portable use (it sets the same three variables).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="build-win"
FULL_PROGS=0
DO_QT=1
DO_INSTALLER=1
DO_VERIFY=0
VERSION=""
ISCC=""
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir)   shift; BUILD_DIR="${1:-}" ;;
    --version)     shift; VERSION="${1:-}" ;;
    --full-progs)  FULL_PROGS=1 ;;
    --no-qt)       DO_QT=0 ;;
    --no-installer) DO_INSTALLER=0 ;;
    --verify)      DO_VERIFY=1 ;;
    --iscc)        shift; ISCC="${1:-}" ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say () { printf '\033[1m==>\033[0m %s\n' "$*"; }
die () { echo "error: $*" >&2; exit 1; }

BUILD="$ROOT/$BUILD_DIR"
SRC_EXE="$BUILD/src/texmacs.exe"
SRC_BOOT="$BUILD/boot"
CACHE="$BUILD/CMakeCache.txt"

# ---------------------------------------------------------------- preflight
[ -n "$BUILD_DIR" ] || die "empty build directory"
[ -f "$CACHE" ] || die "$CACHE missing; configure with CMake first"
[ -x "$SRC_EXE" ] || die "$SRC_EXE not built; run 'cmake --build $BUILD_DIR' first"
[ -d "$SRC_BOOT" ] || die "$SRC_BOOT missing; CMake should have compiled the Scheme modules"
[ -f "$ROOT/TeXmacs/SVNREV" ] || die "TeXmacs/SVNREV missing; CMake writes it at configure time"
command -v cygpath >/dev/null || die "cygpath not found (use an MSYS2 shell)"
command -v ntldd >/dev/null || die "ntldd missing: pacman -S mingw-w64-ucrt-x86_64-ntldd"
command -v rsync >/dev/null || die "rsync missing: pacman -S rsync"

if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/^set (TEXMACS_VERSION \([0-9.]*\)).*/\1/p' "$ROOT/CMakeLists.txt" | head -1 || true)"
  [ -n "$VERSION" ] || VERSION="2.1.5"
fi

SO_COUNT=$(find "$SRC_BOOT" -name '*.so' | wc -l | tr -d ' ')
[ "$SO_COUNT" -gt 0 ] || die "no compiled modules in $SRC_BOOT"
if [ "$FULL_PROGS" -eq 0 ] && [ ! -f "$SRC_BOOT/texmacs.boot" ]; then
  die "$SRC_BOOT/texmacs.boot missing; pass --full-progs or configure with -DCHEZ_SCHEME_EXECUTABLE=..."
fi

# Chez locations from the CMake cache (the authoritative build inputs).
CHEZ_ROOT=$(sed -n 's/^CHEZ_ROOT:STRING=//p' "$CACHE" | head -1 || true)
CHEZ_MACHINE=$(sed -n 's/^CHEZ_MACHINE:STRING=//p' "$CACHE" | head -1 || true)
CHEZ_SCHEME=$(sed -n 's/^CHEZ_SCHEME_EXECUTABLE:FILEPATH=//p' "$CACHE" | head -1 || true)
case "$CHEZ_SCHEME" in
  ""|*NOTFOUND|*-NOTFOUND) CHEZ_SCHEME="" ;;
esac
if [ -z "$CHEZ_SCHEME" ] && [ -n "$CHEZ_ROOT" ] && [ -n "$CHEZ_MACHINE" ]; then
  for c in "$CHEZ_ROOT/../bin/$CHEZ_MACHINE/scheme.exe" \
           "$CHEZ_ROOT/bin/$CHEZ_MACHINE/scheme.exe"; do
    [ -f "$(cygpath -u "$c")" ] && CHEZ_SCHEME="$c" && break
  done
fi

HEAP=""
if [ -n "$CHEZ_ROOT" ]; then
  for c in "$CHEZ_ROOT/$CHEZ_MACHINE" "$CHEZ_ROOT/boot/$CHEZ_MACHINE" "$CHEZ_ROOT"; do
    d="$(cygpath -u "$c" 2>/dev/null || echo "$c")"
    if [ -f "$d/scheme.boot" ] && [ -f "$d/petite.boot" ]; then HEAP="$d"; break; fi
  done
fi
[ -n "$HEAP" ] || die "could not locate petite.boot/scheme.boot via CMakeCache.txt (CHEZ_ROOT=$CHEZ_ROOT)"

DIST="$(cd "$ROOT/.." && pwd)/distr"
STAGE="$DIST/TeXmacs-chez-$VERSION"
[ ! -e "$STAGE" ] || die "$STAGE already exists; move it aside or pass --version X.Y.Z"

say "packaging TeXmacs $VERSION ($SO_COUNT compiled modules) into $STAGE"
mkdir -p "$STAGE/bin"

# ------------------------------------------------------------------ binary
cp -a "$SRC_EXE" "$STAGE/bin/texmacs.exe"

# ---------------------------------------------------------------------- Qt
# Deploy before copying the Scheme payload so the deployer never scans the
# hundreds of Chez FASL .so files (make-bundle.sh on macOS does the same).
if [ "$DO_QT" -eq 1 ]; then
  say "deploying Qt runtime (windeployqt)"
  windeployqt --release --no-translations "$STAGE/bin/texmacs.exe" >"$TMPDIR/windeployqt.log" 2>&1 \
    || { tail -20 "$TMPDIR/windeployqt.log"; die "windeployqt failed"; }
  QT_PLUGINS="/ucrt64/share/qt6/plugins"
  for p in generic imageformats platforms; do
    [ -d "$QT_PLUGINS/$p" ] || continue
    mkdir -p "$STAGE/bin/$p"
    case "$p" in
      platforms) cp -a "$QT_PLUGINS/$p/qwindows.dll" "$STAGE/bin/platforms/" 2>/dev/null || true ;;
      *) cp -a "$QT_PLUGINS/$p/." "$STAGE/bin/$p/" ;;
    esac
  done
fi

# -------------------------------------------------------------- data tree
say "copying data tree"
if [ "$FULL_PROGS" -eq 1 ]; then
  rsync -a --exclude '.git*' --exclude '*.o' --exclude '*.so' \
        "$ROOT/TeXmacs/progs" "$STAGE/"
else
  mkdir -p "$STAGE/progs"
  for f in init-texmacs-boot-file.scm init-buffer.scm tm-mode.el; do
    [ -f "$ROOT/TeXmacs/progs/$f" ] && rsync -a "$ROOT/TeXmacs/progs/$f" "$STAGE/progs/"
  done
  for sub in forms client/forms server; do
    [ -d "$ROOT/TeXmacs/progs/$sub" ] && rsync -a "$ROOT/TeXmacs/progs/$sub" "$STAGE/progs/"
  done
fi
for d in fonts styles texts langs misc doc examples packages include; do
  [ -d "$ROOT/TeXmacs/$d" ] && rsync -a --exclude '.git*' --exclude '*.o' --exclude '*.so' \
        "$ROOT/TeXmacs/$d" "$STAGE/"
done
# The plugin sources live at the repository root, not under TeXmacs/.
[ -d "$ROOT/plugins" ] && rsync -a --exclude '.git*' "$ROOT/plugins" "$STAGE/"
rsync -a "$ROOT/TeXmacs/SVNREV" "$STAGE/SVNREV"
rsync -a "$ROOT/LICENSE" "$STAGE/LICENSE"

# ---------------------------------------------------------- Scheme payload
say "copying Scheme payload ($([ "$FULL_PROGS" -eq 1 ] && echo full || echo slim AOT))"
mkdir -p "$STAGE/boot"
if [ "$FULL_PROGS" -eq 1 ]; then
  rsync -a "$SRC_BOOT/" "$STAGE/boot/"
else
  if [ -z "$CHEZ_SCHEME" ]; then
    die "cannot query startup module list; set CHEZ_SCHEME_EXECUTABLE or pass --full-progs"
  fi
  EXCL="$(cygpath -u "$CHEZ_SCHEME")"
  "$EXCL" --script "$ROOT/src/Scheme/Chez/make-boot.scm" --print-startup-excludes \
    > "$TMPDIR/startup-excludes.txt"
  # Single rsync pass: resident modules from the AOT image, test modules and
  # compiler-only trees are never copied (mirrors make-bundle.sh:241-269).
  rsync -a --prune-empty-dirs \
        --exclude-from="$TMPDIR/startup-excludes.txt" \
        --exclude '*-test.so' --exclude '/check/' --exclude '/utils/test/' \
        --exclude 'texmacs-user.so' \
        --include '*/' --include '*.so' --include 'texmacs.boot' \
        --include 'module-deps.scm' --include 'init-texmacs-boot-file.so' \
        --exclude '*' \
        "$SRC_BOOT/" "$STAGE/boot/"
fi
if [ "$FULL_PROGS" -eq 1 ]; then
  CHEZ_DST="$STAGE/share/src/Scheme/Chez"
  mkdir -p "$CHEZ_DST"
  for f in compile-texmacs.scm compiler-db.scm compiler-scan.scm compile-graph.scm \
           compiler-progress.scm static-analysis.scm lint-modules.scm; do
    [ -f "$ROOT/src/Scheme/Chez/$f" ] && rsync -a "$ROOT/src/Scheme/Chez/$f" "$CHEZ_DST/"
  done
fi

# ------------------------------------------------------------ Chez heaps
say "copying Chez heap images from $HEAP"
mkdir -p "$STAGE/chez"
rsync -a "$HEAP/petite.boot" "$HEAP/scheme.boot" "$STAGE/chez/"

# --------------------------------------------------------- DLL closure
say "resolving MinGW DLL closure (copydll.sh)"
bash "$ROOT/packages/windows/copydll.sh" "$STAGE/bin/texmacs.exe"

# ------------------------------------------------------------- launcher
# The installed build gets the same variables from the .iss registry entries;
# this .bat covers portable/unpacked use.
if [ "$FULL_PROGS" -eq 1 ]; then NOBOOT=1; else NOBOOT=0; fi
cat > "$STAGE/bin/TeXmacs-chez.bat" <<BAT
@echo off
set SCHEMEHEAPDIRS=%~dp0..\chez
set TEXMACS_PATH=%~dp0..
set TEXMACS_BOOT_PATH=%~dp0..\boot
set TEXMACS_HOME_PATH=%APPDATA%\TeXmacs-chez
set TEXMACS_NO_BOOT=$NOBOOT
start "" "%~dp0texmacs.exe" %*
BAT

# ------------------------------------------------------------ installer
if [ "$DO_INSTALLER" -eq 1 ]; then
  if [ -z "$ISCC" ]; then
    ISCC="$(find '/c/Program Files' '/c/Program Files (x86)' -maxdepth 3 -iname 'ISCC.exe' -print -quit 2>/dev/null || true)"
  fi
  [ -n "$ISCC" ] && [ -f "$ISCC" ] || die "ISCC.exe not found; pass --iscc /path/to/ISCC.exe"
  say "rendering Inno Setup script"
  ISS="$DIST/TeXmacs-chez-$VERSION.iss"
  # Forward-slash Windows paths: Inno Setup accepts them, and passing them
  # through awk -v avoids backslash escape processing entirely.
  STAGE_W="$(cygpath -m "$STAGE")"
  OUT_W="$(cygpath -m "$DIST/windows")"
  LICENSE_W="$(cygpath -m "$STAGE/LICENSE")"
  ICON_W="$(cygpath -m "$STAGE/TeXmacs.ico")"
  BANNER_W="$(cygpath -m "$STAGE/topbanner.bmp")"
  [ -f "$STAGE/TeXmacs.ico" ] || cp -a "$ROOT/packages/windows/TeXmacs.ico" "$STAGE/TeXmacs.ico"
  [ -f "$STAGE/topbanner.bmp" ] || cp -a "$ROOT/packages/windows/topbanner.bmp" "$STAGE/topbanner.bmp"
  awk -v ver="$VERSION" -v stage="$STAGE_W" -v out="$OUT_W" \
      -v lic="$LICENSE_W" -v icon="$ICON_W" -v banner="$BANNER_W" '
    /^LicenseFile=/ { print "LicenseFile=" lic; next }
    /^OutputDir=/   { print "OutputDir=" out; next }
    /^AppName=/          { print "AppName=TeXmacs-chez"; next }
    /^AppVerName=/       { print "AppVerName=TeXmacs-chez"; next }
    /^DefaultDirName=/   { print "DefaultDirName={autopf}\\TeXmacs-chez"; next }
    /^DefaultGroupName=/ { print "DefaultGroupName=TeXmacs-chez"; next }
    # Launch through the .bat so the env vars are set in the process itself,
    # independent of whether Explorer has refreshed its cached environment.
    /^Name: "\{group\}\\TeXmacs";/ {
      print "Name: \"{group}\\TeXmacs-chez\"; Filename: \"{app}\\bin\\TeXmacs-chez.bat\"; IconFilename: \"{app}\\TeXmacs.ico\""
      next
    }
    /^Name: "\{userdesktop\}\\TeXmacs";/ {
      print "Name: \"{userdesktop}\\TeXmacs-chez\"; Filename: \"{app}\\bin\\TeXmacs-chez.bat\"; IconFilename: \"{app}\\TeXmacs.ico\""
      next
    }
    /^Source: \.\./ { print "Source: " stage "/*; DestDir: {app}; Flags: recursesubdirs createallsubdirs ignoreversion"; next }
    /^Source: TeXmacs\.ico/ { print "Source: " icon "; DestDir: {app}"; next }
    /^Source: topbanner\.bmp/ { print "Source: " banner "; Flags: dontcopy"; next }
    /ValueName: "TEXMACS_PATH"/ {
      print
      print "Root: HKA; Subkey: \"{code:GetEnvironmentKey}\"; ValueType: string; ValueName: \"SCHEMEHEAPDIRS\"; ValueData: \"{app}\\chez\"; Flags: uninsdeletevalue"
      print "Root: HKA; Subkey: \"{code:GetEnvironmentKey}\"; ValueType: string; ValueName: \"TEXMACS_BOOT_PATH\"; ValueData: \"{app}\\boot\"; Flags: uninsdeletevalue"
      print "Root: HKA; Subkey: \"{code:GetEnvironmentKey}\"; ValueType: string; ValueName: \"TEXMACS_HOME_PATH\"; ValueData: \"{userappdata}\\TeXmacs-chez\"; Flags: uninsdeletevalue"
      next
    }
    {
      gsub(/@PACKAGE@/, "TeXmacs-chez")
      gsub(/@DEVEL_VERSION@/, ver)
      gsub(/@tm_devel@/, "TeXmacs-chez-" ver)
      print
    }
  ' "$ROOT/packages/windows/TeXmacs.iss.in" > "$ISS"
  say "compiling installer with $(cygpath -m "$ISCC")"
  "$ISCC" "$(cygpath -w "$ISS")" > "$TMPDIR/iscc.log" 2>&1 || { tail -40 "$TMPDIR/iscc.log"; die "ISCC.exe failed"; }
  tail -8 "$TMPDIR/iscc.log"
fi

# ------------------------------------------------------------- verification
if [ "$DO_VERIFY" -eq 1 ]; then
  say "headless smoke test of staged tree"
  SCHEMEHEAPDIRS="$(cygpath -m "$STAGE/chez")" \
  HOME="$(cygpath -m "$ROOT/fakehome")" \
  TEXMACS_PATH="$(cygpath -m "$STAGE")" \
  TEXMACS_BOOT_PATH="$(cygpath -m "$STAGE/boot")" \
  TEXMACS_HOME_PATH="$(cygpath -m "$ROOT/fakehome/TeXmacs-chez")" \
  timeout 120s "$STAGE/bin/texmacs.exe" -H \
    -x '(begin (display "BUNDLE_OK: ") (display (texmacs-version)) (newline) (quit-TeXmacs))'
fi

say "bundle ready: $STAGE"
du -sh "$STAGE"
[ "$DO_INSTALLER" -eq 1 ] && say "installer output: $(cygpath -m "$DIST/windows")"
