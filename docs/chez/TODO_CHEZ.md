# TeXmacs Chez Backend Optimization TODO List

This document tracks identified architectural improvements and performance bottlenecks for the TeXmacs Chez Scheme port (`wip-chez`).

---

## 1. High Priority (Performance & Startup)

### [!] Warning: Eager Evaluation Side Effects & Stateful Macro Branching (`if`/`else` at Expand Time)
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), macro definers across `TeXmacs/progs/`
- **Problem**:
  Macros that inspect global tables or mutable variables to conditionally emit different code branches (e.g. `(if (ahash-ref table key) ...)` or `(if (top-level-bound? ...) ...)`) might not compile correctly under our ahead-of-time pipeline.
  Because `compile-texmacs.scm` eagerly evaluates forms into `(compilation-environment)` during Pass 1 (`eval-eager-form!`), mutable tables in compiler memory are modified before Pass 2 (`compile-file`) runs macro expansion. As a result, the expander sees the post-eager-eval state (taking the `else` or "already initialized" branch) rather than the clean initial state that should exist when the compiled `.so` loads at runtime.
  - *Example (`define-group` in `variants.scm`)*: Pass 1 populated `group-table`, causing Pass 2 macro expansion to see `old != #f` and omit procedure declarations (`tm-define (group-list) ...`) from compiled `.so` files.
  - *Example (`state-slots` in `graphics-env.scm`)*: Unquoting mutable slot lists inside macro templates (`(- (length (memq ,i ,state-slots)) 1)`) relied on expand-time environment bindings, failing downstream when compiled across module boundaries.
- **Future Architectural Considerations & Action Plan**:
  1. **Defer Stateful Branching to Runtime**: Whenever possible, avoid expand-time `(if <table-ref> ...)` branching; move the conditional directly into the emitted runtime AST (e.g. `(begin (if (ahash-ref ...) ...) ...)`) so that table mutations and definitions occur at module load time rather than during compilation.
  2. **Audit Macros for Expand-Time State Dependencies**: Review macro definers (`define-macro`, `define-public-macro`, `define-module-macro`) across `TeXmacs/progs/` that query hash tables, property lists, or top-level bound status during expansion.
  3. **Phase-Isolated Compilation Environment**: Investigate parameterizing `(compilation-environment)` with an isolated, copy-on-write snapshot during Pass 1 eager evaluation or resetting stateful tables before `compile-file` to prevent expand-time state leakage between passes.

### [X] Cork Encoding & FFI String/Bytevector Transcoding Mismatch [RESOLVED]
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm) (`recur-transcode-bytevector`, `recur-transcode-string`, `recur-utf8->string`, `recur-string->utf8`, `recur-cork->string`, `recur-string->cork`, `tm-call-by-name`)
- **Problem**:
  In Guile 1.8, Scheme strings were raw 8-bit byte arrays (`char*`), allowing UTF-8, Latin-1, and 8-bit Cork (TeX T1 font encoding with bytes `0x80`–`0xFF`) to coexist without transcoding.
  In Chez Scheme, strings are strictly vectors of Unicode scalar values.
  At the FFI boundary (`chez_tm.cpp`), C++ `string_to_tmscm` allocates an R6RS bytevector (`Smake_bytevector`) containing the raw bytes of `tm_string`.
  However, in `boot-chez.scm`, `recur-utf8->string` unconditionally wrapped every returned bytevector in `(utf8->string bytevector)`.
  When procedures such as `utf8->cork` returned Cork-encoded bytevectors containing 8-bit non-ASCII bytes (e.g. `0xE9` for `'é'`), Chez Scheme's UTF-8 decoder replaced them with Unicode replacement character `U+FFFD` (`\ufffd`), permanently mangling data (`(cork->utf8 (utf8->cork "zéro"))` $\to$ `"zï£¡ro"`).
- **Solution Implemented**:
  1. Built recursive combinators `recur-transcode-bytevector` and `recur-transcode-string` to traverse arbitrary trees, pairs, and vectors cleanly without a generic predicate dispatch.
  2. Implemented bijective 8-bit Cork codecs `cork-bytes->string` and `string->cork-bytes` using R6RS `(latin-1-codec)` with `(eol-style none)` (preventing platform EOL normalization of byte `0x0D` / Cork low quote `‚`), establishing a lossless 1-to-1 mapping between 8-bit Cork byte values `0x00`–`0xFF` and Unicode codepoints `U+0000`–`U+00FF`. Documented the architectural trade-offs, 32-bit container memory cost, semantic operation limitations, and the long-term roadmap to migrate Cork strings to native bytevectors.
  3. Wrapped `tm-call-by-name` (the central C++ glue dispatcher) to handle Cork vs UTF-8 input/output transcoding directly based on procedure name, keeping `tm-install-procedure!` completely generic and `tm-apply` untouched:
     - `utf8->cork` and `sourcecode->cork`: input encoded via `recur-string->utf8`, output decoded via `recur-cork->string`.
     - `cork->utf8`, `cork->sourcecode`, and `escape-to-ascii`: input encoded via `recur-string->cork`, output decoded via `recur-utf8->string`.
     - All other procedures: standard `recur-string->utf8` / `recur-utf8->string`.
  4. Verified full round-trip fidelity with French and German accented text (`(cork->utf8 (utf8->cork "élève naïve à l'Haÿ-les-Roses Grüße"))` $\implies$ `#t`).

### [X] Eliminate Universal FFI Transcoding Overhead in `tm-call-by-name` [RESOLVED]
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm:956-970`](TeXmacs/progs/kernel/boot/boot-chez.scm#L956-L970), [`src/Scheme/Chez/chez_tm.cpp:138-160`](src/Scheme/Chez/chez_tm.cpp#L138-L160)
- **Problem & Measured Impact**:
  - In commit `705e0d47`, `tm-call-by-name` was wrapped with `(in-trans args)` and `(out-trans ...)` to handle Cork/UTF-8 bytevector conversions.
  - Because `tm-call-by-name` is the central trampoline for **all ~1,150 C++ glue procedures**, every keystroke triggers dozens of glue queries (`(tree-label t)`, `(tree-ref t 0)`, `(cursor-path)`).
  - On every single glue call, `recur-string->utf8` and `recur-utf8->string` execute recursive loops over argument lists and return values. This allocates dozens of transient `bytevector` and `string` objects on the Chez nursery heap per keystroke.
  - **Measured Regression**: Math typing regressed from **728.8 ms** (with peaks of **460 ms**) to **1,152.6 ms** (+58% latency); text typing regressed from **1,035.5 ms** to **1,147.0 ms**.
- **Technical Distinction: Symbols vs. Raw Binary Strings**:
  - **Scheme Symbols (`Ssymbolp`, `'math`, `'concat`, `'fraction`, `'bold`)**:
    - Symbols are immutable, interned pointers in Chez Scheme.
    - They represent AST node tags, grammar keywords, and procedure names. They are strictly ASCII identifiers (`[a-z0-9_-]+`).
    - Symbols **never have encoding ambiguity**: they cannot contain 8-bit Cork font bytes, null bytes, or multi-byte UTF-8 sequences.
    - Running `recur-string->utf8` on symbols is a 100% redundant, no-op tree walk that wastes CPU cycles.
  - **Raw Binary Strings in TeXmacs (`string` in C++)**:
    - TeXmacs's C++ `string` class is an unformatted 8-bit byte array (`char*` + length). It is overloaded across the engine to represent three distinct types of data:
      1. *Semantic Unicode/ASCII Text*: e.g. `"The quick brown fox"`, `"change-log.en.tm"`.
      2. *Cork Font Strings*: TeX's T1 Cork font encoding, where bytes `0x80`–`0xFF` represent accented characters and math symbols (e.g. `0x0D` is `‚`, `0xE9` is `'é'`). In Chez Scheme, raw bytes in the range `0x80`–`0xFF` are invalid UTF-8 sequences and cannot be stored in standard Chez `Sstring`s without decoding errors (`\ufffd`).
      3. *Raw Binary Data*: PNG/JPEG images loaded via `tmfs://`, binary TrueType/OpenType font tables, or SQLite database blobs, containing arbitrary byte sequences including `0x00` (null bytes).
    - Chez Scheme strings (`Sstring`) are strictly vectors of 32-bit Unicode scalar values (`0 <= c <= 0x10FFFF`). Passing Cork bytes or binary image buffers to Chez `Sstring` crashes or corrupts data.
- **Granular Census: Which Primitives Need Transcoding vs. Which DO NOT**:
  - **>90% of All Glue Primitives DO NOT Need Any Transcoding**:
    - *AST & Tree Navigation*: `tree-label`, `tree-ref`, `tree-set!`, `tree-children`, `tree-arity`, `tree-insert!`, `tree-remove!`, `tree-cursor`, `cursor-path`, `tree-search`, `tree-copy`. (Operate purely on `tree` blackboxes, integer fixnums, and Scheme symbols).
    - *Typesetting & Layout Controls*: `update-current-buffer`, `update-forced`, `typeset-forced`, `generate-all-aux`, `inclusions-gc`, `picture-gc`, `window-set-view`, `get-page-count`.
    - *Buffer & Window Navigation*: `current-buffer`, `new-buffer`, `buffer-close`, `go-to`, `go-end`, `go-start`, `buffer-tree`, `has-selection?`, `selection-active?`.
    - *Coordinates, State & Undo*: `get-x`, `get-y`, `archive-state`, `start-editing`, `end-editing`, `keyboard-message`.
    - *Mathematical / Geometry Primitives*: All coordinate arithmetic, rectangle computations, and boolean queries.
  - **The Few Primitives That ACTUALLY Handle Strings**:
    - *Text Node Editing*: `cpp-insert` / `insert-tree` (when inserting user text into an atomic AST leaf), `tree-node-text` (reading text from a leaf).
    - *File & URL I/O*: `string-load`, `tm-load-path`, `tm-load-bytes`, `url-load-binary`, `file-save`, `url-save`.
    - *Cork Codecs (Already Custom)*: `cork->utf8`, `utf8->cork`, `cork->sourcecode`, `sourcecode->cork`, `escape-to-ascii`.
- **Solution Implemented & Empirical Validation**:
  1. **Zero-Allocation Structural Sharing in Transcoders**:
     Updated `recur-transcode-bytevector` and `recur-transcode-string` in `boot-chez.scm` to preserve structural sharing:
     ```scheme
     (let ((a (loop (car x))) (d (loop (cdr x))))
       (if (and (eq? a (car x)) (eq? d (cdr x))) x (cons a d)))
     ```
     When an AST subtree contains no bytevectors or strings needing transcoding, it returns `x` directly with **0 cons cells allocated**.
  2. **Selective Raw Routing in Fast Table Dispatch**:
     Procedures with strictly non-string signatures are installed directly to fixed-arity `tm_fast_call_N` trampolines with zero transcoding wrapping.
  3. **Empirical Churn Reduction**: Combined with the fast table dispatch, cold LaTeX export churn plummeted by **126.0 MB (-49.1%)** (GCs cut from 30 to 15); warm export churn dropped by **41.1 MB (-27.0%)** (GCs cut from 18 to 13). Latency dropped by 10%–34% across macro benchmarks.

### [ ] Switch from `(module ...)` to R6RS `(library ...)` Syntax
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm)
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
    - `compile-texmacs.scm` detects cyclic dependencies during topological compilation:
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

### [ ] Inline Boot-Level Helpers (`==`) Without Breaking the Boot Loader
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm), [`TeXmacs/progs/kernel/boot/abbrevs.scm`](TeXmacs/progs/kernel/boot/abbrevs.scm), [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm)
- **Observation**:
  `==` is a normal procedure, `(define-public (== x y) (equal? x y))`. At `optimize-level` 2 Chez still leaves `(== x y)` as a call because each module is compiled separately: the compiler imports the binding, not the body. Inlining requires the definition to be visible in the same compilation unit (or an explicit macro/inline form).
