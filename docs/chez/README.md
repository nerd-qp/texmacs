# TeXmacs / Chez Scheme — Architecture & Developer Guide

**Current tree:** `~/Documents/GitHub/texmacs`, branch `wip-chez`, HEAD `dc683be7e` (2026-11-06: `linter.scm` phase 4 installs the macro dependency closure proactively — see §4.1; the change is unstaged, together with the new `src/Scheme/Chez/macro-closure*.scm`). Chez Scheme **10.4.1**, Qt **6.12.0** (macOS arm64) / Qt **6.10.2** (Ubuntu 26.04 arm64). **453/453** Scheme modules transpile and compile to native `.so` with 0 failures. GUI launch verified: `texmacs-version` = 2.1.5, `(top-level-bound? 'current-buffer)` = `#t`, no `ERROR` / `LOAD-ERROR` / segfault in the log. Runtime suite: only the documented `regtest-tmhtml` fixture mismatch and the `regtest-xmltm` encoding mismatch (§5.9) remain.

This is a condensed replacement for the 2854-line chronological handoff. Historical checkpoints, completed roadmaps, disproven designs, and references to artifacts that existed only in an earlier, different Chez tree have been removed (§10). The earlier "embedded engine" port (Chez 10.5.0-pre-release.1, `docker-sandbox-opencode` workspace, `chez-harness`, `build-chez-macos/`) is a **different project**; none of its paths or commands apply here.

> [!NOTE]
> `TODO_CHEZ.md` (1008 lines, 53 unchecked items) is a stale historical TODO: it still claims "184 Compiled, 273 Remaining" and "400 modules (88.3%)", and its C++↔Scheme optimization items were disproven by the measurements in §7. Do not use it as a status source.

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
10. **No Scheme source in C++.** `src/Scheme/Chez/chez_tm.cpp` contains no Scheme code and builds no Scheme source strings. Everything the kernel needs on the Scheme side lives in `TeXmacs/progs/kernel/boot/boot-chez.scm`, which `initialize_scheme()` loads with Chez's primitive `load` **before** `initialize_glue()`. The only Scheme knowledge left in C++ is the *names* it caches with `Stop_level_value` (`tmscm-null`, `tm-blackbox-guardian`, `tm-eval-string`, `tm-load-file`, `tm-apply`, `list?`, `equal?`, `object-stack`, `tm-install-procedure!`). C++ no longer calls any Scheme procedure by name; `tm-reinstall-io-hooks!` is invoked from `init-texmacs-chez.scm`. Consequences: (a) `boot-chez.scm` must not call a glue procedure at load time; (b) the engine globals must be defined at the very top of that file, because `reap-blackboxes!` is installed as the collect-request handler a few forms down and reads `tm-blackbox-guardian`, so a GC mid-load otherwise raises `variable tm-blackbox-guardian is not bound`; (c) `init-texmacs-chez.scm` and `init-linter.scm` must not re-load `boot-chez.scm` (guard on `boot-chez-loaded?`), or `tm-load-file` is recompiled against the `load` shim and the two recurse forever.

   Dead weight dropped from the bootstrap on 2026-11-05 (160 lines): the per-form / source-loader path (`tm-load-forms-itemized`, `tm-load-from-source`, `tm-read-all-forms`, `tm-compile-eval`, `tm-form-diagnose`, `tm-collect-keywords`, `tm-bind-keywords`) and the compiled-module candidate search (`tm-so-candidates`, `tm-find-so-file`), plus the `tm-load-probe` stub. All of it was unreachable — `tm-load-file` is only `(load f)`, `load-module-file` resolves `.so` files through `module-so-file`, and `compile-texmacs.scm` defines its own `tm-collect-keywords` / `tm-bind-keywords`. Consequence: the `LOAD-START` / `LOAD-SUMMARY` / `FORM-STILL-FAILS` / `LOAD-BATCH-FALLBACK` diagnostic tokens no longer exist; a failing file reports `LOAD-ERROR` with its condition and backtrace, and nothing reports per form.

   Also dropped (83 lines): the boot copy of `delayed-sub`. It duplicated the `define-public` in `kernel/texmacs/tm-dialogue.scm` (same algorithm, rewritten from `npair?` / `nlist?` / `==` / `with` to `pair?` / `list?` / `eq?` / `let`). It looked load-bearing — 119 `(delayed ...)` forms across 58 modules, 54 of which do not import `tm-dialogue` in their header — but it was not: `delayed` lives in `tm-dialogue.scm` next to its own `delayed-sub`, and after the module is imported the interaction environment holds *that* one. Proven by removing it: 453/453 modules compile, and all five `delayed-sub` branches (`:idle`, `:pause`, `:every`, `:require`, plain) evaluate to working thunks whose generated form starts with `with`, i.e. the tm-dialogue implementation, not the deleted `let`-based one.

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

Cold build measured here: 604/604 C++ targets in ~9 min; 453/453 modules in ~10 min, 0 failures (pre-rework pipeline; the single-environment compiler rebuilds all 453 modules in ~30 s, §7.1).

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
4. **Compile** with `(compile-file ".../<name>.scm" ".../<name>.so")` within a `dynamic-wind` block that unbinds ephemeral helper definitions (`*ephemeral-syms*`).
5. **Register loaded module** — load the compiled `.so` with `(parameterize ((compile-export-mode? #t)) ...)` so exports remain permanently bound in `(interaction-environment)`.

### 4.1 Single Reusable Environment & Ephemeral Lifecycle Design

The compilation pipeline in `src/Scheme/Chez/compile-texmacs.scm` operates entirely within a single reusable `(interaction-environment)`, completely eliminating the performance and RAM overhead of `(copy-environment ...)` while guaranteeing module exports and closures persist cleanly across all 453 modules:

1. **Zero-Copy Reusable Environment**:
   - `compile-texmacs.scm` runs `transpile-and-compile-module` directly against `(compilation-environment)` pointing to `(interaction-environment)`.
   - `publish-value!` and `publish-syntax!` are guarded with `(unless (eq? (compilation-environment) (interaction-environment)) ...)` so loaded procedures are not redundantly published or clobbered.
