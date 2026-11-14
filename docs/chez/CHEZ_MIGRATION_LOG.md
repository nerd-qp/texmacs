# Phasing, Boot Sequencing & Compiler Migration Log

This document records the architectural discoveries, root-cause analyses, and dependency reorganizations made during the Chez Scheme ahead-of-time (AOT) compilation and boot-file optimization work.

---

## 0.1 Post-Order Cycle Reordering & `tree-ref` Keyword Conflation (2026-11-14)

### A. Mutual Circular Dependency Post-Generation Patch
- **Issue**: `generic/document-menu.so` defines `(standard-focus-icons t) (:require (tree-is-buffer? t))` containing `focus-style-icons` (document style dropdown, paper size, orientation), but `generic/generic-menu.so` defines unconditioned `(standard-focus-icons t)` (fallback). Because `generic-menu.scm` ends with `(use-modules (generic document-menu))`, post-order DFS recorded `document-menu` as completing before `generic-menu`. Reversing the list for sequential boot placed `generic-menu` after `document-menu`, erasing the conditioned toolbar overload.
- **Fix**: Added `patch-cyclic-boot-order` in [`init-texmacs-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-chez.scm) inside `dump-boot-order-manifest!`. It inspects the traced list and safely ensures `generic-menu.so` precedes `document-menu.so`.

### B. `tree-ref` Chez Scheme Keyword vs. Symbol Conflation
- **Issue**: In Guile Scheme, keywords (`:up`, `:next`, `:previous`, `:down`, etc.) and symbols are disjoint types: `(symbol? :up) => #f` and `(keyword? :up) => #t`. Upstream [`utils/library/tree.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/utils/library/tree.scm) fast-paths `((symbol? (car l)) (find-child-with-tag ...))`, while keyword navigations fall through to `(else (select t l))`. In Chez Scheme, `(symbol? :up) => #t` because keywords are implemented as colon-prefixed symbols. This caused `(tree-ref ft :up)` and `(tree-is? ft :up 'document)` to search for a child tag literally named `:up` and return `#f`. As a result, operations like `(variant-equation t)` (switching from inline math to displayed equation via the focus toolbar) silently did nothing because `(tree-is? t :up 'document)` was `#f`.
- **Fix**: Overrode `tree-ref` in [`init-texmacs-aot.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-aot.scm) to guard `((and (symbol? (car l)) (not (keyword? (car l)))) ...)`. This restores proper keyword delegation to `(select t l)` for all tree navigations without modifying pristine upstream source files.

---

## 0. v2 Phased Helpers: Option Registrations (2026-11-14)

`convert-to-r6rs-v2.scm` now reaches **453/453, 0 failures** for the whole tree,
closing the last seven failures (the `graphics-env` cluster). Details in
[`PHASED_HELPERS_PLAN.md`](PHASED_HELPERS_PLAN.md) §7.5–§7.6; the two changes:

### A. Option registrations move to the helper when their own file needs them
`tm-define` consults `define-option-table` *while expanding* and raises
`unknown option :kw` if the keyword is missing. `graphics-env.scm` registers
`:state-slots` and uses it twelve lines later, but the registration was emitted
as an expression — i.e. after the body had been expanded. The transpiler now
moves a registration into the helper module exactly when the keyword it installs
is used as an option by a `tm-define` / `tm-define-macro` / `tm-property` in the
same file. The helper's `eval-when` wrapper instantiates it during compilation,
which is before the main module is expanded, so the registration lands in time.
The registration seeds the helper closure, so the handler procedure and
everything it calls move with it.

Moving *every* registration stays rejected: 280/453, 173 failures, because
`tm-define.scm`'s own fifteen registrations drag the whole option vocabulary
across the boundary.

### B. `V2-NONMOVABLE` is now computed after the stateful closure
The diagnostic ran before `v2-stateful-closure`, so it flagged names the closure
moved one step later (19 reports, e.g. `menu-define needs gui-make`). Moved
after the closure and taught about `*aux-syntax-names*`, it reports 0 for the
whole tree — which is the honest answer, and makes the report usable as a
regression signal.

### C. Runtime boot verified; two ordering/regression findings
Booting the v2 boot directory headless (`-H -q`) showed one unbound-variable
error the build could not see: `kernel/library/list.scm` calls
`ahash-table->list` with no `:use`, and `ahash-table.scm` is compiled *after*
it, so no import is emitted. Moving `ahash-table.scm` ahead of `list.scm` fixes
it (`list.scm` then gains `(import (for kernel:boot:ahash-table run expand))`),
but **both reorders were reverted** — the tier list in `compile-inventory.scm`
and the runtime `use-modules` order in `init-texmacs-chez.scm`. `*kernel-files*`
is shared with the v1 pipeline and is not ours to change for a v2-only symptom,
and the runtime order could not have helped: a module's free identifier resolves
against that module's imports, not the interaction environment. The dependency
is still undeclared and a fresh v2 build reproduces the error at boot. The fix
belongs with the dependency-order work in §7.6; editing `list.scm`'s header is
ruled out by the pristine-sources invariant.

**v1 is no longer rebuildable.** With the lexical `define-macro` from §4 below,
`kernel/boot/abbrevs.scm` fails with `attempt to reference out-of-phase
identifier ==`: its `for` macro transformer calls `==`, a phase-0 binding of the
same module, which the old `eval`-based transformer resolved through the
interaction environment. 224 failures follow from that one root; restoring
`HEAD`'s `boot-chez.scm` gives 453/453. The `.so` files in
`build-texmacos/boot` predate the change and still work, but cannot be
regenerated from the current tree. See `PHASED_HELPERS_PLAN.md` §7.7.

### D. Open: forward `:use` edges (not fixed)
The build is a two-pass fixed point: an empty boot directory gives 421/453 on
pass 1 and 453/453 on pass 2. The 32 first-pass failures are declared
dependencies that had not been compiled yet; they get a runtime
`(module-provide '<dep>)` instead of an import, and on a cold directory that call
falls back to interpreting the *original Guile source* of the dependency, which
then fails on names the module boundary would have provided. The same
forward-edge fallback produces ~87 `LOAD-ERROR` lines per pass (v1 produces 0);
those are swallowed by the guarded loader and are **not yet explained** — see
`PHASED_HELPERS_PLAN.md` §7.6 for the two candidate causes. Making
`module-provide` inert during the verification load was tried and is wrong:
73/453, 380 failures, because that call is what publishes a not-yet-compiled
dependency's exports into the interaction environment. The fix is to compile in
dependency order from `module-deps.scm` — the dependency graph this pilot
deliberately omits.

---

## 1. Summary of Changes (2026-11-14)

### A. Kernel Boot Sequence Reordering (`list.scm` ahead of `debug.scm`)
* **Problem**: In `debug.scm`, the macro `regression-test-group` calls `first`, `second`, `third`, and `fourth` in its syntax transformer. These selectors are defined in `kernel/library/list.scm`. Placing `debug.scm` at position #4 and `list.scm` at position #8 in Tier 1 created a forward dependency where macro expansion at compile-time relied on uncompiled modules.
* **Circularity with `srfi.scm`**: `list.scm` could not simply be moved earlier because its procedures (`list-partition`, `list-break`, `list-span`, `list-scatter`) use the SRFI-8 `receive` syntax form, which was originally defined in `kernel/boot/srfi.scm` (module #5).
* **Solution**:
  1. Commented out `receive` in [`TeXmacs/progs/kernel/boot/srfi.scm`](../../TeXmacs/progs/kernel/boot/srfi.scm).
  2. Provided SRFI-8 `receive` directly in [`TeXmacs/progs/kernel/boot/chez-compat.scm`](../../TeXmacs/progs/kernel/boot/chez-compat.scm) (the first Tier 1 module, loaded before all others).
  3. Moved `kernel/library/list.scm` to position #4 in `*kernel-files*` (ahead of `debug.scm` and `srfi.scm`).
* **Manifests Synchronized**:
  - [`src/Scheme/Chez/compile-inventory.scm`](../../src/Scheme/Chez/compile-inventory.scm): `list.scm` is now #4.
  - [`TeXmacs/progs/init-texmacs-chez.scm`](../../TeXmacs/progs/init-texmacs-chez.scm): `(kernel library list)` loaded before `(kernel boot debug)`.
  - [`build-texmacos/boot/boot-order-full.scm`](../../build-texmacos/boot/boot-order-full.scm): `list.so` positioned before `debug.so`.

---

## 2. Deep Dive: Why Guile 1.8 Ran Without `list` Ahead of `debug`

In the original Guile port, lines 99–104 of `init-texmacs.scm` loaded all `kernel/boot/*` modules first and all `kernel/library/*` modules second:
```scheme
(inherit-modules (kernel boot compat) (kernel boot abbrevs)
                 (kernel boot debug) (kernel boot srfi)
                 (kernel boot ahash-table) (kernel boot prologue))
(inherit-modules (kernel library base) (kernel library list)
                 (kernel library tree) (kernel library content)
                 (kernel library patch))
```

This succeeded in Guile for two reasons:
1. **Runtime Interpretation & Late Binding**: Defining a macro in Guile registers a closure; it does not execute the transformer body. `regression-test-group` is only called by regression test suites in Tier 7 (`check-master.scm`). By the time tests ran, `list.scm` had long been evaluated, so `first`/`second` were bound in memory.
2. **Guile Load Order**: `(kernel boot srfi)` ran at line 100, defining `receive` before `(kernel library list)` ran at line 102.

**Why Chez Scheme AOT Differed**:
In Chez Scheme, `compile-file` compiles Scheme code to machine code AOT. Macro transformers run immediately at Phase 1 during expansion of calling modules. Any syntax form (`receive`) must be recognized by the compiler as syntax at compile time; otherwise, Chez compiles it as a regular procedure call, causing runtime crashes. Moving `receive` into `chez-compat.scm` cleanly dissolves this cycle.

---

## 3. Architecture of `convert-to-r6rs-v2.scm` & Phased Helper Modules

[`src/Scheme/Chez/convert-to-r6rs-v2.scm`](../../src/Scheme/Chez/convert-to-r6rs-v2.scm) implements the phased helper module architecture proposed in [`docs/chez/PHASED_HELPERS_PLAN.md`](PHASED_HELPERS_PLAN.md).

### Core Concepts:
1. **Sibling Helper Module (`<mod>$h`)**:
   For each file `<mod>.scm`, the transpiler emits:
   - Sibling helper module `<mod>$h` holding pure procedures needed by macros in `<mod>`.
   - Main module `<mod>` importing `<mod>$h` via `(import (for <mod>$h run expand))`.
   - *Why sibling instead of nested?* Chez Scheme pins nested child modules to Phase 0 of the enclosing module; `(for ... run expand)` is only valid on top-level/sibling modules.
2. **Syntactic Partitioning**:
   - `*movable-heads*`: Pure functions (`define`, `define-public`, `define-macro`) whose bodies have no side-effects on compiler tables can safely move to `<mod>$h`.
   - `*eager-heads*`: Stateful forms (`tm-define`, `define-table`, `ahash-set! define-option-table`) register state into runtime tables at execution time and must remain in the main module body.
3. **Internal Body Ordering**:
   Chez module bodies enforce strict definition-before-expression ordering. Stateful forms like `tm-define` expand into `begin` blocks with runtime expressions (`ahash-set!`); placing them among definitions triggers `Exception: invalid context for definition`. v2 partitions forms into pure definitions first, followed by expressions.

---

## 4. The `pre-eval` Mystery & The 57 `and-let*` Failures

### The Phenomenon
Full-tree runs of `convert-to-r6rs-v2.scm` compiled Tiers 1–5 (216/216 modules) cleanly, but suffered **57 failures across Tiers 6 & 7**. All 57 failures boiled down to 9 root modules failing with:
```
Exception in and-let*: Ill-formed binding: ~A with irritant (<var> <expr>)
```

### The Root Cause: Environment Pollution from `pre-eval`
1. **Why `v2` had `pre-eval`**:
   [`boot-chez.scm`](../../TeXmacs/progs/kernel/boot/boot-chez.scm) originally defined `define-macro` using:
   ```scheme
   (define-syntax nm
     (lambda (stx)
       ... (eval `(apply (lambda formals body ...) ...)
                 (compilation-environment))))
   ```
   Because dynamic `eval` only inspects the global `(interaction-environment)`, it could not see lexical `(import (for <helpers> run expand))` imports. To prevent "variable not bound" errors, `v2` added a pre-compilation loop (`pre-eval`) that evaluated module definitions into `(interaction-environment)` before calling `compile-file`.
2. **The Collision in `scmcoqml.scm`**:
   In Tier 5, [`convert/coq/scmcoqml.scm`](../../TeXmacs/progs/convert/coq/scmcoqml.scm) defines a private Coq AST predicate:
   ```scheme
   (define (pair? t) (func? t 'pair 2))
   ```
   The `pre-eval` loop evaluated this definition into `(interaction-environment)`, **clobbering Scheme's core `pair?` primitive** across the compiler process.
3. **The Collapse of `and-let*`**:
   `and-let*` (in `srfi.scm`) validates clauses using `((and (pair? claw) (symbol? (car claw)) ...))`. When running inside `(compilation-environment)`, `and-let*` called the Coq `pair?` instead of Scheme's cons-cell `pair?`. It returned `#f` for valid Scheme binding pairs, triggering the `"Ill-formed binding"` exception across all downstream modules.

### The Pure Solution
1. **Lexical `define-macro`**: Update `define-macro` in `boot-chez.scm` to apply transformer lambdas directly and lexically without calling `eval`:
   ```scheme
   (define-syntax define-macro
     (lambda (x)
       (syntax-case x ()
         ((_ (nm . formals) body ...)
          #'(define-syntax nm
              (lambda (stx)
                (datum->syntax (car (syntax->list stx))
                  (apply (lambda formals body ...)
                         (cdr (syntax->datum stx))))))))))
   ```
2. **Eliminate `pre-eval`**: With lexical macro transformers, `(import (for <helpers> run expand))` resolves helper bindings directly. No definitions need to be evaluated into `(interaction-environment)`, preventing cross-module compiler pollution entirely.

---

## 5. Phasing Mechanics: Why `(import (for ... run expand))` Still Requires `eval-when` on Sibling Modules

A common point of confusion during R6RS/Chez Scheme syntactic migration is: *if `(import (for <mod>$h run expand))` already imports the helper module's bindings for expand time (Phase 1), why must `<mod>$h` also be wrapped in `(eval-when (compile eval load) ...)`?*

### The Separation of Phasing vs. Instantiation

In Chez Scheme, executing a macro at compile-time requires two distinct conditions:

1. **Syntactic Identifier Visibility (Phasing)**:
   * **Mechanism**: `(import (for <mod>$h run expand))`
   * **Function**: Tells the syntax expander that identifiers exported by `<mod>$h` are legally visible in Phase 1 (macro transformer bodies) as well as Phase 0 (runtime code).
   * **Failure mode if omitted**: `Exception: attempt to reference out-of-phase identifier <name>` during expansion.

2. **Module Instantiation (Evaluation in Compiler RAM)**:
   * **Mechanism**: `(eval-when (compile eval load) (module <mod>$h ...))`
   * **Function**: Tells `compile-file` to evaluate and instantiate `<mod>$h` inside the compiler process's memory immediately during compilation.
   * **Failure mode if omitted**: `Exception: variable <name> is not bound` during macro execution.

### Why Sibling Modules Fail Without `eval-when`

Because TeXmacs transpiles both `<mod>$h` and `<mod>` into the **same output file**, `compile-file` processes them in a single compilation pass:

1. By default, `compile-file` processes `(module <mod>$h ...)` by compiling its forms and streaming machine code to the target `.so` file for future load-time execution. **It does not instantiate the module in the active compiler memory.**
2. When the compiler advances to `(module <mod> ...)` and expands a macro, the transformer code executes in Phase 1 and invokes the helper procedure `(<helper> arg)`.
3. Even though `(for ... expand)` made `<helper>` syntactically valid in Phase 1, the variable's value cell in compiler RAM is empty because `<mod>$h` was never evaluated. Compilation crashes with `Exception: variable <helper> is not bound`.

### The Three Situations of `(eval-when (compile eval load) ...)`

Wrapping `<mod>$h` at the top level addresses all execution targets:
* **`compile`**: Forces immediate evaluation and instantiation of `<mod>$h` in compiler RAM so helper procedures are live when downstream macros in `<mod>` expand.
* **`load`**: Compiles `<mod>$h` into the `.so` binary so it is instantiated when the compiled module is loaded at runtime.
* **`eval`**: Evaluates `<mod>$h` when running as uncompiled Scheme source (e.g. REPL, `load`).

### Top-Level Constraint

`eval-when` must wrap the `(module ...)` form at **top-level file scope**. In Chez Scheme, `(compile)` and `(load)` situations are top-level only; inside a module body or local lexical body, `(compile)` and `(load)` never trigger, and only `(eval)` executes upon module instantiation.

---

## 6. Pivot from v2 Phased Helpers to Encapsulated v1 Compiler Oracle

### Findings on the v2 Phased Helper Architecture

The v2 pipeline explored segregating expand-time helper procedures into dedicated sibling modules (`<mod>$h`) with `(import (for <mod>$h run expand))` and lexical `apply` in `define-macro`. During testing, several fundamental architectural drawbacks became apparent:

1. **Loss of Procedure Inlining**: In Chez Scheme, procedures defined in external or sibling modules are not candidates for standard leaf inlining unless compiled as interconnected R6RS libraries or wrapped in a single enclosing `let` block. Moving internal private helpers into `<mod>$h` actually degraded runtime optimization opportunities for procedures that were otherwise inlined within their home module.
2. **Minimal Runtime Performance Upside**: Profile benchmarks confirmed that Scheme execution accounts for $<0.5\%$ of interactive keystroke latency in TeXmacs (the bottlenecks reside in Qt repaint region invalidation and typesetting layout passes). Any theoretical gains from lexical macro application were negligible in practice.
3. **Severe Phasing and Bootstrap Friction**: Nested modules cannot phase-shift with `(for ... run expand)` without triggering `out-of-phase identifier` errors, while top-level sibling modules require complex two-pass instantiation (`(eval-when (compile eval load) ...)`), re-introducing cold-boot circular dependency failures.

### Resolution: Retaining v1 with Oracle Encapsulation Filtering

Rather than splitting modules into synthetic helper units, the codebase reverted to the single-module v1 compiler architecture and addressed cross-module compiler pollution directly at the Oracle layer:

1. **Restored `(compilation-environment)` in `boot-chez.scm`**:
   `define-macro` and `define-module-macro` were reverted to dynamically evaluate transformer bodies in `(compilation-environment)`:
   ```scheme
   (define-syntax define-macro
     (lambda (x)
       (syntax-case x ()
         ((_ (nm . formals) body ...)
          #'(define-syntax nm
              (lambda (stx)
                (datum->syntax (car (syntax->list stx))
                  (eval `(apply (lambda formals body ...)
                                ',(cdr (syntax->datum stx)))
                        (compilation-environment))))))
         ...)))
   ```
2. **Enforced Encapsulation via `oracle-allowed?` in `compiler-oracle.scm`**:
   To prevent the Compiler Oracle from pulling in unimported symbols or private internal definitions from foreign modules, an encapsulation gate was implemented:
   * **Context Parameterization**: `setup-module-environment!` binds `*oracle-current-module*` (the module being compiled) and `*oracle-current-deps*` (its declared `:use` / `:inherit` dependencies).
   * **Filter Criteria**:
     * **Local module definitions**: Allowed (`#t`).
     * **Global dynamic forms** (`tm-define`, `tm-define-macro`): Allowed (`#t`).
     * **Cross-module symbols**: Allowed **only** if the defining module is in `*oracle-current-deps*` **and** the symbol is listed in that module's exported interface (`module-info-exports` in `*compiler-db*` or `module-exports-table`).
     * **Unimported modules / private helpers**: Blocked (`#f`) and logged via `log-note (format "ORACLE-BLOCKED ~a from ~a ...")`.
