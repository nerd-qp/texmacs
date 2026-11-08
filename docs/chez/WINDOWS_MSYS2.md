# Building TeXmacs (Chez backend) on Windows with MSYS2

> **Status: builds and runs.** Verified on Windows x86_64 with MSYS2 UCRT64,
> Qt 6.12.0 and Chez Scheme 10.4.1 built from source with `--machine=ta6nt`.
> Phases A–E are confirmed end to end. Phase F (packaging) is not implemented.

Target: MinGW-w64 / UCRT64. Native MSVC is **not** a viable target — MSYS2's
Qt 6 is MinGW-ABI, so the C++ ABI forces the whole build into one ecosystem,
and this repository's `WIN32` CMake branches already assume MinGW.

---

## Phase A — install packages

Use an **UCRT64** shell (`C:\msys64\ucrt64.exe`), not the MSYS shell; the MSYS
shell puts the wrong compiler first in `PATH`.

```bash
pacman -Syu          # may ask you to close and reopen the terminal, then rerun
pacman -S --needed base-devel \
  mingw-w64-ucrt-x86_64-toolchain \
  mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-qt6-base mingw-w64-ucrt-x86_64-qt6-svg \
  mingw-w64-ucrt-x86_64-qt6-5compat \
  mingw-w64-ucrt-x86_64-freetype mingw-w64-ucrt-x86_64-libjpeg-turbo \
  mingw-w64-ucrt-x86_64-libpng mingw-w64-ucrt-x86_64-gmp \
  mingw-w64-ucrt-x86_64-gnutls mingw-w64-ucrt-x86_64-sqlite3 \
  mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-lz4 \
  mingw-w64-ucrt-x86_64-ncurses mingw-w64-ucrt-x86_64-dlfcn
```

The last two are the non-obvious ones:

| Package | Version | Why |
|---|---|---|
| `mingw-w64-ucrt-x86_64-ncurses` | 6.6-4 | `-lncurses`, needed by Chez's `expeditor.o` |
| `mingw-w64-ucrt-x86_64-dlfcn` | 1.4.2-1 | `-ldl` |
| `mingw-w64-ucrt-x86_64-qt6-5compat` | 6.12.0-1 | `Qt6::Core5Compat`, required by `CMakeLists.txt:670` |

MSYS2's Qt is **6.12.0**, the same version the macOS build is validated
against, so there is no version drift on this platform.

---

## Phase B — build Chez Scheme (the gate)

```bash
mkdir -p ~/build && cd ~/build
curl -LO https://github.com/cisco/ChezScheme/releases/download/v10.4.1/csv10.4.1.tar.gz
tar xf csv10.4.1.tar.gz && cd csv10.4.1
./configure --threads --machine=ta6nt
make -j"$(nproc)"
```

`ta6nt` is the x86_64 Windows machine type.

**Checkpoint.** The directory holding the boot images and kernel is
`ta6nt/boot/ta6nt/` — note the machine name appears twice, once for the build
directory and once for the machine. It must contain:

```text
libkernel.a  scheme.h  petite.boot  scheme.boot
```

If `make` produces `libkernel.lib` instead of `libkernel.a`, you have landed on
the MSVC build path. That is still usable — MinGW can link it, because Chez's
embedding API is plain C — but confirm the boot images are present.

If `configure` or `make` fails outright, fall back to the official MSVC build
(`cd wininstall && make` under a Visual Studio prompt) and point `CHEZ_ROOT` at
its output directory.

---

## Phase C — configure and build TeXmacs

```bash
cd /c/path/to/texmacs        # the wip-chez checkout
cmake -S . -B build-win -G Ninja \
  -DTEXMACS_GUI=Qt6 -DSCHEME_IMPL=chez \
  -DCHEZ_ROOT="$(cygpath -m ~/build/csv10.4.1/ta6nt)" \
  -DCHEZ_MACHINE=ta6nt \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-win -j"$(nproc)"
```

`cygpath -m` converts `/c/...` into `C:/...`, which CMake handles more
reliably on Windows. `CHEZ_ROOT` is the parent of `boot/ta6nt`, because
`CHEZ_MACHINE` is appended to it — passing the `ta6nt` directory itself
produces a doubled `ta6nt/boot/ta6nt/ta6nt` path that happens to work but is
misleading.

Unlike macOS, no `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` is needed — MSYS2
installs every Qt 6 module into a single prefix.

---

## Phase D — prove `.so` loading works first