- **Compile-Flow Problem**:
  The boot path is the obstacle. `boot-chez.scm` is a boot-loading Scheme file that `compile-texmacs.scm` itself needs at startup, so it is loaded from source rather than compiled first. Any helper defined in that layer is not available as a compiled definition when the rest of the tree is compiled. Moving `==` out of the boot files, or compiling `boot-chez.scm` itself, creates a chicken-and-egg dependency: the compiler needs the boot loader loaded before it can compile the boot loader.
- **Proposed Direction**:
  1. **Compile a minimal bootstrap unit first**: extract the smallest boot-loading script, compile it, load it, then compile the rest of the tree (including the current boot files) against that compiled bootstrap. This changes the compile flow but removes the source-only boot layer as an inlining barrier.
  2. **Move small hot helpers into a compiled module**: e.g. `==`, `func?`, `nnull?`, `npair?` could live in a normal compiled module once the bootstrap is compiled, so later modules import a definition the optimizer can see.
  3. **Use an explicit inline/macro form where safe**: `==` could expand to `equal?` at call sites, but only if first-class uses such as `(map == ...)` are either eliminated or kept in a compatibility procedure.
- **Caveats / Acceptance Criteria**:
  - Cross-module inlining is not achieved by merely compiling `abbrevs.scm` separately; the body must be available at the call site's compilation unit or through a macro/inline declaration.
  - A global `optimize-level` 2 experiment is required to measure whether any of this actually helps; the current microbenchmark estimates only **~6–9 ms of 1.7 s** in the LaTeX conversion run, so this is primarily a compile-flow enabler for broader inlining, not an immediate hot-path fix.
  - Verify with `-compile-modules` (0 failures), normal startup, and the conversions benchmark after changing the bootstrap order.