3. **Restored `compiler-scan` Interface**:
   Reverted temporary public exports of `scan-header`, `scan-header->deps`, and `scan-collect` from `(compiler-scan)`.

### Verification

* **Unit Test Suites**: All 5 Scheme test suites pass cleanly (**206 checks, 0 failures** across `compile-graph-test.scm`, `compile-inventory-test.scm`, `compiler-db-test.scm`, `compiler-scan-test.scm`, and `macro-closure-test.scm`).
* **Full-Tree Recompilation**: Rebuilding all 453 modules from scratch via `TeXmacs -recompile-modules` succeeded with **453/453 modules compiled and 0 failures**, confirming that foreign private helpers are cleanly blocked without breaking macro expansion.
* **Headless Startup**: TeXmacs boots successfully with the recompiled native `.so` binaries (`TIME-PRE-GUI-LOOP: 1117 ms`).

---

## 2026-11-14: Ahead-Of-Time (AOT) Boot File (`texmacs.boot`) Generation & Cold Boot Verification

### Goals & Implementation

1. **Restored Pristine Module Ordering**:
   * Returned `kernel/library/list.scm` after `base.scm` (and after `ahash-table.scm` / `srfi.scm`) in `compile-inventory.scm` and `init-texmacs-chez.scm`.
   * Retained `receive` in `chez-compat.scm` for macro expansion transformers running in `(compilation-environment)`.
   * Recompiled all 453 modules cleanly with 0 failures (`build-texmacos/boot/module-deps.scm`).