The module loader hardcodes the Unix suffix in `boot-chez.scm:658` and six
places in `compile-texmacs.scm`. Chez on Windows loads shared objects through
`LoadLibrary`, which accepts any extension for a PE image, so this works in
practice — but verify with the first few modules rather than after a
ten-minute compile:

```bash
cd /c/path/to/texmacs
SCHEMEHEAPDIRS="$(cygpath -m ~/build/csv10.4.1/ta6nt/boot/ta6nt)" \
HOME="$PWD/fakehome" \
TEXMACS_PATH="$PWD/TeXmacs" \
TEXMACS_BOOT_PATH="$PWD/build-win/boot" \
./build-win/src/texmacs.exe -compile-modules
```

`TEXMACS_BOOT_PATH` is what tells the module compiler where to write.
`compile-texmacs.scm` used to hardcode `build-texmacos/boot`, so a tree named
`build-win` silently produced modules in the wrong place; it now honours the
variable, mirroring how `boot-chez.scm` resolves modules at runtime.

**Assignment order matters.** `SCHEMEHEAPDIRS` must be written *before*
`HOME`, because the shell expands `$HOME` using the value in effect before any
of these assignments apply. Put `HOME="$PWD/fakehome"` first and
`SCHEMEHEAPDIRS="$HOME/..."` resolves to `<repo>/fakehome/chez/...`, giving:

```text
cannot open boot file .../fakehome/chez/lib/csv10.4.1/ta6nt/petite.boot
```

Use absolute paths (or a variable set beforehand) for anything derived from
`$HOME`.

---

## Phase E — run

```bash
SCHEMEHEAPDIRS="$(cygpath -m ~/build/csv10.4.1/ta6nt/boot/ta6nt)" \
HOME="$PWD/fakehome" \
TEXMACS_PATH="$PWD/TeXmacs" \
TEXMACS_BOOT_PATH="$PWD/build-win/boot" \
./build-win/src/texmacs.exe
```

Same assignment-order rule as Phase D: `SCHEMEHEAPDIRS` before `HOME`, or it
resolves inside `fakehome` and the boot fails.

`TEXMACS_BOOT_PATH` is mandatory. Without it the runtime loads raw `.scm`
sources instead of the compiled modules, producing `invalid context for
definition` from `boot-chez.scm` followed by `variable current-buffer is not
bound` from `init-buffer.scm`. The window may still open, so check the log.

Binary name by platform (`src/CMakeLists.txt:5-11`):

| Platform | Name | Location |
|---|---|---|
| macOS | `TeXmacs` | `build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs` |
| Windows | `texmacs` | `build-win/src/texmacs.exe` |
| Linux | `texmacs.bin` | `build-texmacos/src/texmacs.bin` |

---

## Phase F — packaging into a distributable bundle

Phases A–E produce a binary that runs **from the build tree with environment
variables set**. That is not a bundle.

A packaging pipeline does exist, but only in the **autotools** build: `Makefile.in:527-585`
defines `WINDOWS_BUNDLE`, `WINDOWS_PACKAGE`, `WINDOWS_APPX_CNRS`,
`WINDOWS_APPX_STORE` and `WINDOWS_APPX`. Those targets depend on `@...@`
substitutions (`@QT_PLUGINS_PATH@`, `@MAKEAPPX@`, `@CV2PDB@`) and on an
autotools `TEXMACS` target, so they do not exist in a CMake build — but their
logic is directly reusable, and `packages/windows/copydll.sh` works unchanged.

What `WINDOWS_BUNDLE` does, in order:

1. Copies the whole `TeXmacs/` data tree into `../distr/TeXmacs-Windows/`.
2. Renames `bin/texmacs.bin` → `bin/texmacs.exe` (the CMake build already
   produces `texmacs.exe`, so this step is a no-op here).
3. Copies Ghostscript, and Qt plugins from `$QT_PLUGINS_PATH`.
4. Runs `copydll.sh` on every `.exe` in `bin/`.

`copydll.sh` is the DLL closure pass:

```bash
ntldd -R "$1" | while read -r lib sign full trash; do
  [[ ! -x $dest/$lib && ${full//\\/\/} =~ ${mingwbase} ]] && cp $full $dest
done
```

It walks dependencies recursively and copies only libraries that live under the
MinGW prefix, leaving system DLLs alone. Install `ntldd` first
(`pacman -S mingw-w64-ucrt-x86_64-ntldd`).

### Doing it by hand for the Chez build

