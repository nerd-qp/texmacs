;;; TODO: UNDER REVIEWED AI GENERATED CODE.
;;;
;;; compile-texmacs.scm -- Transpiles and compiles all TeXmacs modules into native Chez Scheme modules
;;;
;;; Usage:
;;;  ENV=??? TeXmacs --compile-modules

(define-top-level-value 'texmacs-chez-compiling? #t)
(define-top-level-value 'boot-kernel-loaded? #t)

(define tm-load-file (if (top-level-bound? 'tm-load-file) tm-load-file load))
(define texmacs-time (if (top-level-bound? 'texmacs-time) texmacs-time (lambda () 0)))
(define os-win32? (if (top-level-bound? 'os-win32?) os-win32? (lambda () #f)))
(define developer-mode? (if (top-level-bound? 'developer-mode?) developer-mode? #f))
(define native-load
  (lambda (path)
    (load path (lambda (x) (eval x (interaction-environment))))))

(define *progs-dir*
  (cond ((and (getenv "TEXMACS_PATH") (file-exists? (string-append (getenv "TEXMACS_PATH") "/progs")))
         (string-append (getenv "TEXMACS_PATH") "/progs"))
        ((file-exists? "TeXmacs/progs") "TeXmacs/progs")
        ((file-exists? "texmacs/TeXmacs/progs") "texmacs/TeXmacs/progs")
        (else "TeXmacs/progs")))

;; Where transpiled sources and compiled modules are written.
;;
;; TEXMACS_BOOT_PATH takes precedence, mirroring how boot-chez.scm resolves
;; compiled modules at runtime, so that build trees with another name (for
;; instance build-win) work without editing this file. The literals below are
;; the historical default.
(define *boot-dir*
  (cond ((getenv "TEXMACS_BOOT_PATH") (getenv "TEXMACS_BOOT_PATH"))
        ((file-exists? "build-texmacos/boot") "build-texmacos/boot")
        ((file-exists? "texmacs/build-texmacos/boot") "texmacs/build-texmacos/boot")
        ((file-exists? "../build-texmacos/boot") "../build-texmacos/boot")
        (else "build-texmacos/boot")))

(unless (top-level-bound? 'boot-chez-loaded?)
  (load (string-append *progs-dir* "/kernel/boot/boot-chez.scm")))

(define *compiler-dir*
  (cond ((file-exists? "compiler-db.scm") ".")
        ((file-exists? "src/Scheme/Chez/compiler-db.scm") "src/Scheme/Chez")
        ((file-exists? "texmacs/src/Scheme/Chez/compiler-db.scm") "texmacs/src/Scheme/Chez")
        (else
         (error 'compile-texmacs "cannot find compiler-db.scm"))))

(primitive-load (string-append *compiler-dir* "/compiler-db.scm"))
(import (compiler-db))
(primitive-load (string-append *compiler-dir* "/compiler-scan.scm"))
(import (compiler-scan))
(primitive-load (string-append *compiler-dir* "/compile-graph.scm"))
(import (compile-graph))
;; Progress reporting lives in a library rather than here: it imports
;; (chezscheme) explicitly, so its procedures do not depend on what the boot
;; script left bound in the environment this file is exec'd into.
(primitive-load (string-append *compiler-dir* "/compiler-progress.scm"))
(import (compiler-progress))

(unless (top-level-bound? 'compilation-environment)
  (define-top-level-value 'compilation-environment
    (make-parameter (interaction-environment))))

;; The module whitelist lives in its own library: the linters and the tests
;; need the same seven lists, and re-reading this file to eval its `define`
;; forms was the only way to get them. Loading the file here, rather than
;; letting `import` search the default library path, keeps the driver working
;; when it is exec'd from the build directory instead of the source tree.
(primitive-load (string-append *compiler-dir* "/compile-inventory.scm"))
(import (compile-inventory))

;; ---- gated eager evaluation + on-demand install of expand-time helpers ---
;; Plain value definitions are left to `compile-file'; the definitions that
;; must be live while a macro expands are installed on demand into the
;; module's own compilation environment.  Set TEXMACS_EAGER_GATE=0 to get the
;; original behaviour back.
(primitive-load (string-append *compiler-dir* "/macro-closure.scm"))

(define *oracle-defs* (make-eq-hashtable))
(define *oracle-installing* (make-eq-hashtable))
(define *oracle-installed* (make-eq-hashtable))

(define (oracle-index-tree! defs root)
  (define macro-definers
    '(define-syntax define-macro define-public-macro define-module-macro
      define-export-macro tm-define-macro))
  (define value-definers '(define define-public provide-public tm-define))
  (define (walk-files dir)
    (let loop ((rel "") (acc '()))
      (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
        (if (file-directory? full)
            (fold-left (lambda (a n)
                         (if (member n '("." "..")) a
                             (loop (if (string=? rel "") n (string-append rel "/" n)) a)))
                       acc (directory-list full))
            (if (and (> (string-length rel) 4)
                     (string=? (substring rel (- (string-length rel) 4) (string-length rel)) ".scm"))
                (cons rel acc) acc)))))
  (define (index-top! top rel mod)
    ;; only definitions a top-level context can hold: the form itself, or a
    ;; definition under a top-level begin/if/when/unless wrapper.
    (define (walk x at-top?)
      (cond
        ((not (pair? x)) (void))
        ((memq (car x) '(quote syntax syntax-rules quasiquote)) (void))
        ((and at-top? (symbol? (car x))
              (or (memq (car x) macro-definers) (memq (car x) value-definers))
              (pair? (cdr x)))
         (let ((n (mc-leftmost-symbol (mc-cadr x))))
           (when (symbol? n)
             (unless (hashtable-ref defs n #f)
               (hashtable-set! defs n
                 (vector n (if (memq (car x) macro-definers) 'macro 'value)
                         x top rel mod))))))
        ((and at-top? (memq (car x) '(begin if when unless)))
         (for-each (lambda (y) (walk y #t)) (cdr x)))
        (else (void))))
    (walk top #t))
  (for-each
    (lambda (rel)
      (let ((forms (guard (e (else '()))
                     (call-with-input-file
                         (string-append root "/" rel)
                       (lambda (p)
                         (let lp ((a '()))
                           (let ((x (read p)))
                             (if (eof-object? x) (reverse a) (lp (cons x a))))))))))
        (let ((hdr (find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module))) forms)))
          (when hdr
            (for-each (lambda (top) (index-top! top rel (mc-cadr hdr))) forms)))))
    (walk-files root)))

;; A name is live if it holds a value or a working syntax binding.  Neither
;; primitive answers this alone: `top-level-bound?' is #f for a macro, and
;; `top-level-syntax?' is #t for symbols that were never defined.
(define (oracle-live? name env)
  (or (top-level-bound? name env)
      (guard (e (else #f)) (procedure? (top-level-syntax name env)))
      (hashtable-ref *oracle-installed* name #f)))

(define *ephemeral-syms* '())

(define (unbound-marker)
  (guard (e (else (void)))
    (#%$unbound-object)))

(define (unbind-symbol! entry env)
  (let ((sym (car entry))
        (orig-syntax (cdr entry)))
    (when (top-level-bound? sym env)
      (define-top-level-value sym (unbound-marker) env))
    (define-top-level-syntax sym orig-syntax env)))

(define (oracle-site-deps site)
  (let* ((top (vector-ref site 3))
         (inner (vector-ref site 2))
         (head (and (pair? top) (car top))))
    (append (if (and (symbol? head) (hashtable-ref *oracle-defs* head #f)) (list head) '())
            (if (eq? (vector-ref site 1) 'macro)
                (or (mc-macro-deps inner) '())
                (mc-free-names top)))))

;; Install NAME into the current compilation environment, dependencies first.
;; The two rewrite steps matter: the sources contain curried definitions and
;; docstrings, which `define' rejects when evaluated raw.
(define (oracle-install! name)
  (let ((env (compilation-environment))
        (site (and (symbol? name) (hashtable-ref *oracle-defs* name #f))))
    (cond
      ((not (symbol? name)) #f)
      ((oracle-live? name env) #t)
      ((hashtable-ref *oracle-installing* name #f) #f)   ; cycle: leave it
      ((not site) #f)
      (else
       (let* ((orig-syntax (top-level-syntax name env)))
         (hashtable-set! *oracle-installing* name #t)
         (for-each oracle-install! (oracle-site-deps site))
         (let ((form (if (eq? (vector-ref site 1) 'macro)
                         (vector-ref site 3)
                         (tm-strip-docstring (tm-maybe-uncurry (vector-ref site 2))))))
           (let ((ok? (guard-eval 'ORACLE-INSTALL-FAIL (list name) #f
                        (lambda ()
                          ;; `tm-define' publishes through
                          ;; `(interaction-environment)'; keep that inside the
                          ;; module's environment, not the global one.
                          (parameterize ((interaction-environment env))
                            (eval form (interaction-environment)))
                          #t))))
             (hashtable-delete! *oracle-installing* name)
             (when ok?
               (set! *ephemeral-syms* (cons (cons name orig-syntax) *ephemeral-syms*))
               (hashtable-set! *oracle-installed* name #t))
             ok?)))))))

;; A macro definer hides its body from `mc-free-names' (a template is not a
;; use), so its dependencies come from `mc-macro-deps' instead.
(define (oracle-bring-in-form! form)
  (let ((head (and (pair? form) (car form))))
    (for-each oracle-install!
              (if (memq head '(define-syntax define-macro define-public-macro
                               define-module-macro define-export-macro
                               tm-define-macro))
                  (or (mc-macro-deps form) '())
                  (mc-free-names form)))))

;; What must stay eager: everything that is *expand-time state*, not just a
;; procedure.  Skipping these breaks option tables, `define-table' registries
;; consulted during expansion, and group predicates.
(define (eager-skip? x)
  (let ((head (and (pair? x) (car x))))
    (not (or (memq head '(define-syntax define-macro define-public-macro
                          define-module-macro define-export-macro tm-define-macro
                          define-top-level-syntax define-state define-table
                          define-collection extend-table extend-collection
                          smart-table define-group
                          define-table-decls define-collection-decls))
             (and (eq? head 'ahash-set!) (pair? (cdr x))
                  (eq? (cadr x) 'define-option-table))))))

(define *eager-gated?*
  (let ((v (getenv "TEXMACS_EAGER_GATE")))
    (not (and v (string=? v "0")))))

(oracle-index-tree! *oracle-defs* *progs-dir*)

;; The tiers below are compiled in the order *source-files* was appended, so
;; index n is always the nth module of that list.
(progress-start! (length *source-files*))

(define (mod-name->symbol mod-name)
  (let* ((parts (if (pair? mod-name)
                    (map symbol->string mod-name)
                    (list (symbol->string mod-name))))
         (joined (let loop ((p parts))
                   (if (null? (cdr p))
                       (car p)
                       (string-append (car p) ":" (loop (cdr p)))))))
    (string->symbol joined)))

(define (rel-path->mod-name rel-path)
  (let* ((without-ext (if (and (>= (string-length rel-path) 4)
                               (string=? (substring rel-path (- (string-length rel-path) 4) (string-length rel-path)) ".scm"))
                          (substring rel-path 0 (- (string-length rel-path) 4))
                          rel-path))
         (len (string-length without-ext)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
        ((= i len)
         (reverse (cons (string->symbol (substring without-ext start i)) acc)))
        ((char=? (string-ref without-ext i) #\/)
         (loop (+ i 1) (+ i 1) (cons (string->symbol (substring without-ext start i)) acc)))
        (else
         (loop (+ i 1) start acc))))))

;; ========================================================
;; Incremental & Selective Compilation Configuration
;; ========================================================

(define (file-newer? f1 f2)
  (and (file-exists? f1)
       (or (not (file-exists? f2))
           (time>? (file-modification-time f1)
                   (file-modification-time f2)))))

(define (tm-macroify-cp head)
  (if (pair? head)
      (cons (tm-macroify-cp (car head)) (cdr head))
      (string->symbol (string-append (symbol->string head) "$impl"))))

(define *recompile-all?*
  (or (and (top-level-bound? '*recompile-all*) *recompile-all?*)
      (let ((v (getenv "TEXMACS_RECOMPILE_ALL")))
        (and v (not (string=? v "")) (not (string=? v "0"))))))

(define (module-needs-recompile? rel-path trans-scm out-so)
  (cond
    (*recompile-all?* #t)
    ((not (file-exists? out-so)) #t)
    ((not (file-exists? trans-scm)) #t)
    (else
     (let ((src (string-append *progs-dir* "/" rel-path)))
       (or (file-newer? src out-so)
           (file-newer? trans-scm out-so))))))

(when *recompile-all?*
  (emit-progress-line "mode: recompile from scratch (clean build)"))

(define (ensure-dir path)
  (let loop ((i (- (string-length path) 1)))
    (when (>= i 0)
      (if (char=? (string-ref path i) #\/)
          (let ((dir (substring path 0 i)))
            (unless (file-exists? dir)
              (system (string-append "mkdir -p \"" dir "\""))))
          (loop (- i 1))))))

(define (def-form? x)
  (and (pair? x)
       (memq (car x) '(define define-syntax
                       define-public define-public-macro
                       define-module-macro
                       define-state
                       provide-public
                       define-macro
                       define-menu
                       define-widget
                       define-record-type
                       define-values
                       bib-define-style
                       texmacs-modes
                       cas-define-test
                       import export indirect-export))))

(define (has-def? x)
  (cond
    ((def-form? x) #t)
    ((and (pair? x) (eq? (car x) 'begin))
     (let loop ((forms (cdr x)))
       (and (pair? forms)
            (or (has-def? (car forms))
                (loop (cdr forms))))))
    (else #f)))

(define (cond-def? x)
  (and (pair? x)
       (cond
         ((eq? (car x) 'if)
          (and (pair? (cdr x))
               (pair? (cddr x))
               (or (has-def? (caddr x))
                   (and (pair? (cdddr x))
                        (has-def? (cadddr x))))))
         ((memq (car x) '(when unless))
          (and (pair? (cdr x))
               (pair? (cddr x))
               (has-def? (cons 'begin (cddr x)))))
         (else #f))))

(define (ca*r x) (if (pair? x) (ca*r (car x)) x))

(define (unique-syms l)
  (let loop ((rest l) (seen '()) (acc '()))
    (if (null? rest) (reverse acc)
        (let ((x (car rest)))
          (if (or (not (symbol? x))
                  (keyword? x)
                  (memq x seen)
                  (let ((s (symbol->string x)))
                    (and (>= (string-length s) 8) (string=? (substring s 0 8) "_tm_def_"))))
              (loop (cdr rest) seen acc)
              (loop (cdr rest) (cons x seen) (cons x acc)))))))

(define module-public-vars '())
(define module-local-defs '())
(define current-used-symbols '())
(define module-exports-table (make-eq-hashtable))

;; First pass: read every whitelisted file once and record its interface.
(define *compiler-db*
  (scan-source-files->db *progs-dir* *source-files*))

;; The graph is built once and shared: the cycle report reads it, and so does
;; every import decision inside transpile-module.
(define *compile-graph* (make-compile-graph-from-db *compiler-db*))

;; Module -> the SCC it belongs to, for cycle members only. Modules outside a
;; cycle are absent, so a lookup returns '() and the test below stays a single
;; list search with no #f sentinel to special-case.
(define *cycle-mates*
  (let ((t (make-hashtable equal-hash equal?)))
    (for-each (lambda (c) (for-each (lambda (m) (hashtable-set! t m c)) c))
              (compile-graph-cycles *compile-graph*))
    t))

;; `member`, not `memq`: mod-names are lists, and two equal mod-names are not
;; the same object.
(define (cycle-mate? m d)
  (member d (hashtable-ref *cycle-mates* m '())))

;; ========================================================
;; Dependency graph report (TEXMACS_COMPILE_GRAPH=1)
;; ========================================================

(define (compile-graph-mode?)
  (let ((v (getenv "TEXMACS_COMPILE_GRAPH")))
    (and v (not (string=? v "")) (not (string=? v "0")))))

(define (report-tier full title files)
  (let* ((g (compile-graph-subgraph full (map rel-path->mod-name files)))
         (waves (compile-graph-waves g))
         (cycles (compile-graph-cycles g)))
    (format #t "  ~a: ~a modules, ~a waves ~a, ~a cycles~n"
            title (length (compile-graph-nodes g))
            (length waves) (map length waves) (length cycles))
    (for-each (lambda (c) (format #t "      cycle ~s~n" c)) cycles)))

(define (report-compile-graph)
  (let ((full *compile-graph*))
    (format #t "~%Dependency graph~%")
    (format #t "========================================================~%")
    (for-each (lambda (tier)
                (report-tier full (inventory-tier-name tier)
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

(when (compile-graph-mode?)
  (report-compile-graph)
  (exit 0))


;; Seed the export table from that database. Every module the build can ask
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

(define-top-level-value 'module-exports-table module-exports-table)
(define-top-level-value 'module-exports-table module-exports-table (interaction-environment))
(define-top-level-value 'get-module-exports get-module-exports)
(define-top-level-value 'get-module-exports get-module-exports (interaction-environment))



(define (tm-collect-keywords x acc)
  (cond ((and (symbol? x)
              (let ((s (symbol->string x)))
                (and (> (string-length s) 0)
                     (char=? (string-ref s 0) #\:))))
         (if (member x acc) acc (cons x acc)))
        ((pair? x) (tm-collect-keywords (car x)
                     (tm-collect-keywords (cdr x) acc)))
        (else acc)))

(define (tm-bind-keywords x)
  (let ((env (compilation-environment)))
    (for-each
      (lambda (k)
        (unless (top-level-bound? k env)
          (define-top-level-value k k env))
        (unless (top-level-bound? k)
          (define-top-level-value k k)))
      (tm-collect-keywords x '()))))

(define (uncurry-def definer head body)
  (if (pair? (car head))
      (uncurry-def definer (car head) (list `(lambda ,(cdr head) ,@body)))
      `(,definer ,head ,@body)))

(define (tm-maybe-uncurry e)
  (if (and (pair? e) (memq (car e) '(define define-public provide-public))
           (pair? (cadr e)) (pair? (caadr e)))
      (uncurry-def (car e) (cadr e) (cddr e))
      e))

(define (tm-strip-docstring e)
  (if (and (pair? e) (memq (car e) '(define define-public provide-public)) (pair? (cadr e))
           (pair? (cddr e)) (string? (caddr e)) (pair? (cdddr e)))
      (cons (car e) (cons (cadr e) (cdddr e)))
      e))

;; Render any raised object as a printable string, without assuming it is a condition.
(define (condition-text e)
  (if (condition? e)
      (with-output-to-string (lambda () (display-condition e)))
      e))

;; Evaluate `thunk`, reporting any exception as one flat log line
;;   (MESSAGE irritant ... <condition text>)
;; and returning `default` instead of propagating it.  A `message` of #f keeps the call
;; silent.  Every eager evaluation in the transpiler goes through here, so a failure is
;; attributed to the form that caused it instead of aborting the module.
(define (guard-eval message irritants default thunk)
  (guard (e (else
	     (when message
	       (display (append (list message) irritants (list (condition-text e))))
	       (newline))
	     default))
    (thunk)))

(define (eval-in-compile x message)
  (guard-eval message (list x) #f
    (lambda ()
      (parameterize ((interaction-environment (compilation-environment)))
	(eval x (interaction-environment))))))

;; Publish a binding created in `(compilation-environment)` into the global environment.
;; The value is shared, not copied: its free variables keep resolving against the module's
;; own environment, which is exactly what keeps private definitions private.
(define (publish-value! name message)
  (unless (eq? (compilation-environment) (interaction-environment))
    (guard-eval message (list name) #f
      (lambda ()
        (define-top-level-value name
			      (top-level-value name (compilation-environment))
			      (interaction-environment))))))

(define (publish-syntax! name message)
  (unless (eq? (compilation-environment) (interaction-environment))
    (guard-eval message (list name) #f
      (lambda ()
        (define-top-level-syntax name
			      (top-level-syntax name (compilation-environment))
			      (interaction-environment))))))


;; The symbol a definition form introduces:
;;   (tm-define (foo x) ...)              -> foo
;;   (tm-define foo ...)                  -> foo
;;   (define-table foo ...)               -> foo
;;   (define-top-level-syntax 'foo proc)  -> foo   (the argument is a quoted symbol)
(define (defined-name x)
  (let ((head (cadr x)))
    (if (and (pair? head) (eq? (car head) 'quote))
	(cadr head)
	(ca*r head))))

;; These are global top-level values, supposed to be available to texmacs-user space.
;; Evaluate `x` where the module's definitions live, then publish the binding it produced.
(define (eval-install-value-env x message)
  (let ((name (defined-name x)))
    (eval-in-compile x message)
    (publish-value! name message)))

(define (eval-install-syntax-env x message)
  (let ((name (defined-name x)))
    (eval-in-compile x message)
    (publish-syntax! name message)))

(define (eval-install-tm-macro-env x message)
  (let* ((name (defined-name x))
	 (head (cadr x))
	 (impl-name (ca*r (tm-macroify-cp head))))
    (eval-in-compile x message)
    (publish-value! impl-name message)
    (publish-syntax! name message)))

(define (eval-install-group-env x message)
  (let* ((group (cadr x))
	 (list-name (symbol-append group '-list))
	 (pred-name (symbol-append group '?))
	 (inside-name (symbol-append 'inside- group '?)))
    (eval-in-compile x message)
    (publish-value! list-name message)
    (publish-value! pred-name message)
    (publish-value! inside-name message)))

(define (eval-and-auto-publish! x message)
  (let* ((c-env (compilation-environment))
         (before-syms (environment-symbols c-env)))
    ;; 1. Evaluate the form in compilation-environment
    (eval-in-compile x message)
    ;; 2. Publish any newly added bindings to interaction-environment
    (let ((after-syms (environment-symbols c-env)))
      (for-each
        (lambda (sym)
          (unless (memq sym before-syms)
            ;; NOTE: We use `top-level-bound?` to branch between values and syntax because in Chez Scheme
            ;; `top-level-syntax?` returns #t for all identifiers, including regular variables, whereas
            ;; `top-level-bound?` specifically checks for bound variable values.
            (if (top-level-bound? sym c-env)
                (publish-value! sym message)
                (publish-syntax! sym message))))
        after-syms))))

(define (eval-eager-form! x)
  (let ((head (and (pair? x) (car x))))
    (cond
      ((memq head '(define define-public provide-public))
       (guard-eval #f '() #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((memq head '(define-macro define-public-macro))
       (guard-eval #f '() #f
         (lambda ()
           (eval (cons 'define-macro (cdr x)) (compilation-environment)))))

      ((eq? head 'define-module-macro)
       (guard-eval #f '() #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((eq? head 'define-state)
       (guard-eval 'WARNING-DEFINE-STATE-EVAL-FAIL (list (cadr x)) #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((eq? head 'tm-define)
       (eval-install-value-env x 'WARNING-TM-DEFINE-EVAL-FAIL))

      ((eq? head 'tm-define-macro)
       (eval-install-tm-macro-env x 'WARNING-TM-DEFINE-MACRO-EVAL-FAIL))

      ((eq? head 'define-group)
       (eval-install-group-env x 'WARNING-DEFINE-GROUP-EVAL-FAIL))

      ((memq head '(define-table define-collection extend-table extend-collection smart-table))
       (eval-install-value-env x #f))

      ((eq? head 'define-top-level-syntax)
       (eval-install-syntax-env x 'WARNING-TOP-LEVEL-SYNTAX-FAIL))

      ;; We do not evaluate it here at all: the form stays in the module body, Chez
      ;; expands it at compile time, and the emitted `(property-set! ...)` runs at load
      ;; time inside the module's own environment.
      ;; `texmacs-modes` and `cas-define-test` join them: they generate runtime
      ;; values/tables only. No macro reads them at expand time.
      ((memq head '(tm-property define-preferences texmacs-modes cas-define-test)) #f)

      ((memq head '(define-table-decls define-collection-decls))
       (guard-eval #f '() #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((and (eq? head 'ahash-set!)
            (pair? (cdr x)) (eq? (cadr x) 'define-option-table))
       (guard-eval 'FAILED-EVAL-OPT-REG '() #f
         (lambda ()
           (eval x (compilation-environment))))))))

(define (prepare-forms forms)
  (let loop ((rest forms) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((x (car rest)))
          (cond
            ((not x) (loop (cdr rest) acc))
            ((and (pair? x) (eq? (car x) 'begin))
              (loop (append (cdr x) (cdr rest)) acc))
            ((and (pair? x)
               (memq (car x) '(tm-define
                                tm-define-macro
                                lazy-define
                                define-group
                                define-table
                                define-collection
                                extend-table
                                extend-collection
                                tm-property
                                define-preferences)))
              (loop (cdr rest) (cons x acc)))
            ((and (pair? x) (eq? (car x) 'define-top-level-syntax))
              (loop (cdr rest) (cons x acc)))
            ((and (pair? x)
               (eq? (car x) 'define)
               (symbol? (cadr x))
               (pair? (cddr x))
               (symbol? (caddr x))
               (let* ((var-str (symbol->string (cadr x)))
                       (val-str (symbol->string (caddr x))))
                 (and (> (string-length var-str) 4)
                   (string=? (substring var-str 0 4) "cpp-")
                   (string=? (substring var-str 4 (string-length var-str)) val-str))))
              (let* ((var (cadr x))
                      (val (caddr x)))
                (loop (cdr rest) (cons `(define ,var (top-level-value ',val)) acc))))
            ((and (pair? x) (memq (car x) '(define define-public provide-public define-menu define-widget)))
              (let* ((x (tm-strip-docstring (tm-maybe-uncurry x)))
                      (head (cadr x))
                      (var (if (pair? head) (ca*r head) head)))
                (when (symbol? var)
                  (unless (memq var module-local-defs)
                    (set! module-local-defs (cons var module-local-defs))))
                (when (and (symbol? var) (memq (car x) '(define-public provide-public)))
                  (unless (memq var module-public-vars)
                    (set! module-public-vars (cons var module-public-vars))))
                (loop (cdr rest) (cons x acc))))
            ((and (pair? x) (memq (car x) '(define-macro define-public-macro define-module-macro)))
              (let* ((head (cadr x))
                      (nm (if (pair? head) (ca*r head) head)))
                (when (symbol? nm)
                  (unless (memq nm module-local-defs)
                    (set! module-local-defs (cons nm module-local-defs))))
                (when (and (symbol? nm) (memq (car x) '(define-public-macro define-module-macro)))
                  (unless (memq nm module-public-vars)
                  (set! module-public-vars (cons nm module-public-vars))))
              (loop (cdr rest) (cons x acc))))
            ((and (pair? x) (eq? (car x) 'export))
             (for-each
               (lambda (sym)
                 (unless (memq sym module-public-vars)
                   (set! module-public-vars (cons sym module-public-vars))))
               (cdr x))
             (loop (cdr rest) acc))
            ((and (pair? x) (eq? (car x) 'define-syntax))
              (let ((var (cadr x)))
                (when (symbol? var)
                  (unless (memq var module-local-defs)
                    (set! module-local-defs (cons var module-local-defs))))
                (loop (cdr rest) (cons x acc))))
            ((and (pair? x) (eq? (car x) 'bib-define-style))
              (let* ((s (cadr x))
                      (pred (string->symbol (string-append "bib-" s "?"))))
                (unless (memq pred module-local-defs)
                  (set! module-local-defs (cons pred module-local-defs)))
                (unless (memq pred module-public-vars)
                  (set! module-public-vars (cons pred module-public-vars)))
              (loop (cdr rest) (cons x acc))))
            ((and (pair? x) (eq? (car x) 'cas-define-test))
              (let* ((nm (cadr x))
                     (tbl (string->symbol (string-append (symbol->string nm) "-table")))
                     (pred (string->symbol (string-append (symbol->string nm) "?"))))
                (unless (memq tbl module-local-defs)
                  (set! module-local-defs (cons tbl module-local-defs)))
                (unless (memq pred module-local-defs)
                  (set! module-local-defs (cons pred module-local-defs)))
                (loop (cdr rest) (cons x acc))))
           ((and (pair? x) (eq? (car x) 'define-export-macro))
            (loop (cons (cons 'define-public-macro (cdr x)) (cdr rest)) acc))
           ;; In-body `(use-modules ...)` and `(inherit-modules ...)`:
           ;; R6RS forbids `import` inside expression contexts. We desugar in-body module declarations
           ;; to runtime `(module-provide 'mod)` calls, matching dynamic loading behavior without grammar errors.
           ((and (pair? x) (memq (car x) '(use-modules inherit-modules)))
            (loop (append (map (lambda (m) `(module-provide ',m)) (cdr x))
                          (cdr rest))
                  acc))
           ;; Dynamic `define-option-table` registrations (e.g. `:state` and `:state-slots` in `graphics-env.scm`):
           ;; These options are needed by `tm-define-sub` during macro expansion of subsequent definitions.
           ;; We evaluate the registration immediately into `(compilation-environment)` so intra-file and
           ;; downstream `tm-define` declarations recognize the new options at expand time.
           ((and (pair? x) (eq? (car x) 'ahash-set!)
                 (pair? (cdr x)) (eq? (cadr x) 'define-option-table))
            (loop (cdr rest) (cons x acc)))
           ((cond-def? x)
            (let* ((kind (car x))
                   (raw-test (cadr x))
                   (test (if (eq? kind 'unless) `(not ,raw-test) raw-test))
                   (then-b (if (memq kind '(when unless))
                               (cons 'begin (cddr x))
                               (caddr x)))
                   (else-b (if (and (eq? kind 'if) (pair? (cdddr x))) (cadddr x) #f))
                   (eval-val (guard-eval #f '() 'eval-error
					 (lambda ()
					   (eval test (compilation-environment))))))
              (cond
               ((eq? eval-val 'eval-error)
                ;; Could not evaluate test at transpile time; retain as-is
                (loop (cdr rest) (cons x acc)))
               (eval-val
                ;; True branch active: unwrap and compile
                (let ((unwrapped (if (and (pair? then-b) (eq? (car then-b) 'begin))
                                     (cdr then-b)
                                     (list then-b))))
                  (loop (append unwrapped (cdr rest)) acc)))
               (else-b
                ;; False branch active: unwrap and compile
                (let ((unwrapped (if (and (pair? else-b) (eq? (car else-b) 'begin))
                                     (cdr else-b)
                                     (list else-b))))
                  (loop (append unwrapped (cdr rest)) acc)))
               (else
                ;; False and no else branch: strip dead code completely
                (loop (cdr rest) acc)))))
           (else
            (loop (cdr rest) (cons x acc))))))))

;; Linter: Detect potential mid-load mutation hazards where a top-level non-procedure definition
;; follows an expression that mutates state, risking R6RS hoisting anomalies.
(define (check-mid-load-hazards forms mod-name)
  (let loop ((rest forms) (seen-exprs '()) (mutated-vars '()))
    (when (pair? rest)
      (let ((x (car rest)))
        (cond
          ;; Detect direct mutations: (set! var val) or (ahash-set! tbl ...)
          ((and (pair? x) (eq? (car x) 'set!) (pair? (cdr x)) (symbol? (cadr x)))
           (loop (cdr rest) (cons x seen-exprs) (cons (cadr x) mutated-vars)))
          ((and (pair? x) (eq? (car x) 'ahash-set!) (pair? (cdr x)) (symbol? (cadr x)))
           (loop (cdr rest) (cons x seen-exprs) (cons (cadr x) mutated-vars)))
          ;; Check if a subsequent definition is a non-procedure definition reading mutated-vars:
          ((def-form? x)
           (when (and (pair? (cdr x)) (symbol? (cadr x)) (pair? (cddr x)))
             ;; It's (define var val) where val is evaluated at load time
             (let ((val (caddr x)))
               (when (not (and (pair? val) (eq? (car val) 'lambda)))
                 (let has-hazard? ((e val))
                   (cond
                     ((symbol? e)
                      (when (memq e mutated-vars)
                        (log-note (format "warning: ~a defines ~a before ~a is set"
                                          mod-name (cadr x) e))))
                     ((pair? e)
                      (has-hazard? (car e))
                      (has-hazard? (cdr e))))))))
           (loop (cdr rest) seen-exprs mutated-vars))
          (else
           (loop (cdr rest) (cons x seen-exprs) mutated-vars)))))))

(define (partition-forms forms)
  (let loop ((rest forms) (defs '()) (exprs '()))
    (if (null? rest)
        (values (reverse defs) (reverse exprs))
        (let ((x (car rest)))
          (if (def-form? x)
              (loop (cdr rest) (cons x defs) exprs)
              (loop (cdr rest) defs (cons x exprs)))))))

(define compiled-modules '())
(define compile-errors '())

(define (get-module-deps rel-path)
  (let* ((mod-name (rel-path->mod-name rel-path))
         (info (or (compiler-db-ref *compiler-db* mod-name)
                   (error 'get-module-deps
                          "no compiler-db record for module" rel-path mod-name))))
    (module-info-deps info)))

(define (transpile-module rel-path out-path)
  (guard (e (else
              (log-progress "FAILED" rel-path)
              (log-note (condition-text e))
              (set! compile-errors (cons (cons rel-path e) compile-errors))
              #f))
    (let* ((src (string-append *progs-dir* "/" rel-path))
           (forms (read-all-forms src))
           (has-header? (and (pair? forms)
                             (pair? (car forms))
                             (eq? (caar forms) 'texmacs-module)))
           (hdr (if has-header? (car forms) #f))
           (body (if has-header? (cdr forms) forms)))
      (tm-bind-keywords forms)
      (ensure-dir out-path)
      (if (not has-header?)
          ;; Reported as `Skipped` by compile-module-list.
          #f
          (let* ((mod-name (cadr hdr))
                 (mod-sym (mod-name->symbol mod-name))
                 (options (cddr hdr))
                 ;; Every whitelisted module was scanned into the database, so a
                 ;; miss means the scan and this loop disagree about the file.
                 (info (or (compiler-db-ref *compiler-db* mod-name)
                           (error 'transpile-module
                                  "no compiler-db record for module" mod-name)))
                 (deps (module-info-deps info)))

            ;; Track declared dependencies for overload resolution
            (set! current-used-symbols (map mod-name->symbol deps))

            ;; Import declared dependencies into this file's isolated compilation environment
            (for-each
              (lambda (s)
                (let ((s-sym (mod-name->symbol s)))
                  (when (memq s-sym compiled-modules)
                    (guard-eval #f '() #f
                      (lambda ()
                        (eval `(import (for ,s-sym run expand)) (compilation-environment)))))))
              deps)

            (set! module-public-vars '())
            (set! module-local-defs '())
            (let* ((prepared (prepare-forms body)))
              (check-mid-load-hazards prepared rel-path)
              (let* ((public-vars (unique-syms (reverse module-public-vars)))
                     (all-local-defs (unique-syms (reverse module-local-defs)))
                     (seen-imported '())
                     (import-forms '())
                     (export-forms (if (pair? public-vars) (list `(export ,@public-vars)) '())))

                ;; Import one dependency's exports, minus any name that would
                ;; collide with a local definition or with an earlier import.
                (define (import-module! s-sym)
                  (let* ((exports (get-module-exports s-sym))
                         (clash (filter (lambda (v)
                                          (or (memq v all-local-defs)
                                              (memq v seen-imported)))
                                        exports)))
                    (set! import-forms
                          (cons (if (null? clash)
                                    `(import (for ,s-sym run expand))
                                    `(import (for (except ,s-sym ,@clash) run expand)))
                                import-forms))
                    (set! seen-imported
                          (append (filter (lambda (v) (not (memq v clash))) exports)
                                  seen-imported))))

                ;; A dependency that is not compiled yet falls back to a runtime
                ;; module-provide lookup. Say which kind it is: a real cycle, or
                ;; merely a later position in the tier order.
                (define (note-deferred! s s-sym)
                  (log-note (format (if (cycle-mate? mod-name s)
                                        "cycle back-edge: ~a -> ~a (runtime module-provide)"
                                        "deferred forward import: ~a -> ~a (acyclic)")
                                    mod-sym s-sym)))

                (hashtable-set! module-exports-table mod-sym public-vars)
                (for-each
                  (lambda (opt)
                    (when (and (pair? opt) (memq (car opt) '(:use :inherit)))
                      (for-each
                        (lambda (s)
                          (let ((s-sym (mod-name->symbol s)))
                            (if (memq s-sym compiled-modules)
                                (if (eq? (car opt) ':use)
                                    (import-module! s-sym)
                                    (begin
                                      (set! import-forms
                                            (cons `(import (for ,s-sym run expand)) import-forms))
                                      (set! export-forms
                                            (cons `(export (import ,s-sym)) export-forms))))
                                (note-deferred! s s-sym))))
                        (cdr opt))))
                  options)
                (set! import-forms (reverse import-forms))
                (set! export-forms (reverse export-forms))
                ;; Evaluate eager forms sequentially in source order before partitioning:
                (parameterize ((compile-export-mode? #f))
                  (for-each
                    (lambda (x)
                      (unless (and *eager-gated?* (eager-skip? x))
                        (when *eager-gated?* (oracle-bring-in-form! x))
                        (eval-eager-form! x)))
                    prepared))
                (let-values (((defs exprs) (partition-forms prepared)))
                  (let* ((keywords (tm-collect-keywords forms '()))
                         (keyword-defs (map (lambda (k) `(define ,k ',k)) keywords))
                         (dep-provides (map (lambda (d) `(module-provide ',d)) deps)))
                    (let ((out-p (open-output-file out-path 'replace)))
                      (dynamic-wind
                        (lambda () #f)
                        (lambda ()
                          (display ";;; Auto-generated native Chez Scheme module from " out-p)
                          (display rel-path out-p) (newline out-p)
                          (write `(module ,mod-sym ()
                                    ,@import-forms
                                    ,@export-forms
                                    ,@keyword-defs
                                    ,@defs
                                    ,@dep-provides
                                    ,@exprs)
                                 out-p)
                          (newline out-p))
                        (lambda () (close-port out-p))))
                    mod-sym)))))))))

(define (transpile-and-compile-module rel-path trans-scm out-so)
  (let ((mod-sym (transpile-module rel-path trans-scm)))
    (if mod-sym
        (begin
          ;; Emitted only once the module is known to be buildable, so a file
          ;; without a header reports `Skipped` alone and a transpile error
          ;; reports `FAILED` alone -- one line per module either way.
          (log-progress "Compiling" (string-append rel-path " -> " (path-basename out-so)))
          (call/cc
            (lambda (k)
              (with-exception-handler
                (lambda (e)
                  (if (serious-condition? e)
                      (begin
                        (log-progress "FAILED" rel-path)
                        (emit-progress-line
                          (with-output-to-string (lambda () (display-condition e))))
                        (when (who-condition? e)
                          (log-note (format "who: ~a" (condition-who e))))
                        (when (irritants-condition? e)
                          (log-note (format "irritants: ~s" (condition-irritants e))))
                        (when (syntax-violation? e)
                          (log-note (format "form: ~s" (syntax-violation-form e)))
                          (log-note (format "subform: ~s" (syntax-violation-subform e))))
                        (when (top-level-bound? 'tm-backtrace)
                          (tm-backtrace e))
                        (set! compile-errors (cons (cons rel-path e) compile-errors))
                        (k #f))
                      (void)))
                (lambda ()
                  (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (parameterize ((compile-export-mode? #t))
                        (compile-file trans-scm out-so))
                      mod-sym)
                    (lambda ()
                      (for-each
                        (lambda (entry)
                          (unbind-symbol! entry (interaction-environment))
                          (hashtable-delete! *oracle-installed* (car entry)))
                        *ephemeral-syms*)
                      (set! *ephemeral-syms* '()))))))))
        #f)))

(define compiled-count 0)
(define cached-count 0)
(define (save-module-deps-manifest!)
  (let ((manifest-file (string-append *boot-dir* "/module-deps.scm")))
    (log-progress-pct "Writing" (string-append "module dependency manifest " manifest-file))
    (let ((out-p (open-output-file manifest-file 'replace)))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (write (map (lambda (info)
                        (list (module-info-name info)
                              (module-info-deps info)))
                      (compiler-db-modules *compiler-db*))
                 out-p)
          (newline out-p))
        (lambda () (close-port out-p))))))

(define (register-module-loaded! rel-path out-so mod-sym is-cached?)
  (get-module-deps rel-path)
  (let* ((load-ok? #t)
         (mod-name (rel-path->mod-name rel-path)))
    (hashtable-set! *texmacs-modules-loaded* mod-name #t)
    (guard (e (else
                (hashtable-delete! *texmacs-modules-loaded* mod-name)
                (set! load-ok? #f)
                (log-progress "FAILED" rel-path)
                (log-note (condition-text e))
                (when (file-exists? out-so) (delete-file out-so))
                (set! compile-errors (cons (cons rel-path e) compile-errors))))
      (load out-so))
    (when load-ok?
      (when (member rel-path *kernel-files*)
        (guard-eval 'IMPORT-FAIL (list mod-sym) #f
	          (lambda ()
		          (eval `(import ,mod-sym) (interaction-environment)))))
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
      (let* ((trans-scm (string-append *boot-dir* "/" rel-path))
             (out-so (string-append (substring trans-scm 0 (- (string-length trans-scm) 4)) ".so"))
             (needs-build? (module-needs-recompile? rel-path trans-scm out-so))
             (mod-sym (if needs-build?
                          (transpile-and-compile-module rel-path trans-scm out-so)
                          (mod-name->symbol (rel-path->mod-name rel-path)))))
        (cond
          ((and (not needs-build?) (file-exists? out-so))
           (parameterize ((compile-export-mode? #t))
             (register-module-loaded! rel-path out-so mod-sym #t)))
          (mod-sym
           (parameterize ((compile-export-mode? #t))
             (register-module-loaded! rel-path out-so mod-sym #f)))
          ;; Every real failure was already reported by the transpile or load
          ;; handler; what is left is a file without a `texmacs-module` header.
          ((not (assoc rel-path compile-errors))
           (log-progress "Skipped" (string-append rel-path " (no texmacs-module header)"))))))
    file-list))

;; One tier is one compile-module-list call: the banner and the file list both
;; come from the inventory row, so the driver never names a tier twice.
(define (compile-tier! tier)
  (compile-module-list (inventory-tier-title tier) (inventory-tier-files tier)))

;; Tier 1 runs unconditionally: the kernel snapshot and every later tier depend
;; on it, and its failures abort the rest of the build below.
(compile-tier! (car inventory-tiers))

(newline)
(if (null? compile-errors)
    (begin
      (let* ((user-scm (string-append *boot-dir* "/texmacs-user.scm"))
             (user-so (string-append *boot-dir* "/texmacs-user.so"))
             (user-up-to-date? (and (file-exists? user-so)
                                    (not *recompile-all?*)
                                    (let loop ((l *kernel-files*))
                                      (if (null? l) #t
                                          (let* ((rel (car l))
                                                 (trans-scm (string-append *boot-dir* "/" rel))
                                                 (out-so (string-append (substring trans-scm 0 (- (string-length trans-scm) 4)) ".so"))
                                                 (src (string-append *progs-dir* "/" rel)))
                                            (if (or (file-newer? src user-so)
                                                    (file-newer? out-so user-so))
                                                #f
                                                (loop (cdr l)))))))))
        (if user-up-to-date?
            (begin
              (log-progress-pct "Up-to-date" "texmacs-user.so (kernel snapshot)")
              (load user-so))
            (begin
              (log-progress-pct "Building" "aggregate kernel snapshot texmacs-user.so")
              (let ((p (open-output-file user-scm 'replace)))
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (display ";;; Aggregate texmacs-user and texmacs-user-kernel\n" p)
                    (for-each
                      (lambda (rel)
                        (let* ((trans-scm (string-append *boot-dir* "/" rel))
                               (out-so (string-append (substring trans-scm 0 (- (string-length trans-scm) 4)) ".so")))
                          (write `(primitive-load ,out-so) p)
                          (newline p)))
                      *kernel-files*)
                    (let* ((all-mods (map (lambda (rel) (mod-name->symbol (rel-path->mod-name rel))) *kernel-files*))
                           (imports (map (lambda (m) `(import (for ,m run expand))) all-mods))
                           (exports (map (lambda (m) `(export (import ,m))) all-mods)))
                      (write `(module texmacs-user ()
                                ,@imports
                                ,@exports)
                             p)
                      (newline p)
                      (write `(module texmacs-user-kernel ()
                                (export (import texmacs-user)))
                             p)
                      (newline p)
                      (write `(import texmacs-user-kernel) p)
                      (newline p)
                      (for-each
                        (lambda (m)
                          (write `(import ,m) p)
                          (newline p))
                        all-mods))
                    ;; The module forms above bind these names to modules, and a
                    ;; module binding is not a value.  Rebind them to the single
                    ;; environment that user space means everywhere else.
                    (write `(define-top-level-value 'texmacs-user (interaction-environment))
                           p)
                    (newline p)
                    (write `(define-top-level-value 'texmacs-user-kernel (interaction-environment))
                           p)
                    (newline p))
                  (lambda () (close-port p))))
              (compile-file user-scm user-so)
              (load user-so)
              (log-progress-pct "Verified" "texmacs-user.so"))))
      (for-each compile-tier! (cdr inventory-tiers))
      (save-module-deps-manifest!)
      (write-compiler-db *compiler-db*
                         (string-append *boot-dir* "/compiler-db.fasl"))
      (newline)
      (display "========================================================\n")
      (display "[100%] Built target texmacs-chez-modules:\n")
      (display (string-append "  - Recompiled: " (number->string compiled-count)
                              " module" (if (= compiled-count 1) "" "s") "\n"))
      (display (string-append "  - Up-to-date (cached): " (number->string cached-count)
                              " module" (if (= cached-count 1) "" "s") "\n"))
      (display (string-append "  - Failures: "
                              (number->string (length compile-errors)) "\n"))
      (when (pair? compile-errors)
        (for-each
          (lambda (err)
            (display (string-append "    * FAILED: " (car err) "\n")))
          (reverse compile-errors)))
      (display "========================================================\n"))
    (begin
      (display "========================================================\n")
      (display (string-append "[FAILED] Built target texmacs-chez-modules: "
                              (number->string (length compile-errors))
                              " failure(s)\n"))
      (for-each
        (lambda (err)
          (display (string-append "  - " (car err) "\n")))
        compile-errors)
      (display "========================================================\n")))

(when (and (top-level-bound? 'quit-TeXmacs)
           (not (top-level-bound? '*dont-quit*)))
  (quit-TeXmacs))