2. **Ephemeral Syms Scratch-off via `dynamic-wind`**:
   - Helper procedures and expand-time forms brought in by `oracle-bring-in-form!` and gated helper evaluation are recorded in `*ephemeral-syms*`.
   - `compile-file` is wrapped in `dynamic-wind` cleanup: immediately after compilation finishes (whether by normal completion or non-local exit/exception), all symbols in `*ephemeral-syms*` are unbound via `unbind-symbol!` and cleared from `*oracle-installed*`.
   - Permanent exports from loaded `.so` files stay live in the environment; transient helpers introduced solely for the current module's macro expansion are scratched off.
3. **Symmetric Syntax Capture & Native Unbound Object Restoration**:
   - `oracle-install!` captures each symbol's native `orig-syntax = (top-level-syntax name env)` prior to evaluation and pairs them in `*ephemeral-syms*` as `(cons name orig-syntax)`.
   - `unbind-symbol!` cleanly resets the value cell using Chez Scheme's internal unbound sentinel `(define-top-level-value sym (unbound-marker) env)` where `(unbound-marker)` returns `(#%$unbound-object)`. This ensures `top-level-bound?` returns `#f` and subsequent reads throw Chez's native `Exception: variable <sym> is not bound` rather than evaluating to `#!void`.
   - It restores `(define-top-level-syntax sym orig-syntax env)` unconditionally: for macros, this demotes the macro back to its native identifier core-transformer; for values, it idempotently preserves the identifier core-transformer without creating foreign gensym alias redirections.
4. **Gated Eager Helper Evaluation (`*eager-gated?*`) & Clean Separation of Runtime Forms**:
   - Gated evaluation defaults to active (`TEXMACS_EAGER_GATE!=0`).
   - Plain value definitions are deferred to `compile-file`, while macro definers and helpers needed for macro expansion are pulled in on demand via `macro-closure.scm`.
   - This prevents syntax-rules keyword shadowing (such as `...` in `abbrevs.scm` being bound as a variable, which would break auxiliary ellipsis repetition matching in macros like `with-global`).
   - Runtime table generators that do not provide expand-time syntax (such as `cas-define-test`) are excluded from `eager-skip?` and skipped in `eval-eager-form!`, allowing Chez Scheme's `compile-file` to compile them directly in source order.
   - For `define-table`, `eval-install-value-env` passes `#f` to `guard-eval`, matching `define` and `define-public` so that any tables containing runtime-only unquoted procedures fail silently during pre-evaluation without noisy warnings.
5. **AST Lexical Scope Integrity in `mc-free-references`**:
   - `macro-closure.scm` requires binding forms (`let`, `let*`, `letrec`, `letrec*`) to have a body expression (`pair? (cddr x)`) before treating them as lexical binders.
   - Prevents table entries like `(let ,gui-make-let)` in quasiquoted tables from being misparsed as Scheme `let` binders, ensuring unquoted helpers are accurately identified and installed by the oracle.
6. **Preserving Raw `define-public` / `provide-public` Forms**:
   - `eval-eager-form!` evaluates `define-public` and `provide-public` directly via `(eval x (compilation-environment))` without rewriting them to `define`.
   - The macro definition of `define-public` checks `(compile-export-mode?)` dynamically: when false (during helper evaluation), it behaves as internal definitions; when true (upon loading `.so`), it publishes exports.
7. **String search is Scheme under Chez**:
   - `string-search-forwards` and `string-search-backwards` are `define-public`s in `kernel/boot/chez-compat.scm`. The generated glue installs the C++ versions only when `TEXMACS_ENGINE_CHEZ` is undefined (`glue_basic.cpp`, same guard as `string-load`), and `build-glue-basic.scm` still declares both, because Guile keeps the byte-indexed versions.
   - Reason: C++ `search_forwards` / `search_backwards` return UTF-8 byte offsets, which is what Guile 1.8 strings index (byte arrays) but not what Chez strings index (characters); the byte-oriented bridge also truncates a code point above U+00FF to one byte. Searching the Chez string keeps the result in `string-ref` / `substring` units.
   - `compile-texmacs.scm` no longer shadows the pair, so compiler and editor share one implementation. Verified headless: `(string-search-forwards "β" 0 "αβγ")` = 1, `(string-search-forwards "x" 0 "αβγ")` = -1, `(string-search-backwards "β" 3 "αβγ")` = 1, `(string-contains? "αβγ" "β")` = `#t`; the old glue returned the byte offset 2 for the first.

Batch modes:

```bash
# 0. Recompile C++ binary if commits touch C++ or glue files:
ninja -C build-texmacos                                                    # or: cmake --build build-texmacos -j 10

# 1. Module compiler invocation:
build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -compile-modules          # incremental (default)
build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -recompile-modules        # full clean rebuild (~30 s, §7.1)
TEXMACS_RECOMPILE_ALL=1 build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -compile-modules
```

> [!IMPORTANT]
> **Always recompile the C++ binary when commits touch C++ code.** `boot-chez.scm` is loaded dynamically from source at runtime, whereas the C++ executable is compiled ahead-of-time. If commits touch `chez_tm.cpp`, `chez_tm.hpp`, or glue code (e.g. FFI string/bytevector bridges), running with a stale binary causes immediate FFI type signature mismatches (such as string vs. bytevector) that hang or crash the session. Run `ninja -C build-texmacos` before running `-compile-modules` or launching the editor.