2. **Sequential Load Order Manifest & AOT Boot File**:
   * Dumped the complete DFS post-order load order (378 core modules + 75 leaf modules = 453 application modules + `boot-chez.so`) to `build-texmacos/boot/boot-order-full.scm`.
   * Created `src/Scheme/Chez/make-boot.scm` to assemble all compiled modules into a unified AOT boot image (`texmacs.boot`, ~13.06 MB) using Chez Scheme's `make-boot-file`.

3. **Engine & Bootstrap Integration for AOT Booting**:
   * **Direct C++ OS Predicate Registration**: Wrapped `os-win32?`, `os-mingw?`, `os-mingw64?`, `os-macos?`, and `os-android?` with `#if !defined(TEXMACS_ENGINE_CHEZ) && !defined(CHEZ_SCHEME)` in `src/Scheme/Glue/glue_basic.cpp`. Registered the underlying C++ boolean functions directly via `Sforeign_symbol` in `register_foreign_symbols()` and bound them in `boot-chez.scm` with `(foreign-procedure ... () boolean)`.
   * **Deferred Early-Boot Initialization (`on-entry`)**: Updated the `on-entry` macro in `chez-compat.scm` and `boot-chez.scm` to queue thunks into `*on-entry-tasks*` during AOT boot image loading, running them via `run-on-entry-tasks` once C++ server and glue initialization completes.
   * **Two-Phase C++ Glue Installation**: Enhanced `chez_install_procedure` in `src/Scheme/Chez/chez_tm.cpp` to register C function entries in `tm_fast_table` and `tm_proc_registry` in `custom_init()` before the Scheme heap is built, deferring the `tm-install-procedure!` Scheme trampolines until `initialize_glue()`.
   * **AOT Image Loading in `initialize_scheme()`**: `initialize_scheme()` loads `texmacs.boot` after C++ `the_server` and glue procedures are established, avoiding premature server lookups (`get_server()`) while achieving instant binary module loading.

