# Architecture Plan: Single-Image Binary Startup (`texmacs.so` & `texmacs.boot`)

## Executive Summary

Currently, TeXmacs Chez Scheme startup requires loading `boot-chez.so` followed by 453 individual compiled module `.so` files via sequential filesystem lookups (`primitive-load`). While ahead-of-time compiled, this incurs significant disk I/O, 453 individual file opens/stats, FASL deserializations, and dynamic linking overhead during every startup.

To achieve fast binary startup without filesystem thrashing, two architectural approaches have been designed:
1. **Approach 1 (`texmacs.so`) — Single Consolidated Object File (Immediate Milestone)**:
   Concatenates all 453 compiled `.so` files in topological DFS post-order into a single binary image `texmacs.so` (per Chez Scheme User's Guide Section 2.8). Loaded via `load_scheme_file` immediately after C++ glue initialization. Provides 95% of performance gains with zero changes to glue generation or upstream Scheme code.
2. **Approach 2 (`texmacs.boot`) — Native Secondary Boot File via `Sregister_boot_file` (Ultimate Target)**:
   Builds a native Chez Scheme secondary boot file loaded directly into the static GC generation during `Sbuild_heap()`. Requires re-architecting C++ glue procedures to use Chez `Sforeign_symbol` in `custom_init()` and decoupling top-level server calls.

```
Approach 1 (Immediate):
+----------------------------------------------------------------------------------+
|                              texmacs.so                                          |
|  Concatenation of 453 compiled .so modules in topological DFS post-order         |
+----------------------------------------------------------------------------------+
                                        |
      Sbuild_heap() -> Construct server sv -> initialize_glue() -> load("texmacs.so")

Approach 2 (Ultimate):
+----------------------------------------------------------------------------------+
|                              texmacs.boot                                        |
|  Native boot header ('("petite" "scheme")) + compiled object code stream          |
+----------------------------------------------------------------------------------+
                                        |
      Sregister_boot_file("texmacs.boot") -> custom_init() -> Sbuild_heap()
```

---

## 1. Analysis of the Two Approaches

### Approach 1: Consolidated Object File (`texmacs.so`)

* **Chez Scheme Reference**: CSUG Section 2.8 (*Building and Distributing Applications*):
  > *"Although not strictly necessary, we suggest that you concatenate your Scheme object files, if you have more than one, into a single object file. This may be done on Unix systems simply via the `cat` program or on Windows via `copy`. Placing all of the object code into a single file simplifies both building and distribution of applications."*
* **Execution Flow**:
  1. `Sscheme_init()` and `Sbuild_heap()` initialize the base Chez Scheme runtime (`petite.boot`, `scheme.boot`).
  2. `TeXmacs_main()` initializes GUI and creates `server sv;` (`the_server = this`).
  3. `initialize_scheme()` registers C foreign symbols, loads `boot-chez.so`, and executes `initialize_glue()`, installing all 1,170 C++ glue procedures.
  4. `load_scheme_file("texmacs.so")` loads all 453 modules in **one single file read**.
* **Advantages**:
  - Replaces 453 file operations with 1 file read (~20–30 ms total load time).
  - Normal TeXmacs boot sequence, `the_server` lifetime, and glue installation remain intact.
  - Zero modifications to upstream `TeXmacs/progs/` files.
  - Zero ad-hoc glue stubs required.

### Approach 2: Native Secondary Boot File (`texmacs.boot`)

* **Chez Scheme Reference**: CSUG Section 12.1 (`make-boot-file`) and C API (`Sregister_boot_file`, `Sbuild_heap`).
* **The Core Mechanism**:
  A boot file registered with `Sregister_boot_file()` is evaluated during `Sbuild_heap()`. All objects, symbols, and procedures loaded this way are placed directly into Chez Scheme's **static generation**, making them permanently exempt from garbage collection.
* **Why It Requires a Deeper Architectural Overhaul**:
  1. **Circular Dependency on Heap Build**:
     - `Sbuild_heap()` evaluates `texmacs.boot` before returning control to C++.
     - `initialize_glue()` installs procedures into Scheme via `tmscm_install_procedure()`, which calls `Sstring_to_symbol()` and defines top-level values. In Chez Scheme, creating Scheme symbols/definitions before `Sbuild_heap()` crashes because the heap does not exist.
     - Therefore, during `Sbuild_heap()`, the 1,170 C++ glue procedures do not exist yet.
  2. **Missing C++ Server Instance**:
     - `the_server` does not exist during `Sbuild_heap()`.
     - Modules like `fonts-composite.scm` call `(set-font-rules ...)` at top-level, which calls `get_server()`. This crashes if executed during `Sbuild_heap()`.
* **Prerequisites to Realize Approach 2**:
  1. **Regenerate Chez Glue as Foreign Symbols**:
     Rewrite/extend `build-glue-*.scm` to generate C++ wrappers registered via `Sforeign_symbol()` in `custom_init()` rather than runtime `tmscm_install_procedure()`.
  2. **Scheme Foreign Procedure Bindings**:
     Bind all 1,170 foreign symbols via `(foreign-procedure ...)` in `boot-chez.scm` before boot file evaluation.
  3. **Decouple Server Access from Load Time**:
     Ensure top-level forms in modules either defer calls to `(on-entry ...)` or guard against null server instances.

---

## 2. Implementation Roadmap

### Phase 1: Implement Approach 1 (`texmacs.so`) — Current Task
1. **Generator Script**:
   Generate `texmacs.so` by concatenating all 453 compiled `.so` modules according to `boot-order-full.scm` (topological DFS post-order).
2. **C++ Loader in `chez_tm.cpp`**:
   Support `TEXMACS_SO_FILE` (or `texmacs.so` in boot directory) to load the single consolidated object file post-glue.
3. **Runtime Bypass in `init-texmacs-chez.scm`**:
   Detect that modules are already loaded from `texmacs.so`, skipping the 453 individual `use-modules` / `load` calls.
4. **Benchmark Verification**:
   Measure startup time and verify 0 errors during GUI cold boot.

### Phase 2: Design and Implement Approach 2 (`texmacs.boot`) — Subsequent Milestone
1. Design the Chez-native FFI glue generator (`build-glue-chez.scm`).
2. Register foreign symbols in `custom_init()`.
3. Separate bootstrap kernel modules into `texmacs-kernel.boot`.
4. Decouple top-level C++ side effects.
2. **Auto-detect default `texmacs.boot` location:**
   Extend `start_scheme()` to probe for:
   - Explicit environment variable: `$TEXMACS_BOOT_FILE`
   - Build/bundled path: `$TEXMACS_BOOT_PATH/texmacs.boot` or `$TEXMACS_PATH/boot/texmacs.boot`

### Phase 2: Compiler Integration (`compile-texmacs.scm`)
Add a dedicated generator stage after Pass 2 finishes compiling and verifying modules:
```scheme
(define (build-texmacs-boot-file)
  (let* ((boot-file (boot-path "texmacs.boot"))
         (boot-chez (boot-path "kernel/boot/boot-chez.so"))
         (user-so   (boot-path "texmacs-user.so")))
    (when (and (file-exists? boot-chez) (file-exists? user-so))
      (log-progress-pct "Generating" "texmacs.boot image")
      (make-boot-file boot-file
                      '("petite" "scheme")
                      boot-chez
                      user-so)
      (log-progress-pct "Verified" "texmacs.boot"))))
```

### Phase 3: Runtime Bootstrap Adaptation (`init-texmacs-chez.scm`)
Guard the module loading sequence so that if `(top-level-bound? 'texmacs-booted-from-image?)` (or `(chez-has-boot?)`) is set, loading of core snapshot modules is bypassed:
```scheme
(unless (top-level-bound? '*texmacs-boot-loaded*)
  ;; Only load modules from disk if not already initialized in the boot image
  (load-core-modules-or-snapshot!))
```

### Phase 4: Packaging & Bundling (`make-bundle.sh`)
Update `packages/macos/make-bundle.sh` to copy `texmacs.boot` alongside the other boot artifacts:
```bash
if [ -f "$SRC_BOOT/texmacs.boot" ]; then
  cp -p "$SRC_BOOT/texmacs.boot" "$SHARE/boot/texmacs.boot"
fi
```

---

## 4. Expected Benefits & Verification

| Metric | Current AOT Setup (`.so` files) | With `texmacs.boot` Image |
|---|---|---|
| **Filesystem `open`/`read` calls** | ~454 file descriptors | 1 file descriptor (`texmacs.boot`) |
| **Scheme engine bootstrap** | ~64 - 96 ms | **~5 - 15 ms** |
| **Startup memory fragmentation** | Multiple incremental FASL heap allocations | Single contiguous heap allocation |
| **Deployment surface** | Hundreds of loose `.so` files | 1 unified boot image + non-core plugin `.so`s |

### Verification Protocol
1. **Verification of build:** `make-boot-file` completes with 0 errors and generates a non-empty `texmacs.boot`.
2. **Verification of headless test suite:** Run `all-tests.scm` using `TEXMACS_BOOT_FILE=build-texmacos/boot/texmacs.boot`.
3. **Verification of GUI startup:** Launch TeXmacs and confirm `Chez Scheme: booting from AOT image texmacs.boot` appears in stderr, with GUI interactive time dropping noticeably.