> [!WARNING]
> **Incremental builds run, but there is no guarantee that the result compiles correctly.** `-compile-modules` compares mtimes, marks up-to-date `.so` files `UP-TO-DATE` and loads them directly. Cached `.so` files carry serialized FASL environment descriptors that can mismatch newly recompiled modules, producing unbound-variable errors (`make-soft-port`, `hash-ref`, `ahash-ref`). A successful exit is **not** evidence that the produced modules are correct. Use `-recompile-modules` (or `TEXMACS_RECOMPILE_ALL=1`) whenever running into trouble or certifying a release; at **~30 s** for the full 453-module rebuild (§7.1) it is now cheap enough to prefer over trusting mtimes. For fast smoke testing, selectively delete target `.so` files in `build-texmacos/boot/` to force recompilation of only those modules.

Historical 181/186-module timings came from the retired workspace and are not comparable to this tree.

### 4.2 Static analysis: `TeXmacs -lint`

`texmacs.cpp:819` sets `lint_mode`, which makes `tm_server` boot `progs/init-linter.scm` instead of `progs/init-texmacs-chez.scm` (compile mode similarly boots `progs/init-chez-compile.scm`) — kernel only, no GUI, no editor program. `init-linter.scm` loads `src/Scheme/Chez/linter.scm`, which runs five phases over the progs tree and writes four TSVs:

```bash
SCHEMEHEAPDIRS="/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1/tarm64osx" \
HOME="$PWD/fakehome" TEXMACS_PATH="$PWD/TeXmacs" TEXMACS_HOME_PATH="$PWD/.sandbox-texmacs" \
TEXMACS_LINT_CLOSURE_OUT=/tmp/macro-closure.tsv \
  ./build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -lint
```

| phase | what | measured 2026-11-06 |
|---|---|---|
| 1 | index every definition site | 459 files, 14431 top-level forms, 11710 definitions |
| 2 | select macro sites by hardcoded head rule | 387 (280 kernel, 107 analysed) |
| 3 | expand each with the kernel only, harvest free names | 106 ok, 1 fail, 82 distinct deps |
| 4 | install the proactive closure, expand, evaluate | 106 ok, 1 fail, 402 installed |
| 5 | syntactic module dependency graph | 408 nodes / 1929 edges, 209 SCCs, 7 waves |

Outputs: `$TEXMACS_LINT_OUT` (per macro: status + deps), `_DEPS_OUT` (dependency demand), `_MODULES_OUT` (edges), `_CLOSURE_OUT` (per macro: its transitive helper set).

**Dependency resolution is proactive, not reactive.** The old model trapped `&assertion`, parsed `"variable <name> is not bound"` out of the message, evaluated the definition and retried up to 400 times. That cannot work for a missing *macro*: `expand` does not raise for an unbound identifier, it lowers it to `($primitive n $top-level-value)`, so `(for (i l) ...)` stayed a procedure call and `i` was reported as a free variable. `src/Scheme/Chez/macro-closure.scm` instead computes, before anything runs and with no environment, the transitive closure of every name a form needs, and installs it in dependency order.

**The relation is a DAG of SCCs, not a tree.** 117 mutually recursive groups exist here (largest 62 names: the `Big-*` / `And-*` symbol tables). Two mechanisms handle that: the DFS keeps a three-state mark per node and stops at any node it is already inside — the "no revisit" rule, which terminates the walk and yields the install order; and Tarjan's condensation makes the recorded *set* exact, so every member of a cycle reports the whole cycle rather than whichever part the walk reached first. The walker also reads `syntax-rules` templates (pattern variables, literals and `...` excluded), because a template's helper identifiers are invisible to the definer-headed walk and a missing one silently misparses at the consumer.

Phase 4's *outcome* is unchanged at 106/1 — the kernel already sufficed — so the gain is structural: the retry loop and the message scraping are gone, and macro dependencies classified "defined but not installed" fell **10 → 1**. The closure is 1194 definitions, 117 SCCs, stop rule fired 62 times; 402 install in 415 ms with 8 failures (`graphical-tag-list`, `graphical-group-tag-list` need runtime state `-lint` does not create).

`macro-closure.scm` is plain definitions loaded with `primitive-load` (a TeXmacs process has no library search path into `src/Scheme/Chez`), so `src/Scheme/Chez/macro-closure-report.scm` can also run it standalone: `chez --script src/Scheme/Chez/macro-closure-report.scm /tmp/closure.tsv` indexes the tree and records 345 closures in **0.7 s**, no build and no TeXmacs. That script is a recorder, not a build-order tool: a closure says what must be *live* before a macro expands, not which module compiles first, and a form still needs its own module context to expand at all.

## 5. Engine invariants (C++ ↔ Chez)

1. **GC pinning.** Chez's nursery moves young objects. Any `ptr` held in a C++ global/static must be `Slock_object(p)`-ed, or it dangles after GC. Two lifetimes, two patterns:
   - **Process-lifetime handles are locked once and never unlocked.** That is the nine cached in `initialize_scheme` plus `object-stack`. There is no later point to unlock at: `start_scheme` runs once, `server sv;` (`texmacs.cpp:593`) is the only construction site of the server that calls `initialize_scheme`, and the tree never calls `Sdestroy_heap` / `Sscheme_deinit`, so the heap outlives every caller. It also costs no memory — every one of them is independently reachable from the interaction environment (`tmscm-null`, `tm-apply`, `object-stack`, … are top-level definitions; `list?` / `equal?` are live library bindings), so the lock pins the *address*, not the lifetime. Unlocking on shutdown would be strictly harmful: `Sunlock_object` re-permits relocation, so any teardown path still calling through `tm_apply_proc` / `tm_load_file_proc` would read a stale pointer — the exact bug the lock exists to prevent.
   - **Per-object handles** (`object.cpp`) are locked on construction and `Sunlock_object`-ed when drained — the pattern for anything with a finite lifetime. `load_scheme_file` likewise locks its temporary path string and unlocks it immediately.

   Cost, measured 2026-11-05 by locking N extra pairs in `initialize_scheme` and timing collections: **~2–3 ns per locked object per collection**, linear, paid by *every* minor and major collection.


   | locked objects | forced full collects | 100 M-pair allocation churn |
   |---|---|---|
   | 0 | 0.0 ms/collect (idle heap) | 237–284 ms |
   | 100 000 | 0.27 ms/collect | 276–413 ms |
   | 1 000 000 | 3.0 ms/collect | 929–1118 ms (~4x slower) |

   So the nine pointers cached in `initialize_scheme` (~25 ns per collection) are free, and locking a few hundred more procedure lookups would still be free. Do not lock per-call results, per-module caches, or anything large: for an object that is not otherwise reachable, the lock makes it a permanent root, so the cost becomes both throughput (scanned every collection) and memory (never reclaimed).

