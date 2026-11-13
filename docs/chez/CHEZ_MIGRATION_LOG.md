# Phasing, Boot Sequencing & Compiler Migration Log

This document records the architectural discoveries, root-cause analyses, and dependency reorganizations made during the Chez Scheme ahead-of-time (AOT) compilation and boot-file optimization work.

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