### Verification

* **Cold Boot via `TEXMACS_BOOT_FILE`**:
  ```bash
  SCHEMEHEAPDIRS="..." TEXMACS_PATH="..." TEXMACS_BOOT_FILE=".../texmacs.boot" \
    ./build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -H -x '(begin (display "BOOT_OK: ") (display (list (texmacs-version) (os-macos?))) (newline) (quit-TeXmacs))'
  ```
  Result:
  ```
  Chez Scheme: booting from AOT image .../texmacs.boot
  Chez Scheme: loading .../boot-chez.so
  Chez Scheme: initialize_glue
  Chez Scheme: loading AOT boot image .../texmacs.boot
  Alternative pattern selector
  TeXmacs] Loading doxygen C++ support
  TIME-SERVER-INIT: 3591 ms
  ...
  TIME-PRE-GUI-LOOP: 3716 ms
  BOOT_OK: (2.1.5 #t)
  ```
  Exited with status `0`, verified 0 errors, 0 unbound variables.

---

## 2026-11-14: Implementation of Approach 1 (`texmacs.so`) & Dedicated AOT Bootstrap (`init-texmacs-aot.scm`)

### Architectural Decisions & Progress

1. **Logged Long-Term Roadmap in `docs/chez/BOOT_FILE_PLAN.md`**:
   * Documented both **Approach 1 (`texmacs.so`)** as the clean, immediate milestone and **Approach 2 (`texmacs.boot`)** as the ultimate architectural target.
   * Clarified that Approach 2 requires migrating C++ glue generation to `Sforeign_symbol` foreign functions in `custom_init()` and decoupling top-level server calls (`get_server()`).