2. **Thread activation.** Every C++→Scheme entry (`eval_scheme`, `call_scheme`) from Qt event loops needs an RAII `Sactivate_thread` / `Sdeactivate_thread` activator plus a recursive mutex (`chez_lock`).
3. **Unbound marker.** `Stop_level_value` returns `0x1e` for unbound symbols (not NULL/0) without throwing; validate handles with `Sprocedurep(p)`.
4. **Guile→Chez reader differences:** `#{symbol}#` → `|symbol|`; bare `'|` → `(string->symbol "|")`; octal `#\00` → `#\x00`; `#\cr` → `#\return`.
5. **FFI exceptions.** C++ `string` exceptions cannot be caught by Scheme `guard`; shims must screen preconditions (e.g. `file-exists?`) before invoking C++ routines.
6. **Top-level variable cells.** A bare symbol inside a running top-level procedure resolves through a mutable cell; if that procedure triggers redefinition of its own symbol (`lazy-define-force`), later reads see the **new** value. Never use `(eq? proc ,name)` for self-identity; use lexical bindings or explicit state flags.
7. **Introspection is stubbed.** Chez provides no `procedure-name` / `procedure-source` / `procedure-documentation`; `init-texmacs-chez.scm:297-300` stubs them to `#f` (and `func?` to `procedure?`). Guile-side code assumes a form comes back: `promise-source` (`menu-widget.scm:402`) would `(car #f)` and break all menu construction; `replace-procedures` injects `#f`; shortcut hints, check marks, `:applicable` greying and balloon/synopsis help are silently disabled. Guarded 2026-10-04 with `(pair? source)` in `promise-source` — crash gone, features still missing. Correct fix: capture the `(lambda ...)` form at definition time in `tm-define`, and store it in a procedure-keyed side table.
8. **Pure-expression `tm-define`.** It is expression-only (no local definitions), installing values with `define-top-level-value` and syntax with `define-top-level-syntax` in `(interaction-environment)`. This avoids closing the definition context prematurely in R6RS module bodies, and is why `define-macro-trace` / `define-public-macro-trace` are **gone**: both were removed on 2026-11-05, together with the `'macro-transformer` property they recorded, because no module used the macros and nothing in the toolchain read the property. The transpiler still expands `tm-define` / `tm-define-macro` / `tm-property` in interpreter style on its own.
9. **String encoding duality (OPEN — raw bytes on the bridge, by design).** The bridge in `chez_tm.cpp` is byte-for-byte: `string_to_tmscm` stores `(unsigned char) s[i]` per byte, `tmscm_to_string` casts `Sstring_ref` back to `char`. One Scheme character = one C++ byte, in both directions.
   - **Why it is not a UTF-8 bridge.** TeXmacs reuses Scheme strings for two conflicting roles, and Guile 1.8 (byte arrays) let it get away with that. `string-load` / `string-save` and the tmfs handlers move PNG and embedded-object data through Scheme strings (`utils/misc/artwork.scm`, `generic/embedded-edit.scm`). Decoding/encoding UTF-8 here expands PNG magic `0x89` to `0xC2 0x89`, which inflates and corrupts image data.
   - **The cost.** A code point above `0xFF` cannot cross: `tmscm_to_string` truncates it to its low byte, so `U+03BC μ` reaches C++ as `0xBC` and `regtest-xmltm` reports one mismatch in the `Bx` row of `latin1-chart`. Conversely a non-ASCII C++ string arrives in Scheme as one character per UTF-8 byte.
   - **Measured 2026-11-05:** this failure is *pre-existing*, not a regression. Stashing every working-tree change and relinking only the C++ (`boot-chez.scm` is loaded from source, never compiled) reproduces it exactly: `Do not match!` ×1, `Regression failure` ×2. Verified healthy in the same state: `(string-save (string-load png) out)` is byte-identical (SHA-256 match on a 97 KB PNG).
   - **A UTF-8 bridge was tried and reverted.** Decoding UTF-8 on the way in and encoding on the way out, with bytes that fail UTF-8 validation mapped to `U+F0000+b` (Supplementary Private Use Area-A) and back, *is* a bijection — it made `regtest-xmltm` pass and kept the PNG round trip byte-identical. It was still rejected: any Scheme code that inspects a byte buffer numerically (magic sniffing, `string-ref` on loaded data) sees `0xF0089` instead of `0x89`, and nothing in the tree guarantees binary only ever travels load→save. Do not re-land it without auditing every binary consumer.
   - **Where the real fix belongs.** At the boundary that knows whether it holds text or bytes — an explicit byte-buffer type (R6RS `bytevector`) for the image/tmfs path, leaving text on a UTF-8 bridge — not inside these two functions, which cannot tell the two apart.
   - **`tmfs-load` binary handling (RESOLVED):** `string-load` returns an R6RS bytevector for binary images (`welcome-videos.png`, artwork, thumbnails). Previously, `tmfs-load` in `tm-file-system.scm` checked `(if (string? r) r (object->tmstring r))`; because `(string? #vu8(...))` is `#f`, it fell back to `object->tmstring`, serializing the bytevector into the ASCII text string `"#vu8(137 80 78 71 ...)"` and saving corrupted text files to `/tmp/` that Qt could not render. Updated `tmfs-load` and `object->tmstring` to pass bytevectors directly.