```bash
STAGE=../distr/TeXmacs-Windows
mkdir -p "$STAGE/bin"
cp -r TeXmacs/* "$STAGE/"                    # data tree
cp build-win/src/texmacs.exe "$STAGE/bin/"
cp -r build-win/boot "$STAGE/boot"           # 453 compiled modules
mkdir -p "$STAGE/chez"
cp ~/build/csv10.4.1/boot/ta6nt/{petite.boot,scheme.boot} "$STAGE/chez/"

# Qt: DLLs + platforms/qwindows.dll
windeployqt --release --no-translations "$STAGE/bin/texmacs.exe"

# MinGW runtime and everything else it pulls in
packages/windows/copydll.sh "$STAGE/bin/texmacs.exe"

# Installer (Inno Setup, Windows side)
iscc packages/windows/TeXmacs.iss
```

`TeXmacs.iss.in` needs its paths retargeted first — it still assumes the old
layout (`..\..\..\distr\TeXmacs-Windows\LICENSE`, output to
`..\..\..\distr\windows`).

### Remaining gap: `SVNREV` and the heap images

Two things a hand-built bundle still needs, both covered above but easy to miss:

- `SVNREV` at the data-tree root, or startup refuses the tree. The CMake fix
  writes it into the source tree at configure time, so copy it along.
- `petite.boot`/`scheme.boot` for `ta6nt`, and a way for the binary to find
  them without the user setting `SCHEMEHEAPDIRS` — see the blocker below.

### Bundle contents checklist

| Component | Source | Notes |
|---|---|---|
| `texmacs.exe` | `build-win/src/texmacs.exe` | |
| Qt DLLs + plugins | `windeployqt` | needs `platforms/qwindows.dll` or it exits silently |
| MinGW runtime | `libgcc_s_seh-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll` | not copied by `windeployqt` |
| Data tree | `TeXmacs/{progs,fonts,styles,doc,plugins}` | plus a generated `SVNREV` |
| Compiled modules | `build-win/boot/*.so` + `module-deps.scm` | 453 modules |
| Chez heap images | `boot/ta6nt/{petite.boot,scheme.boot}` | architecture-bound, `ta6nt` only |

### The blocker: no Windows branch for `SCHEMEHEAPDIRS`

`src/Texmacs/Texmacs/texmacs.cpp:195-214` auto-sets `SCHEMEHEAPDIRS` to
`<exe>/../Resources/share/chez` — but that entire block is inside `#ifdef
OS_MACOS`. There is no Windows equivalent, so a Windows bundle would depend on
the user setting the variable by hand.

The fix is a small `WIN32` arm in that block, pointing at wherever the bundle
places `petite.boot`/`scheme.boot` (for example `<exe>/chez` or
`<exe>/../share/chez`). Until that exists, a Windows "bundle" is a folder plus
a `.bat` that exports `SCHEMEHEAPDIRS`, `TEXMACS_PATH` and `TEXMACS_BOOT_PATH`.

### Other scaffolding

- `packages/windows/TeXmacs.iss.in` — Inno Setup script; retarget its paths at
  a CMake tree first.
- `packages/windows/resource.rc.in`, `TeXmacs.ico`, banners — usable as-is.
- `packages/msix/*.in` — MSIX manifests, driven by the `WINDOWS_APPX_*` targets.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `cannot find -ldl` | dlfcn not installed | `pacman -S mingw-w64-ucrt-x86_64-dlfcn` |
| `cannot find -lncurses` | ncurses not installed | `pacman -S mingw-w64-ucrt-x86_64-ncurses` |
| `cannot find -lpthread` | wrong shell | use the UCRT64 shell, not MSYS |
| `cannot find -lm` | MinGW folds libm into the CRT | drop `m` from `CMakeLists.txt:883` |
| `Chez Scheme kernel library not found` | `CHEZ_ROOT`/`CHEZ_MACHINE` wrong | must be `ta6nt`, and `libkernel.*` must exist |
| Stray console window | subsystem not set to GUI | check `WIN32_EXECUTABLE` on the target |

---

## Verification checklist

1. `boot/ta6nt/` has all six artifacts.
2. `cmake --build` links without unresolved symbols.
3. `-compile-modules` reports `Failures: 0` (453 modules).
4. Launch prints `texmacs-version` = 2.1.5, `(top-level-bound? 'current-buffer)` = `#t`.
5. No `LOAD-ERROR` / `Exception` lines in the log.

Expected pre-existing failure, present on every platform: `buffer-export`
returns `Error: bad format or data`. Tracked in `TODO_CHEZ.md`, unrelated to
the platform.