2. **Unified Image Builder (`src/Scheme/Chez/make-boot.scm`)**:
   * Generates both `texmacs.so` (Approach 1: concatenated object file via CSUG Section 2.8) and `texmacs.boot` (Approach 2: native secondary boot file via CSUG Section 12.1).
   * Bundles all 453 application modules in topological DFS post-order (`boot-order-full.scm`), omitting `boot-chez.so` which serves as the primary bootstrap loader.

3. **Dedicated AOT Bootstrap Script (`TeXmacs/progs/init-texmacs-aot.scm`)**:
   * Created a lean, dedicated bootstrap script executed when booting from an AOT binary image (`texmacs.so` / `texmacs.boot`).
   * Imports all 453 resident modules into `(interaction-environment)` in a single `(import ...)` form, eliminating 700+ lines of redundant `(use-modules ...)` and lazy stubs.
   * Defines runtime syntax overrides (`define-public`, `define-public-macro`, `indirect-export`) for dynamic user scripts and the REPL.
   * Updated `src/Texmacs/Server/tm_server.cpp` to automatically select `init-texmacs-aot.scm` when `chez_has_boot()` is true.

4. **Engine Auto-Detection in `src/Scheme/Chez/chez_tm.cpp`**:
   * Probes `TEXMACS_BOOT_FILE`, `TEXMACS_SO_FILE`, and auto-falls back to `$TEXMACS_BOOT_PATH/texmacs.so`.

