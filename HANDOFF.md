# TeXmacs / Chez Scheme — Handoff (compact, verified 2026-11-05)

**Current tree:** `~/texmacs`, branch `wip-chez`, HEAD `59f601221`. Chez Scheme **10.4.1**, Qt **6.12.0** (macOS arm64) / Qt **6.10.2** (Ubuntu 26.04 arm64). **453/453** Scheme modules transpile and compile to native `.so` with 0 failures. GUI launch verified: `texmacs-version` = 2.1.5, `(top-level-bound? 'current-buffer)` = `#t`, no `ERROR` / `LOAD-ERROR` / segfault in the log.

This is a condensed replacement for the 2854-line chronological handoff. Historical checkpoints, completed roadmaps, disproven designs, and references to artifacts that existed only in an earlier, different Chez tree have been removed (§10). The earlier "embedded engine" port (Chez 10.5.0-pre-release.1, `docker-sandbox-opencode` workspace, `chez-harness`, `build-chez-macos/`) is a **different project**; none of its paths or commands apply here.

> [!NOTE]
> `TODO_CHEZ.md` (856 lines, 55 unchecked items) is a stale historical TODO: it still claims "184 Compiled, 273 Remaining" and "400 modules (88.3%)", and its C++↔Scheme optimization items were disproven by the measurements in §7. Do not use it as a status source.

---

## 1. Hard invariants

1. **Pristine upstream sources.** `.scm` files in `TeXmacs/progs/` stay `git diff`-clean; no dummy defines (`_tm_def_N`), no hardcoded global `eval`, no file-level rewrites.
2. **Topological compilation.** Modules are transpiled, compiled and verified in dependency order; each is isolated in Chez's syntactic `(module <id> (<exports> ...) <imports> ... <body> ...)` (R6RS `(library ...)` migration planned).
3. **Hermetic compilation environment.** `boot-chez.scm` defines `(define compilation-environment (make-parameter (interaction-environment)))`; macro transformers evaluate there at compile time.
4. **Compile-time conditionals.** Chez `if` is an expression — definitions inside it raise `Exception: invalid context for definition`. The transpiler evaluates the test once in `(compilation-environment)`, unwraps the active branch into the module body, and drops dead dialect branches.
5. **Exports are explicit.** Only `define-public`, `provide-public`, `define-public-macro` symbols go into the export header; private helpers stay lexical. Every module gets a fresh-process check that the public API works and `(top-level-bound? 'private-helper)` is `#f`.
6. **AOT serialization.** `compile-file` must target the root `(interaction-environment)`. Never wrap it in `(parameterize ((interaction-environment child-env)) ...)`: Chez's FASL serializer bakes the anonymous RAM environment descriptor into the `.so`, making symbols unreachable in a fresh process.
7. **Never load `init-texmacs.scm`.** All runtime registrations (`lazy-define`, `lazy-menu`, `lazy-keyboard`, fonts, plugin hooks) belong natively in `init-texmacs-chez.scm`.
8. **Fail fast.** On any failure, report it loudly. No `if/else` bypasses, silent catches, or `top-level-bound?` fallbacks that mask missing definitions; fix root causes.
9. **No AI git commits.** All agent changes stay unstaged/uncommitted for user review.

## 2. Toolchain, configure and build (macOS, current machine)

Chez comes from Homebrew — no source build, no `build-chez-macos` tree.

| Component | Path |
|---|---|
| Chez Scheme 10.4.1 (`brew install chezscheme`) | `/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1/tarm64osx` |
| Qt 6.12.0 (`brew install qt`) | `/opt/homebrew/opt/qtbase`, `/opt/homebrew/opt/qtsvg`, `/opt/homebrew/opt/qt5compat` |

The keg ships `libkernel.a`, `scheme.h`, `petite.boot`, `scheme.boot`, `liblz4.a`, `libz.a`. The machine directory is `tarm64osx`, **not** `tarm64le`.

```bash
cd ~/texmacs
cmake -S . -B build-texmacos -G Ninja \
  -DTEXMACS_GUI=Qt6 \
  -DSCHEME_IMPL=chez \
  -DCHEZ_ROOT=/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1 \
  -DCHEZ_MACHINE=tarm64osx \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/qtbase;/opt/homebrew/opt/qt5compat;/opt/homebrew/opt/qtsvg" \
  -DQT_ADDITIONAL_PACKAGES_PREFIX_PATH="/opt/homebrew/opt/qtbase;/opt/homebrew/opt/qt5compat;/opt/homebrew/opt/qtsvg"
cmake --build build-texmacos -j 10
```

