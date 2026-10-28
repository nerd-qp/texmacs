# TeXmacs Chez Backend Optimization TODO List

This document tracks identified architectural improvements and performance bottlenecks for the TeXmacs Chez Scheme port (`wip-chez`).

---

## 1. High Priority (Performance & Startup)

### [x] Up-front Static Pre-declaration / Indirect Export of State Slots in `define-state` & `graphics-env.scm` [RESOLVED]
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-states.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/texmacs/tm-states.scm), [`TeXmacs/progs/graphics/graphics-env.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/graphics/graphics-env.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Status & Priority**: Complete & Verified (Exit code 0, 116 modules compiled with 0 failures).
- **Resolution**:
  - `state-slots` remains module-private in `graphics-env.scm` to prevent clobbering `(define (state-slots sr) ...)` in `tm-states.scm`.
  - `state-slot-ref` and `state-len` are defined using `(define-module-macro (<name> ...) (state-slots) ...)` emitting `state-slots` without unquoting.
  - `define-module-macro` uses `with-module-export-if-active` to automatically emit `(indirect-export <macro> state-slots)` inside the module while allowing clean top-level evaluation during AST preparation.
  - Dependent modules (such as `graphics-group.scm`) compile and expand `state-ref` / `state-slot-ref` without `state-slots` being unbound.
- **Context & Motivation**:
  - Currently, `define-state` only constructs the state structure `(state-create ...)` without declaring its slot and prop variables (`graphics-action`, `choosing`, `sticky-point`, `current-x`, etc.) into the environment.
  - In upstream GNU Guile 1.8, slot and prop variables were lazily allocated via `(if (not (defined? ...)) (define-public ...))` only when `state-load` was invoked at runtime.
  - In reality, the list of slots and properties is **100% static** once declared in `define-state`—no slots or props are ever dynamically added or removed at runtime; only their stored values mutate during `state-save` / `state-write`.
- **Target Solution**:
  - Modify `define-state` macro to pre-declare and initialize all slot and prop variables directly at declaration time into `(interaction-environment)` (using `define-top-level-value`).
  - Pre-binding these variables up-front eliminates the need for lazy binding checks (`unless (top-level-bound? ...)`) in `proplist-load` and `slotlist-load`.
  - Ensures that when compiling modules such as `graphics-env.scm` (and downstream editing modules), all state variables are fully known and bound at compile time, eliminating undefined variable warnings and compile-time evaluation failures.
- **Testing & Verification Scope**:
  - Full audit of all state variables across `graphics-env.scm` and dependent modules (`graphics-drd.scm`, `graphics-object.scm`, `graphics-edit.scm`, `graphics-single.scm`).
  - Verify that initial values and thunks are not prematurely invoked before dependent subsystems (e.g. GUI/C++ glue for `get-graphical-x`) are initialized.

### [x] Stateful Macro Expansion Fix in `define-group` (`variants.scm`) [RESOLVED]
- **Location**: [`TeXmacs/progs/utils/edit/variants.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/utils/edit/variants.scm)
- **Status**: Complete & Verified (Exit code 0, 18/18 harness checks pass).
- **Problem**: `define-group` checked `(ahash-ref group-table group)` at macro expansion time. Eager evaluation in Pass 1 populated `group-table`, causing Pass 2 (`compile-file`) to omit `(tm-define (group-list) ...)` in compiled `.so` files, breaking `text-edit.so`, `graphics-drd.so`, and `graphics-object.so`.
- **Solution**: Moved `(set! group-resolve-table ...)` and `(if old ...)` directly into the generated runtime code (`begin ...`). When modules load at runtime, they check `group-table` and properly define `*-list`, `*?`, and `inside-*?` via `tm-define` / `define-top-level-value` into `(interaction-environment)`. All dependent modules compile cleanly with `(OK)`.

### [!] Warning: Eager Evaluation Side Effects & Stateful Macro Branching (`if`/`else` at Expand Time)
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), macro definers across `TeXmacs/progs/`
- **Problem**:
  Macros that inspect global tables or mutable variables to conditionally emit different code branches (e.g. `(if (ahash-ref table key) ...)` or `(if (top-level-bound? ...) ...)`) might not compile correctly under our ahead-of-time pipeline.
  Because `compile_kernel.scm` eagerly evaluates forms into `(compilation-environment)` during Pass 1 (`eval-eager-form!`), mutable tables in compiler memory are modified before Pass 2 (`compile-file`) runs macro expansion. As a result, the expander sees the post-eager-eval state (taking the `else` or "already initialized" branch) rather than the clean initial state that should exist when the compiled `.so` loads at runtime.
  - *Example (`define-group` in `variants.scm`)*: Pass 1 populated `group-table`, causing Pass 2 macro expansion to see `old != #f` and omit procedure declarations (`tm-define (group-list) ...`) from compiled `.so` files.
  - *Example (`state-slots` in `graphics-env.scm`)*: Unquoting mutable slot lists inside macro templates (`(- (length (memq ,i ,state-slots)) 1)`) relied on expand-time environment bindings, failing downstream when compiled across module boundaries.
- **Future Architectural Considerations & Action Plan**:
  1. **Defer Stateful Branching to Runtime**: Whenever possible, avoid expand-time `(if <table-ref> ...)` branching; move the conditional directly into the emitted runtime AST (e.g. `(begin (if (ahash-ref ...) ...) ...)`) so that table mutations and definitions occur at module load time rather than during compilation.
  2. **Audit Macros for Expand-Time State Dependencies**: Review macro definers (`define-macro`, `define-public-macro`, `define-module-macro`) across `TeXmacs/progs/` that query hash tables, property lists, or top-level bound status during expansion.
  3. **Phase-Isolated Compilation Environment**: Investigate parameterizing `(compilation-environment)` with an isolated, copy-on-write snapshot during Pass 1 eager evaluation or resetting stateful tables before `compile-file` to prevent expand-time state leakage between passes.

### [ ] Progressive Compilation Census (184 Compiled, 273 Remaining)
- **Total Scheme files**: 457 files across `TeXmacs/progs/`.
- **Compiled `.so` files**: 184 files in `build-texmacos/boot/` (including all 39 kernel modules and 38 Tier 2 modules).
- **Remaining uncompiled `.scm` files**: 273 files. Breakdown by top-level category:
  - `utils/`: 29 files
  - `dynamic/`: 26 files
  - `convert/`: 25 files
  - `doc/`: 18 files
  - `server/`: 18 files
  - `prog/`: 17 files
  - `database/`: 15 files
  - `client/`: 13 files
  - `tools/`: 13 files
  - `text/`: 12 files
  - `bibtex/`: 10 files
  - `link/`: 10 files
  - `security/`: 10 files
  - `math/`: 9 files
  - `source/`: 9 files
  - `version/`: 8 files
  - `kernel/`: 7 files (e.g. `boot-chez.scm`, `boot.scm`, `menu-convert.scm`, `iterator.scm`, test suites)
  - `education/`: 5 files
  - `fonts/`: 3 files
  - `(root)`: 3 files (`init-buffer.scm`, `init-texmacs-chez.scm`, `init-texmacs.scm`)
  - `language/`: 3 files
  - `part/`: 3 files
  - `graphics/`: 2 files
  - `table/`: 2 files
  - `texmacs/`: 2 files (`latex-kbd.scm`, `prefix-kbd.scm`)
  - `check/`: 1 file
  - `debug/`: 1 file
  - `notification/`: 1 file