### Performance & Verification

* **Cold Boot Timing with `texmacs.so`**:
  * `TIME-SERVER-INIT`: 1876 ms
  * `TIME-OPEN-WINDOW`: **100 ms** (down from ~4700 ms without AOT)
  * `TIME-PRE-GUI-LOOP`: **1977 ms**
  * Zero load exceptions, zero unbound variable errors (`current-buffer`, etc.).

---

## 2026-11-14: Clean Bootstrap Architecture & Foreign Procedure Separation

### Clean Architecture Improvements
1. **Extracted Foreign Procedures into `initial-foreign-proc.scm`**:
   * Created [`initial-foreign-proc.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/initial-foreign-proc.scm) containing early C++ foreign procedures:
     * Blackbox hooks: `tmscm_delete_blackbox`, `tmscm_blackbox_equal`, `tmscm_blackbox_hash`
     * Fast trampolines: `tm-call-by-name`, `tm-fast-call-0` .. `tm-fast-call-10`
     * OS predicates: `os-win32?`, `os-mingw?`, `os-mingw64?`, `os-macos?`, `os-android?`
   * In [`boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm), cleanly included via `(include "initial-foreign-proc.scm")`.
   * Completely eliminated ad-hoc definitions of `ca*r`, `ca*adr`, and deferred `*on-entry-tasks*` queues from `boot-chez.scm`.