9b. **Cork encoding & FFI string/bytevector transcoding (RESOLVED in `boot-chez.scm`).**
   TeXmacs uses Cork (TeX T1 font encoding) for font metrics, hyphenation, and spellchecking.
   - **The Latin-1 Container Hack:** Chez Scheme strings are 32-bit Unicode scalar values (`uint32_t`). To preserve legacy Guile 1.8 compatibility (`(string? (utf8->cork ...))` returning `#t` and calls to `string-length`, `substring`, `string=?`), raw 8-bit Cork bytes (`0x00`–`0xFF`) are tunneled through Scheme strings using R6RS `(latin-1-codec)` via `*latin1-tc*`.
   - **Memory & Semantic Trade-offs:**
     - Memory efficiency is reduced: each 8-bit byte occupies a 32-bit box on the Scheme heap.
     - Semantic/linguistic operations on Cork strings are broken: `char-upcase` on Cork `0xF7` (`œ`) maps to Unicode `U+00F7` (`÷`), not Cork `0xD7` (`Œ`); `char-alphabetic?` on Cork `0x80`–`0xBF` (carons/ogoneks) returns `#f` (Unicode C1 controls). Only structural byte operations (`string-length`, `string-ref`, `substring`, `string-append`, `string=?`) work.
     - Real long-term fix: Migrate all Cork buffers to native R6RS bytevectors (`#vu8(...)`) and Scheme callers to `bytevector-*`.
   - **Trap 1: End-of-Line (eol-style) Normalization:** `(make-transcoder (latin-1-codec))` defaults to platform-native EOL style (`crlf` on Windows, or normalizing `\r\n` / `\r` $\to$ `\n` on POSIX). This would silently delete or convert byte `0x0D` (`\r`), which in Cork encoding is the single low quote glyph (`‚`), shifting string indices and corrupting data. `*latin1-tc*` explicitly passes `(eol-style none)`.
   - **Trap 2: Literal UTF-8 Characters in .scm Files / REPL:** `string->cork-bytes` expects Scheme characters in range `U+0000`–`U+00FF`. Passing literal multi-byte characters (e.g. `"你好"` or `"α"`) directly to Cork-expecting routines cannot fit in Latin-1 bytes. Non-ASCII characters must first be processed through `(utf8->cork s)` (which invokes C++ `utf8_to_cork` over UTF-8 bytes to generate ASCII escape sequences like `"<#4F60>"` or `"<alpha>"`).
   - **Dispatch Architecture:** Centralized in `tm-call-by-name` wrapper in `boot-chez.scm` via `recur-transcode-bytevector` / `recur-transcode-string`, keeping `tm-install-procedure!` completely generic and `tm-apply` clean of Cork branching.


10. **Glue installation is a Scheme procedure, not generated source.** `chez_install_procedure` no longer builds `(define <name> (lambda args (tm-call-by-name "<name>" args)))` as a string and `eval`s it. It registers the C++ pointer in `tm_proc_registry` and calls `(tm-install-procedure! "name")`, which `define-top-level-value`s a closure over its own name. Failure is reported per name as `INSTALL-FAILED` instead of aborting the whole glue pass. Two ordering traps:
   - `tm-install-procedure!` must already exist, so `boot-chez.scm` is loaded **before** `initialize_glue()` — the reverse of the old order.
   - `tm-output` / `tm-errput` are *also* C++ glue procedures (`glue_basic.cpp`), so `initialize_glue()` replaces the Chez-native writers defined in `boot-chez.scm`. With the new order `init-texmacs-chez.scm` therefore calls `(tm-reinstall-io-hooks!)` right after the bootstrap, restoring `original-display` / `console-error-port`. Without it, non-ASCII `display` output would be pushed through the byte-oriented `tmscm_to_string` bridge.

## 6. Diagnostic rules