### [ ] Switch from `(module ...)` to R6RS `(library ...)` Syntax
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Motivation & Benefits**:
  - Chez Scheme's internal `(module name ...)` form uses flat symbol identifiers (e.g. `kernel:boot:srfi`).
  - Standard R6RS `(library (dir-A dir-B module-name) (export ...) (import ...) body...)` natively supports structured hierarchical path identifiers: `(kernel boot srfi)`.
  - This directly mirrors TeXmacs's module declarations:
    `(texmacs-module (kernel boot srfi) (:use (kernel boot abbrevs)))`
    `(use-modules (kernel boot abbrevs))`
    `(inherit-modules (kernel boot debug))`
  - Switching to `library` syntax eliminates synthetic symbol mangling (`spec->symbol`), enables Chez's automatic library path resolution (`library-directories`), and aligns 1:1 with TeXmacs's `use-modules` / `inherit-modules` semantics.
  - **Dynamic Procedure-Level Loading & `lazy-define` without `eval`**:
    - With R6RS libraries, Chez Scheme's `(environment <import-spec> ...)` procedure can dynamically construct environments from runtime library specs without requiring `eval`.
    - `lazy-define` or dynamic plugin dispatch can retrieve procedures directly:
      ```scheme
      (define (load-plugin-fn lib-spec fn-sym)
        (let ([lib-env (environment lib-spec)])
          (top-level-value fn-sym lib-env)))
      ```
    - In contrast, Chez's `(module ...)` forms live in the lexical/interaction environment and cannot be resolved by `environment` (which raises `unknown module`), requiring `(eval `(import ...) (interaction-environment))` to dynamically load. Switching to `library` enables isolated, first-class runtime loading and eliminates `eval` overhead in dynamic stubs.

- **Architectural Prerequisite & Circular Dependency Strategy**:
  - **The R6RS Library Acyclic Invariant**:
    - Standard R6RS strictly forbids circular dependencies between libraries (R6RS §7.1: *"A library definition must not import, directly or indirectly, the library being defined"*).
    - TeXmacs upstream has mutual/cyclic dependencies between modules (particularly across menus, editors, and tools).
    - **Strategy Decision**: To migrate to R6RS `(library ...)`, the codebase's module dependency graph must either be refactored to be strictly acyclic (DAG), OR we must retain the `(module ...)` architecture as-is.
  - **Compile-Time Design (under `(module ...)` architecture)**:
    - `compile_kernel.scm` detects cyclic dependencies during topological compilation:
      - If module `A` declares a dependency on `B`, and `B` is not yet compiled (`(not (memq s-sym compiled-modules))`), the compile-time syntactic `(import (for B run expand))` is omitted (`DEFER-CIRCULAR-IMPORT`).
      - Identifiers referencing `B` inside `A` are preserved as top-level free variables (`#{var *top*:var}`).
      - During compile-time verification (`native-load out-so`), `module-provide` is strictly guarded via `(when (and (not (compile-export-mode?)) (not (module-loaded? m))) (module-load m))` so that AOT compilation never attempts to load uncompiled sources or stale forward/circular `.so` files. [RESOLVED]
  - **Run-Time Design (Self-Sufficient Predecessor Loading in `exprs`)**:
    - In the transpiled Scheme module, insert `(module-provide '<dep>)` calls for all predecessor dependencies at the **beginning of the module's expression segment** (`exprs`), immediately following the definition segment (`defs`) and preceding any menu bindings or executable code:
      ```scheme
      (module <mod-sym> ()
        ,@import-forms              ;; Phase 1 (expand/run): macro availability & lexical scoping
        ,@export-forms
        ,@keyword-defs
        ,@defs                      ;; Phase 0: internal definitions
        ;; --- Beginning of expression segment (load-time execution) ---
        ,@(map (lambda (d) `(module-provide ',d)) deps)  ;; Guarantee prerequisites are loaded
        ,@exprs)                    ;; Remaining load-time registrations / expressions
      ```
    - **R6RS Phasing Compliance**: Because `module-provide` calls are placed strictly in `exprs` after all `defs`, Chez Scheme definition phasing is fully respected—zero `invalid context for definition` errors.
    - **Autonomy**: Loading any `.so` directly (via `primitive-load`, lazy stub, or idle timer) automatically ensures all its predecessor prerequisites are loaded and their top-level values bound before the module's own expressions (e.g. `tm-menu` `:require` hooks) evaluate.
    - **Re-entrancy & Cycle Safety**: `boot-chez.scm`'s `module-load` uses `*module-loading-stack*` to break recursive runtime cycles in $O(1)$, and `module-provide` returns immediately if the target module is already in `*texmacs-modules-loaded*`.
  - **Optimization Opportunity: Single-Unit Co-location for Inlining & Direct Compile-Time Resolution**:
    - **Cross-Module Inlining**: When strongly coupled or mutually recursive modules are compiled into separate `.so` files, Chez Scheme's optimizer (`cp0`) cannot inline procedures across `.so` boundaries, necessitating dynamic lookups or external procedure calls.
    - **Co-located Compilation**: If tightly coupled cyclic modules (e.g. `doc/tmdoc-menu.scm` and `doc/tmdoc-edit.scm`) are combined into the **same file / single compilation unit**:
      - Both modules can directly import and resolve each other's identifiers at compile time without requiring `DEFER-CIRCULAR-IMPORT`.
      - Eliminates top-level free variable renaming (`#{var *top*:var}`) and runtime `(interaction-environment)` indirection.
      - Enables Chez Scheme's compiler to perform direct inter-module beta reduction, dead-code elimination, and procedure inlining across call sites, eliminating function call overhead for small helpers, predicates, and accessors.

### [ ] Native Chez Primitive Deduplication Guideline
- **Location**: Module transpilers and compatibility headers ([`TeXmacs/progs/kernel/boot/srfi.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/srfi.scm), [`init-texmacs-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-chez.scm))
- **Rule**: Whenever porting/compiling Scheme files that define polyfill macros or compatibility emulators (e.g. SRFI-16 `case-lambda`, SRFI-9 `define-record-type`, SRFI-11 `let-values`, SRFI-39 `make-parameter`), always check whether Chez Scheme natively implements the primitive.
- **Action**: Comment out or bypass macro emulators in favor of Chez's native optimizing compiler primitives. Native compiler forms benefit from direct code generation, fast jump-tables, and zero runtime expansion overhead.

---

### [ ] Automated Topological Boot Manifest Generation
- **Location**: [`src/Scheme/Chez/boot_files.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/boot_files.scm), [`src/Scheme/Chez/build-boot.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/build-boot.scm)
- **Problem**: When capturing boot file order by logging file load starts (`LOAD-START`), it produces DFS pre-order where orchestrators (e.g. `init-texmacs.scm`) precede the modules they depend on. Sequential compilation and boot-file evaluation require DFS post-order (dependencies evaluated before callers). Currently, `boot_files.scm` has manually adjusted ordering.
- **Goal / Solution**: Automate manifest extraction in the build system:
  - Option A: Trace `LOAD-FINISH` hooks during a verified headless boot session so files are recorded upon return (natural post-order).
  - Option B: Static dependency analysis of `(texmacs-module ... (:use ...))` declarations and `(load ...)` calls to construct a dependency DAG and compute topological sort (`tsort`).

### [ ] Zuo-Driven Build System for Scheme AOT Compilation & Parallel Dependency DAG (`build.zuo`)
- **Location**: [`ChezScheme/zuo`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/ChezScheme/zuo), `src/Scheme/Chez/build.zuo`, `CMakeLists.txt`, `build-texmacos.sh`
- **Context & Motivation**:
  - Chez Scheme 9.9+ and 10.x bundle and bootstrap using `zuo` (`ChezScheme/zuo`), a tiny (~10k LOC C99 single-file executable), zero-dependency Scheme/Racket build tool designed by Matthew Flatt specifically for building Chez Scheme and Racket.
  - Currently, TeXmacs compiles Scheme libraries by launching the full C++ engine (`TeXmacs -compile-modules`) and running a single-threaded sequential interpreter loop in `compile_kernel.scm`.
  - This tightly couples Scheme compilation to the C++ runtime, executes serially on a single core, has ad-hoc cache invalidation, and makes partial or incremental rebuilds during development slow and cumbersome.