2. **Two-Stage AOT Module Loading & Runtime GUI Initializations**:
   * `make-boot.scm` assembles `texmacs.so` containing 452 modules (excluding `boot-chez.so` and `chez-compat.so`).
   * In [`init-texmacs-aot.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-aot.scm):
     1. Loads `chez-compat.so` and imports `kernel:boot:chez-compat` into `(interaction-environment)`.
     2. Loads consolidated `texmacs.so` (13.05 MB).
     3. Bulk-imports remaining modules into `(interaction-environment)`.
     4. Sets up essential top-level runtime definitions:
        * `supports-email?` via `(url-exists-in-path? "mmail")` required by `tools-menu` and `main-menu`
        * `notify-set-attachment` stub
        * Interactive property annotations (`tm-property (...) (:interactive #t)`) for search, format, style, and dialog selectors
        * Lazy plugin initialization via `(for-each lazy-plugin-initialize (plugin-list))`
   * Result: Guile compatibility macros and syntax transformers (including `ca*r`) are available immediately for any dynamic `eval` or top-level macro expansion during `texmacs.so` loading, and all GUI menu bar / toolbar widgets (including style widget and `tools-menu`) construct cleanly without unbound variable errors.

3. **Module Loading Order: Overloaded `standard-focus-icons`**:
   * **Symptom**: In the GUI focus toolbar, the Document Style dropdown (`focus-style-icons`) and page format widgets were missing.
   * **Root Cause**: Both `generic-menu.scm` and `document-menu.scm` define `(standard-focus-icons t)` using `tm-menu` / `tm-define`.
     - `document-menu.scm` defines `(standard-focus-icons t) (:require (tree-is-buffer? t))` containing `(dynamic (focus-style-icons t))`.
     - `generic-menu.scm` defines `(standard-focus-icons t)` *without* `:require` (unconditioned fallback for non-buffer tags).
     - In `boot-order-full.scm` and `init-texmacs-aot.scm`, `document-menu.so` was ordered before `generic-menu.so`. Because `generic-menu.scm` has no `:require` condition, `tm-define-overloaded` treated it as a base definition and wiped out the conditioned definition from `document-menu.so`.
   * **Fix**: Reordered modules so `generic:generic-menu` loads before `generic:document-menu`. Now `document-menu` wraps `former` with `(:require (tree-is-buffer? t))`, correctly displaying the Document Style dropdown (`Generic`), Paper size (`A4`), Font (`Roman`), Font size (`10pt`), and Orientation (`Portrait`) on the focus toolbar.





