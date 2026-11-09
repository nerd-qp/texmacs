;;; TODO: UNDER REVIEWED AI GENERATED CODE.
;;;
;;; compile-texmacs.scm -- Transpiles and compiles all TeXmacs modules into native Chez Scheme modules
;;;
;;; Usage:
;;;  ENV=??? TeXmacs --compile-modules

(define-top-level-value 'texmacs-chez-compiling? #t)
(define-top-level-value 'boot-kernel-loaded? #t)

;; ---- Paths and small helpers ---------------------------------------------

(define (string-prefix? prefix s)
  (let ((n (string-length prefix)))
    (and (>= (string-length s) n)
         (string=? prefix (substring s 0 n)))))

(define (string-suffix? suffix s)
  (let ((n (string-length suffix))
        (m (string-length s)))
    (and (>= m n)
         (string=? suffix (substring s (- m n) m)))))

(define (strip-scm path)
  (if (string-suffix? ".scm" path)
      (substring path 0 (- (string-length path) 4))
      path))

(define (scm->so path)
  (string-append (strip-scm path) ".so"))

(define (env-flag? name)
  (let ((value (getenv name)))
    (and value
         (not (string=? value ""))
         (not (string=? value "0")))))

(define *progs-dir*
  (let ((path (getenv "TEXMACS_PATH")))
    (cond ((and path (file-exists? (string-append path "/progs")))
           (string-append path "/progs"))
          ((file-exists? "TeXmacs/progs") "TeXmacs/progs")
          ((file-exists? "texmacs/TeXmacs/progs") "texmacs/TeXmacs/progs")
          (else "TeXmacs/progs"))))

;; Where transpiled sources and compiled modules are written.
;;
;; TEXMACS_BOOT_PATH takes precedence, mirroring how boot-chez.scm resolves
;; compiled modules at runtime, so that build trees with another name (for
;; instance build-win) work without editing this file. The literals below are
;; the historical default.
(define *boot-dir*
  (or (getenv "TEXMACS_BOOT_PATH")
      (and (file-exists? "build-texmacos/boot") "build-texmacos/boot")
      (and (file-exists? "texmacs/build-texmacos/boot") "texmacs/build-texmacos/boot")
      (and (file-exists? "../build-texmacos/boot") "../build-texmacos/boot")
      "build-texmacos/boot"))

(define (boot-path rel-path)
  (string-append *boot-dir* "/" rel-path))

(define (progs-path rel-path)
  (string-append *progs-dir* "/" rel-path))

(unless (top-level-bound? 'boot-chez-loaded?)
  (load (string-append *progs-dir* "/kernel/boot/boot-chez.scm")))

(define *compiler-dir*
  (or (and (file-exists? "compiler-db.scm") ".")
      (and (file-exists? "src/Scheme/Chez/compiler-db.scm") "src/Scheme/Chez")
      (and (file-exists? "texmacs/src/Scheme/Chez/compiler-db.scm")
           "texmacs/src/Scheme/Chez")
      (error 'compile-texmacs "cannot find compiler-db.scm")))

;; These libraries are loaded with `primitive-load', not `import': a TeXmacs
;; process has no library search path into src/Scheme/Chez.
(primitive-load (string-append *compiler-dir* "/tarjan.scm"))
(import (tarjan))
(primitive-load (string-append *compiler-dir* "/compiler-db.scm"))
(import (compiler-db))
(primitive-load (string-append *compiler-dir* "/compiler-scan.scm"))
(import (compiler-scan))
(primitive-load (string-append *compiler-dir* "/compile-graph.scm"))
(import (compile-graph))
;; Progress reporting imports (chezscheme) explicitly, so it does not depend on
;; what the boot script left bound in the environment this file is exec'd into.
(primitive-load (string-append *compiler-dir* "/compiler-progress.scm"))
(import (compiler-progress))

(unless (top-level-bound? 'compilation-environment)
  (define-top-level-value 'compilation-environment
    (make-parameter (interaction-environment))))

;; The module whitelist lives in its own library: the linters and the tests
;; need the same seven lists, and re-reading this file to eval its `define`
;; forms was the only way to get them.
(primitive-load (string-append *compiler-dir* "/compile-inventory.scm"))
(import (compile-inventory))

;; ---- Definitions the transpiler has to understand ------------------------

(define *macro-definers*
  '(define-syntax define-macro define-public-macro define-module-macro
    define-export-macro tm-define-macro))

(define *value-definers*
  '(define define-public provide-public tm-define define-table))

;; (define ((f a) b) body) -> (define (f a) (lambda (b) body))
(define (uncurry-def definer head body)
  (if (pair? (car head))
      (uncurry-def definer (car head) (list `(lambda ,(cdr head) ,@body)))
      `(,definer ,head ,@body)))

(define (tm-maybe-uncurry form)
  (if (and (pair? form)
           (memq (car form) '(define define-public provide-public))
           (pair? (cadr form))
           (pair? (caadr form)))
      (uncurry-def (car form) (cadr form) (cddr form))
      form))

;; (define (f) "doc" body) -> (define (f) body)
(define (tm-strip-docstring form)
  (if (and (pair? form)
           (memq (car form) '(define define-public provide-public))
           (pair? (cadr form))
           (pair? (cddr form))
           (string? (caddr form))
           (pair? (cdddr form)))
      (cons (car form) (cons (cadr form) (cdddr form)))
      form))

(define (normalize-definition form)
  (tm-strip-docstring (tm-maybe-uncurry form)))

;; ---- Gated eager evaluation + on-demand install of expand-time helpers ---
;; Plain value definitions are left to `compile-file'; definitions that must be
;; live while a macro expands are installed on demand into the module's own
;; compilation environment. Set TEXMACS_EAGER_GATE=0 to disable the gate.
(primitive-load (string-append *compiler-dir* "/macro-closure.scm"))

(define *oracle-defs* (make-eq-hashtable))
(define *oracle-installing* (make-eq-hashtable))
(define *oracle-installed* (make-eq-hashtable))
(define *ephemeral-syms* '())

(define (scheme-files dir)
  (let loop ((rel "") (acc '()))
    (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
      (if (file-directory? full)
          (fold-left
            (lambda (acc name)
              (if (member name '("." ".."))
                  acc
                  (loop (if (string=? rel "") name (string-append rel "/" name)) acc)))
            acc
            (directory-list full))
          (if (string-suffix? ".scm" rel) (cons rel acc) acc)))))

(define (oracle-index-tree! defs root)
  (define (index-top! top rel mod)
    ;; Only definitions a top-level context can hold: the form itself, or a
    ;; definition under a top-level begin/if/when/unless wrapper.
    (define (record! form)
      (let ((name (mc-leftmost-symbol (mc-cadr form))))
        (when (and (symbol? name) (not (hashtable-ref defs name #f)))
          (hashtable-set! defs name
                          (vector name
                                  (if (memq (car form) *macro-definers*) 'macro 'value)
                                  form top rel mod)))))
    (define (walk form)
      (when (pair? form)
        (let ((head (car form)))
          (cond ((memq head '(quote syntax syntax-rules quasiquote)) (void))
                ((and (symbol? head)
                      (or (memq head *macro-definers*)
                          (memq head *value-definers*))
                      (pair? (cdr form)))
                 (record! form))
                ((memq head '(begin if when unless))
                 (for-each walk (cdr form)))))))
    (walk top))

  (for-each
    (lambda (rel)
      (let ((forms (guard (e (else '()))
                     (read-all-forms (string-append root "/" rel)))))
        (let ((header (find (lambda (form)
                              (and (pair? form) (eq? (car form) 'texmacs-module)))
                            forms)))
          (when header
            (for-each (lambda (top) (index-top! top rel (mc-cadr header))) forms)))))
    (scheme-files root)))

;; A name is live if it holds a value or a working syntax binding. Neither
;; primitive answers this alone: `top-level-bound?' is #f for a macro, and
;; `top-level-syntax?' is #t for symbols that were never defined.
(define (oracle-live? name env)
  (or (top-level-bound? name env)
      (guard (e (else #f)) (procedure? (top-level-syntax name env)))
      (hashtable-ref *oracle-installed* name #f)))

(define (unbound-marker)
  (guard (e (else (void)))
    (#%$unbound-object)))

(define (unbind-symbol! entry env)
  (let ((name (car entry))
        (syntax (cdr entry)))
    (when (top-level-bound? name env)
      (define-top-level-value name (unbound-marker) env))
    (define-top-level-syntax name syntax env)))

(define (oracle-head-dependency form)
  (let ((head (and (pair? form) (car form))))
    (if (and (symbol? head) (hashtable-ref *oracle-defs* head #f))
        (list head)
        '())))

(define (oracle-macro? sym)
  (let ((e (hashtable-ref *oracle-defs* sym #f)))
    (and e (eq? (vector-ref e 1) 'macro))))

(define (oracle-site-deps site)
  (append
    (oracle-head-dependency (vector-ref site 3))
    (if (eq? (vector-ref site 1) 'macro)
        ;; A macro definer hides its body from `mc-free-references' (a template is
        ;; not a use), so its dependencies come from `mc-macro-deps' instead.
        (or (mc-macro-deps (vector-ref site 2)) '())
        (mc-val-dependencies (vector-ref site 3) oracle-macro? (compilation-environment)))))

;; Evaluate `thunk`, reporting any exception as one flat log line
;;   (MESSAGE irritant ... <condition text>)
;; and returning `default` instead of propagating it. A `message` of #f keeps
;; the call silent. Every eager evaluation in the transpiler goes through here,
;; so a failure is attributed to the form that caused it instead of aborting
;; the module.
(define (guard-eval message irritants default thunk)
  (guard (e (else
              (when message
                (display (append (list message) irritants (list (condition-text e))))
                (newline))
              default))
    (thunk)))

;; Install NAME into the current compilation environment, dependencies first.
;; The two rewrite steps matter: the sources contain curried definitions and
;; docstrings, which `define' rejects when evaluated raw.
(define (oracle-install! name)
  (let ((env (compilation-environment))
        (site (and (symbol? name) (hashtable-ref *oracle-defs* name #f))))
    (cond ((not site) #f)
          ((oracle-live? name env) #t)
          ((hashtable-ref *oracle-installing* name #f) #f)   ; cycle: leave it
          (else (oracle-install-site! name site env)))))

(define (oracle-install-site! name site env)
  (let ((syntax (top-level-syntax name env))
        (form (if (eq? (vector-ref site 1) 'macro)
                  (vector-ref site 3)
                  (normalize-definition (vector-ref site 2)))))
    (hashtable-set! *oracle-installing* name #t)
    (for-each oracle-install! (oracle-site-deps site))
    (let ((ok? (guard-eval 'ORACLE-INSTALL-FAIL (list name) #f
                 (lambda ()
                   ;; `tm-define' publishes through `(interaction-environment)';
                   ;; keep that inside the module's environment, not the global one.
                   (parameterize ((interaction-environment env))
                     (eval form (interaction-environment)))
                   #t))))
      (hashtable-delete! *oracle-installing* name)
      (when ok?
        (set! *ephemeral-syms* (cons (cons name syntax) *ephemeral-syms*))
        (hashtable-set! *oracle-installed* name #t))
      ok?)))

(define (oracle-bring-in-form! form)
  (for-each oracle-install!
            (if (and (pair? form) (memq (car form) *macro-definers*))
                (or (mc-macro-deps form) '())
                (mc-val-dependencies form oracle-macro? (compilation-environment)))))

(define *eager-gated?*
  (let ((value (getenv "TEXMACS_EAGER_GATE")))
    (not (and value (string=? value "0")))))

;; Expand-time state must stay eager, not just procedures. Skipping these
;; breaks option tables, `define-table' registries consulted during expansion,
;; and group predicates.
(define (needs-eager-eval? form)
  (let ((head (and (pair? form) (car form))))
    (or (not *eager-gated?*)
        (memq head *macro-definers*)
        (memq head '(define-top-level-syntax define-state define-table
                      define-collection extend-table extend-collection
                      smart-table define-group define-table-decls
                      define-collection-decls))
        (and (eq? head 'ahash-set!)
             (pair? (cdr form))
             (eq? (cadr form) 'define-option-table)))))

(oracle-index-tree! *oracle-defs* *progs-dir*)

;; The tiers below are compiled in the order *source-files* was appended, so
;; index n is always the nth module of that list.
(progress-start! (length *source-files*))

;; ---- Module names and paths ----------------------------------------------

(define (mod-name->symbol mod-name)
  (let* ((parts (if (pair? mod-name)
                    (map symbol->string mod-name)
                    (list (symbol->string mod-name))))
         (joined (let loop ((parts parts))
                   (if (null? (cdr parts))
                       (car parts)
                       (string-append (car parts) ":" (loop (cdr parts)))))))
    (string->symbol joined)))

(define (rel-path->mod-name rel-path)
  (let* ((path (strip-scm rel-path))
         (len (string-length path)))
    (let loop ((i 0) (start 0) (parts '()))
      (cond ((= i len)
             (reverse (cons (string->symbol (substring path start i)) parts)))
            ((char=? (string-ref path i) #\/)
             (loop (+ i 1) (+ i 1)
                   (cons (string->symbol (substring path start i)) parts)))
            (else
             (loop (+ i 1) start parts))))))

;; ========================================================
;; Incremental & Selective Compilation Configuration
;; ========================================================

(define (file-newer? f1 f2)
  (and (file-exists? f1)
       (or (not (file-exists? f2))
           (time>? (file-modification-time f1)
                   (file-modification-time f2)))))

(define *recompile-all?*
  (or (and (top-level-bound? '*recompile-all*) *recompile-all?*)
      (env-flag? "TEXMACS_RECOMPILE_ALL")))

(define (module-needs-recompile? rel-path trans-scm out-so)
  (or *recompile-all?*
      (not (file-exists? out-so))
      (not (file-exists? trans-scm))
      (hashtable-ref *dirty-modules* (rel-path->mod-name rel-path) #f)))

(when *recompile-all?*
  (emit-progress-line "mode: recompile from scratch (clean build)"))

(define (ensure-dir path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) (void))
          ((char=? (string-ref path i) #\/)
           (let ((dir (substring path 0 i)))
             (unless (file-exists? dir)
               (system (string-append "mkdir -p \"" dir "\"")))))
          (else (loop (- i 1))))))

(define *definition-heads*
  '(define define-syntax define-public define-public-macro define-module-macro
    define-state provide-public define-macro define-menu define-widget
    define-record-type define-values bib-define-style texmacs-modes
    cas-define-test import export indirect-export))

(define (def-form? form)
  (and (pair? form) (memq (car form) *definition-heads*)))

(define (has-def? form)
  (cond ((def-form? form) #t)
        ((and (pair? form) (eq? (car form) 'begin))
         (exists has-def? (cdr form)))
        (else #f)))

(define (cond-def? form)
  (and (pair? form)
       (case (car form)
         ((if)
          (or (and (pair? (cddr form)) (has-def? (caddr form)))
              (and (pair? (cdddr form)) (has-def? (cadddr form)))))
         ((when unless)
          (and (pair? (cddr form)) (has-def? (cons 'begin (cddr form)))))
         (else #f))))

;; ---- The compiler database ------------------------------------------------

(define module-exports-table (make-eq-hashtable))

;; Database persistence path and previous build's saved database.
(define *compiler-db-file*
  (string-append *boot-dir* "/compiler-db.fasl"))

(define *saved-db*
  (read-compiler-db-or-empty *compiler-db-file*))

;; Digest of a compiled .so artifact for integrity checking.
(define (compute-file-hash path)
  (and (file-exists? path)
       (let ((port (open-file-input-port path)))
         (dynamic-wind
           void
           (lambda ()
             (let ((bytes (get-bytevector-all port)))
               (if (eof-object? bytes) 0 (equal-hash bytes))))
           (lambda () (close-port port))))))

(define (update-compiler-db-artifact! mod-name artifact-hash built-at)
  (let ((info (compiler-db-ref *compiler-db* mod-name)))
    (when info
      (compiler-db-set!
        *compiler-db*
        (make-module-info
          (module-info-name info)
          (module-info-path info)
          (module-info-exports info)
          (module-info-global-values info)
          (module-info-global-macros info)
          (module-info-macro-impls info)
          (module-info-deps info)
          (module-info-compile-uses info)
          (module-info-runtime-uses info)
          (module-info-interface-hash info)
          (module-info-source-hash info)
          artifact-hash
          built-at)))))

;; First pass: read every whitelisted file once and record its interface.
(define *compiler-db*
  (scan-source-files->db *progs-dir* *source-files*))

;; Pre-populate artifact hashes for cached modules from *saved-db* or existing .so
(for-each
  (lambda (info)
    (let* ((name (module-info-name info))
           (old (compiler-db-ref *saved-db* name))
           (out-so (string-append *boot-dir* "/" (scm->so (module-info-path info)))))
      (cond ((and old (module-info-artifact-hash old))
             (update-compiler-db-artifact! name
                                           (module-info-artifact-hash old)
                                           (module-info-built-at old)))
            ((file-exists? out-so)
             (update-compiler-db-artifact! name
                                           (compute-file-hash out-so)
                                           (time-second (current-time)))))))
  (compiler-db-modules *compiler-db*))

;; The graph is built once and shared: the cycle report reads it, and so does
;; every import decision inside transpile-module.
(define *compile-graph* (make-compile-graph-from-db *compiler-db*))

;; Module -> the SCC it belongs to, for cycle members only. Modules outside a
;; cycle are absent, so a lookup returns '() and the test below stays a single
;; list search with no #f sentinel to special-case.
(define *cycle-mates*
  (let ((table (make-hashtable equal-hash equal?)))
    (for-each (lambda (cycle)
                (for-each (lambda (module)
                            (hashtable-set! table module cycle))
                          cycle))
              (compile-graph-cycles *compile-graph*))
    table))

;; `member`, not `memq`: mod-names are lists, and two equal mod-names are not
;; the same object.
(define (cycle-mate? module dependency)
  (member dependency (hashtable-ref *cycle-mates* module '())))

;; ========================================================
;; Incremental Dependency Propagation
;; ========================================================

(define (artifact-changed? old-info out-so)
  (and old-info
       (module-info-artifact-hash old-info)
       (not (equal? (compute-file-hash out-so)
                    (module-info-artifact-hash old-info)))))

(define (source-changed? old-info new-info)
  (and old-info
       new-info
       (module-info-source-hash old-info)
       (module-info-source-hash new-info)
       (not (= (module-info-source-hash old-info)
               (module-info-source-hash new-info)))))

(define (module-directly-changed? rel-path)
  (let* ((trans-scm (boot-path rel-path))
         (out-so (scm->so trans-scm))
         (src (progs-path rel-path))
         (name (rel-path->mod-name rel-path))
         (old-info (compiler-db-ref *saved-db* name))
         (new-info (compiler-db-ref *compiler-db* name)))
    (or ;; Missing outputs
        (not (file-exists? out-so))
        (not (file-exists? trans-scm))
        ;; 1. Artifact integrity against the saved database record
        (artifact-changed? old-info out-so)
        ;; 2. Source content hash (defeats spurious mtime changes from touch/git)
        (source-changed? old-info new-info)
        ;; 3. Filesystem mtime, when database hashes are unavailable
        (file-newer? src out-so)
        (file-newer? trans-scm out-so))))

;; Kernel modules inherit from each other and every downstream tier depends on
;; the texmacs-user snapshot. If any of them is dirty, the whole tree is.
(define (compute-dirty-modules!)
  (define dirty (make-hashtable equal-hash equal?))
  (define queue '())
  (define (mark-dirty! name)
    (unless (hashtable-ref dirty name #f)
      (hashtable-set! dirty name #t)
      (set! queue (cons name queue))))
  (define (mark-rel! rel) (mark-dirty! (rel-path->mod-name rel)))

  (let* ((changed
          (let ((table (make-hashtable equal-hash equal?)))
            (unless *recompile-all?*
              (for-each (lambda (rel)
                          (when (module-directly-changed? rel)
                            (hashtable-set! table (rel-path->mod-name rel) #t)))
                        *source-files*))
            table))
         (kernel-dirty?
          (or *recompile-all?*
              (not (file-exists? (boot-path "texmacs-user.so")))
              (exists (lambda (rel)
                        (hashtable-ref changed (rel-path->mod-name rel) #f))
                      *kernel-files*))))
    (if kernel-dirty?
        (for-each mark-rel! *source-files*)
        (vector-for-each mark-dirty! (hashtable-keys changed)))

    ;; Transitive successor propagation via compile-graph.
    (let ((dependents (compile-graph-dependents *compile-graph*)))
      (let propagate ()
        (unless (null? queue)
          (let ((module (car queue)))
            (set! queue (cdr queue))
            (for-each mark-dirty! (hashtable-ref dependents module '()))
            (propagate)))))
    (values dirty kernel-dirty?)))

(define-values (*dirty-modules* *any-kernel-dirty?*)
  (compute-dirty-modules!))

;; ========================================================
;; Dependency graph report (TEXMACS_COMPILE_GRAPH=1)
;; ========================================================

(define (report-tier full title files)
  (let* ((graph (compile-graph-subgraph full (map rel-path->mod-name files)))
         (waves (compile-graph-waves graph))
         (cycles (compile-graph-cycles graph)))
    (format #t "  ~a: ~a modules, ~a waves ~a, ~a cycles~n"
            title (length (compile-graph-nodes graph))
            (length waves) (map length waves) (length cycles))
    (for-each (lambda (cycle) (format #t "      cycle ~s~n" cycle)) cycles)))

(define (report-compile-graph)
  (let ((full *compile-graph*))
    (format #t "~%Dependency graph~%")
    (format #t "========================================================~%")
    (for-each (lambda (tier)
                (report-tier full
                             (inventory-tier-name tier)
                             (inventory-tier-files tier)))
              inventory-tiers)
    (let ((waves (compile-graph-waves full)))
      (format #t "--------------------------------------------------------~%")
      (format #t "  whole tree: ~a modules, ~a waves ~a~%"
              (length (compile-graph-nodes full))
              (length waves) (map length waves))
      (format #t "  macro-defining modules: ~a~%"
              (length (compile-graph-macro-nodes full)))
      (format #t "  cycles: ~a~%" (length (compile-graph-cycles full)))
      (format #t "========================================================~%"))))

(when (env-flag? "TEXMACS_COMPILE_GRAPH")
  (report-compile-graph)
  (exit 0))

;; ---- Exports --------------------------------------------------------------

;; Seed the export table from the database. Every module the build can ask
;; about already has its public names recorded, so no transpiled file is ever
;; opened again to find out what a module exports.
(for-each
  (lambda (info)
    (hashtable-set! module-exports-table
                    (mod-name->symbol (module-info-name info))
                    (module-info-exports info)))
  (compiler-db-modules *compiler-db*))

;; A module transpiled in this run overwrites its own entry with the exact
;; export list it emitted; everything else is answered from the database.
(define (get-module-exports mod-sym)
  (or (hashtable-ref module-exports-table mod-sym #f)
      (begin
        (log-note (format "exports unknown for ~a" mod-sym))
        (hashtable-set! module-exports-table mod-sym '())
        '())))

(define (publish-global! name value)
  (define-top-level-value name value)
  (define-top-level-value name value (interaction-environment)))

(publish-global! 'module-exports-table module-exports-table)
(publish-global! 'get-module-exports get-module-exports)

;; ---- Keywords and definition rewriting -----------------------------------

(define (tm-collect-keywords form acc)
  (cond ((and (symbol? form)
              (string-prefix? ":" (symbol->string form)))
         (if (member form acc) acc (cons form acc)))
        ((pair? form)
         (tm-collect-keywords (cdr form)
                              (tm-collect-keywords (car form) acc)))
        (else acc)))

(define (tm-bind-keywords form)
  (for-each
    (lambda (keyword)
      (for-each (lambda (env)
                  (unless (top-level-bound? keyword env)
                    (define-top-level-value keyword keyword env)))
                (list (compilation-environment) (interaction-environment))))
    (tm-collect-keywords form '())))

(define (condition-text condition)
  (if (condition? condition)
      (with-output-to-string (lambda () (display-condition condition)))
      condition))

(define (eval-in-compile! form . opt-message)
  (let ((message (if (pair? opt-message) (car opt-message) 'FAILED-EVAL)))
    (guard-eval message (list form) #f
      (lambda ()
        (parameterize ((interaction-environment (compilation-environment)))
          (eval form (interaction-environment)))))))

;; The symbol a definition form introduces:
;;   (tm-define (foo x) ...)              -> foo
;;   (tm-define foo ...)                  -> foo
;;   (define-table foo ...)               -> foo
;;   (define-top-level-syntax 'foo proc)  -> foo   (the argument is quoted)
(define (defined-name form)
  (let ((head (cadr form)))
    (if (and (pair? head) (eq? (car head) 'quote))
        (cadr head)
        (mc-leftmost-symbol head))))

(define (eval-eager-form! form)
  (let ((head (and (pair? form) (car form))))
    (cond
      ((memq head '(define define-public provide-public define-module-macro
                    define-macro define-public-macro
                    define-state tm-define tm-define-macro define-group
                    define-table define-collection extend-table
                    extend-collection smart-table
                    define-table-decls define-collection-decls
                    define-top-level-syntax))
       (eval-in-compile! form))

      ((and (eq? head 'ahash-set!)
            (pair? (cdr form))
            (eq? (cadr form) 'define-option-table))
       (eval-in-compile! form))

      (else #f))))

;; ---- Form preparation -----------------------------------------------------

(define (tm-internal-name? name)
  (string-prefix? "_tm_def_" (symbol->string name)))

(define (add-name name names)
  (if (and (symbol? name)
           (not (keyword? name))
           (not (tm-internal-name? name))
           (not (memq name names)))
      (cons name names)
      names))

(define (cpp-alias? form)
  (and (eq? (car form) 'define)
       (symbol? (cadr form))
       (pair? (cddr form))
       (symbol? (caddr form))
       (string=? (symbol->string (cadr form))
                 (string-append "cpp-" (symbol->string (caddr form))))))

(define (branch-forms branch)
  (cond ((not branch) '())
        ((and (pair? branch) (eq? (car branch) 'begin)) (cdr branch))
        (else (list branch))))

(define (transpile-conditional form)
  (let* ((kind (car form))
         (test (if (eq? kind 'unless) `(not ,(cadr form)) (cadr form)))
         (then (if (memq kind '(when unless))
                   (cons 'begin (cddr form))
                   (caddr form)))
         (else-branch (and (eq? kind 'if)
                           (pair? (cdddr form))
                           (cadddr form)))
         (value (guard-eval #f '() 'eval-error
                  (lambda () (eval test (compilation-environment))))))
    (if (eq? value 'eval-error)
        (values #f '())
        (values #t (branch-forms (if value then else-branch))))))

;; Return the prepared forms, the public names, and every local definition,
;; all in source order. The old version kept the last two in globals and
;; re-read them between modules.
(define (prepare-forms forms)
  (let loop ((rest forms) (out '()) (public '()) (local '()))
    (cond
      ((null? rest)
       (values (reverse out) (reverse public) (reverse local)))
      ((not (car rest))
       (loop (cdr rest) out public local))
      ((not (pair? (car rest)))
       (loop (cdr rest) (cons (car rest) out) public local))
      (else
       (let ((form (car rest)))
         (case (car form)
           ((begin)
            (loop (append (cdr form) (cdr rest)) out public local))

           ((tm-define tm-define-macro lazy-define define-group define-table
             define-collection extend-table extend-collection tm-property
             define-preferences define-top-level-syntax)
            (loop (cdr rest) (cons form out) public local))

           ((define)
            (if (cpp-alias? form)
                (loop (cdr rest)
                      (cons `(define ,(cadr form)
                               (top-level-value ',(caddr form)))
                            out)
                      public local)
                (let ((normalized (normalize-definition form)))
                  (loop (cdr rest) (cons normalized out)
                        public
                        (add-name (defined-name normalized) local)))))

           ((define-public provide-public define-menu define-widget)
            (let* ((normalized (normalize-definition form))
                   (name (defined-name normalized)))
              (loop (cdr rest) (cons normalized out)
                    (if (memq (car form) '(define-public provide-public))
                        (add-name name public)
                        public)
                    (add-name name local))))

           ((define-macro define-public-macro define-module-macro)
            (let ((name (defined-name form)))
              (loop (cdr rest) (cons form out)
                    (if (memq (car form) '(define-public-macro define-module-macro))
                        (add-name name public)
                        public)
                    (add-name name local))))

           ((export)
            (loop (cdr rest) out
                  (fold-left (lambda (acc name) (add-name name acc))
                             public (cdr form))
                  local))

           ((define-syntax)
            (loop (cdr rest) (cons form out)
                  public
                  (add-name (cadr form) local)))

           ((bib-define-style)
            (let* ((style (cadr form))
                   (predicate (string->symbol (string-append "bib-" style "?"))))
              (loop (cdr rest) (cons form out)
                    (add-name predicate public)
                    (add-name predicate local))))

           ((cas-define-test)
            (let* ((name (cadr form))
                   (table (string->symbol
                            (string-append (symbol->string name) "-table")))
                   (predicate (string->symbol
                                (string-append (symbol->string name) "?"))))
              (loop (cdr rest) (cons form out)
                    public
                    (add-name predicate (add-name table local)))))

           ((define-export-macro)
            (loop (cons (cons 'define-public-macro (cdr form)) (cdr rest))
                  out public local))

           ;; R6RS forbids `import' inside expression contexts, so in-body
           ;; module declarations become runtime `module-provide' calls.
           ((use-modules inherit-modules)
            (loop (append (map (lambda (module) `(module-provide ',module))
                               (cdr form))
                          (cdr rest))
                  out public local))

           (else
            (if (cond-def? form)
                (let-values (((handled? forms) (transpile-conditional form)))
                  (if handled?
                      (loop (append forms (cdr rest)) out public local)
                      (loop (cdr rest) (cons form out) public local)))
                (loop (cdr rest) (cons form out) public local)))))))))

;; Linter: detect potential mid-load mutation hazards where a top-level
;; non-procedure definition follows an expression that mutates state, risking
;; R6RS hoisting anomalies.
(define (check-mid-load-hazards forms mod-name)
  (define (warn-hazard! value name mutated)
    (cond ((symbol? value)
           (when (memq value mutated)
             (log-note (format "warning: ~a defines ~a before ~a is set"
                               mod-name name value))))
          ((pair? value)
           (warn-hazard! (car value) name mutated)
           (warn-hazard! (cdr value) name mutated))))

  (let loop ((rest forms) (mutated '()))
    (unless (null? rest)
      (let ((form (car rest)))
        (cond
          ((and (pair? form)
                (memq (car form) '(set! ahash-set!))
                (pair? (cdr form))
                (symbol? (cadr form)))
           (loop (cdr rest) (cons (cadr form) mutated)))
          ((def-form? form)
           (when (and (pair? (cdr form))
                      (symbol? (cadr form))
                      (pair? (cddr form)))
             (let ((value (caddr form)))
               (unless (and (pair? value) (eq? (car value) 'lambda))
                 (warn-hazard! value (cadr form) mutated))))
           (loop (cdr rest) mutated))
          (else
           (loop (cdr rest) mutated)))))))

;; ---- Transpilation --------------------------------------------------------

(define compiled-modules '())
(define compile-errors '())

(define (module-header forms)
  (and (pair? forms)
       (pair? (car forms))
       (eq? (caar forms) 'texmacs-module)
       (car forms)))

(define (import-declared-deps! deps)
  (for-each
    (lambda (dependency)
      (let ((module (mod-name->symbol dependency)))
        (when (memq module compiled-modules)
          (eval-in-compile! `(import (for ,module run expand))))))
    deps))

(define (module-link-forms mod-name deps options public local)
  (define imports '())
  (define exports (if (null? public) '() (list `(export ,@public))))
  (define imported '())

  ;; Import one dependency's exports, minus any name that would collide with a
  ;; local definition or with an earlier import.
  (define (use-module! module)
    (let* ((names (get-module-exports module))
           (clash (filter (lambda (name)
                            (or (memq name local) (memq name imported)))
                          names))
           (kept (filter (lambda (name) (not (memq name clash))) names)))
      (set! imports
            (cons (if (null? clash)
                      `(import (for ,module run expand))
                      `(import (for (except ,module ,@clash) run expand)))
                  imports))
      (set! imported (append kept imported))))

  (define (inherit-module! module)
    (set! imports (cons `(import (for ,module run expand)) imports))
    (set! exports (cons `(export (import ,module)) exports)))

  ;; A dependency that is not compiled yet falls back to a runtime
  ;; module-provide lookup. Say which kind it is: a real cycle, or merely a
  ;; later position in the tier order.
  (define (note-deferred! dependency)
    (let ((module (mod-name->symbol dependency)))
      (log-note (format (if (cycle-mate? mod-name dependency)
                            "cycle back-edge: ~a -> ~a (runtime module-provide)"
                            "deferred forward import: ~a -> ~a (acyclic)")
                        (mod-name->symbol mod-name)
                        module))))

  (for-each
    (lambda (option)
      (when (and (pair? option) (memq (car option) '(:use :inherit)))
        (for-each (lambda (dependency)
                    (let ((module (mod-name->symbol dependency)))
                      (cond ((not (memq module compiled-modules))
                             (note-deferred! dependency))
                            ((eq? (car option) ':use)
                             (use-module! module))
                            (else
                             (inherit-module! module)))))
                  (cdr option))))
    options)

  (values (reverse imports) (reverse exports)))

(define (keyword-definitions forms)
  (map (lambda (keyword) `(define ,keyword ',keyword))
       (tm-collect-keywords forms '())))

(define (eval-eager-forms! forms)
  (parameterize ((compile-export-mode? #f))
    (for-each (lambda (form)
                (when (needs-eager-eval? form)
                  (when *eager-gated?* (oracle-bring-in-form! form))
                  (eval-eager-form! form)))
              forms)))

(define (write-module-file out-path rel-path mod-sym imports exports keywords
                           definitions dep-provides expressions)
  (call-with-output-file out-path
    (lambda (port)
      (format port ";;; Auto-generated native Chez Scheme module from ~a~%"
              rel-path)
      (write `(module ,mod-sym ()
                ,@imports
                ,@exports
                ,@keywords
                ,@definitions
                ,@dep-provides
                ,@expressions)
             port)
      (newline port))
    'replace))

(define (transpile-module rel-path out-path)
  (guard (e (else
              (log-progress "FAILED" rel-path)
              (log-note (condition-text e))
              (set! compile-errors (cons (cons rel-path e) compile-errors))
              #f))
    (let* ((forms (read-all-forms (progs-path rel-path)))
           (header (module-header forms)))
      (tm-bind-keywords forms)
      (ensure-dir out-path)
      (and header
           (let* ((mod-name (cadr header))
                  (mod-sym (mod-name->symbol mod-name))
                  (options (cddr header))
                  ;; Every whitelisted module was scanned into the database, so
                  ;; a miss means the scan and this loop disagree about the file.
                  (info (or (compiler-db-ref *compiler-db* mod-name)
                            (error 'transpile-module
                                   "no compiler-db record for module" mod-name)))
                  (deps (module-info-deps info)))

             ;; Declared dependencies are imported into the eager-evaluation
             ;; environment before any form is prepared.
             (import-declared-deps! deps)

             (let-values (((prepared public local)
                           (prepare-forms (cdr forms))))
               (check-mid-load-hazards prepared rel-path)
               (let-values (((imports exports)
                             (module-link-forms mod-name deps options public local)))
                 (hashtable-set! module-exports-table mod-sym public)
                 (eval-eager-forms! prepared)
                 (let-values (((definitions expressions)
                               (partition def-form? prepared)))
                   (write-module-file
                     out-path rel-path mod-sym
                     imports exports
                     (keyword-definitions forms)
                     definitions
                     (map (lambda (dep) `(module-provide ',dep)) deps)
                     expressions))
                 mod-sym)))))))

;; ---- Compilation ----------------------------------------------------------

(define (compile-transpiled-module! rel-path trans-scm out-so mod-sym)
  (dynamic-wind
    void
    (lambda ()
      (parameterize ((compile-export-mode? #t))
        (compile-file trans-scm out-so))
      (let ((hash (compute-file-hash out-so)))
        (when hash
          (update-compiler-db-artifact! (rel-path->mod-name rel-path)
                                        hash
                                        (time-second (current-time)))))
      mod-sym)
    (lambda ()
      (for-each (lambda (entry)
                  (unbind-symbol! entry (interaction-environment))
                  (hashtable-delete! *oracle-installed* (car entry)))
                *ephemeral-syms*)
      (set! *ephemeral-syms* '()))))

(define (report-compile-failure! rel-path condition)
  (log-progress "FAILED" rel-path)
  (emit-progress-line (condition-text condition))
  (when (who-condition? condition)
    (log-note (format "who: ~a" (condition-who condition))))
  (when (irritants-condition? condition)
    (log-note (format "irritants: ~s" (condition-irritants condition))))
  (when (syntax-violation? condition)
    (log-note (format "form: ~s" (syntax-violation-form condition)))
    (log-note (format "subform: ~s" (syntax-violation-subform condition))))
  (when (top-level-bound? 'tm-backtrace)
    (tm-backtrace condition))
  (set! compile-errors (cons (cons rel-path condition) compile-errors)))

(define (transpile-and-compile-module rel-path trans-scm out-so)
  (let ((mod-sym (transpile-module rel-path trans-scm)))
    (and mod-sym
         (begin
           ;; Emitted only once the module is known to be buildable, so a file
           ;; without a header reports `Skipped' alone and a transpile error
           ;; reports `FAILED' alone -- one line per module either way.
           (log-progress "Compiling"
                         (string-append rel-path " -> " (path-basename out-so)))
           (call/cc
             (lambda (escape)
               (with-exception-handler
                 (lambda (condition)
                   (when (serious-condition? condition)
                     (report-compile-failure! rel-path condition)
                     (escape #f)))
                 (lambda ()
                   (compile-transpiled-module!
                     rel-path trans-scm out-so mod-sym)))))))))

(define compiled-count 0)
(define cached-count 0)

(define (save-module-deps-manifest!)
  (let ((manifest-file (string-append *boot-dir* "/module-deps.scm")))
    (log-progress-pct "Writing"
                      (string-append "module dependency manifest " manifest-file))
    (call-with-output-file manifest-file
      (lambda (port)
        (write (map (lambda (info)
                      (list (module-info-name info)
                            (module-info-deps info)))
                    (compiler-db-modules *compiler-db*))
               port)
        (newline port))
      'replace)))

(define (load-compiled-module! rel-path out-so mod-sym mod-name)
  (hashtable-set! *texmacs-modules-loaded* mod-name #t)
  (guard (e (else
              (hashtable-delete! *texmacs-modules-loaded* mod-name)
              (log-progress "FAILED" rel-path)
              (log-note (condition-text e))
              (when (file-exists? out-so) (delete-file out-so))
              (set! compile-errors (cons (cons rel-path e) compile-errors))
              #f))
    (load out-so)
    (when (member rel-path *kernel-files*)
      (guard-eval 'IMPORT-FAIL (list mod-sym) #f
        (lambda ()
          (eval `(import ,mod-sym) (interaction-environment)))))
    #t))

(define (register-module-loaded! rel-path out-so mod-sym is-cached?)
  (let ((mod-name (rel-path->mod-name rel-path)))
    (unless (compiler-db-ref *compiler-db* mod-name)
      (error 'register-module-loaded!
             "no compiler-db record for module" rel-path mod-name))
    (when (load-compiled-module! rel-path out-so mod-sym mod-name)
      (set! compiled-modules (cons mod-sym compiled-modules))
      (if is-cached?
          (begin
            (set! cached-count (+ cached-count 1))
            (log-progress "Up-to-date" rel-path))
          ;; A recompiled module already reported itself as `Compiling`; the
          ;; successful load adds no second line for the same index.
          (set! compiled-count (+ compiled-count 1))))))

(define (compile-module-list tier-title file-list)
  (emit-progress-line (string-append "-- " tier-title " --"))
  (for-each
    (lambda (rel-path)
      (progress-tick!)
      (let* ((trans-scm (boot-path rel-path))
             (out-so (scm->so trans-scm))
             (needs-build? (module-needs-recompile? rel-path trans-scm out-so)))
        (if needs-build?
            (let ((mod-sym (transpile-and-compile-module rel-path trans-scm out-so)))
              (cond (mod-sym
                     (parameterize ((compile-export-mode? #t))
                       (register-module-loaded! rel-path out-so mod-sym #f)))
                    ;; Every real failure was already reported by the transpile
                    ;; or load handler; what is left is a file without a
                    ;; `texmacs-module' header.
                    ((not (assoc rel-path compile-errors))
                     (log-progress
                       "Skipped"
                       (string-append rel-path " (no texmacs-module header)")))))
            (parameterize ((compile-export-mode? #t))
              (register-module-loaded!
                rel-path out-so
                (mod-name->symbol (rel-path->mod-name rel-path))
                #t)))))
    file-list))

;; One tier is one compile-module-list call: the banner and the file list both
;; come from the inventory row, so the driver never names a tier twice.
(define (compile-tier! tier)
  (compile-module-list (inventory-tier-title tier) (inventory-tier-files tier)))

;; ---- Kernel snapshot and final report ------------------------------------

(define (write-line port object)
  (write object port)
  (newline port))

(define (write-kernel-snapshot! user-scm)
  (call-with-output-file user-scm
    (lambda (port)
      (display ";;; Aggregate texmacs-user and texmacs-user-kernel\n" port)
      (for-each (lambda (rel)
                  (write-line port `(primitive-load ,(scm->so (boot-path rel)))))
                *kernel-files*)
      (let* ((modules (map (lambda (rel)
                             (mod-name->symbol (rel-path->mod-name rel)))
                           *kernel-files*))
             (imports (map (lambda (module)
                             `(import (for ,module run expand)))
                           modules))
             (exports (map (lambda (module)
                             `(export (import ,module)))
                           modules)))
        (write-line port `(module texmacs-user ()
                            ,@imports
                            ,@exports))
        (write-line port `(module texmacs-user-kernel ()
                            (export (import texmacs-user))))
        (write-line port `(import texmacs-user-kernel))
        (for-each (lambda (module) (write-line port `(import ,module)))
                  modules))
      ;; The module forms above bind these names to modules, and a module
      ;; binding is not a value. Rebind them to the single environment that
      ;; user space means everywhere else.
      (write-line port `(define-top-level-value 'texmacs-user
                         (interaction-environment)))
      (write-line port `(define-top-level-value 'texmacs-user-kernel
                         (interaction-environment))))
    'replace))

(define (build-kernel-snapshot!)
  (let* ((user-scm (boot-path "texmacs-user.scm"))
         (user-so (boot-path "texmacs-user.so")))
    (if (and (file-exists? user-so)
             (not *recompile-all?*)
             (not *any-kernel-dirty?*))
        (begin
          (log-progress-pct "Up-to-date" "texmacs-user.so (kernel snapshot)")
          (load user-so))
        (begin
          (log-progress-pct "Building"
                            "aggregate kernel snapshot texmacs-user.so")
          (write-kernel-snapshot! user-scm)
          (compile-file user-scm user-so)
          (load user-so)
          (log-progress-pct "Verified" "texmacs-user.so")))))

(define (plural-suffix n)
  (if (= n 1) "" "s"))

(define (report-build-summary!)
  (newline)
  (display "========================================================\n")
  (if (null? compile-errors)
      (begin
        (display "[100%] Built target texmacs-chez-modules:\n")
        (format #t "  - Recompiled: ~a module~a\n"
                compiled-count (plural-suffix compiled-count))
        (format #t "  - Up-to-date (cached): ~a module~a\n"
                cached-count (plural-suffix cached-count))
        (format #t "  - Failures: ~a\n" (length compile-errors))
        (for-each (lambda (error)
                    (format #t "    * FAILED: ~a\n" (car error)))
                  (reverse compile-errors)))
      (begin
        (format #t "[FAILED] Built target texmacs-chez-modules: ~a failure(s)\n"
                (length compile-errors))
        (for-each (lambda (error)
                    (format #t "  - ~a\n" (car error)))
                  compile-errors)))
  (display "========================================================\n"))

;; ---- Main -----------------------------------------------------------------

;; Tier 1 runs unconditionally: the kernel snapshot and every later tier depend
;; on it, and its failures abort the rest of the build below.
(compile-tier! (car inventory-tiers))

(unless (pair? compile-errors)
  (build-kernel-snapshot!)
  (for-each compile-tier! (cdr inventory-tiers))
  (save-module-deps-manifest!)
  (write-compiler-db *compiler-db* *compiler-db-file*))

(report-build-summary!)

(when (and (top-level-bound? 'quit-TeXmacs)
           (not (top-level-bound? '*dont-quit*)))
  (quit-TeXmacs))