- **Core Architecture & Advantages**:
  1. **Zero-Dependency Native Binary**: `zuo` is already compiled during Chez Scheme configuration (`build-chez-macos/bin/zuo`). It requires no Python, Make, or Ninja at build time, only standard C library headers.
  2. **Rule-Based Dependency DAG (`build.zuo`)**: Zuo provides an embedded `make`-like Scheme DSL (`#lang zuo`) with target rules, mtime / SHA256 tracking, and automatic topological resolution of `:use` / `:inherit` dependencies across all 453 Scheme modules.
  3. **Parallel Multicore Compilation (`zuo -j $(sysctl -n hw.ncpu)`)**: Compiles independent Scheme files concurrently across CPU cores, reducing full-distribution build times from ~30s down to 2–3s, and sub-second for single-file edits.
  4. **Headless Chez Scheme Worker Driver**: Rather than spinning up the Qt GUI / C++ server, Zuo spawns lightweight native Chez Scheme worker scripts (`scheme --script transpile_module.scm <src> <dst>`) targeting `build-texmacos/boot/`.
  5. **Clean Build System Decoupling**: Easily hooked into CMake (`add_custom_target(scheme_boot ALL COMMAND ${CHEZ_DIR}/bin/zuo build.zuo)`), separating Scheme module compilation from C++ builds and fitting naturally into existing package manager workflows.