- **Non-hygienic `when`/`unless`.** `abbrevs.scm`'s `define-public-macro` versions shadowed Chez's hygienic ones and stripped lexical context inside `while`'s template. Both definitions were deleted; use Chez's library versions. Chez's `when` needs at least one body form — write `(when c (void))`. Any `define-public-macro` used inside another macro's template is suspect (`and-with` nests `with`; audit next).
- **`pretty-print` after `expand`.** To diagnose a "variable is not bound" that only appears in compiled modules, pretty-print `(expand '<form>)`. The expander renames lexically bound identifiers to `#{name <unique>}`; the same identifier renamed in one place and bare in another means a non-hygienic macro lost lexical context. Reproduce headlessly by copying `init-texmacs-chez.scm`, appending `(load "/tmp/probe.scm")`, and launching with `-i /tmp/init-probe.scm`; add `(delayed (:idle 3000) (open-preferences))` to reproduce GUI-only bugs without a mouse. Probe output goes to stdout — grep the log.
- **Macros must exist at COMPILE time.** A macro must already be a syntax binding when the consuming module is compiled; `define-top-level-syntax` afterwards does not repair an already-compiled call. Any module using a macro from another module must be compiled **after** it, declare the `:use`, and confirm the ordering. If a declared dependency never appears in the emitted `(import ...)`, suspect ordering. Kernel modules need `:use` for macros, not for plain functions.
- **Stale cache after a `TEXMACS_PATH` change.** `$TEXMACS_HOME_PATH/system/cache` memoises filesystem lookups by absolute path; a cache built for `./TeXmacs` breaks a packaged `.app` — menu entries and style macros silently disappear with no error. Clear it first: `mv ~/.TeXmacs/system/cache ~/.TeXmacs/system/cache.bak`. The Chez build defaults `TEXMACS_HOME_PATH` to `~/.TeXmacs-chez` so Guile and Chez never share a cache. When a packaged build renders differently, clear the cache before suspecting missing files.
- **Testing whether a name is bound in Chez.** Neither primitive answers it. `top-level-bound?` is `#f` for a *syntax* binding, so every macro looks unbound; `top-level-syntax?` is `#t` for any symbol at all, including one that was never defined. The only discriminating signal is the syntax value — an installed macro is a `procedure`, an unbound name yields a `#<core-transformer>`. Use `(procedure? (top-level-syntax s env))`; using `top-level-syntax?` on 2026-11-06 made a whole install pass a silent no-op (0 of 1194 definitions installed, and nothing failed).
- **Never re-evaluate a live macro.** Evaluating a `define-macro` / `define-syntax` form whose name is already a working syntax binding replaces the transformer with one whose template identifiers resolve in the evaluator's context rather than the defining module's. Expanding the site then fails with renamed-but-unbound identifiers (`(#{map *top*:map})`, `(#{body *top*:body})`). One unguarded re-evaluation took linter phase 4 from 106 expansions to 7.
- **`(interaction-environment)` is global.** Anything evaluated into it can redefine the analyser's own top-level names: a definition named `mode` in the tree overwrote the linter's run mode mid-run, which silently switched it back to the reactive path. Prefix analyser globals (`*mcr-*`) or read them before installing anything.
- **Do not index headerless files.** The four `init-*.scm` scripts at the progs root are bootstrap glue, not modules. `init-linter.scm:133` declares a two-argument `(func? p kind)` stub that sorts *before* `kernel/library/base.scm:273`'s real 2+-argument definition, so an index built over them records the stub and every `(func? x 'tag n)` call looks broken.

## 7. Measured performance

### 7.1 Compilation cost (453 modules, `-recompile-modules`)

**Single-environment compiler (measured 2026-11-07): 453/453 modules, 0 failures, median 29.7 s (5 runs, 22.6–35.6 s), peak RSS 292 MB (278 MiB).** That is ~65 ms per module, ~52 ms of it inside `compile-file`.

Measured on macOS arm64 (8 cores, load average 2.2–3.3), branch `wip-chez` at `247394d40` with the working-tree compiler changes, binary linked against the local Chez **10.5.0-pre-release.1** (`SCHEMEHEAPDIRS=chez-macos/tarm64osx`). The phase split comes from a temporary timing-instrumented copy of `compile-texmacs.scm` (nanosecond timers per phase, repo untouched).

| Phase | Time (median of 3 runs) | Share of wall |
|---|---|---|
| **Transpile** — read, rewrite, eager eval, emit `<name>.scm` | **3.37 s** (2.36–4.02) | **~11%** |
| - read forms | 0.41 s | 1.4% |
| - prepare/rewrite | 0.003 s | <0.1% |
| - eager eval into `(compilation-environment)` | 2.54 s | 8.4% (75% of transpile) |
| - emit `.scm` + import bookkeeping | 0.42 s | 1.4% |
| **Compile** — `compile-file` → native `.so` | **23.8 s** (18.3–28.7) | **~82%** |
| Load `.so` + register exports | 1.36 s (1.05–1.46) | ~4.7% |
| Tier loop, manifest, `compiler-db` write | 0.68 s | ~2.3% |

`compile-file` now dominates, so transpiler work can move at most the ~11% transpile share — and ~75% of that is still eager evaluation. Peak memory (`/usr/bin/time -l`): max RSS 283–292 MB across the 5 runs (median 291.9 MB = 278 MiB); macOS peak memory footprint 262–268 MB (250–256 MiB).

**Previous pipeline (per-module `copy-environment`, eager evaluation ungated by default): full rebuild 8 m 6 s; Tier 7 ≈ 70% of total** (measured 2026-11-05, Chez 10.4.1, `~/texmacs` tree). Superseded above, kept as the baseline that motivated the redesign:

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

That prediction held: gating the eager pass by default and dropping the per-module `copy-environment` took the total from 8 m 6 s to ~30 s between these two measurements (table above; different tree and Chez build, so indicative only).

### 7.2 Keystroke latency (measured 2026-11-05; Apple M2 Virtual Machine, macOS arm64, Qt 6.12.0, Chez 10.4.1, Release)

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

Chez vs published s7/femtolisp numbers (§7.7 of `src/docs/femtolisp/07-performance.md`; multi-run measured on commit `705e0d47` on Apple M2 Virtual Machine with `QT_QPA_PLATFORM=offscreen`):

| task | Chez (`705e0d47` warm mean) | s7-11.9 (10-run warm mean) | femtolisp (10-run warm mean) |
|---|---|---|---|
| menus-text, warm | **83.0 ms** (±4.7 ms) | 102.0 ms (±10.8 ms) | 92.4 ms (±5.1 ms) |
| menus-math, warm | **64.2 ms** (±2.2 ms) | 80.8 ms (±7.2 ms) | 74.3 ms (±2.95 ms) |
| typing-text-520, warm | **1147.0 ms** (±43.2 ms, ~2.2 ms/key) | 1104.6 ms (±53.4 ms, ~2.1 ms/key) | 1059.4 ms (±35.4 ms, ~2.0 ms/key) |
| typing-math-270, warm | **1152.6 ms** (±56.7 ms, ~4.3 ms/key) | 1067.5 ms (±35.7 ms, ~4.0 ms/key) | 1047.8 ms (±46.4 ms, ~3.9 ms/key) |
| open-change-log, warm | **185.4 ms** (±8.7 ms) | 215.5 ms (±12.4 ms) | 188.0 ms (±12.7 ms) |
| manual-124-pages, total | **6549.0 ms** (warm peak) | 6970.7 ms (±348.1 ms) | **6596.3 ms** (±206.9 ms) |

*Detailed breakdowns, raw vectors, and manual compilation runs are recorded in [`docs/chez/benchmarks.md`](benchmarks.md).*

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

### 7.5 Figure 9.5 animations: O(document) per frame (measured 2026-11-06)

The composed-animation examples in the user manual (Fig. 9.5: Compose, Blinking, TeXmacs logo, Magix) are **not** slowed down by their durations. Timing is correct: `sec-length` is 1000 ms (`src/Typeset/Env/env_length.cpp:533`), and on a one-page document blinking/logo measured ~1 s per state and the Magix cycle ~3 s (`anim-repeat` of a 2 s `anim-progressive` + 1 s `anim-constant`). The cost is that per-frame bookkeeping is **global, not per animated box**:

- `edit_interface_rep::animate()` (`src/Edit/Interface/edit_interface.cpp:1147-1153`) calls `eb->anim_invalid()` on the **whole buffer box**.
- The default `box_rep::anim_invalid()` (`src/Typeset/Boxes/Basic/boxes.cpp:795`) and `box_rep::anim_next()` (`:784`) recurse into every subbox of every page; only the animation boxes override them. Nothing caches the set of boxes that animate.
- `draw_text()` (`src/Edit/Interface/edit_repaint.cpp:49-55`) recomputes the same full-tree `anim_next()` minimum on every repaint, and floors the next frame at `now + 25 ms`.
- `anim_effect_box_rep::anim_next()` asks for `get_refresh_time (0.0)` — now + 1 ms — while a progressive animation is incomplete (`src/Typeset/Boxes/Animate/animate_boxes.cpp:391-399`). The Magix example is progressive 2 s of every 3 s, so while the figure is visible the editor requests a frame every 25 ms continuously.

Each frame therefore performs two O(all boxes in all pages) traversals while only four small table cells change. `sample` of the generated manual with Fig. 9.5 on screen (3 s, main thread; pre-existing `build-texmacos` binary — the profiled path is C++-only and identical in this tree): **23% of all samples in `animate()` → `box_rep::anim_invalid()`**, and **93% of repaint samples in `draw_text()` → `box_rep::anim_next()`**. Rendering the figure itself is negligible.

Consequence: the animation clock is wall-clock and stays correct, but the frame rate degrades with document size. On the ~67-page generated manual the walks still fit the 25 ms budget; at the 273-page manual's box count they do not — frames are dropped and the animation looks slow/choppy. §7.2's LUB collapse (`qt_simple_widget.cpp:679-681`) can amplify a frame further by merging the small animation rectangle with distant dirty rectangles into one large repaint.

Ruled out: Chez↔C++ dispatch (no Scheme on the per-frame path), player speed/elapsed (`basic_player_rep` speed 1, elapsed = wall clock, `src/Kernel/Abstractions/player.cpp:90-100`), and the ms/second units. Fix direction: keep a per-view registry of animated boxes and walk only those in `animate()`/`draw_text()` instead of recursing from the root.

## 8. Test suites

Native toolchain tests (`src/Scheme/Chez/*-test.scm`), **231 checks, 0 failures**:

| suite | checks | covers |
|---|---|---|
| `compile-inventory-test.scm` | 17 | tier partitioning, whitelist paths, bootstrap order (`chez-compat.scm` first) |
| `compile-graph-test.scm` | 41 | dependency waves, topological sort, SCC, cycle breaking |
| `compiler-db-test.scm` | 50 | FASL compiler DB, record serialization, interface/source hashing, corrupt cache invalidation |
| `compiler-scan-test.scm` | 29 | AST parsing of `tm-define` / `define-macro` / `define-public`, exports, module headers |
| `static-analysis-test.scm` | 36 | whole-program call graph, unbound variables, dead code |
| `macro-closure-test.scm` | 58 | dependency closure: chain / diamond / 2- and 3-cycle / self-edge, exactness inside a cycle, install-order validity, free-name walker on source *and* core AST, `syntax-rules` template deps |

```bash
cd texmacs
for t in src/Scheme/Chez/*-test.scm; do /opt/homebrew/bin/chez -q "$t"; done   # 2 of 6 need the cwd below
cd src/Scheme/Chez && for t in compiler-db-test.scm compiler-scan-test.scm; do /opt/homebrew/bin/chez -q "$t"; done
```

`compiler-db-test.scm` and `compiler-scan-test.scm` locate `compiler-db.scm` relative to the working directory, so the single-line loop above reports `cannot find compiler-db.scm` for both; run them from `src/Scheme/Chez` (verified 2026-11-06: 17 + 41 + 36 + 50 + 29 + 58 = 231 checks, 0 failures). `macro-closure-test.scm` finds `macro-closure.scm` by searching up from the cwd, so it runs from either.

TeXmacs runtime suite: `(run-all-tests)` in `TeXmacs/progs/check/check-master.scm` covers `regtest-htmltm`, `regtest-xmltm`, `regtest-tmlength`, `regtest-environment`, `regtest-mathtm`, `regtest-tmhtml`, `regtest-tmmltm`, `regtest-prog-format`, `regtest-cite-sort`. Fixes applied: `non` moved into `kernel/boot/chez-compat.scm` and `kernel/library/list.scm` compiled before `base.scm` (`list-drop-while`); `(:use (prog prog-format-test))` → `(:use (prog prog-format))` typo fixed. Known open mismatches: **`regtest-xmltm`** — one character in the `Bx` row of `latin1-chart` (`U+03BC μ` is truncated to `0xBC ¼` by the byte-oriented string bridge, §5.9; confirmed pre-existing by A/B against a stashed tree); **`regtest-tmhtml`** `<img class="image">` — the runtime converter is modern, but the test fixture `make-expected-sub` in `tmhtml-test.scm` omits `(class "image")`.

```bash
SCHEMEHEAPDIRS="/opt/homebrew/Cellar/chezscheme/10.4.1/lib/csv10.4.1/tarm64osx" HOME="$PWD/fakehome" \
TEXMACS_PATH="$PWD/TeXmacs" TEXMACS_HOME_PATH="$PWD/.sandbox-texmacs" \
TEXMACS_BOOT_PATH="$PWD/build-texmacos/boot" \
  ./build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -H \
  -x '(begin (use-modules (check check-master)) (run-all-tests) (display "ALL-TESTS-DONE") (newline) (quit-TeXmacs))'
```

`run-all-tests` does not return normally: the last `regtest-*` raises, so a following `(quit-TeXmacs)` never runs and the process hangs until killed. Judge the run by the log (count `Do not match!` / `Regression failure`) and by whether `ALL-TESTS-DONE` was printed, not by the exit status. A single `regtest-xmltm`-style check can be run in isolation with `-x '(begin (use-modules (convert tools xmltm-test)) (regtest-xmltm) (quit-TeXmacs))'`.

Not wired into `run-all-tests`: `regtest-tm-convert` (`kernel/texmacs/tm-convert-test.scm`), `run-integration-tests` (server notifications, backups, disk cache), `check-all` / `run-checks` (`utils/test/test-latex-export.scm`). Other reference benchmarks: R7RS/Gabriel tasks, startup boot latency (`TIME-SERVER-INIT`, `TIME-OPEN-WINDOW-TOTAL`, `TIME-PRE-GUI-LOOP`), full-document conversion via `-H -C`, and `time ... -recompile-modules`.

## 9. Open work

1. Find the `slot` / message in `qt_simple_widget_rep::send` producing the 348,732 px-tall invalidation; stop emitting document-spanning rectangles (§7.2).
2. Port PR #333 in the three-step order above, measuring with `TEXMACS_BENCH_BIG=1 docs/chez/bench/ui.scm` after each step (§7.4).
3. Fix `-compile-modules` incremental dependency propagation so cached `.so` files can be trusted, or make the full rebuild the default (§4).
4. Restore Guile introspection features by capturing source forms at definition time (§5.7).
5. Reconcile `regtest-tmhtml`'s stale fixture with the modern runtime converter (§8).
6. Do not trust `TODO_CHEZ.md` as a status source (see header note).
7. Resolve the string encoding duality (§5.9). Phase 1 complete: `string-load` and `tmfs-load` now return R6RS `bytevector` for binary assets (PNG, JPEG, fonts), passing directly to C++ without string serialization. Next: migrate remaining `raw-data` paths to bytevectors before migrating text to a pure UTF-8 bridge. A UTF-8 bridge over *all* strings was tried on 2026-11-05 and reverted — see §5.9 for why the `U+F0000+b` escape is not sufficient.
8. The bootstrap now hard-depends on `TEXMACS_PATH` being resolvable when `initialize_scheme()` runs. If the packaged `.app` or a future Windows build fails with `bootstrap file not found`, check `boot_scheme_path()` in `chez_tm.cpp` before anything else.
9. **`func?` has the wrong arity in both bootstraps.** `init-texmacs-chez.scm:122` and `init-linter.scm:133` both declare `(define (func? p kind) (procedure? p))`, while `kernel/library/base.scm:273` is `(define-public (func? x f . opts) ...)`. Any `(func? x 'tag n)` — e.g. `convert/tools/tmconcat.scm:90` — raises `incorrect number of arguments` instead of returning `#f`. Fix the stubs to `(lambda (x f . opts) (procedure? x))`. Not urgent for the editor, but it costs the linter and every standalone harness a whole class of spurious failures.
10. **Linter phase 4 leaves 8 install failures**, all `graphical-tag-list` / `graphical-group-tag-list`: they read `graphics-state`, which `-lint` never creates. Decide whether to model that state in the linter or to keep reporting them as expected.
11. **The closure has no consumer yet.** Its only effect so far is a recorded TSV plus the removal of the retry loop — phase 4's outcome did not move. The natural consumer is `compile-texmacs.scm`'s eager-evaluation step: gating it by default already took that step from 51 s of the 52 s transpile budget (§7.1) down to 2.5 s; installing a definition once, in closure order, instead of per-file on demand is the remaining thing to try there, and it must be measured against the §7.1 table before it is believed.
12. **Do not quote numbers from the older exploratory scripts.** `macro-lazy-install.scm`, `macro-helpers.scm`, `macro-inventory.scm` and `macro-expand-inventory.scm` predate `macro-closure.scm` and re-implement a partial TeXmacs bootstrap by hand. That bootstrap is where their numbers come from, not the macro layer: they need the transpiler's three eval rewrites (uncurry, strip docstring, unwrap a top-level `if`) and still hit stub limits. `macro-lazy-install.scm` is worth keeping only as the record of what the reactive model did.
13. **Animation frame cost is O(document).** `animate()` and `draw_text()` walk the entire box tree every frame via `anim_invalid()` / `anim_next()`, so Fig. 9.5's animations in the full manual run at a collapsing frame rate (§7.5). Track animated boxes per view instead of recursing from the root.

## 10. What was removed, and where to recover it

The 2854-line chronological handoff was compressed to this file on 2026-11-05. Removed: interim milestones (39/39, 116/184/220/400/452-module checkpoints), roadmaps and "next steps" already completed, the disproven C++↔Scheme optimization blueprint, the reverted "Phase 2" trampoline design, resolved-bug narratives, and all references to artifacts that exist only in the retired workspace (`build-chez-macos/`, `chez-harness`, `build-texmacos.sh`, `misc/chez-probe.sh`, `src/Scheme/Chez/compile_kernel.scm` (now `src/Scheme/Chez/compile-texmacs.scm`), the `TEXMACS_*_PROBE` instrumentation, Chez 10.5.0-pre-release.1 paths). Duplicate `## 4` / `## 5` / `## 6` numbering and three copies of the boot-module table were collapsed. Still-valid engine invariants from the legacy handoff were folded into §5.

Recovery is reversible; nothing was committed:

- Full pre-compression `HANDOFF.md` (2854 lines) is stored as git blob `db519f3c3c258b0024754139fe2123033e601b6b` in this repo's object database: `git cat-file blob db519f3c3c258b0024754139fe2123033e601b6b > HANDOFF.md`.
- The same file is at `/Users/king-kong/.Trash/HANDOFF-pre-compression-2026-11-05.md` (SHA-256 `cd9a96a5…`).
- The verbatim 920-line legacy handoff is git blob `bcc5cd938401916caa83d74e0e9dc449ec231ef5` and `/Users/king-kong/.Trash/HANDOFF.md` (SHA-256 `bbb80bd2…`).