Two fatal configure pitfalls:

- `CMakeLists.txt:337/339` defaults `CHEZ_ROOT=/usr/lib/csv10.5.0-pre-release.1` and `CHEZ_MACHINE=tarm64le` → `Chez Scheme kernel library not found`. Override both.
- `Qt6Config.cmake` is in `qtbase` but Svg/Core5Compat are separate kegs; `CMAKE_PREFIX_PATH` alone fails with `Failed to find required Qt component "Svg"`. Set `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` to all three.

Then compile the Scheme modules:

```bash
HOME="$PWD/fakehome" \
SCHEMEHEAPDIRS="/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1/tarm64osx" \
TEXMACS_PATH="$PWD/TeXmacs" \
build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -compile-modules
```

Cold build measured here: 604/604 C++ targets in ~9 min; 453/453 modules in ~10 min, 0 failures.

## 3. Running, packaging, Linux

### 3.1 From the build tree

```bash
cd ~/texmacs
SCHEMEHEAPDIRS="/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1/tarm64osx" \
HOME="$PWD/fakehome" \
TEXMACS_PATH="$PWD/TeXmacs" \
TEXMACS_BOOT_PATH="$PWD/build-texmacos/boot" \
./build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs
```

- `SCHEMEHEAPDIRS`: Chez boot files (`petite.boot`, `scheme.boot`); set explicitly so a Chez upgrade cannot mismatch the linked `libkernel.a`.
- `HOME`: fake home (`fakehome`) keeps the real home clean.
- `TEXMACS_PATH`: data/source tree `TeXmacs/` (contains `progs/`).
- `TEXMACS_BOOT_PATH`: **mandatory** — compiled `.so` modules plus `module-deps.scm`. Without it the runtime loads raw `.scm` and dies with `Exception: invalid context for definition` from `boot-chez.scm`, ending in `LOAD-ERROR .../init-buffer.scm variable current-buffer is not bound`. The GUI may still open, so check the log.

Screenshot verification from a shell is unreliable on current macOS (Screen Recording permission returns only wallpaper); use `CGWindowListCopyWindowInfo` (window number, bounds, alpha, onscreen) plus absence of log errors.

### 3.2 Standalone `.app` / `.dmg`

```bash
cd ~/texmacs
brew install cmake pkg-config qt chezscheme freetype jpeg libpng gnutls gmp
# ... configure/build and -compile-modules as in §2 ...
./packages/macos/make-bundle.sh --bundle-qt --dmg
```

Outputs `dist/TeXmacs-chez-2.1.5/TeXmacs-chez.app` (0 external Homebrew references) and `dist/TeXmacs-chez-2.1.5.dmg`. `make-bundle.sh` resolves its own root, defaults to `$ROOT/build-texmacos` (override `--build-dir <path>`) and `$ROOT/dist`; the bundle carries `progs/` and `boot/` under `Contents/Resources/share/TeXmacs/`, so it needs none of the env vars above. Do **not** set `TEXMACS_BOOT_FILE=texmacs-user.so` — it is not a Chez boot image (`base boot file ... must come before other boot files`).

### 3.3 Linux (Ubuntu 26.04.1 arm64, Qt 6.10.2) — verified

Chez must be built from source: distro packages do not ship `liblz4.a` / `libz.a` in one directory (`CMakeLists.txt:918` hardcodes them; `:919` links `ncurses`).

```bash
sudo apt install -y build-essential cmake ninja-build pkg-config git curl \
  qt6-base-dev qt6-base-dev-tools libqt6svg6-dev qt6-5compat-dev \
  libfreetype-dev libjpeg-dev libpng-dev libgmp-dev libgnutls28-dev \
  libsqlite3-dev zlib1g-dev liblz4-dev libncurses-dev
curl -LO https://github.com/cisco/ChezScheme/releases/download/v10.4.1/csv10.4.1.tar.gz
tar xf csv10.4.1.tar.gz && cd csv10.4.1
./configure --installprefix="$HOME/chez" --threads --installschemename=chez
make -j"$(nproc)" && make install
```