### [ ] Transitive Predecessor Invalidation in Incremental Compilation (`compile-texmacs.scm`)
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](file:///Users/king-kong/Documents/GitHub/texmacs/src/Scheme/Chez/compile-texmacs.scm)
- **Problem & Context**:
  - The current incremental compilation check (`compile-texmacs.scm`) determines whether a module is `UP-TO-DATE` purely by comparing the timestamp of the module's target `.so` against its own upstream `.scm` source file.
  - If a predecessor module $A$ is modified (e.g. exporting fewer functions, altering macro definitions, or changing public signatures), downstream module $B$ that depends on $A$ is not automatically invalidated or recompiled if $B$'s own source timestamp has not changed.
  - In ahead-of-time compiled Chez Scheme binaries, macro expansions and direct variable references across module boundaries can bake in assumptions about predecessor exports. If a predecessor exports fewer functions or reorders bindings, call-sites and address offsets in previously compiled downstream `.so` units can become stale or broken.
- **Goal / Action Plan**:
  - Implement transitive dependency checking in the compilation script: check not only the `.scm` file itself, but also walk its dependency DAG (predecessors via `*all-module-deps*`). If any predecessor `.so` was rebuilt or has a newer timestamp than the downstream `.so`, invalidate and trigger recompilation of the dependent module.

---

## 2. Medium Priority (GUI & Responsiveness)

### [ ] Defer Secondary Tool Initialization (92 Delayed Tasks)
- **Location**: [`TeXmacs/progs/texmacs/menus/`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/texmacs/menus/), [`src/Edit/Interface/edit_interface.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Edit/Interface/edit_interface.cpp)
- **Problem**: In GUI mode, 92 delayed actions eagerly initialize sub-menus and tools (LaTeX export, BibTeX manager, Collaboration chat, Poster designer, etc.) during startup before the user even clicks them, triggering synchronous loads of 30+ large Scheme files.
- **Solution**: Convert secondary toolbars and menus to lazy callbacks evaluated only on first display or submenu popup.

---

## 3. Low Priority / Maintenance

### [ ] Fast C++ Scheme Glue Dispatch: `foreign-procedure` / `tm_call_by_id`
- **Location**: [`src/Scheme/Chez/chez_tm.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/chez_tm.cpp#L194-L261), [`src/Scheme/Scheme/glue.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Scheme/glue.cpp)
- **Problem**: `tm-call-by-name` does string-to-symbol, argument list consing, and `std::map<string, tm_proc_entry>` red-black tree lookup on every Scheme -> C++ invocation (~1,150 glue procedures).
- **Solution (Direct Chez `foreign-procedure`)**:
  - Register C++ glue functions with Chez Scheme via `Sforeign_symbol("tmg_proc_name", (void*) fn)`.
  - Define typed foreign procedure stubs directly in Scheme:
    ```scheme
    (define proc-name (foreign-procedure "tmg_proc_name" (ptr ptr) ptr))
    ```
  - Eliminates Scheme argument-list packing/unpacking and C++ map lookups entirely, turning glue invocations into raw native CPU `call` instructions.
  - *Alternative*: Array-indexed dispatch `(tm-call-by-id <id> ...)` with an $O(1)$ C++ pointer table. *(Low priority for now)*

### [ ] Boot Image Developer Workflow: Dynamic Override & Cache Rebuilding
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm), CLI / UI menus
- **Concept & Developer Loop**:
  - **Dynamic Runtime Override**: In development mode (`--dev` or `TEXMACS_DEV_MODE=1`), compare `.scm` file modification timestamps against `*texmacs-boot-timestamp*`. If a source file on disk is newer than the pre-compiled boot image, `module-provide` dynamically re-loads that single file via `tm-load-file`, hot-updating procedures in RAM without requiring a full rebuild of `texmacs.boot`.
  - **Rebuild Cache Utility**: Use the dedicated `--build-chez-boot` command-line flag to rebuild and dump `texmacs.boot` on disk.
  - **Bundled Location Reminder**: When creating production release bundles (e.g. `.app` or Linux packages), ensure `build-boot.scm` and `boot_files.scm` are bundled into `$TEXMACS_PATH` (or `$TEXMACS_PATH/src/Scheme/Chez/`) so `--build-chez-boot` works out-of-the-box without requiring a full source git checkout.


---

## 4. Bug Fixes & Stability

### [ ] Separate Compilation Environment from Runtime Initialization
- **Location**: [`src/Texmacs/Server/tm_server.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Texmacs/Server/tm_server.cpp), [`src/Scheme/Chez/chez_tm.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/chez_tm.cpp), [`TeXmacs/progs/init-texmacs-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-chez.scm), [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm)
- **Problem**: Currently, both compilation (`-compile-modules`) and runtime startup load `init-texmacs-chez.scm`. `init-texmacs-chez.scm` relies on conditional runtime checks (`texmacs-chez-compiling?`) to decide whether to load `.so` files, redefine `define-public` / macros for runtime REPL evaluation, or skip them. This coupling introduces fragility, phase confusion, and order-of-initialization hazards between batch compiling and runtime execution.
- **Solution**: Decouple the two workflows cleanly into dedicated entry points:
  - **`init-texmacs-compile.scm`**: A dedicated entry point for `-compile-modules` and batch AOT compilation. Configures `compilation-environment`, keyword tokens, module transpilation rules, and macro-expansion helpers without any runtime `.so` loading or dynamic REPL shims.
  - **`init-texmacs-chez.scm`**: Strictly dedicated to normal runtime startup. Preloads compiled `.so` files, initializes `texmacs-user`, registers runtime dynamic definitions, and transitions directly to the GUI event loop without any compilation flags or conditionals.
  - In C++ (`tm_server.cpp` / `chez_tm.cpp`), select the appropriate init script based on `compile_modules_mode` before initializing Scheme.

### [ ] Migrate Macro Expand-Time Helpers from `(eval ... (compilation-environment))` to Phased `meta define` Modules (UNREALISTIC / DEFERRED)
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm), [`TeXmacs/progs/kernel/texmacs/tm-convert.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/texmacs/tm-convert.scm), macro definers throughout `TeXmacs/progs/`
- **Status & Note**: Marked as unrealistic / too much work. Migrating hundreds of dynamic legacy Guile macro helpers across the codebase to strictly phased `meta define` libraries would require sweeping structural rewrites of upstream TeXmacs code with high regression risk. The existing dynamic compilation-environment evaluation bridge works robustly and will be retained.
- **Problem**: Currently, macro definers (`define-public-macro` and `define-module-macro`) use `(eval `(apply ...) (compilation-environment))` as a bridge to evaluate legacy Guile macros and their helper procedures (e.g. `converter-sub`) without triggering Chez Scheme's static Phase 0 / Phase 1 lexical cross-phase checks.
- **Solution**: Refactor expand-time macro helpers out of runtime modules into dedicated macro-helper modules, or use `meta define` / `(meta import ...)` so Chez Scheme can compile macro transformers statically as native Phase 1 syntax transformers without relying on dynamic `eval` against `(compilation-environment)`.

### [ ] Exit Issue After Editing Initial Buffer
- **Location**: Buffer exit handler, `quit-TeXmacs`, modified buffer prompt ([`TeXmacs/progs/texmacs/texmacs/tm-files.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/texmacs/texmacs/tm-files.scm), [`src/Texmacs/Texmacs/texmacs.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Texmacs/Texmacs/texmacs.cpp))
- **Problem**: TeXmacs is having issues exiting cleanly after editing the initial buffer (e.g. unsaved changes dialog or exit hook hanging).
- **Solution**: Inspect the buffer discard / save verification workflow during exit on the Chez backend.

### [ ] Dynamic Menu Evaluation: Guard `#f` in `make-menu-items` (`(TM-APPLY-ERROR #f is not a pair)`)
- **Location**: [`TeXmacs/progs/kernel/gui/menu-widget.scm:811-825`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/gui/menu-widget.scm#L811-L825), [`src/Scheme/Chez/chez_tm.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/chez_tm.cpp)
- **Problem**: When a dynamic menu thunk returns `#f` (e.g. inactive mode or delayed plugin menu not yet initialized), `make-menu-items` falls through `(if (pair? p) ...)` to `(make-menu-bad-format p style)`. Calling `car`/`cdr` on `#f` triggers Chez Scheme's `~s is not a pair (#f)` which is trapped in `tm-apply` as `(TM-APPLY-ERROR (#t #f "~s is not a pair" (#f) ()))`.
- **Solution**: Guard against non-pair/`#f` values in `make-menu-items` to treat them as an empty item list `'()` rather than logging `menu has bad format (make-menu)` or throwing in Scheme.

### [ ] Refactor `define-table` and `define-collection` (Post Pure-Expression `tm-define` Simplification)
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), [`TeXmacs/progs/kernel/boot/ahash-table.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/ahash-table.scm)
- **Status & Note**: Currently, `define-table` and `define-collection` are desugared directly in `prepare-forms` to avoid Chez Scheme multiple-definition errors during forward declarations (`(define-table style-synopsis)`) and ensure tables are exported to `texmacs-user-kernel`.
- **Target Solution**: With `tm-define` now refactored to be purely an expression installing top-level values directly without internal local definitions, complex definition-hoisting via `define-public-macro-trace` is no longer required. Migrate `define-table` and `define-collection` to standard macro definitions emitting top-level table registrations or definitions and remove ad-hoc compiler desugaring.

### [ ] Quick Hack: Implicit Cross-Module Macro Propagation via `(interaction-environment)` for `tm-define-macro`
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-define.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/texmacs/tm-define.scm#L284-L295), [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm#L933-L945)
- **Problem**: In upstream GNU Guile TeXmacs, every module implicitly inherited `texmacs-user` via `(module-use! (current-module) texmacs-user)`. Macros defined via `tm-define-macro` anywhere in the codebase (e.g. `smart-table` in `utils/library/smart-table.scm`) were automatically available as global syntax in downstream modules without explicit `(:use ...)` declarations (such as `convert/latex/latex-define.scm`). Under Chez Scheme's hermetic R6RS AOT module model, modules only import explicit syntax dependencies declared in `:use` / `:inherit`.
- **Current Quick Hack**:
  - `tm-define-macro` emits `(define-top-level-syntax ',var ... c-env)`.
  - When `compile_kernel.scm`'s `prepare-forms` encounters `define-top-level-syntax`, it executes both:
    ```scheme
    (eval x (compilation-environment))
    (eval x (interaction-environment))
    ```
  - This pollutes `(interaction-environment)` with the syntax transformer so that whenever a subsequent module copies `(interaction-environment)` via `(parameterize ((compilation-environment (copy-environment (interaction-environment) #t))) ...)`, it implicitly inherits all previously transpiled `tm-define-macro` syntax transformers.
- **Side Effect**: Potential duplicate syntax definitions and global namespace pollution during compilation.
- **Target Clean Solution**:
  - Automatically infer macro dependencies by scanning module source bodies for known `tm-define-macro` symbols, or dynamically injecting `(import (for <declaring-module> run expand))` during AOT transpilation.
  - Or formalizing an aggregated syntax library (e.g. `(texmacs macros)`) that encapsulates all public `tm-define-macro` syntax transformers without mutating `(interaction-environment)`.

### [ ] First-Class Generic Procedure Architecture for `tm-define` & Expansion Isolation
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-define.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/texmacs/tm-define.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Concept & Future Architecture**:
  - **Implicit Generic Object Registration**: Rather than relying on a mutable compile-time table (`tm-defined-table`) to decide between `(define-public ...)` and `(set! ...)`, `tm-define` should treat overloaded routines as first-class generic procedure objects:
    1. The first `tm-define` for a symbol implicitly initializes, registers, and binds an overloaded dispatcher object.
    2. Subsequent `tm-define` declarations (whether in the same module or downstream modules) look up the existing object and register the new specialization/branch.
  - **Clean Macro Phase Isolation**:
    - Macro transformers and `tm-define` helpers (e.g. `ca*r`, `compute-arguments`, `predicate-option?`, option tables) are supplied in the compilation expansion phase (`(for ... run expand)`) without leaking into or mutating the global runtime namespace.
    - Prevents namespace collisions, removes the need for ad-hoc host `eval` shims, and preserves 100% of GNU TeXmacs's dynamic overloading semantics under strict R6RS AOT compilation.

- **Reference Architecture Walkthrough: Overloading Across Modules**:
  ```scheme
  ;; --- TeXmacs/progs/test/mod-a.scm ---
  (texmacs-module (test mod-a))
  ;; 1. Master definition:
  (tm-define (greeting who) (string-append "Hello, " who "!"))
  ;; 2. Intra-module overload:
  (tm-define (greeting who) (:mode "formal") (string-append "Good day, " who "."))

  ;; --- TeXmacs/progs/test/mod-b.scm ---
  (texmacs-module (test mod-b) (:use (test mod-a)))
  ;; 3. Downstream cross-module overload:
  (tm-define (greeting who) (:mode "french") (string-append "Bonjour, " who "!"))
  ```
  - **Compilation of `mod-a.scm`**:
    1. First `tm-define` takes Branch B: emits `(define-public greeting ...)` into the module definition block.
    2. Second `tm-define` takes Branch A: emits `(let ((former greeting)) (set! greeting ...))` into the initialization expression block.
    3. `partition-forms` arranges them into Chez R6RS order:
       ```scheme
       (module test:mod-a ()
         ;; Definitions block:
         (export greeting)
         (define greeting (lambda (who) (string-append "Hello, " who "!")))
         ;; Expressions block:
         (ahash-set! tm-defined-table 'greeting ...)
         (let ((former greeting))
           (set! greeting (lambda (who) (if (== (get-current-mode) "formal") ... (former who))))
           (ahash-set! tm-defined-table 'greeting ...)))
       ```
    4. Compiled natively into `mod-a.so` via `compile-file`.
  - **Compilation of `mod-b.scm`**:
    1. Emits `(import (for test:mod-a run expand))`, bringing `greeting` into scope.
    2. Third `tm-define` takes Branch A: emits `(let ((former greeting)) (set! greeting ...))`.
    3. Emits `(module test:mod-b () (import (for test:mod-a run expand)) (let ((former greeting)) (set! greeting ...)))` and compiles to `mod-b.so`.
  - **Runtime Execution**:
    1. `(load "mod-a.so")` defines and initializes the formal dispatch.
    2. `(load "mod-b.so")` wraps `greeting` to dispatch French mode without touching any global interpreter propagation tables or running host `eval`.

---

## 2. Compilation Pipeline Expansion & Residual Failure Tracking

### Current Census (Updated 2026-10-20)
- **Total Scheme Files in TeXmacs**: 457
- **Modules in Unified Compilation Pipeline (`compile_kernel.scm` Tiers 1–7)**: **453 modules** (100% of all modular Scheme files in TeXmacs, ordered via topological DAG analysis)
- **Successfully Compiled & Verified (`.so`)**: **400 modules** (88.3%)
- **Failing Modules (Strict Audit)**: **52 modules** (including 39 cascading native-load dependencies, tracked by root cause items below)
- **Non-Module Bootstrap Scripts**: **4 files** (`init-buffer.scm`, `init-texmacs.scm`, `init-texmacs-chez.scm`, `kernel/boot/boot-chez.scm`) evaluated directly at runtime.

---

### Root-Cause Diagnoses & Ready Fixes

#### [ ] Item 1: Keyword Binding Blocker for `document-part.scm` & Downstream Modules
- **Affected Modules (5)**:
  - `generic/document-part.scm`
  - `source/macro-edit.scm`
  - `source/macro-widgets.scm`
  - `link/ref-edit.scm`
  - `part/part-menu.scm`
- **Error**:
  - `Exception: variable :one is not bound` during load of `generic/document-part.so`.
  - Cascades into `Exception: unknown module generic:document-part` in `source/macro-edit.scm`, `source/macro-widgets.scm`, `link/ref-edit.scm`, and `part/part-menu.scm`.
- **Root Cause**: Keywords `:one`, `:several`, `:preamble` were omitted from `init-texmacs-chez.scm:67-73` and `boot-chez.scm`. Because `document-part.so` failed to load, its module was never bound in the compiler's top-level, breaking downstream dependents.
- **Ready Fix**:
  - Add `:one`, `:several`, `:preamble`, `:first`, `:last`, `:previous`, `:next` to `init-texmacs-chez.scm` and `boot-chez.scm`.
  - In `compile_kernel.scm`, emit self-evaluating bindings `(define :k ':k)` in module headers for all syntactic keywords found in the source file.

#### [ ] Item 2: `lazy-define` Expression Hazard in Definition Contexts
- **Affected Modules (2)**:
  - `convert/bibtex/init-bibtex.scm`
  - `convert/coq/init-coqml.scm`
- **Error**: `Exception: invalid context for definition (define (tmbib-snippet->texmacs . args) ...)`
- **Root Cause**: In `tm-define.scm:335`, `lazy-define-one` returns `#f` for symbols already bound at the top level. `lazy-define` splices `#f` into `(begin #f (define-public ...))`. In R6RS internal definition bodies, `#f` is treated as an expression, making subsequent definitions illegal.
- **Ready Fix**: Desugar `lazy-define` cleanly in `prepare-forms`: emit pure `(define-public ...)` stubs directly in the definitions block and registration calls in the expressions block without inserting `#f` literals.

#### [ ] Item 3: Destructuring Let Syntax in Converters & Macro Shadowing
- **Affected Modules (1)**:
  - `convert/coq/scmcoqml.scm`
- **Error**: `Exception: invalid bound variable (node proc children) in (let (((node proc children) ...)))`
- **Root Cause**: In `scmcoqml.scm:26`, the module defined a local procedure `(define (pair? t) (func? t 'pair 2))` checking for CoqML pair trees. Because `define-public-macro` in `boot-chez.scm` evaluates macro bodies dynamically via `(eval ... (compilation-environment))`, `abbrevs.scm`'s `with` macro evaluated `(pair? '(node proc children))` using `scmcoqml`'s `pair?`, which returned `#f`. It fell through to `(let ((,var ,val)) ,@body)`, generating an invalid binding `(let (((node proc children) ...)))`.
- **Immediate Workaround**: Commented out `with` in `kernel/boot/abbrevs.scm` so the system relies on the hygienic `syntax-case` `with` transformer defined in `boot-chez.scm`.
- **Permanent Fix**: See Item 4.

#### [ ] Item 4: Proper Lexical Closure Capture for `define-public-macro`
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm#L595)
- **Problem**: `define-public-macro` currently expands defmacro transformers by calling `(eval `(apply (lambda ,formals ,@body) ...) (compilation-environment))`. This executes the macro body in the *calling module's* compilation environment rather than the *definition module's* lexical environment. Any standard Scheme primitive called inside a macro body (e.g. `pair?`, `list?`, `symbol?`, `string?`) can be inadvertently shadowed or mutated if the downstream module defines a helper with the same name (as demonstrated by `(define (pair? t) ...)` in `scmcoqml.scm`).
- **Goal**: Implement a proper closure-capturing or syntax-case compiler for `define-public-macro` that evaluates macro procedures in their definition-site environment or binds primitives hygienically.


#### [ ] Item 5: Missing Guile Primitives in XML/Converter Subsystems
- **Affected Modules (3)**:
  - `convert/tools/xmltm.scm`
  - `convert/latex/tmtex.scm`
  - `convert/latex/tmtex-ieee.scm`
- **Error**: `Exception: variable delq! is not bound`
- **Root Cause**: Guile mutation primitives `delq!`, `delv!`, and `delete!` are used in legacy converter code but missing from Chez Scheme compatibility layers.
- **Ready Fix**: Define `delq!`, `delv!`, and `delete!` as aliases to Chez Scheme's `remq!` / `remove!` in `init-texmacs-chez.scm` and `boot-chez.scm`.

#### [ ] Item 6: Module Namespace Pollution & Missing Compile-Time Isolation
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Problem**: In Chez Scheme, every transpiled module file currently emits a trailing `(import mod-sym)` into `(interaction-environment)`. Consequently, all functions (not just `tm-define` extension points, but also internal `define-public` helpers) leak into the global environment.
- **Consequences**:
  1. *Hidden undeclared dependencies*: If Module C uses helper `h` from Module B without declaring `(:use (path B))`, and B was compiled earlier, C compiles and runs successfully by accident. If C is ever compiled in isolation or loaded in a different order, it crashes at runtime.
  2. *Namespace collision & shadowing*: Unrelated non-kernel modules exporting identical helper names (e.g., `parse`, `convert`, `init`) collide or overwrite each other in `(interaction-environment)`.
  3. *Semantic mismatch with Guile*: Guile gives each `(define-module ...)` a private obarray that imports *only* explicitly listed modules, preserving lexical hygiene.
- **Suggested Fixes**:
  1. *Clean compilation environment per module*: In `compile_kernel.scm`, construct each module's `compilation-environment` from a pristine base environment (Chez Scheme builtins + kernel shims) and explicitly import *only* the declared `:use` / `:inherit` dependencies.
  2. *Compile-time warning & linting pass via `(expand form (compilation-environment))`*: In `prepare-forms` / `transpile-kernel-module`, expand forms inside the module's isolated `(compilation-environment)`. If an identifier or macro is not bound in the declared scope, Chez Scheme's expander raises or flags the unbound variable, allowing the compiler to emit targeted warnings:
     `WARNING: module <mod> references <var> not found in kernel or declared (:use ...) dependencies`.
  3. *Remove trailing global imports from non-kernel modules*: Only import base kernel modules into the default interactive environment; non-kernel modules should only be imported by modules that explicitly declare a dependency on them.
  4. *Dispatch cross-module entry points via `lazy-define` and `tm-apply`*: Keep dynamic C++/GUI calls routed through `lazy-define` stubs and the `tm-defined-module` registry rather than dumping every module's private bindings into the global namespace.

#### [ ] Item 7: Clean Up Bare `()` in Expression Positions to `'()`
- **Affected Module**: `convert/latex/tmtex-ieee.scm:134`
- **Issue**: Upstream TeXmacs used bare `(if (null? l) () ...)` without quoting the empty list. In GNU Guile, bare `()` in expression position is non-standardly self-evaluating to the empty list, whereas in standard Scheme (R5RS, R6RS, Chez Scheme) bare `()` is invalid syntax (`Exception: invalid syntax ()`).
- **Solution & Upstreaming Note**: Quoting the empty list as `'()` (`(if (null? l) '() ...)`) is standard Scheme and evaluates identically in GNU Guile (1.8, 2.x, 3.x) and Chez Scheme. Replacing bare `()` with `'()` in source eliminates the need for any brittle transpiler AST-walking hacks (`tm-fix-empty-syntax`), preventing accidental corruption of formal parameter lists or quasiquote templates.

#### [ ] Item 8: Atomic `define-state` Initialization Before Macro Expansion
- **Affected Module**: `graphics/graphics-env.scm`
- **Issue**: In upstream `tm-states.scm`, `define-state` expands into a split declaration: `(begin (tm-define <name> #f) ... (set! <name> (state-create ...)))`. In R6RS module bodies, definitions precede expressions, leaving `<name>` `#f` during compile-time macro expansion of dependent macros (such as `(state-len)` which inspects `,state-slots`).
- **Solution**: In `compile_kernel.scm`, `define-state` is intercepted before generic macro expansion, emitting an atomic `(define-public <name> (state-create ...))` definition and registering `state-slots` in `(compilation-environment)` so downstream macros expand cleanly.

#### [ ] Item 9: Local Definition Collisions with Imported Module Symbols
- **Affected Module**: `convert/latex/tmtex-springer.scm` (and potential other converters)
- **Issue**: A module importing another module (`(:use (convert latex tmtex))`) that also defines a local procedure of the same name (`(define (tmtex-author-affiliation-ref t) ...)`) triggers Chez Scheme's `Exception: multiple definitions for <sym> in body`.
- **Solution**: Chez Scheme requires imported shadowed identifiers to be excluded via `(import (for (except <module> <sym> ...) run expand))`. Tracking all local definitions (both public and private) ensures `compile_kernel.scm` automatically emits `except` clauses for any locally shadowed symbols.

#### [ ] Item 10: Unify Macro Evaluation Environments (`interaction-environment` vs `compilation-environment`)
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm#L322-L344), [`TeXmacs/progs/kernel/texmacs/tm-define.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/texmacs/tm-define.scm#L246-L253), [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm)
- **Background & Issue**:
  - In Chez Scheme, `define-top-level-value` without an explicit environment argument defaults to `(interaction-environment)`, completely bypassing `(compilation-environment)`.
  - Conversely, macro transformers defined via `define-macro`, `define-public-macro`, and `define-macro-trace` execute their expansion logic inside `(compilation-environment)` via `(eval \`(apply (lambda formals body ...) ...) (compilation-environment))`.
  - This mismatch caused definitions emitted by macros or helper routines (such as `gui-make` in `menu-define.scm`) to install bindings into `(interaction-environment)` while being completely invisible to macro expanders executing in `(compilation-environment)`, raising `Exception: variable <var> is not bound` during `compile-file`.
- **Proposed Architectural Unification**:
  - Investigate transitioning all `(eval ... (compilation-environment))` call sites to `(eval ... (interaction-environment))`.
  - Under this design, compilation phases would parameterize `(interaction-environment)` with isolated snapshots/copies of the environment via `(parameterize ((interaction-environment (copy-environment (interaction-environment) #t))) ...)`.
  - **Considerations & Invariants**:
    - Ensure that modules compiled via `compile-file` under a parameterized `interaction-environment` retain the canonical top-level token (`'*top*'`) or maintain proper module metadata so subsequent `(import ,mod-sym)` and `native-load` into the global runtime environment locate compiled modules without token mismatches.
    - Confirm all stateful macro operations (`define-top-level-value`, `top-level-bound?`, `top-level-value`) naturally align with the active parameterized `(interaction-environment)` without requiring explicit environment arguments.

#### [ ] Item 11: Phasing Out Traced Macro Expansion (`define-macro-trace` / `public-trace`)
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), [`TeXmacs/progs/kernel/boot/ahash-table.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/ahash-table.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Status & Shift in Direction**:
  - Previously, `define-macro-trace`, `define-public-macro-trace`, and `public-trace` were introduced because `tm-define` expansions interleaved definitions (`define-public`) with runtime expressions (`ahash-set!`), requiring iterative AST macro tracing to peel them apart for R6RS `(module Name () defs ... exprs ...)`.
  - Since `tm-define` has now been refactored into a **pure expression** using `define-top-level-value` directly without any internal definitions, forms producing `tm-define` calls no longer contaminate definition contexts.
  - As a result, `tm-define-overloaded` and `texmacs-modes` have already been reverted to plain `define-public-macro`.
  - **Action Plan**:
    1. Verify remaining macros that were using `define-macro-trace` (e.g. in `latex-define.scm`, `tmtex.scm`, `cas-out.scm`).
    2. Confirm whether they can simply use standard `define-macro` or `define-public-macro`.
    3. Remove `define-macro-trace` and `define-public-macro-trace` apparatus once verified, simplifying the compilation pipeline.

#### [ ] Item 12: Idle TeXmacs High CPU Consumption & Runtime GUI Callback Environment Alignment
- **Location**: [`src/Plugins/Qt/qt_gui.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Plugins/Qt/qt_gui.cpp#L989-L1015), [`src/Texmacs/Server/tm_server.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Texmacs/Server/tm_server.cpp#L220-L245), [`TeXmacs/progs/init-texmacs-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-chez.scm)
- **Problem**: When idle, the TeXmacs GUI consumes high CPU resources (~100% core utilization).
- **Root Causes**:
  1. **Exception Feedback Loop on `0 ms` QTimer**: `qt_gui_rep::update()` runs at an idle interval of 15 ms, but flags `delay = 0` whenever `needing_update` is set. Because GUI callbacks (`notify-cursor-moved`, `lazy-initialize-force`, `text-icons`, `texmacs-focus-icons`) fail with `variable <var> is not bound` in `(interaction-environment)`, `apply_changes()` and `update_menus()` repeatedly log errors and trigger `notify_change(THE_CURSOR)`, keeping `needing_update = true` permanently active in a zero-sleep busy loop.
  2. **Disabled Upstream CPU Throttling (`QT_CPU_FIX`)**: In `basic.hpp` and `qt_gui.cpp`, upstream commented out `//#define QT_CPU_FIX 1` which implements an adaptive `tm_sleep()` usleep throttling mechanism.
- **Action Plan**:
  1. Align the runtime evaluation environment: import kernel module exports and `texmacs-user` bindings into `(interaction-environment)` so C++ callbacks (`lazy-initialize-force`, `notify-cursor-moved`, toolbar icons) resolve cleanly.
  2. Verify that successful menu and cursor updates break the `needing_update` loop, allowing `updatetimer` to settle into its normal idle interval.
  3. If idle polling overhead remains high, evaluate enabling or modernizing the `QT_CPU_FIX` adaptive sleep mechanism in `qt_gui.cpp`.

#### [ ] Item 13: Replace `...` Identifier in `abbrevs.scm` with `range-inclusive` or `...*`
- **Location**: [`TeXmacs/progs/kernel/boot/abbrevs.scm:166`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/abbrevs.scm#L166), and 8 call sites across `progs/`
- **Problem**: `abbrevs.scm` defines an inclusive integer range procedure named `...` (`(define-public (... start end . delta) ...)`). In Chez Scheme, `...` is the core syntax ellipsis keyword in the macro expander (`syntax-case` / `syntax-rules`). Exporting `...` as a procedure binds it at the top level, causing Chez's hygienic macro expander (`free-identifier=?`) to treat `...` as a normal pattern variable rather than the ellipsis keyword, breaking any macro containing multiple ellipses with `duplicate pattern variable ...`.
- **Call Sites (8 total)**:
  1. `dynamic/animate-menu.scm:322`
  2. `dynamic/calc-table.scm:65`
  3. `dynamic/calc-table.scm:70`
  4. `utils/email/email-tmfs.scm:71`
  5. `utils/email/email-tmfs.scm:81`
  6. `generic/embedded-edit.scm:122`
  7. `text/text-structure.scm:118`
  8. `text/text-structure.scm:128`
- **Action Plan**: Rename `...` in `abbrevs.scm` (and its 8 callers) to a non-conflicting procedure name (e.g. `range-inclusive` or `..*`) to eliminate the ellipsis identifier collision in Chez Scheme.

#### [ ] Item 14: Legacy 4-Operand `if` Syntax in `client-widgets.scm`
- **Location**: [`TeXmacs/progs/client/client-widgets.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/client/client-widgets.scm)
- **Affected Module (1)**: `client/client-widgets.scm`
- **Error**: `Exception: invalid syntax (if (== ret "done") (client-notify-account ...) (client-login-home ...) (client-open-error ...))`
- **Root Cause**: Upstream GNU Guile 1.8 permitted `if` forms with multiple expressions in the `else` branch (behaving like an implicit `begin`). Chez Scheme strictly enforces R6RS syntax: `(if <test> <consequent> [<alternate>])` taking at most 3 operands.
- **Action Plan**: Wrap multiple `else` expressions in `(begin ...)` or add a 4-operand `if` desugaring rule in `compile_kernel.scm`'s `prepare-forms`.

#### [ ] Item 15: Empty `(begin)` Form in `wallet-menu.scm`
- **Location**: [`TeXmacs/progs/security/wallet/wallet-menu.scm:15`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/security/wallet/wallet-menu.scm#L15)
- **Affected Module (1)**: `security/wallet/wallet-menu.scm`
- **Error**: `Exception: invalid syntax (begin)`
- **Root Cause**: A conditional menu macro expands into an empty `(begin)`. Chez Scheme's R6RS specification requires `(begin form1 form ...)`, requiring at least one subform.
- **Action Plan**: Desugar empty `(begin)` into `(noop)` or `(void)` during transpilation in `prepare-forms`, or guard the macro expansion.

#### [ ] Item 16: Premature Definition in Expression Context in `cas-out.scm`
- **Location**: [`TeXmacs/progs/utils/cas/cas-out.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/utils/cas/cas-out.scm)
- **Affected Module (1)**: `utils/cas/cas-out.scm`
- **Error**: `Exception: invalid context for definition (define cas-assign-op-table (list->ahash-set (cas-collect-members "arithmetic-assign")))`
- **Root Cause**: In `cas-out.scm`, side-effecting initialization expressions precede the definition of `cas-assign-op-table`. Under Chez Scheme's R6RS module layout (`defs` before `exprs`), definitions appearing after initialization expressions trigger definition context violations.
- **Action Plan**: Hoist `cas-assign-op-table` or convert to `tm-define` so `partition-forms` cleanly separates the definition from expression expressions.

#### [ ] Item 17: Unbound Keyword Tokens in Dynamic Hooks (`:on-cpu-idle` & `:uninit`)
- **Location**: [`TeXmacs/progs/client/client-base.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/client/client-base.scm), [`TeXmacs/progs/tools/spell/spell-lantool.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/tools/spell/spell-lantool.scm)
- **Affected Modules (3)**:
  - `client/client-base.scm` (`:on-cpu-idle`)
  - `tools/spell/spell-lantool.scm` (`:uninit`)
  - `tools/spell/spell-kbd.scm` (Cascaded from `spell-lantool`)
- **Error**: `Exception: variable :on-cpu-idle is not bound`, `Exception: variable :uninit is not bound`.
- **Root Cause**: Unquoted keyword tokens starting with `:` evaluated as global variable references at runtime.
- **Action Plan**: Add `:on-cpu-idle` and `:uninit` to the keyword binding tables in `init-texmacs-chez.scm` and `boot-chez.scm`.

#### [ ] Item 18: Record Field Specifier Mismatch in `tmcolor.scm`
- **Location**: [`TeXmacs/progs/convert/tools/tmcolor.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/convert/tools/tmcolor.scm)
- **Affected Modules (2)**:
  - `convert/tools/tmcolor.scm`
  - `convert/tools/old-tmtable.scm` (Cascaded: `unknown module convert:tools:tmcolor`)
- **Error**: `Exception in record-accessor: invalid field specifier name-promise`
- **Root Cause**: `tmcolor.scm` uses SRFI-9 or Guile record definitions with field accessor `name-promise` that fails Chez Scheme's internal record descriptor validation.
- **Action Plan**: Check record type field declarations in `tmcolor.scm` and align with Chez Scheme record accessor conventions.

#### [ ] Item 19: Missing Module Declaration or Search Path for `init-rewrite.scm`
- **Location**: [`TeXmacs/progs/convert/rewrite/init-rewrite.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/convert/rewrite/init-rewrite.scm)
- **Affected Modules (3)**:
  - `doc/apidoc-funcs.scm`
  - `prog/prog-format.scm`
  - `prog/scheme-tools.scm`
- **Error**: `Exception: unknown module convert:rewrite:init-rewrite`
- **Root Cause**: `convert/rewrite/init-rewrite.scm` was not included in the pre-compiled pipeline sequence prior to loading downstream dependents.
- **Action Plan**: Include `convert/rewrite/init-rewrite.scm` in Tier 2/5 pipeline so its module symbol is available for import.

#### [ ] Item 20: Unbound `scm-error` in `debug-menu.scm`
- **Location**: [`TeXmacs/progs/debug/debug-menu.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/debug/debug-menu.scm)
- **Affected Module (1)**: `debug/debug-menu.scm`
- **Error**: `Exception: variable scm-error is not bound`
- **Root Cause**: `scm-error` is evaluated inside a macro transformer or form during compilation before the runtime bridge in `init-texmacs-chez.scm` is imported.
- **Action Plan**: Define `scm-error` in `(compilation-environment)` within `boot-chez.scm` / `compile_kernel.scm`.

#### [ ] Item 21: Expand-Time State Contamination from Eager Evaluation in `compile_kernel.scm`
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), [`TeXmacs/progs/utils/edit/variants.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/utils/edit/variants.scm), [`TeXmacs/progs/graphics/graphics-env.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/graphics/graphics-env.scm)
- **Problem**: Macros generating conditional code via expand-time `(if (ahash-ref ...) ...)` or `(if (top-level-bound? ...) ...)` can miscompile during batch AOT compilation because `compile_kernel.scm`'s Pass 1 eagerly evaluates forms into `(compilation-environment)`. By the time Pass 2 (`compile-file`) runs macro expansion, tables and variables in compiler memory are already populated, triggering the wrong expand-time conditional branch (e.g. omitting definitions that should be generated at runtime module load time).
- **Remediation Strategies**:
  1. Defer stateful table lookups to runtime by generating `(if (ahash-ref ...) ...)` directly inside the emitted runtime code (`begin ...`) rather than evaluating it at macro-expansion time.
  2. Isolate Pass 1 eager evaluation inside a disposable/sandboxed environment so side effects to global tables do not leak into Pass 2 macro expansion.
  3. Where macro output needs private module state across modules, use `define-module-macro` with `indirect-export` instead of unquoting expand-time environment variables.

#### [ ] Item 22: Evaluation Timing & Lazy Resolution of `(doc help-funcs)` for `help-menu`
- **Location**: [`TeXmacs/progs/doc/help-funcs.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/doc/help-funcs.scm), [`TeXmacs/progs/doc/help-menu.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/doc/help-menu.scm), [`TeXmacs/progs/init-texmacs-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-chez.scm)
- **Problem**: When TeXmacs initializes the GUI window during boot (`TIME-OPEN-WINDOW`), the menu bar resolves `help-menu`. If `help-menu` evaluates before `(module-provide '(doc help-funcs))` has run, global multimethods defined via `tm-define` (such as `load-help-article`, `load-help-buffer`, and `url-exists-in-help?`) are not yet bound in `(interaction-environment)`, raising `(TM-APPLY-ERROR variable load-help-article is not bound)`.
- **Architectural Principle**: `tm-define` definitions are dynamic multimethods in the global dispatch table (`tm-defined-table` / `(interaction-environment)`), NOT static R6RS module exports. Downstream modules do not import them via static `import`; the defining module must simply be evaluated before symbols are resolved.
- **Action Plan**:
  1. Audit `(lazy-menu (doc help-menu) help-menu)` and ensure `(doc help-funcs)` is registered via `lazy-define` in `init-texmacs-chez.scm`:
     `(lazy-define (doc help-funcs) load-help-article load-help-buffer url-exists-in-help? help-file-title)`
  2. Verify that accessing `help-menu` on demand triggers `load-module` for `(doc help-funcs)` before menu item callbacks fire.

#### [ ] Item 23: Format Escape `~:s` Evaluation Error in `(open-preferences)`
- **Location**: [`TeXmacs/progs/texmacs/menus/preferences-*.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/texmacs/menus/), [`TeXmacs/progs/kernel/gui/menu-widget.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/gui/menu-widget.scm)
- **Problem**: Invoking `(open-preferences)` in headless mode raises `(PREF-ERROR: variable ~:s is not bound)` when constructing `(top-window preferences-widget "User preferences")`.
- **Root Cause**: An unescaped or misquoted format string directive (such as `~:s` from `format`, `texmacs-error`, or `display*`) is being evaluated as a Scheme symbol/variable expression rather than parsed as a formatting specifier.
- **Action Plan**:
  1. Locate the call emitting `(PREF-ERROR: ...)` across the preferences widget constructors.
  2. Fix the quote or macro expansion causing the format string to be evaluated as Scheme code.

#### [ ] Item 24: Module System Modernization via Explicit Side-Effect Wrapping (`%module-side-effect`)
- **Location**: [`src/Scheme/Chez/compile_kernel.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/compile_kernel.scm), [`TeXmacs/progs/kernel/texmacs/tm-modes.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/texmacs/tm-modes.scm), macro definers across `progs/`
- **Background & Context**: Upstream GNU TeXmacs used dummy definitions `(define _tm_def_XX (begin ... (void)))` to smuggle runtime side-effects (`set-symbol-procedure!`, `logic-rules`, option registrations) into macro outputs intended for definition contexts.
- **Proposed Architecture**:
  - Replace artificial `_tm_def_XX` dummy bindings with an explicit compiler marker form: `(%module-side-effect <expr> ...)`.
  - In the module compilation/expansion pass, the transpiler cleanly partitions:
    1. Genuine procedure and syntax definitions into `defs` and extracts exported symbols for `(export ...)`.
    2. Any `(%module-side-effect ...)` forms directly into the module's runtime initialization block (`exprs`).
  - Eliminates dummy variables in symbol tables, prevents compiler definition context violations, and cleanly decouples definitions from runtime side-effects.

#### [ ] Item 25: Runtime Unbound Variable `opts` in `(open-preferences)` and `(top-window ...)`
- **Location**: [`TeXmacs/progs/kernel/gui/menu-widget.scm`](file:///Users/king-kong/Documents/GitHub/texmacs/TeXmacs/progs/kernel/gui/menu-widget.scm#L1226), [`TeXmacs/progs/texmacs/menus/preferences-widgets.scm`](file:///Users/king-kong/Documents/GitHub/texmacs/TeXmacs/progs/texmacs/menus/preferences-widgets.scm)
- **Error**: `(TM-APPLY-ERROR variable opts is not bound)`
- **Symptom**: Triggered when invoking `(open-preferences)` or any window constructor delegating to `(top-window ...)` or `(dialogue-window ...)`.
- **Diagnosis**: 
  - Traceback isolated to:
    ```
    (FRAME 0 CODE new-val SRC opts LOC ())
    (FRAME 1 CODE #f SRC (top-window preferences-widget User preferences) LOC ())
    ```
  - `top-window` uses `(tm-define (top-window menu-promise name . opts) ... (with (bufs qqq) (decode-options opts) ...))`.
  - In `(interaction-environment)`, macros like `with`, `tm-widget`, and `receive` interact with rest arguments and dynamic module environments. If `receive` (or destructuring `with`) is not recognized as syntax transformer in the caller's evaluation context, forms like `(receive (opts ...) ...)` or `(with (bufs qqq) ...)` fall back to function applications where `opts` is evaluated as an unbound variable.

#### [ ] Item 26: Document Style Package Lists & Feature Lists Invoked as Procedures in `tm-apply`
- **Location**: `src/Scheme/Chez/chez_tm.cpp`, `src/Scheme/Scheme/object.cpp`, stylesheet environment handlers
- **Errors**:
  - `(TM-APPLY-ERROR ("std" "typeset") is not a procedure)`
  - `(TM-APPLY-ERROR ("chapter-post-sep" "page-the-page" ...) is not a procedure)`
  - `(TM-APPLY-ERROR ("item-hsep" "last-item-nr" "item-vsep") is not a procedure)`
  - `(TM-APPLY-ERROR () is not a procedure)`
- **Root Cause**:
  - `("std" "typeset")` is the style package list declared by documents (`use-package`).
  - `("chapter-post-sep" ...)` and `("item-hsep" ...)` are stylesheet environment variable lists.
  - In C++, `call_scheme(object_to_tmscm(obj))` or `as_command(obj)->apply()` invokes `tm-apply` on a Scheme object that is expected to be a command or procedure. When C++ passes an evaluated document property, stylesheet list, or raw data list where a callback procedure was expected, `tm-apply` attempts `(apply proc args)`, triggering `<list> is not a procedure`.
- **Action Plan**:
  - Guard `tm-apply` in `chez_tm.cpp`: if `fun` is not a symbol, procedure, or callable entity, return `#f` or evaluate data safely rather than raising an unhandled exception.
  - Audit C++ command callback bridging in `object.cpp` (`object_command_rep`, `call_scheme`) to ensure raw property lists are not passed as callbacks.

#### [x] Item 27: Tagged Pointer / Blackbox Conversion Error (`<int> is not a proper list / pair`)
- **Location**: [`src/Scheme/Chez/chez_tm.cpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/chez_tm.cpp), [`src/Scheme/Chez/chez_tm.hpp`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/src/Scheme/Chez/chez_tm.hpp), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/kernel/boot/boot-chez.scm), [`TeXmacs/progs/init-texmacs-chez.scm`](file:///Users/king-kong/Documents/my-repo/docker-sandbox-opencode/texmacs/TeXmacs/progs/init-texmacs-chez.scm)
- **Errors**:
  - `(TM-APPLY-ERROR 4712781216 is not a pair)`
  - `(TM-APPLY-ERROR 5012788192 is not a proper list)`
  - `Exception in map: 4705105096 is not a proper list` in `link-flatten-sub` / `(tm-cdr ln)`
- **Root Cause**:
  - Blackboxes (`tree`, `widget`, `observer`, etc.) were represented as a Scheme pair `(cons 'tmscm-blackbox <pointer-int>)`.
  - Polymorphic TeXmacs procedures in `content.scm` (e.g. `(tm-cdr x)`) use `(if (pair? x) x (tree->list x))` to distinguish Scheme lists from C++ trees (which were SMOBs in Guile where `pair?` returned `#f`).
  - Because Chez Scheme represented blackboxes as pairs, `(pair? tree)` returned `#t`, returning the raw pointer address integer instead of the child trees list and detonating `map`.
- **Solution (Approach 2 - Native Box Representation + Guardian Lifecycle)**:
  1. **Chez Box Representation**: Switched `blackbox_to_tmscm` / `tmscm_to_blackbox` to Chez Scheme native Boxes (`Sbox` / `Sunbox` / `Sboxp`). Because Box is a native, non-pair, non-list Chez datatype, `(pair? tree)` correctly returns `#f`, enabling all polymorphic functions (`tm-car`, `tm-cdr`, `tm-label`, `tm-children`, `tm-is?`) to take their intended tree paths.
  2. **Automatic Lifecycle via Guardians**: Established a Chez Scheme Guardian `(define tm-blackbox-guardian (make-guardian))`. When C++ glue procedures return blackbox objects to Scheme, `tm-register-guardian!` registers them. When objects become unreachable, dead blackboxes are collected and reclaimed via `tmscm_delete_blackbox` / `tm_delete` in both `collect-request-handler` and the Qt idle loop (`command_queue::exec_pending`).
  3. **Value Equality & Hash Tables**: Implemented C foreign procedures `tmscm_blackbox_equal` and `tmscm_blackbox_hash` hooked into Scheme's `equal?`, `==`, `!=`, and `make-hash-table`, providing full content-equality and persistent hashing for blackbox-keyed structures.