### [ ] Native Chez Primitive Deduplication Guideline
- **Location**: Module transpilers and compatibility headers ([`TeXmacs/progs/kernel/boot/srfi.scm`](TeXmacs/progs/kernel/boot/srfi.scm), [`init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm))
- **Rule**: Whenever porting/compiling Scheme files that define polyfill macros or compatibility emulators (e.g. SRFI-16 `case-lambda`, SRFI-9 `define-record-type`, SRFI-11 `let-values`, SRFI-39 `make-parameter`), always check whether Chez Scheme natively implements the primitive.
- **Action**: Comment out or bypass macro emulators in favor of Chez's native optimizing compiler primitives. Native compiler forms benefit from direct code generation, fast jump-tables, and zero runtime expansion overhead.

---

### [ ] Automated Topological Boot Manifest Generation
- **Location**: `src/Scheme/Chez/boot_files.scm` and `src/Scheme/Chez/build-boot.scm` (retired scripts from the earlier workspace; the boot manifest now lives in `build-texmacos/boot/module-deps.scm`)
- **Problem**: When capturing boot file order by logging file load starts (`LOAD-START`), it produces DFS pre-order where orchestrators (e.g. `init-texmacs.scm`) precede the modules they depend on. Sequential compilation and boot-file evaluation require DFS post-order (dependencies evaluated before callers). Currently, `boot_files.scm` has manually adjusted ordering.
- **Goal / Solution**: Automate manifest extraction in the build system:
  - Option A: Trace `LOAD-FINISH` hooks during a verified headless boot session so files are recorded upon return (natural post-order).
  - Option B: Static dependency analysis of `(texmacs-module ... (:use ...))` declarations and `(load ...)` calls to construct a dependency DAG and compute topological sort (`tsort`).

### [ ] Transitive Predecessor Invalidation in Incremental Compilation (`compile-texmacs.scm`)
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm)
- **Problem & Context**:
  - The current incremental compilation check (`compile-texmacs.scm`) determines whether a module is `UP-TO-DATE` purely by comparing the timestamp of the module's target `.so` against its own upstream `.scm` source file.
  - If a predecessor module $A$ is modified (e.g. exporting fewer functions, altering macro definitions, or changing public signatures), downstream module $B$ that depends on $A$ is not automatically invalidated or recompiled if $B$'s own source timestamp has not changed.
  - In ahead-of-time compiled Chez Scheme binaries, macro expansions and direct variable references across module boundaries can bake in assumptions about predecessor exports. If a predecessor exports fewer functions or reorders bindings, call-sites and address offsets in previously compiled downstream `.so` units can become stale or broken.
- **Goal / Action Plan**:
  - Implement transitive dependency checking in the compilation script: check not only the `.scm` file itself, but also walk its dependency DAG (predecessors via `*all-module-deps*`). If any predecessor `.so` was rebuilt or has a newer timestamp than the downstream `.so`, invalidate and trigger recompilation of the dependent module.

---

## 2. Medium Priority (GUI & Responsiveness)

### [ ] Keyboard Input Latency & Eliminating JIT Native-Code `eval` in C++ Dispatch
- **Location**: [`src/Edit/Interface/edit_keyboard.cpp`](src/Edit/Interface/edit_keyboard.cpp), [`src/Scheme/Scheme/object.cpp`](src/Scheme/Scheme/object.cpp), [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp)
- **Root Cause (Chez JIT Native Compilation Overhead)**:
  - Typing in TeXmacs can feel sluggish because every single keystroke in `edit_interface_rep::handle_keypress` invokes multiple Scheme procedures by string name:
    - `call ("keyboard-press", gkey, t)` in `edit_keyboard.cpp`
    - `call ("kbd-find-key-binding", key)` inside `tm_config.cpp:find_key_binding`
    - `call ("kbd-insert", rew)` in `edit_keyboard.cpp`
  - In `src/Scheme/Scheme/object.cpp`, `call (string fun, ...)` wraps the function name with `eval_scheme(fun)`, which in Chez calls `(eval x tm-user-env)` via `tm-eval-string`.
  - **Why `eval` is exceptionally slow in Chez Scheme**: Unlike bytecode interpreters (like Guile 1.8), **Chez Scheme's `eval` invokes its full optimizing native machine-code compiler on every call**. A single character typed triggers at least 3 full JIT native-code compilations on the fly.
  - Bypassing `eval` turns microsecond/millisecond native compilations into nanosecond function calls.
- **Action Plan**:
  1. **Instrument `call` and Keystroke Phases**:
     - Instrument `call (string fun, ...)` and `eval_scheme (fun)` with `<chrono>` in `src/Scheme/Scheme/object.cpp`.
     - Record sub-millisecond breakdowns (`[KBD PERF]`): time spent compiling via `eval_scheme` vs. Scheme execution (`call_scheme`) vs. C++ tree layout (`end_editing`).
  2. **Approach A: Interned Symbol Caching (`Stop_level_value` + `ScallN`)**:
     - *Chez GC Invariant*: Chez Scheme uses a moving, copying garbage collector. Pointers to heap closures can move during GC, but **symbols never move once interned**.
     - Cache the interned symbol `ptr` (e.g. `sym = Sstring_to_symbol ("kbd-insert")`) in C++.
     - Fetch the procedure via `proc = Stop_level_value (sym)` right before calling (a single pointer dereference in Chez), or pin closure pointers with `Slock_object (proc)`.
     - Dispatch via `Scall1(proc, ...)` / `Scall2(proc, ...)` with zero `eval` compilation overhead.
  3. **Approach B: Direct Native Function Pointers (`foreign-callable`)**:
     - For ultra-hot interactive loops, export Scheme handlers using `(foreign-callable proc (types...) ret-type)`.
     - Pin the callable with `(lock-object code)` and expose `(foreign-callable-entry-point code)`.
     - C++ casts this to a raw C function pointer (`using KbdInsertFn = void (*)(ptr)`), executing pure native machine code directly with zero C-API dispatch overhead.
  4. **Approach C: Replace String-Building `eval` with S-expression / Data Dispatch**:
     - Avoid constructing dynamic Scheme command strings (e.g. `"(math-separator \"|\" #t)"`) for evaluation.
     - Build pairs/lists directly in C++ via `Scons` and pass to locked handlers, or pre-compile a pattern-matching `case` dispatcher in Scheme.

### [ ] Defer Secondary Tool Initialization (92 Delayed Tasks)
- **Location**: [`TeXmacs/progs/texmacs/menus/`](TeXmacs/progs/texmacs/menus/), [`src/Edit/Interface/edit_interface.cpp`](src/Edit/Interface/edit_interface.cpp)
- **Problem**: In GUI mode, 92 delayed actions eagerly initialize sub-menus and tools (LaTeX export, BibTeX manager, Collaboration chat, Poster designer, etc.) during startup before the user even clicks them, triggering synchronous loads of 30+ large Scheme files.
- **Solution**: Convert secondary toolbars and menus to lazy callbacks evaluated only on first display or submenu popup.

---

## 3. Low Priority / Maintenance

### [ ] Fast C++ Scheme Glue Dispatch: `foreign-procedure` / `tm_call_by_id`
- **Location**: [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp#L194-L261), [`src/Scheme/Scheme/glue.cpp`](src/Scheme/Scheme/glue.cpp)
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
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm), CLI / UI menus
- **Concept & Developer Loop**:
  - **Dynamic Runtime Override**: In development mode (`--dev` or `TEXMACS_DEV_MODE=1`), compare `.scm` file modification timestamps against `*texmacs-boot-timestamp*`. If a source file on disk is newer than the pre-compiled boot image, `module-provide` dynamically re-loads that single file via `tm-load-file`, hot-updating procedures in RAM without requiring a full rebuild of `texmacs.boot`.
  - **Rebuild Cache Utility**: Use the dedicated `--build-chez-boot` command-line flag to rebuild and dump `texmacs.boot` on disk.
  - **Bundled Location Reminder**: When creating production release bundles (e.g. `.app` or Linux packages), ensure `build-boot.scm` and `boot_files.scm` are bundled into `$TEXMACS_PATH` (or `$TEXMACS_PATH/src/Scheme/Chez/`) so `--build-chez-boot` works out-of-the-box without requiring a full source git checkout.

---

## 4. Bug Fixes & Stability

### [X] String Encoding Duality: Unicode Text vs. Binary Asset Buffers (PNG / Images) [RESOLVED]
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-file-system.scm:38,58-64`](TeXmacs/progs/kernel/texmacs/tm-file-system.scm#L38), [`src/System/Files/web_files.cpp:155`](src/System/Files/web_files.cpp#L155), [`TeXmacs/progs/kernel/boot/boot-chez.scm:830`](TeXmacs/progs/kernel/boot/boot-chez.scm#L830)
- **Problem**:
  In GNU Guile 1.8, Scheme strings were raw 8-bit C `char*` byte arrays without Unicode awareness (`scm_str2scm` / `scm_scm2str`). Consequently, TeXmacs historically uses the Scheme `string` type for two conflicting roles:
  1. **Text**: UTF-8 and Cork encoded strings passed to/from document trees, XML/HTML converters, and Qt GUI widgets (`QString::fromUtf8`).
  2. **Binary Buffers**: Raw binary file assets (such as PNG images loaded via `(string-load ...)` and `(tmfs-load ...)`).
  In Chez Scheme, `string-load` was updated to read non-UTF-8 binary files into native R6RS bytevectors (`#vu8(...)`).
  However, in `tm-file-system.scm`, `tmfs-load` checked `(if (string? r) r (object->tmstring r))`.
  Because `(string? #vu8(...))` is `#f`, `tmfs-load` fell back to calling `(object->tmstring r)` on the bytevector!
  `object->tmstring` printed the bytevector as an ASCII text string (`"#vu8(137 80 78 71 13 10 ...)"`, inflating a 32 KB PNG into 115 KB of Scheme text).
  C++ `web_files.cpp` wrote that text string to temporary files in `/tmp/` and Qt reported:
  `convert-error, Cannot read image file 'tmfs://help/article/tm/misc/images/welcome-videos.png' in qt_image_size` and `warning: cannot render`.
- **Solution Implemented**:
  1. Updated `tmfs-load` in `tm-file-system.scm` to accept both strings and bytevectors directly: `(if (or (string? r) (bytevector? r)) r (object->tmstring r))`.
  2. Updated `object->tmstring` to pass bytevectors through unchanged.
  3. Exported `bytevector?` cleanly in `kernel/boot/chez-compat.scm` (using `(#%bytevector? x)`) and `kernel/boot/compat.scm` (returning `#f` in Guile 1.8).
  4. Verified that `(url-materialize "tmfs://help/article/tm/misc/images/welcome-videos.png" "r")` writes exact raw binary PNG data (verified with `file`: `PNG image data, 371 x 248, 8-bit/color RGBA`) and renders in the welcome page without warnings.

### [X] Top-Level Definitions Inside Conditional Expressions in Plugin Inits (`invalid context for definition`) [RESOLVED]
- **Locations**:
  - [`plugins/coq/progs/init-coq.scm:22-26`](plugins/coq/progs/init-coq.scm#L22-L26)
  - [`plugins/giac/progs/init-giac.scm:24-36`](plugins/giac/progs/init-giac.scm#L24-L36)
  - [`plugins/mupad/progs/init-mupad.scm:24-30`](plugins/mupad/progs/init-mupad.scm#L24-L30)
  - [`plugins/reduce/progs/init-reduce.scm:28-29`](plugins/reduce/progs/init-reduce.scm#L28-L29)
  - [`plugins/cocoa5/progs/init-cocoa5.scm:16-17`](plugins/cocoa5/progs/init-cocoa5.scm#L16-L17)
- **Problem**:
  In GNU Guile 1.8, top-level code was evaluated dynamically by an interpreter. When evaluating `(when (supports-<plugin>?) ...)`, if the plugin CLI tool was not installed on the host system, the test returned `#f` and Guile skipped the body without evaluating or inspecting internal definitions.
  In Chez Scheme, `(load "file.scm")` compiles each top-level form to native machine code ahead of time via `compile` / `sc-expand`. `when` expands into `(if test (begin ...))`. In standard R6RS and Chez Scheme, `if` is an expression form, and definitions (`define`, `texmacs-modes`) are strictly forbidden inside an expression context. Consequently, even when the plugin is not installed and the condition would evaluate to `#f`, Chez Scheme's compiler failed during the compilation/expansion phase with:
  ```
  Exception: invalid context for definition (define ...)
  ```
  Additionally, `init-cocoa5.scm` contained Guile-style non-semicolon-terminated hex escapes (`\x05\x02`), which failed in Chez's R6RS reader.
- **Solution Implemented**:
  1. Hoisted `texmacs-modes` declarations outside `(when ...)` to top level in `init-coq.scm` and `init-mupad.scm`.
  2. Hoisted `(define (giac-eval) ...)` outside `(when ...)` to top level in `init-giac.scm`.
  3. Hoisted `(define reduce-help #f)` outside `(when ...)` to top level in `init-reduce.scm`.
  4. Updated string escapes in `init-cocoa5.scm` to R6RS-compliant `\x05;\x02;`.
  5. Verified headless execution with `(lazy-plugin-force)`: all 46 plugins initialize cleanly with zero `invalid context for definition` or `LOAD-ERROR` exceptions.

### [ ] Missing Conversion Route for `(convert doc "texmacs-tree" "latex-document")` in `tm-convert.scm`
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-convert.scm:272-274`](TeXmacs/progs/kernel/texmacs/tm-convert.scm#L272-L274), [`TeXmacs/progs/convert/latex/init-latex.scm`](TeXmacs/progs/convert/latex/init-latex.scm)
- **Problem**:
  Direct serialization via `(serialize-latex (texmacs->latex doc '()))` works cleanly. However, high-level export via `(texmacs->generic doc "latex-document")` or `buffer-export` returns `"Error: bad format or data"`.
  This indicates that the dynamic converter table in `tm-convert.scm` does not have `latex-document` registered as a target format from `texmacs-tree` until `(convert latex init-latex)` or similar converter declarations are executed.
- **Action**:
  Investigate lazy registration / dynamic loading of `init-latex.scm` converters when `texmacs->generic` or `buffer-export` is invoked.

### [X] Separate Compilation Environment from Runtime Initialization [RESOLVED]
- **Location**: [`src/Texmacs/Server/tm_server.cpp`](src/Texmacs/Server/tm_server.cpp), [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp), [`TeXmacs/progs/init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm)
- **Problem** (historical): compilation (`-compile-modules`) and runtime startup both loaded `init-texmacs-chez.scm`, which used `texmacs-chez-compiling?` conditionals to skip `.so` loading and REPL shims during batch compilation.
- **Resolved**:
  1. Commit `e0206bc65` added `progs/init-chez-compile.scm` and the three-way `tm_init_file` selection in `tm_server.cpp:147-149` (`init-chez-compile.scm` / `init-linter.scm` / `init-texmacs-chez.scm`).
  2. 2026-11-12: removed both `texmacs-chez-compiling?` guards and the `eval-forms` indirection from `init-texmacs-chez.scm`; its ~380 registration forms are now plain top-level forms. The three `eval`-installed syntax overrides became direct top-level `define-syntax` forms in both `init-texmacs-chez.scm` and `init-linter.scm`.
  3. The overrides must stay: `boot-chez.scm`'s `define-public` / `define-public-macro` route through `with-export-if-active`, which emits `(export ...)` when `compile-export-mode?` is active, and `export` is illegal outside a module or library. Runtime-loaded source (plugins, `-x` scripts, REPL) therefore needs export-free versions.
  4. Removed the now write-only `texmacs-chez-compiling?` flag: the C++ `tm-set-compiling-mode!` call, the `boot-chez.scm` helper, and the setters in `init-chez-compile.scm` / `compile-texmacs.scm`.

### [ ] Migrate Macro Expand-Time Helpers from `(eval ... (compilation-environment))` to Phased `meta define` Modules (UNREALISTIC / DEFERRED)
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm), [`TeXmacs/progs/kernel/texmacs/tm-convert.scm`](TeXmacs/progs/kernel/texmacs/tm-convert.scm), macro definers throughout `TeXmacs/progs/`
- **Status & Note**: Marked as unrealistic / too much work. Migrating hundreds of dynamic legacy Guile macro helpers across the codebase to strictly phased `meta define` libraries would require sweeping structural rewrites of upstream TeXmacs code with high regression risk. The existing dynamic compilation-environment evaluation bridge works robustly and will be retained.
- **Problem**: Currently, macro definers (`define-public-macro` and `define-module-macro`) use `(eval `(apply ...) (compilation-environment))` as a bridge to evaluate legacy Guile macros and their helper procedures (e.g. `converter-sub`) without triggering Chez Scheme's static Phase 0 / Phase 1 lexical cross-phase checks.
- **Solution**: Refactor expand-time macro helpers out of runtime modules into dedicated macro-helper modules, or use `meta define` / `(meta import ...)` so Chez Scheme can compile macro transformers statically as native Phase 1 syntax transformers without relying on dynamic `eval` against `(compilation-environment)`.

### [ ] Exit Issue After Editing Initial Buffer
- **Location**: Buffer exit handler, `quit-TeXmacs`, modified buffer prompt ([`TeXmacs/progs/texmacs/texmacs/tm-files.scm`](TeXmacs/progs/texmacs/texmacs/tm-files.scm), [`src/Texmacs/Texmacs/texmacs.cpp`](src/Texmacs/Texmacs/texmacs.cpp))
- **Problem**: TeXmacs is having issues exiting cleanly after editing the initial buffer (e.g. unsaved changes dialog or exit hook hanging).
- **Solution**: Inspect the buffer discard / save verification workflow during exit on the Chez backend.

### [ ] Dynamic Menu Evaluation: Guard `#f` in `make-menu-items` (`(TM-APPLY-ERROR #f is not a pair)`)
- **Location**: [`TeXmacs/progs/kernel/gui/menu-widget.scm:811-825`](TeXmacs/progs/kernel/gui/menu-widget.scm#L811-L825), [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp)
- **Problem**: When a dynamic menu thunk returns `#f` (e.g. inactive mode or delayed plugin menu not yet initialized), `make-menu-items` falls through `(if (pair? p) ...)` to `(make-menu-bad-format p style)`. Calling `car`/`cdr` on `#f` triggers Chez Scheme's `~s is not a pair (#f)` which is trapped in `tm-apply` as `(TM-APPLY-ERROR (#t #f "~s is not a pair" (#f) ()))`.
- **Solution**: Guard against non-pair/`#f` values in `make-menu-items` to treat them as an empty item list `'()` rather than logging `menu has bad format (make-menu)` or throwing in Scheme.

### [ ] Refactor `define-table` and `define-collection` (Post Pure-Expression `tm-define` Simplification)
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`TeXmacs/progs/kernel/boot/ahash-table.scm`](TeXmacs/progs/kernel/boot/ahash-table.scm)
- **Status & Note**: Currently, `define-table` and `define-collection` are desugared directly in `prepare-forms` to avoid Chez Scheme multiple-definition errors during forward declarations (`(define-table style-synopsis)`) and ensure tables are exported to `texmacs-user-kernel`.
- **Target Solution**: With `tm-define` now refactored to be purely an expression installing top-level values directly without internal local definitions, complex definition-hoisting via `define-public-macro-trace` is no longer required. Migrate `define-table` and `define-collection` to standard macro definitions emitting top-level table registrations or definitions and remove ad-hoc compiler desugaring.

### [ ] Quick Hack: Implicit Cross-Module Macro Propagation via `(interaction-environment)` for `tm-define-macro`
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-define.scm`](TeXmacs/progs/kernel/texmacs/tm-define.scm#L284-L295), [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm)
- **Problem**: In upstream GNU Guile TeXmacs, every module implicitly inherited `texmacs-user` via `(module-use! (current-module) texmacs-user)`. Macros defined via `tm-define-macro` anywhere in the codebase (e.g. `smart-table` in `utils/library/smart-table.scm`) were automatically available as global syntax in downstream modules without explicit `(:use ...)` declarations (such as `convert/latex/latex-define.scm`). Under Chez Scheme's hermetic R6RS AOT module model, modules only import explicit syntax dependencies declared in `:use` / `:inherit`.
- **Current Quick Hack**:
  - `tm-define-macro` emits `(define-top-level-syntax ',var ... c-env)`.
  - When `compile-texmacs.scm`'s `prepare-forms` encounters `define-top-level-syntax`, it executes both:
    ```scheme
    (eval x (compilation-environment))
    (eval x (interaction-environment))
    ```
  - This pollutes `(interaction-environment)` with the syntax transformer so that whenever a subsequent module copies `(interaction-environment)` via `(parameterize ((compilation-environment (copy-environment (interaction-environment) #t))) ...)`, it implicitly inherits all previously transpiled `tm-define-macro` syntax transformers.
- **Side Effect**: Potential duplicate syntax definitions and global namespace pollution during compilation.
- **Target Clean Solution**:
  - Automatically infer macro dependencies by scanning module source bodies for known `tm-define-macro` symbols, or dynamically injecting `(import (for <declaring-module> run expand))` during AOT transpilation.
  - Or formalizing an aggregated syntax library (e.g. `(texmacs macros)`) that encapsulates all public `tm-define-macro` syntax transformers without mutating `(interaction-environment)`.

---

## 5. Compilation Pipeline Expansion & Residual Failure Tracking

### Current Census (Updated 2026-10-20)
- **Total Scheme Files in TeXmacs**: 457
- **Modules in Unified Compilation Pipeline (`compile-texmacs.scm` Tiers 1–7)**: **453 modules** (100% of all modular Scheme files in TeXmacs, ordered via topological DAG analysis)
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
  - In `compile-texmacs.scm`, emit self-evaluating bindings `(define :k ':k)` in module headers for all syntactic keywords found in the source file.

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
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm#L595)
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
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Problem**: In Chez Scheme, every transpiled module file currently emits a trailing `(import mod-sym)` into `(interaction-environment)`. Consequently, all functions (not just `tm-define` extension points, but also internal `define-public` helpers) leak into the global environment.
- **Consequences**:
  1. *Hidden undeclared dependencies*: If Module C uses helper `h` from Module B without declaring `(:use (path B))`, and B was compiled earlier, C compiles and runs successfully by accident. If C is ever compiled in isolation or loaded in a different order, it crashes at runtime.
  2. *Namespace collision & shadowing*: Unrelated non-kernel modules exporting identical helper names (e.g., `parse`, `convert`, `init`) collide or overwrite each other in `(interaction-environment)`.
  3. *Semantic mismatch with Guile*: Guile gives each `(define-module ...)` a private obarray that imports *only* explicitly listed modules, preserving lexical hygiene.
- **Suggested Fixes**:
  1. *Clean compilation environment per module*: In `compile-texmacs.scm`, construct each module's `compilation-environment` from a pristine base environment (Chez Scheme builtins + kernel shims) and explicitly import *only* the declared `:use` / `:inherit` dependencies.
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
- **Solution**: In `compile-texmacs.scm`, `define-state` is intercepted before generic macro expansion, emitting an atomic `(define-public <name> (state-create ...))` definition and registering `state-slots` in `(compilation-environment)` so downstream macros expand cleanly.

#### [ ] Item 9: Local Definition Collisions with Imported Module Symbols
- **Affected Module**: `convert/latex/tmtex-springer.scm` (and potential other converters)
- **Issue**: A module importing another module (`(:use (convert latex tmtex))`) that also defines a local procedure of the same name (`(define (tmtex-author-affiliation-ref t) ...)`) triggers Chez Scheme's `Exception: multiple definitions for <sym> in body`.
- **Solution**: Chez Scheme requires imported shadowed identifiers to be excluded via `(import (for (except <module> <sym> ...) run expand))`. Tracking all local definitions (both public and private) ensures `compile-texmacs.scm` automatically emits `except` clauses for any locally shadowed symbols.

#### [ ] Item 10: Unify Macro Evaluation Environments (`interaction-environment` vs `compilation-environment`)
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm#L322-L344), [`TeXmacs/progs/kernel/texmacs/tm-define.scm`](TeXmacs/progs/kernel/texmacs/tm-define.scm#L246-L253), [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm)
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
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`TeXmacs/progs/kernel/boot/ahash-table.scm`](TeXmacs/progs/kernel/boot/ahash-table.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Status & Shift in Direction**:
  - Previously, `define-macro-trace`, `define-public-macro-trace`, and `public-trace` were introduced because `tm-define` expansions interleaved definitions (`define-public`) with runtime expressions (`ahash-set!`), requiring iterative AST macro tracing to peel them apart for R6RS `(module Name () defs ... exprs ...)`.
  - Since `tm-define` has now been refactored into a **pure expression** using `define-top-level-value` directly without any internal definitions, forms producing `tm-define` calls no longer contaminate definition contexts.
  - As a result, `tm-define-overloaded` and `texmacs-modes` have already been reverted to plain `define-public-macro`.
  - **Action Plan**:
    1. Verify remaining macros that were using `define-macro-trace` (e.g. in `latex-define.scm`, `tmtex.scm`, `cas-out.scm`).
    2. Confirm whether they can simply use standard `define-macro` or `define-public-macro`.
    3. Remove `define-macro-trace` and `define-public-macro-trace` apparatus once verified, simplifying the compilation pipeline.

#### [ ] Item 12: Idle TeXmacs High CPU Consumption & Runtime GUI Callback Environment Alignment
- **Location**: [`src/Plugins/Qt/qt_gui.cpp`](src/Plugins/Qt/qt_gui.cpp#L989-L1015), [`src/Texmacs/Server/tm_server.cpp`](src/Texmacs/Server/tm_server.cpp#L220-L245), [`TeXmacs/progs/init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm)
- **Problem**: When idle, the TeXmacs GUI consumes high CPU resources (~100% core utilization).
- **Root Causes**:
  1. **Exception Feedback Loop on `0 ms` QTimer**: `qt_gui_rep::update()` runs at an idle interval of 15 ms, but flags `delay = 0` whenever `needing_update` is set. Because GUI callbacks (`notify-cursor-moved`, `lazy-initialize-force`, `text-icons`, `texmacs-focus-icons`) fail with `variable <var> is not bound` in `(interaction-environment)`, `apply_changes()` and `update_menus()` repeatedly log errors and trigger `notify_change(THE_CURSOR)`, keeping `needing_update = true` permanently active in a zero-sleep busy loop.
  2. **Disabled Upstream CPU Throttling (`QT_CPU_FIX`)**: In `basic.hpp` and `qt_gui.cpp`, upstream commented out `//#define QT_CPU_FIX 1` which implements an adaptive `tm_sleep()` usleep throttling mechanism.
- **Action Plan**:
  1. Align the runtime evaluation environment: import kernel module exports and `texmacs-user` bindings into `(interaction-environment)` so C++ callbacks (`lazy-initialize-force`, `notify-cursor-moved`, toolbar icons) resolve cleanly.
  2. Verify that successful menu and cursor updates break the `needing_update` loop, allowing `updatetimer` to settle into its normal idle interval.
  3. If idle polling overhead remains high, evaluate enabling or modernizing the `QT_CPU_FIX` adaptive sleep mechanism in `qt_gui.cpp`.

#### [ ] Item 13: Replace `...` Identifier in `abbrevs.scm` with `range-inclusive` or `...*`
- **Location**: [`TeXmacs/progs/kernel/boot/abbrevs.scm:166`](TeXmacs/progs/kernel/boot/abbrevs.scm#L166), and 8 call sites across `progs/`
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
- **Location**: [`TeXmacs/progs/client/client-widgets.scm`](TeXmacs/progs/client/client-widgets.scm)
- **Affected Module (1)**: `client/client-widgets.scm`
- **Error**: `Exception: invalid syntax (if (== ret "done") (client-notify-account ...) (client-login-home ...) (client-open-error ...))`
- **Root Cause**: Upstream GNU Guile 1.8 permitted `if` forms with multiple expressions in the `else` branch (behaving like an implicit `begin`). Chez Scheme strictly enforces R6RS syntax: `(if <test> <consequent> [<alternate>])` taking at most 3 operands.
- **Action Plan**: Wrap multiple `else` expressions in `(begin ...)` or add a 4-operand `if` desugaring rule in `compile-texmacs.scm`'s `prepare-forms`.

#### [ ] Item 15: Empty `(begin)` Form in `wallet-menu.scm`
- **Location**: [`TeXmacs/progs/security/wallet/wallet-menu.scm:15`](TeXmacs/progs/security/wallet/wallet-menu.scm#L15)
- **Affected Module (1)**: `security/wallet/wallet-menu.scm`
- **Error**: `Exception: invalid syntax (begin)`
- **Root Cause**: A conditional menu macro expands into an empty `(begin)`. Chez Scheme's R6RS specification requires `(begin form1 form ...)`, requiring at least one subform.
- **Action Plan**: Desugar empty `(begin)` into `(noop)` or `(void)` during transpilation in `prepare-forms`, or guard the macro expansion.

#### [ ] Item 16: Premature Definition in Expression Context in `cas-out.scm`
- **Location**: [`TeXmacs/progs/utils/cas/cas-out.scm`](TeXmacs/progs/utils/cas/cas-out.scm)
- **Affected Module (1)**: `utils/cas/cas-out.scm`
- **Error**: `Exception: invalid context for definition (define cas-assign-op-table (list->ahash-set (cas-collect-members "arithmetic-assign")))`
- **Root Cause**: In `cas-out.scm`, side-effecting initialization expressions precede the definition of `cas-assign-op-table`. Under Chez Scheme's R6RS module layout (`defs` before `exprs`), definitions appearing after initialization expressions trigger definition context violations.
- **Action Plan**: Hoist `cas-assign-op-table` or convert to `tm-define` so `partition-forms` cleanly separates the definition from expression expressions.

#### [ ] Item 17: Unbound Keyword Tokens in Dynamic Hooks (`:on-cpu-idle` & `:uninit`)
- **Location**: [`TeXmacs/progs/client/client-base.scm`](TeXmacs/progs/client/client-base.scm), [`TeXmacs/progs/tools/spell/spell-lantool.scm`](TeXmacs/progs/tools/spell/spell-lantool.scm)
- **Affected Modules (3)**:
  - `client/client-base.scm` (`:on-cpu-idle`)
  - `tools/spell/spell-lantool.scm` (`:uninit`)
  - `tools/spell/spell-kbd.scm` (Cascaded from `spell-lantool`)
- **Error**: `Exception: variable :on-cpu-idle is not bound`, `Exception: variable :uninit is not bound`.
- **Root Cause**: Unquoted keyword tokens starting with `:` evaluated as global variable references at runtime.
- **Action Plan**: Add `:on-cpu-idle` and `:uninit` to the keyword binding tables in `init-texmacs-chez.scm` and `boot-chez.scm`.

#### [ ] Item 18: Record Field Specifier Mismatch in `tmcolor.scm`
- **Location**: [`TeXmacs/progs/convert/tools/tmcolor.scm`](TeXmacs/progs/convert/tools/tmcolor.scm)
- **Affected Modules (2)**:
  - `convert/tools/tmcolor.scm`
  - `convert/tools/old-tmtable.scm` (Cascaded: `unknown module convert:tools:tmcolor`)
- **Error**: `Exception in record-accessor: invalid field specifier name-promise`
- **Root Cause**: `tmcolor.scm` uses SRFI-9 or Guile record definitions with field accessor `name-promise` that fails Chez Scheme's internal record descriptor validation.
- **Action Plan**: Check record type field declarations in `tmcolor.scm` and align with Chez Scheme record accessor conventions.

#### [ ] Item 19: Missing Module Declaration or Search Path for `init-rewrite.scm`
- **Location**: [`TeXmacs/progs/convert/rewrite/init-rewrite.scm`](TeXmacs/progs/convert/rewrite/init-rewrite.scm)
- **Affected Modules (3)**:
  - `doc/apidoc-funcs.scm`
  - `prog/prog-format.scm`
  - `prog/scheme-tools.scm`
- **Error**: `Exception: unknown module convert:rewrite:init-rewrite`
- **Root Cause**: `convert/rewrite/init-rewrite.scm` was not included in the pre-compiled pipeline sequence prior to loading downstream dependents.
- **Action Plan**: Include `convert/rewrite/init-rewrite.scm` in Tier 2/5 pipeline so its module symbol is available for import.

#### [ ] Item 20: Unbound `scm-error` in `debug-menu.scm`
- **Location**: [`TeXmacs/progs/debug/debug-menu.scm`](TeXmacs/progs/debug/debug-menu.scm)
- **Affected Module (1)**: `debug/debug-menu.scm`
- **Error**: `Exception: variable scm-error is not bound`
- **Root Cause**: `scm-error` is evaluated inside a macro transformer or form during compilation before the runtime bridge in `init-texmacs-chez.scm` is imported.
- **Action Plan**: Define `scm-error` in `(compilation-environment)` within `boot-chez.scm` / `compile-texmacs.scm`.

#### [ ] Item 21: Expand-Time State Contamination from Eager Evaluation in `compile-texmacs.scm`
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`TeXmacs/progs/utils/edit/variants.scm`](TeXmacs/progs/utils/edit/variants.scm), [`TeXmacs/progs/graphics/graphics-env.scm`](TeXmacs/progs/graphics/graphics-env.scm)
- **Problem**: Macros generating conditional code via expand-time `(if (ahash-ref ...) ...)` or `(if (top-level-bound? ...) ...)` can miscompile during batch AOT compilation because `compile-texmacs.scm`'s Pass 1 eagerly evaluates forms into `(compilation-environment)`. By the time Pass 2 (`compile-file`) runs macro expansion, tables and variables in compiler memory are already populated, triggering the wrong expand-time conditional branch (e.g. omitting definitions that should be generated at runtime module load time).
- **Remediation Strategies**:
  1. Defer stateful table lookups to runtime by generating `(if (ahash-ref ...) ...)` directly inside the emitted runtime code (`begin ...`) rather than evaluating it at macro-expansion time.
  2. Isolate Pass 1 eager evaluation inside a disposable/sandboxed environment so side effects to global tables do not leak into Pass 2 macro expansion.
  3. Where macro output needs private module state across modules, use `define-module-macro` with `indirect-export` instead of unquoting expand-time environment variables.

#### [ ] Item 22: Evaluation Timing & Lazy Resolution of `(doc help-funcs)` for `help-menu`
- **Location**: [`TeXmacs/progs/doc/help-funcs.scm`](TeXmacs/progs/doc/help-funcs.scm), [`TeXmacs/progs/doc/help-menu.scm`](TeXmacs/progs/doc/help-menu.scm), [`TeXmacs/progs/init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm)
- **Problem**: When TeXmacs initializes the GUI window during boot (`TIME-OPEN-WINDOW`), the menu bar resolves `help-menu`. If `help-menu` evaluates before `(module-provide '(doc help-funcs))` has run, global multimethods defined via `tm-define` (such as `load-help-article`, `load-help-buffer`, and `url-exists-in-help?`) are not yet bound in `(interaction-environment)`, raising `(TM-APPLY-ERROR variable load-help-article is not bound)`.
- **Architectural Principle**: `tm-define` definitions are dynamic multimethods in the global dispatch table (`tm-defined-table` / `(interaction-environment)`), NOT static R6RS module exports. Downstream modules do not import them via static `import`; the defining module must simply be evaluated before symbols are resolved.
- **Action Plan**:
  1. Audit `(lazy-menu (doc help-menu) help-menu)` and ensure `(doc help-funcs)` is registered via `lazy-define` in `init-texmacs-chez.scm`:
     `(lazy-define (doc help-funcs) load-help-article load-help-buffer url-exists-in-help? help-file-title)`
  2. Verify that accessing `help-menu` on demand triggers `load-module` for `(doc help-funcs)` before menu item callbacks fire.

#### [ ] Item 23: Format Escape `~:s` Evaluation Error in `(open-preferences)`
- **Location**: [`TeXmacs/progs/texmacs/menus/preferences-*.scm`](TeXmacs/progs/texmacs/menus/), [`TeXmacs/progs/kernel/gui/menu-widget.scm`](TeXmacs/progs/kernel/gui/menu-widget.scm)
- **Problem**: Invoking `(open-preferences)` in headless mode raises `(PREF-ERROR: variable ~:s is not bound)` when constructing `(top-window preferences-widget "User preferences")`.
- **Root Cause**: An unescaped or misquoted format string directive (such as `~:s` from `format`, `texmacs-error`, or `display*`) is being evaluated as a Scheme symbol/variable expression rather than parsed as a formatting specifier.
- **Action Plan**:
  1. Locate the call emitting `(PREF-ERROR: ...)` across the preferences widget constructors.
  2. Fix the quote or macro expansion causing the format string to be evaluated as Scheme code.

#### [ ] Item 24: Module System Modernization via Explicit Side-Effect Wrapping (`%module-side-effect`)
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`TeXmacs/progs/kernel/texmacs/tm-modes.scm`](TeXmacs/progs/kernel/texmacs/tm-modes.scm), macro definers across `progs/`
- **Background & Context**: Upstream GNU TeXmacs used dummy definitions `(define _tm_def_XX (begin ... (void)))` to smuggle runtime side-effects (`set-symbol-procedure!`, `logic-rules`, option registrations) into macro outputs intended for definition contexts.
- **Proposed Architecture**:
  - Replace artificial `_tm_def_XX` dummy bindings with an explicit compiler marker form: `(%module-side-effect <expr> ...)`.
  - In the module compilation/expansion pass, the transpiler cleanly partitions:
    1. Genuine procedure and syntax definitions into `defs` and extracts exported symbols for `(export ...)`.
    2. Any `(%module-side-effect ...)` forms directly into the module's runtime initialization block (`exprs`).
  - Eliminates dummy variables in symbol tables, prevents compiler definition context violations, and cleanly decouples definitions from runtime side-effects.

#### [x] Item 25: Runtime Unbound Variable `opts` in `(open-preferences)` and `(top-window ...)`
- **Location**: [`TeXmacs/progs/kernel/gui/menu-widget.scm`](TeXmacs/progs/kernel/gui/menu-widget.scm#L1202)
- **Error**: `(TM-APPLY-ERROR variable opts is not bound)`
- **Symptom**: Triggered when invoking `(open-preferences)`, `(open-error-messages)`, or any window constructor delegating to `(top-window ...)` or `(dialogue-window ...)`.
- **Diagnosis & Root Cause**: 
  - Traceback isolated to:
    ```
    (FRAME 0 CODE decode-options SRC opts LOC ())
    (FRAME 1 CODE new-val SRC (decode-options opts) LOC ())
    (FRAME 2 CODE #f SRC (open-error-messages) LOC ())
    ```
  - In `menu-widget.scm:1202`, `(decode-options opts)` used `(while (and (pair? opts) (url? (car opts))) ...)`.
  - While `while` was present in `boot-chez.scm` in `(interaction-environment)`, if compiled `.so` files were built with an out-of-order macro expansion or if `opts` was evaluated before while expansion, it threw unbound variable errors.
  - Rewriting `decode-options` with a clear, functional tail-recursive named `let loop` completely eliminates `while` and `set!` from `decode-options`.
- **Resolution**:
  - Rewrote `decode-options` in `menu-widget.scm` as a clean tail-recursive named `let loop` without `set!` or external macro dependencies.

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
- **Location**: [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp), [`src/Scheme/Chez/chez_tm.hpp`](src/Scheme/Chez/chez_tm.hpp), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm), [`TeXmacs/progs/init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm)
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
  2. **Automatic Lifecycle via Guardians**: Established a Chez Scheme Guardian `(define tm-blackbox-guardian (make-guardian))`. When C++ glue procedures return blackbox objects to Scheme, `blackbox_to_tmscm` registers them directly in C++ via `Scall1(tm_blackbox_guardian, box)` in $O(1)$ time without Scheme wrappers. Dead blackboxes are collected and reclaimed via `tmscm_delete_blackbox` / `tm_delete` in both `collect-request-handler` and the Qt idle loop (`command_queue::exec_pending`).
  3. **Value Equality & Hash Tables**: Implemented C foreign procedures `tmscm_blackbox_equal` and `tmscm_blackbox_hash` hooked into Scheme's `equal?`, `==`, `!=`, and `make-hash-table`, providing full content-equality and persistent hashing for blackbox-keyed structures.

#### [ ] Item 28: Image Resource Decoding / Conversion Failures (`libpng bad header` / `qt_image_size`)
- **Location**: [`src/Plugins/Qt/qt_picture.cpp`](src/Plugins/Qt/qt_picture.cpp), `src/Plugins/Qt/qt_image.cpp` (no longer in this tree), [`TeXmacs/progs/convert/images/`](TeXmacs/progs/convert/images/)
- **Errors**:
  ```
  libpng error: [00][00][00][00]: bad header (invalid type)
  TeXmacs] convert-error, Cannot read image file 'tmfs://help/article/tm/misc/images/welcome-videos.png' in qt_image_size
  TeXmacs] warning: cannot render .../.TeXmacs/system/tmp/75845/tmp_1838543410.png
  ```
- **Diagnosis & Root Cause**:
  - When opening help articles (like `welcome/start.en.tm`), embedded images are resolved through the virtual filesystem (`tmfs://help/article/...`).
  - TeXmacs attempts to unpack or convert these resources into temporary PNG files in `~/.TeXmacs/system/tmp/`. If the image converter or virtual filesystem unpacker writes an empty (0-byte) or incomplete header before the reader executes, Qt's `QImageReader` / `libpng` aborts with `[00][00][00][00]: bad header (invalid type)`.
- **Action Plan**:
  - Audit `qt_image_size` and image caching pipeline for `tmfs://` URIs.
  - Verify that temporary file writing in `system/tmp/` checks file creation and write return codes before invoking Qt/libpng.
  - Stream virtual filesystem images directly into memory buffers (`QByteArray`) instead of round-tripping through temporary files on disk.

#### [x] Item 29: Unquoted Box / Blackbox Literals in Expressions Passed to `eval` (`invalid syntax #&<addr>`)
- **Location**: [`TeXmacs/progs/init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm), [`src/Scheme/Scheme/object.cpp`](src/Scheme/Scheme/object.cpp), [`src/Texmacs/Data/new_window.cpp`](src/Texmacs/Data/new_window.cpp)
- **Error**: `Exception: invalid syntax #&4974615488` in `(eval '((lambda () (safely-kill-window #&4974615488))))`
- **Root Cause**:
  - In Chez Scheme, Box objects (`#&...`) are native data records. Unlike numbers, booleans, or strings, an unquoted Box datum in expression position is rejected by Chez's `syntax-case` expander as invalid syntax.
  - In Guile, SMOBs were treated as self-evaluating literal datums. When C++ builds commands like `scheme_cmd (list_object ("safely-kill-window", object (*id)))`, the resulting S-expression contains raw Box objects in expression position.
- **Resolution**:
  - In `init-texmacs-chez.scm`, `eval` now runs `tm-quote-boxes` on incoming forms, automatically wrapping unquoted Box datums in `(quote ...)` (`#&addr` -> `'(#&addr)`). This permits C++ commands and closures carrying blackboxes to evaluate without syntax errors.

#### [x] Item 30: Popup / Menu Expansion Latency & Zero-Height Layout Stalls
- **Location**: [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Symptoms**:
  - Submenus such as `HELP -> FULL MANUALS` appeared delayed or stalled on macOS, logging temporary 0-height popup warnings (`qt.qpa.window: Window position QRect(1282,1612 318x0) outside any known screen`).
  - Menu expansion and initial startup had high latency (`TIME-PRE-GUI-LOOP: ~2450 ms`).
- **Diagnosis & Root Cause**:
  1. **Latency in `chez_tm.cpp`**:
     - `tm-register-guardian!` was wrapped around every single foreign C++ procedure return in Scheme.
     - For compound data structures (menus, document trees, stylesheet definitions), `tm-register-guardian!` recursively walked the entire tree in interpreted Scheme and called `(top-level-bound? 'blackbox?)` on every node, inflating menu building times by seconds and stalling Qt layout passes.
  2. **Bignum Modular Arithmetic in `hash`**:
     - `boot-chez.scm` used a handwritten recursive DJB2 Scheme function with bignum modular arithmetic on every cons cell and symbol in expanded menu trees during hash map insertions and lookups.
  3. **Menu Widget Scheme Logic**:
     - The upstream Scheme menu routines in `menu-widget.scm` (`make-menu-when`, `make-menu-if`) are 100% upstream-compatible: `pred?` in live menus is always a closure thunk evaluated via `(pred?)`.
- **Resolution**:
  - In `chez_tm.cpp`, eliminated `tm-register-guardian!` entirely. Instead, registered newly created boxes in `blackbox_to_tmscm` directly via `Scall1(tm_blackbox_guardian, box)` in $O(1)$ time in C++, and restored `chez_install_procedure` to call `tm-call-by-name` directly without wrapping.
  - In `boot-chez.scm`, replaced the recursive Scheme `hash` with Chez Scheme's native `(equal-hash obj)`, dropping menu hashing time to 0 ms and pre-GUI startup time to ~1200 ms.
  - Kept `make-menu-when`, `make-menu-if`, and `make-menu-mini` completely identical to upstream GNU TeXmacs.
  - Reverted Qt C++ files back to upstream master, maintaining pure Scheme/Chez integration integrity.

#### [ ] Item 31: `while` Macro Resolution & Unbound Variable `t` in `(graphics-exit-right)`
- **Location**: [`TeXmacs/progs/graphics/graphics-main.scm`](TeXmacs/progs/graphics/graphics-main.scm#L63-L76), [`TeXmacs/progs/kernel/boot/abbrevs.scm`](TeXmacs/progs/kernel/boot/abbrevs.scm), [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm)
- **Error**: `(EVAL-ERROR (graphics-exit-right) variable t is not bound (t))`
- **Symptom**: Triggered when exiting a graphics canvas, e.g. clicking outside a graphics object, invoking `(graphics-exit-right)`, or mouse release events in `src/Edit/Interface/edit_mouse.cpp:559`.
- **Diagnosis & Root Cause**:
  - In `graphics-main.scm`:
    ```scheme
    (tm-define (graphics-exit-right)
      ...
      ((inside? 'graphics)
       (with-innermost t 'graphics
         (while (and (tree-up t) (tree-func? (tree-up t) 'with))
           (set! t (tree-up t)))
         (tree-go-to t :end)))
      ((tree-is? (cursor-tree) 'graphics)
       (with t (cursor-tree)
         (while (and (tree-up t) (tree-func? (tree-up t) 'with))
           (set! t (tree-up t)))
         (tree-go-to t :end))))
    ```
  - In upstream Guile, `while` is a core language syntax form built directly into the Guile runtime.
  - In Chez Scheme, `while` is defined via `define-syntax` in `boot-chez.scm` in the top-level interaction environment. However, `while` is not exported by `(kernel boot abbrevs)` or the standard R6RS module headers.
  - When modules like `(graphics graphics-main)` or `(kernel gui menu-widget)` are compiled into isolated R6RS libraries via `compile-texmacs.scm`, the Chez compiler does not recognize `while` as a syntax transformer. It compiles `(while ...)` as a free procedure call, evaluating its arguments under applicative order.
  - When `(while ...)` is evaluated as a procedure rather than syntax, arguments containing local variable mutations or references (like `(set! t ...)` or `t`) fail with unbound variable errors.
- **Action Plan**:
  - Export a hygienic `while` macro from `(kernel boot abbrevs)` so all modules importing `abbrevs` recognize `while` at compilation time.
  - Audit `compile-texmacs.scm` macro environment to ensure core control structures (`while`, `repeat`, etc.) are in the compilation expansion environment across all module tiers.

#### [x] Item 32: Unquoted Procedure Literals in Expressions Passed to `eval` (`invalid syntax #<procedure ...>`)
- **Location**: [`TeXmacs/progs/init-texmacs-chez.scm`](TeXmacs/progs/init-texmacs-chez.scm), [`src/Scheme/Scheme/object.cpp`](src/Scheme/Scheme/object.cpp), [`src/Texmacs/Window/tm_dialogue.cpp`](src/Texmacs/Window/tm_dialogue.cpp)
- **Error**: `Exception: invalid syntax #<procedure new-val>` in `(eval '((lambda () (#<procedure new-val> (system->url ...)))))`
- **Symptom**: Triggered when opening an existing file on disk from the file chooser dialogue (`choose-file load-buffer "Load file" ""`).
- **Diagnosis & Root Cause**:
  - In `tm_dialogue.cpp`, `dialogue_command_rep::apply()` constructs an expression pair `(cons fun cmd)` where `fun` is the Scheme procedure closure (`load-buffer`, printed as `#<procedure new-val>` by `tm-define`), and `cmd` contains unevaluated argument forms `((system->url "..."))`.
  - `scheme_cmd (object cmd)` wraps this into `(lambda () (#<procedure new-val> (system->url "...")))` and passes it to `eval`.
  - In Guile 1.8, the interpreter accepted raw procedure objects in expression/operator positions as self-evaluating. In Chez Scheme, `eval` compiles forms via `sc-expand` / `chi-expr`; an unquoted procedure literal in expression position is rejected as invalid syntax.
  - When `eval` failed, `tm-apply` trapped the condition and returned `(#t "invalid syntax")`, which was queued by `exec_delayed` and subsequently triggered `Exception: attempt to apply non-procedure (#t "invalid syntax")`.
- **Resolution**:
  - In `init-texmacs-chez.scm`, extended `tm-quote-boxes` into `tm-quote-eval-literals` to wrap both `(box? x)` and `(procedure? x)` in `(list 'quote x)`.
  - Quoting the procedure literal transforms the form into `(lambda () ((quote #<procedure new-val>) (system->url "...")))`, allowing Chez Scheme's compiler to treat it as a literal datum yielding the procedure while properly evaluating its argument expressions.

#### [ ] Item 33: Explicit Error Reporting in `wrap-catch` & Menu Exception Masking
- **Location**: [`TeXmacs/progs/kernel/boot/debug.scm`](TeXmacs/progs/kernel/boot/debug.scm#L316-L332), [`TeXmacs/progs/kernel/gui/menu-widget.scm`](TeXmacs/progs/kernel/gui/menu-widget.scm#L1190-L1195), [`src/Texmacs/Window/tm_frame.cpp`](src/Texmacs/Window/tm_frame.cpp#L28-L38)
- **Problem**:
  - `(wrap-catch proc)` wraps menu-to-widget generation in [`make-menu-widget`](TeXmacs/progs/kernel/gui/menu-widget.scm#L1194).
  - When exceptions occur inside dynamic menu generation, submenus, or widget constructors, `as_widget` in C++ receives nil or an error pair, causing [`make_menu_widget`](src/Texmacs/Window/tm_frame.cpp#L28-L38) to silently fall back to an empty menu `horizontal_menu(0)`.
  - Empty menu widgets have height 0, causing macOS Cocoa QPA to report:
    `qt.qpa.window: Window position QRect(...) outside any known screen, using primary screen`.
  - Because exceptions can be swallowed or discarded without clear diagnostics reaching the terminal, developers cannot easily see which Scheme procedure or menu item failed.
- **Action Plan**:
  - Make `wrap-catch` (and `tm-catch-runtime` in `boot-chez.scm`) output explicit error diagnostics (`display-condition`, stack context) when catching conditions during menu building.
  - In `tm_frame.cpp:make_menu_widget`, log an explicit warning with the menu expression whenever `as_widget` returns nil instead of silently returning an empty 0-height menu.

#### [ ] Item 34: Smart Downstream Invalidation via Interface Hash (`interface-hash` in `compiler-db`)
- **Location**: [`src/Scheme/Chez/compile-texmacs.scm`](src/Scheme/Chez/compile-texmacs.scm), [`src/Scheme/Chez/compiler-db.scm`](src/Scheme/Chez/compiler-db.scm)
- **Problem**:
  - The incremental compilation system currently invalidates all downstream successors in `*compile-graph*` whenever any non-kernel module's source changes.
  - Modifying a single mid-graph utility (like `bib-complete.scm` or `tree.scm`) forces recompilation of 150+ downstream modules, even if the change was purely an internal implementation fix or performance optimization that altered no public macros or exported signatures.
- **Background & Available Infrastructure**:
  - `compiler-db.scm` computes and stores `interface-hash` for each module via `(scan-interface-hash exports global-macros macro-impls)`.
  - In Scheme / Chez Scheme, downstream modules compiling against module $M$ only depend on $M$'s expand-time definitions (macro transformers, expand-time helpers in `*oracle-defs*`, and exported public identifiers). Runtime value definitions (procedure bodies) are compiled as runtime references and do not affect the compilation or machine code of downstream modules.
- **Action Plan**:
  - In `compile-texmacs.scm:compute-dirty-modules!`, compare `(module-info-interface-hash old-info)` against `(module-info-interface-hash new-info)` when a module is directly changed:
    1. *Interface Unchanged*: If `interface-hash` is identical (meaning only internal runtime function bodies, comments, or private values changed, without altering `exports`, `global-macros`, or `macro-impls`), mark only the changed module for recompilation. **Do not propagate dirty status to downstream successors**.
    2. *Interface Changed*: If `interface-hash` differs (e.g. an export was added/removed, or a macro signature/transformer was modified), mark both the module and transitively invalidate all its dependents via `(compile-graph-dependents *compile-graph*)`.
  - For kernel modules (`*kernel-files*`), sequential inheritance still applies: changes to kernel modules rebuild the cumulative snapshot `texmacs-user.so` and invalidate all tiers.

---

## 6. Boot File Loading & Foreign Symbol Initialization (Design Note)

### [ ] Move foreign-symbol registration into `Sbuild_heap` `custom_init`

- **Status**: Not implemented; design note.
- **Location**: [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp#L439-L498), [`src/Scheme/Chez/chez_tm.cpp`](src/Scheme/Chez/chez_tm.cpp#L741-L750), [`src/Scheme/Chez/chez_tm.hpp`](src/Scheme/Chez/chez_tm.hpp)
- **Current state**:
  - `start_scheme` registers `petite.boot`, `scheme.boot`, and optionally `TEXMACS_BOOT_FILE`, then calls `Sbuild_heap (argv[0], custom_init)`.
  - `custom_init` is currently empty.
  - `initialize_scheme` registers `tm-call-by-name`, `tmscm_delete_blackbox`, `tmscm_blackbox_equal`, and `tmscm_blackbox_hash` with `Sforeign_symbol` **after** `Sbuild_heap` returns.
  - Consequence: a boot file that evaluates `(foreign-procedure "tm-call-by-name" ...)` at top level during heap construction cannot resolve the symbol yet.
- **Core idea**:
  - `Sbuild_heap` initializes the Chez kernel and symbol table, then calls `custom_init()` **before** running the registered boot files.
  - Registering C++ wrappers in `custom_init` makes them visible to any `foreign-procedure` evaluated by the boot files.
  - Alternatively, defer `foreign-procedure` bindings and calls to `scheme-start` or a post-`Sbuild_heap` callback.
- **C++ shape**:
  ```cpp
  extern "C" int cpp_engine_compute (int x) {
    return g_engine->compute (x);
  }

  static void
  register_cpp_interfaces (void) {
    g_engine= new Engine ();
    Sforeign_symbol ("cpp_engine_compute", (void*) cpp_engine_compute);
  }

  int
  main (int argc, const char *argv[]) {
    Sscheme_init (nullptr);
    Sregister_boot_file ("petite.boot");
    Sregister_boot_file ("app.boot");
    Sbuild_heap (argv[0], register_cpp_interfaces);
    int status= Sscheme_start (argc, argv);
    Sscheme_deinit ();
    delete g_engine;
    return status;
  }
  ```
- **Scheme shape**:
  ```scheme
  (import (chezscheme))

  ;; Safe during boot loading because custom_init ran first.
  (define engine-compute
    (foreign-procedure "cpp_engine_compute" (int) int))

  (scheme-start
    (lambda fns
      (printf "Result from C++ Engine: ~a\n" (engine-compute 10))))
  ```
- **Mapping to TeXmacs**:
  - Move the four existing `Sforeign_symbol` calls from `initialize_scheme` into `custom_init`, or split registration into a dedicated `register_tm_foreign_symbols()` called from both places.
  - Keep `custom_init` free of TeXmacs server/window state; it runs before normal application initialization.
  - Ensure any C++ object used by a wrapper is constructed before `Sbuild_heap`, or make the wrapper tolerate a null/uninitialized object until `scheme-start`.
  - If a boot file binds `(foreign-procedure "tm-call-by-name" ...)` at top level, the symbol must be registered in `custom_init`.
- **Deferred alternative**:
  - If registration remains after `Sbuild_heap`, boot files may still define libraries that **bind** `foreign-procedure` inside functions or inside `scheme-start`.
  - They must not **call** the foreign function at top level while the library is being defined.
  - `foreign-procedure` resolves its name when the expression is evaluated, so a later `Sforeign_symbol` registration works if evaluation is deferred.
- **Caveats**:
  - `custom_init` runs after Chez kernel initialization but before boot files; it is not a general C++ static-initialization hook.
  - Use `extern "C"` wrappers to avoid C++ name mangling.
  - `Sforeign_symbol` names must match the strings used by `foreign-procedure` exactly.
  - Boot heaps are Chez-version and platform specific; rebuild `app.boot` when Chez changes.
  - `SCHEMEHEAPDIRS` and `TEXMACS_BOOT_FILE` control boot-file discovery; keep both paths consistent.
  - Current TeXmacs embedding does not call `Sscheme_start`; it calls a C++ callback after `Sbuild_heap`. The `scheme-start` route would need an explicit entry point in the boot file or a callback bridge.
- **Concrete test**:
  - Build a tiny boot file containing a top-level `(define f (foreign-procedure "cpp_engine_compute" (int) int))`.
  - With the current empty `custom_init`, heap construction should fail to resolve the symbol.
  - After moving `Sforeign_symbol` into `custom_init`, the same boot file should load and `(f 10)` should return `420`.
- **Expected benefit**:
  - Boot files can bind foreign procedures at definition time.
  - Fewer runtime initialization steps and a shorter startup path.
  - A more natural split between heap construction, foreign-symbol registration, and application entry.

---

## 7. Session Persistence & the `-x` Entry Point

### [X] RESOLVED: `-x "(save-learned)"` and shutdown hook abort
- **Location**: [`TeXmacs/progs/kernel/texmacs/tm-dialogue.scm`](TeXmacs/progs/kernel/texmacs/tm-dialogue.scm) (`save-learned`, `retrieve-learned`).
- **Why it worked in Guile 1.8**: In Guile 1.8, `(texmacs-module (kernel texmacs tm-dialogue) ...)` dynamically switched `(current-module)`. When `(on-exit (save-learned))` expanded in Guile, the lambda captured the active module's environment as its lexical environment. When C++ later invoked `quit-TeXmacs-scheme` at exit, Guile executed the closure within that captured module scope, so private `(define (save-learned) ...)` was resolved successfully.
- **Why it failed in Chez Scheme**: Chez Scheme compiles files ahead-of-time (AOT) via `compile-texmacs.scm` into R6RS `(module kernel:texmacs:tm-dialogue () ...)` blocks. Definitions using plain `(define ...)` are strictly private and excluded from the module's `(export ...)` list. At runtime, C++ calls `call ("quit-TeXmacs-scheme")` from the top-level `(interaction-environment)`. Because `save-learned` was not exported publicly, the top-level environment had no binding for it, raising `Exception: variable save-learned is not bound` and aborting shutdown.
- **Fix**: Promoted `save-learned` and `retrieve-learned` from module-private `(define ...)` to `(define-public ...)`. Recompiled `tm-dialogue.so`.
- **Verification**: `TeXmacs -x '(begin (save-learned) (quit-TeXmacs))'` exits cleanly with code 0; `interactive.scm` is written successfully without raising `variable save-learned is not bound`.

### [ ] Qt 6 / Emacs Look-and-Feel: Minibuffer Footer Prompt Auto-Cancelled by Focus Race
- **Location**: [`src/Plugins/Qt/QTMMenuHelper.cpp:443-448`](src/Plugins/Qt/QTMMenuHelper.cpp#L443-L448) (`QTMInputTextWidgetHelper::leave`), [`src/Texmacs/Window/tm_dialogue.cpp`](src/Texmacs/Window/tm_dialogue.cpp), [`TeXmacs/progs/texmacs/texmacs/tm-server.scm`](TeXmacs/progs/texmacs/texmacs/tm-server.scm) (`safely-quit-TeXmacs`).
- **Symptom**: In Emacs mode (`"look and feel" "emacs"`, where `"interactive questions"` defaults to `"footer"`), closing an unsaved buffer causes the confirmation prompt in the footer to flash for a fraction of a second and immediately disappear; the right footer then resets to `"start" "s"`, and the window does not close.
- **Why it worked in Guile / Qt 4-5**: Under Qt 4 and Qt 5, window and canvas focus was not forced asynchronously on buffer switch, and status bar focus was retained.
- **Why it fails in Qt 6 / Chez**:
  1. `safely-quit-TeXmacs` calls `(switch-to-buffer (car l))` immediately prior to `(user-confirm ...)`.
  2. `switch-to-buffer` invokes `window_set_view(win, v, focus=true)`, which queues `send_keyboard_focus` (`canvas()->setFocus()`) to the Qt event loop.
  3. `user-confirm` installs the prompt into the status bar and focuses `_le` (`QTMInteractivePrompt::start()`).
  4. The Qt event loop then processes the queued `canvas()->setFocus()`, stealing keyboard focus from `_le`.
  5. `QTMLineEdit::focusOutEvent` emits `focusOut(reason)`, calling `QTMInputTextWidgetHelper::leave(reason)`.
  6. In `leave()`, because autocommit is off and reason is focus loss, it calls `wid()->commit(false)`.
  7. `commit(false)` notifies `ia_command_rep` with `#f`, which calls `win->interactive_return()`, dismantling the interactive prompt and restoring the status bar with canvas cursor context (`"start"` `"s"`).
  8. Because confirmation returned `#f` (cancelled), the quit sequence is aborted.
- **Candidate Fixes**:
  1. In `QTMMenuHelper.cpp` (`QTMInputTextWidgetHelper::leave`), only commit if autocommit is explicitly `"on"`; do not auto-cancel active interactive footer prompts on focus loss.
  2. In `fakehome/.TeXmacs-chez/system/preferences.scm`, set `("interactive questions" "popup")` so confirmation uses persistent modal dialogs rather than the focus-sensitive footer line.

---

## 8. C++ <-> Scheme Interaction & FFI Optimization Roadmap

### [ ] Eliminate `tm-apply` & List Consing in `call_scheme`
- **Location**: [`src/Scheme/Chez/chez_tm.cpp:395-438`](src/Scheme/Chez/chez_tm.cpp#L395-L438)
- **Problem**: `call_scheme (fun, a1, a2, ...)` constructs Scheme lists using `Scons` and dispatches via `Scall2 (tm_apply_proc, fun, args_list)`.
- **Optimization**: Chez Scheme's C API natively provides `Scall0(fun)`, `Scall1(fun, a1)`, `Scall2(fun, a1, a2)`, `Scall3(fun, a1, a2, a3)`. Invoking `ScallN` directly eliminates Scheme heap allocations (cons cells) and dynamic `apply` dispatch overhead for all 0-3 argument C++ -> Scheme invocations.

### [X] Replace Scheme -> C++ Glue Trampoline (`tm-call-by-name` & `std::map`) [RESOLVED]
- **Location**: [`src/Scheme/Chez/chez_tm.cpp:250-395`](src/Scheme/Chez/chez_tm.cpp#L250-L395), [`TeXmacs/progs/kernel/boot/boot-chez.scm:956-1050`](TeXmacs/progs/kernel/boot/boot-chez.scm#L956-L1050)
- **Problem**: All 1,180+ C++ glue primitives (`tmg_*`) were installed as:
  ```scheme
  (define <name> (lambda args (tm-call-by-name "<name>" args)))
  ```
  Every time Scheme called a C++ primitive (e.g. `(tree-label t)` during editing or typesetting):
  1. Scheme allocated a heap rest-argument list `args` (16 bytes per argument).
  2. Called foreign procedure `tm-call-by-name`.
  3. C++ executed `std::map<string, tm_proc_entry>::find(name)` with `std::string` heap allocations and $O(\log N)$ comparisons.
  4. C++ unpacked the Scheme list one element at a time via `Scar`/`Scdr`.
- **Solution Implemented & Empirical Validation**:
  1. **Direct Array Table Dispatch**: Implemented static array `tm_fast_proc_entry tm_fast_table[2048]` in C++ `.data` segment. Assigned sequential integer IDs to all 1,181 glue procedures at boot time.
  2. **Fixed-Arity Trampolines with Zero-Cost C++ Exception Containment**:
     - Created `tm_fast_call_0` through `tm_fast_call_10` in `chez_tm.cpp` taking `(int id, ptr a1, ...)` with zero-cost Itanium C++ `try/catch` unwinding and `chez_lock`.
     - Bound in Scheme as `foreign-procedure` calls passing arguments purely in CPU registers (`x0` through `x7`).
     - **0 GC Bytes**: Both array table lookup and register argument passing allocate 0 bytes on the Scheme heap.
     - **Crash Safety**: Unlike direct un-wrapped foreign-procedure addresses, any C++ exception is caught inside C++ and converted to a Scheme condition, preventing fatal `std::terminate()` process aborts across foreign stack frames.
  3. **Measured Speedup & Churn Reduction**:
     - Microbenchmark (`url-none?` $\times 1,000,000$): Latency dropped from **220 ns to 58 ns** (**3.8× throughput speedup**).
     - LaTeX export: Gross heap allocation dropped from 152.33 MB to **124.53 MB (-27.80 MB / -18.3% churn)**, cutting **3 full GC cycles** warm and **4 GCs** cold.
     - Macro conversion speedup: LaTeX export -165 ms (-12.0%), LaTeX import -306 ms (-34.1%), HTML import -25 ms (-11.8%).

### [X] Fast Character Set Checks & String Split Optimizations [RESOLVED]
- **Location**: [`TeXmacs/progs/kernel/boot/chez-compat.scm:122-230`](TeXmacs/progs/kernel/boot/chez-compat.scm#L122-L230)
- **Problem**:
  1. In `char-in-set?`, testing `(list? cs)` executed an $O(N)$ cycle-detection traversal of `cs` on every single character check.
  2. `string-split`, `string-index`, `string-rindex`, and `string-count` called `char-in-set?` inside the inner loop for every character, evaluating a 4-way `cond` type dispatch on invariant delimiters.
  3. In `string-split`, if a string had no delimiters, it unconditionally copied the entire string with `substring` and allocated cons cells.
- **Solution Implemented & Empirical Validation**:
  1. Replaced `(list? cs)` with $O(1)$ single-instruction pointer tag check `(pair? cs)`.
  2. Hoisted delimiter checks outside the loops: specialized tight inner loops for `char?` (e.g. `#\newline`, `#\/`, `#\:`) and 1-char `string?` bypass `char-in-set?` and use direct `char=?`.
  3. Added no-delimiter zero-allocation fast path in `string-split`: returns `(list s)` directly with 0 substring copies allocated.
  4. Measured Results: `menu-expand-x10` allocation dropped to 7.98 MB (-0.76 MB), `import-html` dropped to 55.85 MB (-1 GC), `export-html` dropped to 88.39 MB (-8.84 MB, -2 GCs).

### [X] Clean Up Redundant Symbol Lookup in `tmscm_is_equal` [RESOLVED]
- **Location**: [`src/Scheme/Chez/chez_tm.cpp:111`](src/Scheme/Chez/chez_tm.cpp#L111)
- **Problem**:
  ```cpp
  ptr equal_proc= Stop_level_value (Sstring_to_symbol ("equal?"));
  ```
  `Stop_level_value(Sstring_to_symbol("equal?"))` was re-evaluated on every equality comparison where pointer inequality occurred (`o1 != o2`). However, `tm_equal_pred` was already fetched and locked at boot time in `initialize_scheme()` (line 687).
- **Solution**: Removed the redundant lookup on line 111 and directly check and invoke the cached `tm_equal_pred`, saving string hashing and oblist lookups on equality failures.

### [ ] Downstream String Concatenation & Comparison in HTML/LaTeX Exporters
- **Location**: `TeXmacs/progs/convert/html/`, `TeXmacs/progs/convert/latex/`
- **Empirical Finding on `symbol->string`**:
  Calling `(symbol->string sym)` in Chez Scheme allocates **0 bytes of heap memory** (verified via `1,000,000` calls allocating 0 bytes). In Chez Scheme, symbols store an immutable string pointer to their print-name; `symbol->string` is an $O(1)$ single-instruction field dereference (`ldr x0, [x_sym, #8]`).
- **Where the Real Churn Lies**:
  The GC churn comes from what is done *with* the string immediately after conversion:
  1. `(string-append "<" (symbol->string s) ">")` in `htmlout.scm` (called 57,000+ times per HTML export), repeatedly allocating temporary tag strings.
  2. `(string-starts? (symbol->string (car t)) "tmmath")` in `tmtex.scm`, converting symbols to strings just for prefix checks.
- **Optimization**:
  1. Prefer direct symbol `eq?` or `memq` checks (e.g. `(eq? tag 'td)`) rather than converting symbols to strings for comparisons.
  2. Pre-format common HTML element open/close tag strings (`'td` $\to$ `"<td"`, `"</td>"`), eliminating dynamic `string-append` in inner serialization loops.

### [ ] Typesetter `<extern|...>` AST Execution: Replace Dynamic `eval` with Cached Procedure Calls
- **Location**: [`src/Typeset/Env/env_exec.cpp:49-65`](src/Typeset/Env/env_exec.cpp#L49-L65)
- **Problem**: During typesetting of documents with dynamic tags, menus, or macros, `<extern|fun|arg1|...>` builds a cons cell `(cons (string_to_object fun) args)` and calls `eval(expr)`. In Chez Scheme, this invokes the native compiler on every dynamic tag evaluation.
- **Optimization**: Look up the cached Scheme procedure `fun` and invoke it directly with `call_scheme(proc, args)` or compile once and reuse.

### [ ] Optimize Blackbox Object Allocation & Guardian Tracking
- **Location**: [`src/Scheme/Chez/chez_tm.cpp:170-215`](src/Scheme/Chez/chez_tm.cpp#L170-L215)
- **Problem**: Every C++ object (`tree`, `widget`, `command`, `url`) passed into Scheme triggers `tm_new<blackbox>(b)`, a Chez integer allocation (`Sinteger`), a Box allocation (`Sbox`), and registration with `tm_blackbox_guardian`. Reclaiming requires running `reap_blackboxes` during GC.
- **Optimization**: Investigate pooling/recycling blackbox memory or batching guardian operations to reduce allocator and GC pressure.

### [X] Thread Activation & Mutex Granularity (`chez_lock` / `chez_activate`) [RESOLVED & IMPLEMENTED]
- **Location**: [`src/Scheme/Chez/chez_tm.cpp:40-68`](src/Scheme/Chez/chez_tm.cpp#L40-L68)
- **Problem**:
  1. `chez_lock`: Every leaf FFI glue call (`tm_fast_call_0`..`10`) acquired and released `std::recursive_mutex`. In single-threaded execution, this incurred hundreds of thousands of redundant atomic CAS instructions and memory fences.
  2. `chez_activate`: Every C++ $\to$ Scheme call (`call_scheme`, `eval_scheme`) called `Sactivate_thread()` and immediately called `Sdeactivate_thread()` upon return. This caused the main GUI thread to constantly cycle active $\leftrightarrow$ inactive with redundant TLS lookups.
- **Implementation & Empirical Results**:
  1. **Permanent Main Thread Activation**: Main thread is activated once at boot time by `Sscheme_init()` and stays active for the lifetime of the process. Clean shutdown is handled by calling `Sscheme_deinit()` when `call_back` returns in `start_scheme()`.
  2. **Lock-Free Leaf Glue**: Completely removed `chez_lock` and `chez_activate` scaffolding from `tm_fast_call_0`..`10`, `tm_call_by_name`, `call_scheme`, `eval_scheme`, and `reap_blackboxes`.
  3. **Foreign Call Microbenchmark** (`1,000,000` calls to `url-none?`): Latency dropped from **38 ms to 30 ms** (**-21% latency / +33% throughput**, saving ~8 ns of mutex atomic CAS overhead per foreign call).
  4. **LaTeX Export (`export-latex`)**:
    - Warm latency dropped from **1,303 ms to 1,127 ms (-176 ms / -13.5% speedup)**.
    - Cold latency dropped from **3,091 ms to 1,872 ms (-1,219 ms / -39.4% speedup)**.
  5. **Engine Stability**: 100% stable; verified clean boot and shutdown with return code 0 and zero memory faults or GC errors.

### [X] Direct Fixed-Arity C++ `call_scheme` Dispatch & Tree-Safe Transcoding [RESOLVED & IMPLEMENTED]
- **Location**: [`src/Scheme/Chez/chez_tm.cpp:465-610`](src/Scheme/Chez/chez_tm.cpp#L465-L610), [`TeXmacs/progs/kernel/boot/boot-chez.scm:975-1015`](TeXmacs/progs/kernel/boot/boot-chez.scm#L975-L1015)
- **Problem**:
  1. Every C++ $\to$ Scheme call (`call_scheme`) packed arguments into a heap-allocated list via `Scons` and invoked Scheme `tm-apply`.
  2. `tm-apply` ran `recur-utf8->string` on arguments, set up a dynamic `guard` exception frame, used reflection-based `(apply proc ...)`, and then ran `recur-string->utf8` across the entire return value tree, converting every string into a newly allocated `bytevector`.
  3. In benchmarks, 100,000 calls returning small trees allocated **79.4 MB** and triggered **9 GCs** (24.5 ms).
- **Implementation & Empirical Results**:
  1. **Fixed-Arity Dispatch**: Introduced `tm-call-0` through `tm-call-4` and `tm-call-n` in `boot-chez.scm` with direct fixed-arity invocation and zero dynamic `apply`.
  2. **Register-Based Calling in C++**: In `chez_tm.cpp`, `call_scheme` passes arguments directly in registers via `Scall1`, `Scall2`, `Scall3`, `scall4`, `scall5`. Consing argument lists on the Scheme heap is 100% eliminated.
  3. **Tree-Safe Iterative Transcoding**:
    - `to_scheme_arg` and `from_scheme_result` perform iterative list-spine traversal with `Svectorp` and `Spairp` support, completely immune to C++ stack overflows on deep trees.
    - Direct UTF-8 decoding via `Sstring_utf8`, strictly matching the original `tm-apply` semantics without unnecessary validation overhead or Cork assumptions.
    - Direct UTF-8 encoding delegates to Chez Scheme's native compiled R6RS `(string->utf8 str)` via `Scall1 (tm_string_to_utf8_proc, str)` (~79 ns, zero C++ heap churn).
    - Preserves structural sharing: if a tree contains no strings needing conversion, 0 heap allocations occur.
  4. **Empirical Verification**:
    - Simple calls: **10.3× faster** (17.2 ms $\to$ 1.66 ms) and **-87% allocation** (50.5 MB $\to$ 6.4 MB).
    - Nested tree/menu returns: **31.0× faster** (24.5 ms $\to$ 0.79 ms) and **-74% allocation** (79.4 MB $\to$ 20.8 MB).
    - `export-latex` warm latency dropped under 1 second to **982 ms**.
    - Full round-trip fidelity verified on Cork accented text (`"élève naïve à l'Haÿ-les-Roses Grüße"`) and nested mathematical ASTs.

### [X] Fast-Path Dynamic Evaluation (`eval`) in `boot-chez.scm` [RESOLVED & IMPLEMENTED]
- **Location**: [`TeXmacs/progs/kernel/boot/boot-chez.scm:43-95`](TeXmacs/progs/kernel/boot/boot-chez.scm#L43-L95)
- **Problem & Root Cause**:
  1. In Guile, `(eval 'file-menu)` was a simple hash-table variable lookup in the current module.
  2. In Chez Scheme, even with `(compile-interpret-simple #t)`, `eval` wraps forms into syntax objects, invokes the full `syntax-case` macro expander (`expand`), checks scope ribbons, builds intermediate core ASTs, and dispatches to the interpreter (~2,600 ns and heap allocation per lookup).
  3. Menu generation (`(expand-all-menus)`) in `menu-widget.scm` repeatedly expands `(link <name>)` (evaluating symbols like `'file-menu`, `'math-menu`) and `(dynamic (proc))` (evaluating forms like `'(texmacs-focus-icons)`).
  4. Dynamic toolbar/focus-bar updates during editing in `generic-menu.scm` call `eval` on focus-tag names and markup icons on every cursor move.
  5. Furthermore, `tm-quote-eval-literals` unconditionally re-`cons`ed every pair on every list passed to `eval`, allocating 20+ MB of garbage per 100k calls.
- **Implementation**:
  1. **Bound Symbols**: Resolved via `(top-level-value form e)` in ~14 ns (direct value-cell dereference, ~200× faster than native `eval`, zero GC allocation).
  2. **Self-Evaluating Literals**: Numbers, strings, booleans, procedures, characters, and `'()` return `form` immediately.
  3. **`(quote datum)`**: Unwrapped directly to `(cadr form)` in ~4 ns (660× faster, zero allocation).
  4. **Nullary Calls `(proc)`**: If `(car form)` is a bound top-level procedure and `(cdr form)` is null, executes the procedure directly in native machine code (~90× faster, eliminates 1 GB allocation per 100k calls).
  5. **Zero-Allocation Structural Sharing**: Rewrote `tm-quote-eval-literals` to reuse original cons cells via `(if (and (eq? a a*) (eq? d d*)) x (cons a* d*))`, allocating 0 bytes when no raw procedures or boxes need quoting.
- **Empirical Results**:
  - `menus-math`: dropped from **70.6 ms $\to$ 55.3 ms** (**+21.7% faster**).
  - `menus-text`: cold dropped from **628 ms $\to$ 540 ms**, warm dropped from **81.0 ms $\to$ 73.0 ms**.
  - `open-change-log`: cold dropped from **1,546 ms $\to$ 906 ms** (**+41.4% faster**), warm dropped from **223 ms $\to$ 168 ms**.
  - `typing-math-270-keys`: warm dropped from **1,103 ms $\to$ 1,013 ms** (**+8.2% faster**).

### [ ] Further Dynamic Evaluation (`eval`) & Menu Generation Optimizations
- **Location**: [`TeXmacs/progs/kernel/gui/menu-widget.scm`](TeXmacs/progs/kernel/gui/menu-widget.scm#L949-L958), [`TeXmacs/progs/generic/generic-menu.scm`](TeXmacs/progs/generic/generic-menu.scm), [`TeXmacs/progs/kernel/boot/boot-chez.scm`](TeXmacs/progs/kernel/boot/boot-chez.scm)
- **Opportunities Identified**:
  1. **Unary Call Fast-Path for Pure Functions**:
     - In dynamic menus (e.g. `generic-menu.scm`), forms like `(eval (upcase-first "file"))` or `(eval (pull-focus t "name"))` are common.
     - Extend direct invocation in `eval` to single-argument calls where the function is a bound procedure and the argument is a literal (string/number/boolean/symbol), avoiding Chez expander dispatch.
  2. **Direct Procedure Caching at Caller Sites (`menu-widget.scm`)**:
     - In `menu-widget.scm`: `menu-expand-link` executes `((eval (cadr p)))`.
     - Because `menu-widget.scm` is compiled into `menu-widget.so`, checking `(cond ((procedure? target) target) ((and (symbol? target) (top-level-bound? target)) (top-level-value target)) (else (eval target)))` allows the compiled C-native code of `menu-widget.so` to resolve the procedure directly without a dynamic Scheme call to `eval`.
  3. **Dynamic Menu Tree Memoization**:
     - Menus like `(texmacs-menu)` return static trees that are re-expanded repeatedly when traversing submenus.
     - Adding short-lived caching or hash-consing for static submenus during a single menu-bar refresh cycle avoids re-expanding unchanged subtrees on every key press.