`--threads` matches the Homebrew build; `libncurses-dev` is required (the linker needs the unversioned `libncurses.so`, not just `libncurses6`'s `.so.6`).

```bash
cd ~/texmacs
MACH=$( [ "$(uname -m)" = "aarch64" ] && echo tarm64le || echo ta6le )
cmake -S . -B build-texmacos -G Ninja -DTEXMACS_GUI=Qt6 -DSCHEME_IMPL=chez \
  -DCHEZ_ROOT="$HOME/chez/lib/csv10.4.1" -DCHEZ_MACHINE="$MACH" -DCMAKE_BUILD_TYPE=Release
cmake --build build-texmacos -j"$(nproc)"
```

Linux needs no `CMAKE_PREFIX_PATH` / `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` (the distro installs every Qt 6 module in one prefix). The executable is **`build-texmacos/src/texmacs.bin`** (`src/CMakeLists.txt:5-11`) — there is no `.app` wrapper, so adjust macOS commands.

`CMakeLists.txt` writes `TeXmacs/SVNREV` from `ALTERNATIVE_VERSION` (`CMakeLists.txt:407`) at configure time when missing or stale; the file is untracked (`.gitignore:26`). On older trees generate it with `grep -o 'ALTERNATIVE_VERSION "[^"]*"' CMakeLists.txt | cut -d'"' -f2 > TeXmacs/SVNREV`. A missing SVNREV produces "does not contain a valid TeXmacs installation" **without** the "incompatible version" line.

Compile and run:

```bash
SCHEMEHEAPDIRS="$HOME/chez/lib/csv10.4.1/$MACH" HOME="$PWD/fakehome" \
TEXMACS_PATH="$PWD/TeXmacs" ./build-texmacos/src/texmacs.bin -compile-modules
SCHEMEHEAPDIRS="$HOME/chez/lib/csv10.4.1/$MACH" HOME="$PWD/fakehome" \
TEXMACS_PATH="$PWD/TeXmacs" TEXMACS_BOOT_PATH="$PWD/build-texmacos/boot" \
./build-texmacos/src/texmacs.bin
```

**Assignment order matters:** `SCHEMEHEAPDIRS` must precede `HOME`, otherwise `$HOME` expands to the real home and the boot path becomes `<repo>/fakehome/chez/lib/.../petite.boot`.

## 4. Compilation pipeline

Per module `kernel/.../<name>.scm`:

1. **Load deps** — `(load "build-texmacos/boot/path/depN.so")` then `(import path:depN)`.
2. **Transform AST** — strip `(texmacs-module ...)`; `define-public` → export + plain `define`; `define-public-macro` → exported hygienic `define-syntax`; private `define-macro` → private `define-syntax`; evaluate top-level `if` tests in `(compilation-environment)` and unwrap the live branch; plain `define` stays private.
3. **Pre-evaluate** definitions in `(compilation-environment)` so intra-file macros/tables are live, then emit `(module kernel:sub:name (<exports>) (import (for dep run expand)) ... <body>)` to `build-texmacos/boot/kernel/.../<name>.scm`.
4. **Compile** with `(compile-file ".../<name>.scm" ".../<name>.so")`.
5. **Verify in a fresh process**: load prereq + target `.so`, import both, call a public procedure, and assert `(top-level-bound? 'private-helper)` is `#f`; run via `.../TeXmacs -H -x '(load "verify_module.scm")'` with `SCHEMEHEAPDIRS`, `TEXMACS_PATH`, `TEXMACS_BOOT_PATH` set.

Batch modes:

```bash
build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -compile-modules          # incremental (default)
build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -recompile-modules        # full clean rebuild
TEXMACS_RECOMPILE_ALL=1 build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -compile-modules
```

> [!WARNING]
> **Incremental builds run, but there is no guarantee that the result compiles correctly.** `-compile-modules` compares mtimes, marks up-to-date `.so` files `UP-TO-DATE` and loads them directly. Cached `.so` files carry serialized FASL environment descriptors that can mismatch newly recompiled modules, producing unbound-variable errors (`make-soft-port`, `hash-ref`, `ahash-ref`). A successful exit is **not** evidence that the produced modules are correct. Use `-recompile-modules` whenever correctness matters; treat incremental only as a fast smoke pass (~seconds, 0–1 recompiled). A full rebuild of 453 modules takes ~10 min.

Historical 181/186-module timings came from the retired workspace and are not comparable to this tree.

## 5. Engine invariants (C++ ↔ Chez)

1. **GC pinning.** Chez's nursery moves young objects. Any `ptr` held in a C++ global/static must be `Slock_object(p)`-ed (and `Sunlock_object` on shutdown), or it dangles after GC.
2. **Thread activation.** Every C++→Scheme entry (`eval_scheme`, `call_scheme`) from Qt event loops needs an RAII `Sactivate_thread` / `Sdeactivate_thread` activator plus a recursive mutex (`chez_lock`).
3. **Unbound marker.** `Stop_level_value` returns `0x1e` for unbound symbols (not NULL/0) without throwing; validate handles with `Sprocedurep(p)`.
4. **Guile→Chez reader differences:** `#{symbol}#` → `|symbol|`; bare `'|` → `(string->symbol "|")`; octal `#\00` → `#\x00`; `#\cr` → `#\return`.
5. **FFI exceptions.** C++ `string` exceptions cannot be caught by Scheme `guard`; shims must screen preconditions (e.g. `file-exists?`) before invoking C++ routines.
6. **Top-level variable cells.** A bare symbol inside a running top-level procedure resolves through a mutable cell; if that procedure triggers redefinition of its own symbol (`lazy-define-force`), later reads see the **new** value. Never use `(eq? proc ,name)` for self-identity; use lexical bindings or explicit state flags.
7. **Introspection is stubbed.** Chez provides no `procedure-name` / `procedure-source` / `procedure-documentation`; `init-texmacs-chez.scm:297-300` stubs them to `#f` (and `func?` to `procedure?`). Guile-side code assumes a form comes back: `promise-source` (`menu-widget.scm:402`) would `(car #f)` and break all menu construction; `replace-procedures` injects `#f`; shortcut hints, check marks, `:applicable` greying and balloon/synopsis help are silently disabled. Guarded 2026-10-04 with `(pair? source)` in `promise-source` — crash gone, features still missing. Correct fix: capture the `(lambda ...)` form at definition time in `tm-define` and in the per-form loader in `chez_tm.cpp`, and store it in a procedure-keyed side table.
8. **Pure-expression `tm-define`.** It is expression-only (no local definitions), installing values with `define-top-level-value` and syntax with `define-top-level-syntax` in `(interaction-environment)`. This avoids closing the definition context prematurely in R6RS module bodies and removes the need for `define-macro-trace` / `public-trace`.
9. **String encoding duality (Unicode text vs. raw binary byte buffers).** In GNU Guile 1.8, Scheme strings were raw 8-bit C `char*` arrays (`scm_str2scm` / `scm_scm2str`) without Unicode awareness, so TeXmacs historically reused Scheme strings for two conflicting roles:
   - **Unicode/Cork text**: Evaluated by HTML/XML/MathML converters and test suites (`regtest-htmltm`, `regtest-mathtm`), requiring UTF-8 decoding/encoding so non-ASCII characters (`é`, `α`, `→`) are not mangled into multi-byte fragments or truncated when code point $> 255$.
   - **Raw binary buffers**: Read by `(string-load ...)` and `tmfs-load` for assets such as PNG images.
   Chez Scheme strings are native vectors of Unicode scalar characters. Passing binary strings through UTF-8 encoding (`encode_as_utf8` / `decode_from_utf8` in `tmscm_to_string` / `string_to_tmscm`) expands raw bytes $\ge 128$ into multi-byte UTF-8 sequences (e.g. PNG magic `0x89` $\to$ `0xC2 0x89`), corrupting image files written to disk and triggering `Cannot read image file ... in qt_image_size` and `warning: cannot render`. Conversely, purely casting characters to 8-bit `char` truncates code points $> 255$ and splits UTF-8 sequences, failing parser regression tests. Resolution requires differentiating binary buffers (image magic header sniffing or R6RS `bytevector`) from UTF-8 text transfers.

## 6. Diagnostic rules

- **Non-hygienic `when`/`unless`.** `abbrevs.scm`'s `define-public-macro` versions shadowed Chez's hygienic ones and stripped lexical context inside `while`'s template. Both definitions were deleted; use Chez's library versions. Chez's `when` needs at least one body form — write `(when c (void))`. Any `define-public-macro` used inside another macro's template is suspect (`and-with` nests `with`; audit next).
- **`pretty-print` after `expand`.** To diagnose a "variable is not bound" that only appears in compiled modules, pretty-print `(expand '<form>)`. The expander renames lexically bound identifiers to `#{name <unique>}`; the same identifier renamed in one place and bare in another means a non-hygienic macro lost lexical context. Reproduce headlessly by copying `init-texmacs-chez.scm`, appending `(load "/tmp/probe.scm")`, and launching with `-i /tmp/init-probe.scm`; add `(delayed (:idle 3000) (open-preferences))` to reproduce GUI-only bugs without a mouse. Probe output goes to stdout — grep the log.
- **Macros must exist at COMPILE time.** A macro must already be a syntax binding when the consuming module is compiled; `define-top-level-syntax` afterwards does not repair an already-compiled call. Any module using a macro from another module must be compiled **after** it, declare the `:use`, and confirm the ordering. If a declared dependency never appears in the emitted `(import ...)`, suspect ordering. Kernel modules need `:use` for macros, not for plain functions.
- **Stale cache after a `TEXMACS_PATH` change.** `$TEXMACS_HOME_PATH/system/cache` memoises filesystem lookups by absolute path; a cache built for `./TeXmacs` breaks a packaged `.app` — menu entries and style macros silently disappear with no error. Clear it first: `mv ~/.TeXmacs/system/cache ~/.TeXmacs/system/cache.bak`. The Chez build defaults `TEXMACS_HOME_PATH` to `~/.TeXmacs-chez` so Guile and Chez never share a cache. When a packaged build renders differently, clear the cache before suspecting missing files.

## 7. Measured performance

### 7.1 Compilation cost (Chez 10.4.1, 453 modules, `-recompile-modules`)

Full rebuild **8 m 6 s**; Tier 7 ≈ **70%** of total.

| Tier | Time |
|---|---|
| Kernel | 6.8 s |
| Tier 2 (Application Core) | 12.1 s |
| Tier 3 (Core Editing) | 20.4 s |
| Tier 4 (Desktop GUI & Menus) | 24.4 s |
| Tier 5 (Document Converters) | 44.0 s |
| Tier 6 (Dynamic & Interactive Sessions) | 33.3 s |
| Tier 7 (Extended Subsystems & Plugins) | 340.0 s |

Cumulative: kernel+tier2 28.5 s, through tier3 39.5 s, tier4 59.1 s, tier5 93.2 s. Tier 7 isolated: 211 modules, transpile 16.7 s, compile 21.3 s, load 4.5 s, wall 131 s (slowest file 1.06 s) — many medium modules, not one outlier. Transpile subphases: `eval eager forms` 51,089 ms of ~52.0 s (**98%**); read forms 787 ms, bind keywords 112 ms, everything else < 30 ms. So `eval-eager-form!` — which evaluates every `tm-define` / `define-public` / `define-macro` / `define-state` / `define-table` into `compilation-environment` before `compile-file` compiles it again — is the cost. Optimizing `prepare-forms` or source generation will not move the needle; reducing duplicate work between eager `eval` and `compile-file` is the highest-leverage change. Caveat: these figures were measured on the 452-module census, so absolute totals are approximate for 453.

### 7.2 Keystroke latency (measured 2026-11-05; macOS arm64, Qt 6.12.0, Chez 10.4.1, Release)

Earlier assumptions that C++↔Scheme dispatch dominates typing were **wrong by two orders of magnitude**. The C++↔Scheme optimization blueprint (`Scall0..3` trampolines, procedure caching, `foreign-callable`, thread-activation batching) is **ruled out**: a "Phase 2" arity-trampoline implementation was built, measured (215 → 217 ns on the procedure path) and **reverted**. Do not re-add it without a measurement. `Scall4` does not exist in the Chez C API (max `Scall3`).

**Keystroke path:** Qt `QTMWidget::keyPressEvent` → `edit_interface_rep::handle_keypress` (`edit_keyboard.cpp:365`) → `start_editing()` → `call ("keyboard-press", gkey, t)` → `(keyboard-press key time)` (`kbd-handlers.scm:26`) → `key_press(string gkey)` → shortcut lookup via `sv->get_keycomb` / `find_key_binding` / `call ("kbd-find-key-binding", key)` → `archive_state()` → `call ("kbd-insert", rew)` → `(kbd-insert s)` (math: `math-edit.scm:73`; text: `kbd-handlers.scm:40`) → `cpp-insert` / `insert_tree` mutates the tree → `update_focus_loci()` → `notify_change (THE_DECORATIONS)` → `end_editing()` (typesetting, line breaking, box model) → `keyboard_message ("kbd-" * key)` → Qt `paintEvent` / `drawPixmap` on dirty rectangles.

**Phase 1 landed:** all twelve `call (string|const char*, ...)` overloads in `src/Scheme/Scheme/object.cpp:455-482` now pass `symbol_to_tmscm (fun)` instead of `eval_scheme (fun)`; `tm-apply` resolves symbols through the module-env chain, so behaviour is unchanged.

| path | before | after |
|---|---|---|
| `call ("name")` | 3412–4196 ns | 341–568 ns (median ~354) |
| `call (proc)` | 206–225 ns | 206–225 ns |

~10.7x on the string path, but typing makes only **~3.5 symbol calls per keystroke**, so it saves ~11 µs of ~2000 µs (**0.5%**). `docs/chez/bench/manual.scm` (124 pages) performs only ~20k symbol calls per full regeneration — under 1% of ~8 s, below run-to-run spread (baseline mean 8273 ms vs Phase 1 8513 ms). **Never use that benchmark to evaluate dispatch changes.**

**Per-phase `handle_keypress`** (`setup` = `apply_changes` + `start_editing`; `scheme` = `call ("keyboard-press", ...)`; `finish` = focus loci + `notify_change` + `end_editing`):

| document | keys | p50 | mean | max |
|---|---|---|---|---|
| `man-manual.en.tm` (117 pp) | 201 | 2 ms | 2.3 ms | 11 ms |
| `man-user-manual.en.tm` (273 pp) | 105 | 3 ms | 3.2 ms | 36 ms (`return`) |

`setup` was 0 ms on every key; `finish` never exceeded 2 ms; document size barely matters. `call ("delayed-keyboard-press", ...)` at `edit_keyboard.cpp:401` is **IME pre-edit only**; normal keys use `call ("keyboard-press", ...)` at line 403.

**The lag is repaint.** In one 334-key session: repaint 4,870 ms vs 941 ms in all key handlers (~84% of interactive cost); only 763 of 17,972 repaint calls did any work. Two single repaints dominate:

| repaint | time | regions | area (px²) | ratio to window |
|---|---|---|---|---|
| after `return` | 352 ms | 1 | 145,801,600 | 119x |
| after `a` | 181 ms | 1 | 326,829,648 | 266x |

A full-window repaint is 1,228,800; every other repaint is ≤ 36 ms. Mechanism: `repaint_invalid_regions` (`src/Plugins/Qt/qt_simple_widget.cpp:679-681`) collapses the dirty set into its least upper bound when `area (lub) < 1.2 * area (invalid_regions)`. A keystroke dirtying two far-apart document regions (a page break, or an edit that renumbers TOC/index entries) produces a document-spanning rectangle 119–266x the window. The `invalidate_rect` probe showed the origin is `qt_simple_widget_rep::send(slot, blackbox)` on the very first render: `rect=[28,84,754,348816]` — 726 px wide, **348,732 px tall** (all 273 pages). `notify_change (THE_DECORATIONS)` on every key is the prime suspect. Next step: instrument `send` to print the slot and message body, then decide whether the editor should invalidate the visible page only.

**Consequences:** further C++↔Scheme dispatch work cannot improve typing (measured ceiling ~0.5%). The actionable target is **invalidation granularity**: stop producing document-spanning rectangles (avoid LUB collapse for far-apart regions, or invalidate per page/viewport).

**Instrumentation caveats.** The `TEXMACS_KBD_PROBE` / `TEXMACS_PAINT_PROBE` / `TEXMACS_INV_PROBE` variables described in earlier revisions came from a temporary instrumented local build and are **not in this tree**. `QTMWidget::paintEvent` never fired when launched from a shell here, so screen-blit cost is not included — only TeXmacs-side rendering. The compiled Qt widget code is `src/Plugins/Qt/`, **not** `src/Plugins/Qt6/` (a parallel copy; patching it changes nothing). Scripted keystrokes via `osascript ... keystroke` are denied by macOS TCC (`-10004`); drive typing in Scheme instead.

### 7.3 Benchmarks (`docs/chez/bench`)

| file | measures | usage |
|---|---|---|
| `manual.scm` | full manual regeneration, per phase + page count | `-x '(load "docs/chez/bench/manual.scm")'` |
| `ui.scm` | interactive: menus, typing, opening a document | `-x '(load "docs/chez/bench/ui.scm")'` |

Run from the repository root with the §3.1 environment plus `TEXMACS_DOC_PATH`. `ui.scm` is ported from mgubi's `docs/femtolisp/bench/ui.scm` (commit `1fb56ec`) and reports cold + median of three warm runs; a key is driven exactly as the event loop drives it, including typesetting:

```scheme
(define (key k)
  (archive-state) (start-editing) (key-press k) (end-editing) (update-forced))
```

```
BENCH menus-text cold 720 warm 110 items 99
BENCH menus-math cold 82 warm 74 items 106
BENCH typing-text-520-keys cold 1955 warm 1358
BENCH typing-math-270-keys cold 1477 warm 1480
BENCH open-change-log cold 2103 warm 284
```

Chez vs published s7/femtolisp numbers (§7.7 of `src/docs/femtolisp/07-performance.md`; load average ~6.5 here vs ~4 there — treat the gap as an upper bound):

| task | Chez | s7 | femtolisp |
|---|---|---|---|
| menus-text, warm | 110–114 ms | 85–121 ms | 76–86 ms |
| typing-text-520, warm | 1205–1358 ms (~2.4 ms/key) | 723–826 ms | 775–825 ms |
| typing-math-270, warm | 1323–1480 ms (~5.2 ms/key) | 834–855 ms | 882–978 ms |
| open-change-log, warm | 198–284 ms | 127–144 ms | 121–132 ms |

The large-document case is off by default: `TEXMACS_BENCH_BIG=1 ... -x '(load "docs/chez/bench/ui.scm")'` types into the 273-page manual (~80 s per round, currently ~197 ms/key) and reproduces §7.2's repaint behaviour. `update-forced` is stricter than the GUI, which defers typesetting to the paint path. **Load matters more than any of these gaps** — the same binary gave `manual.scm expand` 763–1213 ms at load ~2 and 2109 ms at load 7.3. Report load average with every number; never compare a single run against a single run.

### 7.4 Where the real typing speed-up lives: incremental typesetting

`upsilon_texmacs`'s `wip_fixes` branch contains **PR #333** ("Incremental typesetting and typing caches: an edit no longer typesets or page-breaks the rest of the document", merged `47428ea`, 2026-10-17; 72 commits, 68 files, +5,335/-356), which targets exactly the cost measured in §7.2:

| operation | before | after |
|---|---|---|
| typing a letter | 283 ms | **17 ms** |
| joining two paragraphs | 854 ms | 16 ms |
| inserting a new section | 1355 ms | 62 ms |
| bridge re-typesets, manual, new section | 18,805 | 519 |
| bridge re-typesets, manual, paragraph join | 13,117 | 3 |

Three independent causes, all producing byte-identical output: **(1) reuse by inputs** — a cached paragraph ("bridge") was re-typeset whenever anything in its environment changed, now reused unless an input it actually read changed; **(2) page breaks** — every edit re-searched all breaks even with no line-height change, now cached by a signature of page items; **(3) automatic labels** — counter-based `auto-1`, `auto-2` renamed every following label on insertion and forced a full re-typeset; the new `auto-id` primitive numbers labels per document tag, stored as a tree addendum with a Scheme fallback.

Related upstream PR `texmacs/texmacs#112` (15 commits, 32 files, +1,132/-67) cut 57.4 → 24.7 ms/key on a 2000-paragraph document but was **closed unmerged** and only helps papyrus (continuous) page mode, not paper mode; 10 of its 13 commits live inside #333.

**None of this is in this tree** (verified: no `auto-id`, no page-break cache, no `TEXMACS_TYPESET_READS`, no `TEXMACS_EDIT_PROFILE` under `src/` or `TeXmacs/progs/`). Porting order, cheapest first, measuring after each with `TEXMACS_BENCH_BIG=1 docs/chez/bench/ui.scm`:

1. **Stable automatic labels** (`auto-id`): one C++ primitive, a tree addendum, a Scheme fallback in `std-automatic.ts`. Removes the renumbering cascade — the most likely single cause of the 181–352 ms repaints.
2. **Page-break signature caching** (`src/Typeset/Page/` plus the breaker); removes the full re-search per edit.
3. **Reuse by inputs** (`bridge_rep`, `edit_env_rep`, `bridge_document`) — largest piece; use the PR's `check`-mode old-vs-new diffing and fuzz test `892205c`.

Do not treat #333 as a drop-in (5,335 lines across 68 files, depends on other `wip_fixes` infrastructure). Its `off`/`check` switch variables (`TEXMACS_TYPESET_READS`, `TEXMACS_PAGE_BREAK_CACHE`, `TEXMACS_TYPESET_CACHES`, `TEXMACS_PAGE_REUSE`, `TEXMACS_EDIT_PROFILE`) are worth copying as a validation pattern.

## 8. Test suites

Native toolchain tests (`src/Scheme/Chez/*-test.scm`), **173 checks, 0 failures**:

| suite | checks | covers |
|---|---|---|
| `compile-inventory-test.scm` | 17 | tier partitioning, whitelist paths, bootstrap order (`chez-compat.scm` first) |
| `compile-graph-test.scm` | 41 | dependency waves, topological sort, SCC, cycle breaking |
| `compiler-db-test.scm` | 50 | FASL compiler DB, record serialization, interface/source hashing, corrupt cache invalidation |
| `compiler-scan-test.scm` | 29 | AST parsing of `tm-define` / `define-macro` / `define-public`, exports, module headers |
| `static-analysis-test.scm` | 36 | whole-program call graph, unbound variables, dead code |

```bash
(cd texmacs && for t in src/Scheme/Chez/*-test.scm; do /opt/homebrew/bin/chez -q "$t"; done)
```

TeXmacs runtime suite: `(run-all-tests)` in `TeXmacs/progs/check/check-master.scm` covers `regtest-htmltm`, `regtest-xmltm`, `regtest-tmlength`, `regtest-environment`, `regtest-mathtm`, `regtest-tmhtml`, `regtest-tmmltm`, `regtest-prog-format`, `regtest-cite-sort`. Fixes applied: `non` moved into `kernel/boot/chez-compat.scm` and `kernel/library/list.scm` compiled before `base.scm` (`list-drop-while`); `(:use (prog prog-format-test))` → `(:use (prog prog-format))` typo fixed. Known open mismatch: `regtest-tmhtml` `<img class="image">` — the runtime converter is modern, but the test fixture `make-expected-sub` in `tmhtml-test.scm` omits `(class "image")`.

```bash
TEXMACS_HOME_PATH="$PWD/.sandbox-texmacs" TEXMACS_BOOT_PATH="$PWD/build-texmacos/boot" \
  ./build-texmacs/TeXmacs.app/Contents/MacOS/TeXmacs -H -x '(begin (use-modules (check check-master)) (run-all-tests))'
```

Not wired into `run-all-tests`: `regtest-tm-convert` (`kernel/texmacs/tm-convert-test.scm`), `run-integration-tests` (server notifications, backups, disk cache), `check-all` / `run-checks` (`utils/test/test-latex-export.scm`). Other reference benchmarks: R7RS/Gabriel tasks, startup boot latency (`TIME-SERVER-INIT`, `TIME-OPEN-WINDOW-TOTAL`, `TIME-PRE-GUI-LOOP`), full-document conversion via `-H -C`, and `time ... -recompile-modules`.

## 9. Open work

1. Find the `slot` / message in `qt_simple_widget_rep::send` producing the 348,732 px-tall invalidation; stop emitting document-spanning rectangles (§7.2).
2. Port PR #333 in the three-step order above, measuring with `TEXMACS_BENCH_BIG=1 docs/chez/bench/ui.scm` after each step (§7.4).
3. Fix `-compile-modules` incremental dependency propagation so cached `.so` files can be trusted, or make the full rebuild the default (§4).
4. Restore Guile introspection features by capturing source forms at definition time (§5.7).
5. Reconcile `regtest-tmhtml`'s stale fixture with the modern runtime converter (§8).
6. Do not trust `TODO_CHEZ.md` as a status source (see header note).
7. Resolve string encoding duality in `chez_tm.cpp`: differentiate binary buffers (image magic sniffing or R6RS `bytevector`) from UTF-8 text so PNGs render without breaking XML/MathML Unicode test suites (§5.9).

## 10. What was removed, and where to recover it

The 2854-line chronological handoff was compressed to this file on 2026-11-05. Removed: interim milestones (39/39, 116/184/220/400/452-module checkpoints), roadmaps and "next steps" already completed, the disproven C++↔Scheme optimization blueprint, the reverted "Phase 2" trampoline design, resolved-bug narratives, and all references to artifacts that exist only in the retired workspace (`build-chez-macos/`, `chez-harness`, `build-texmacos.sh`, `misc/chez-probe.sh`, `src/Scheme/Chez/compile_kernel.scm`, the `TEXMACS_*_PROBE` instrumentation, Chez 10.5.0-pre-release.1 paths). Duplicate `## 4` / `## 5` / `## 6` numbering and three copies of the boot-module table were collapsed. Still-valid engine invariants from the legacy handoff were folded into §5.

Recovery is reversible; nothing was committed:

- Full pre-compression `HANDOFF.md` (2854 lines) is stored as git blob `db519f3c3c258b0024754139fe2123033e601b6b` in this repo's object database: `git cat-file blob db519f3c3c258b0024754139fe2123033e601b6b > HANDOFF.md`.
- The same file is at `/Users/king-kong/.Trash/HANDOFF-pre-compression-2026-11-05.md` (SHA-256 `cd9a96a5…`).
- The verbatim 920-line legacy handoff is git blob `bcc5cd938401916caa83d74e0e9dc449ec231ef5` and `/Users/king-kong/.Trash/HANDOFF.md` (SHA-256 `bbb80bd2…`).
