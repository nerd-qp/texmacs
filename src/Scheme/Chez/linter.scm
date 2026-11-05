;;; linter.scm -- five-phase static analysis of TeXmacs's macro layer.
;;;
;;; Loaded by progs/init-linter.scm, i.e. from inside a TeXmacs process that
;;; has booted the Scheme *kernel only* (`TeXmacs -lint`).  Nothing below is
;;; TeXmacs-specific machinery: it is plain Chez Scheme driving `expand` over
;;; the progs tree and reporting what the macro layer needs in order to exist.
;;;
;;;   phase 1  index every definition in the tree, using the hardcoded rule
;;;   phase 2  select the macro definitions out of that index
;;;   phase 3  expand each one and harvest the free top-level names it needs
;;;   phase 4  evaluate each one, installing the names phase 3 asked for
;;;   phase 5  module dependency graph over the whole tree (syntactic)
;;;
;;; Phases 3 and 4 are deliberately separate runs over the same forms: phase 3
;;; sees only what the kernel provides, phase 4 is allowed to pull definitions
;;; out of the index.  The difference between the two is the point of the
;;; report -- it is the set of macros that cannot be expanded without help
;;; from outside the kernel.
;;;
;;; Phase 4 installs dependencies PROACTIVELY: before a form is expanded, the
;;; transitive closure of every name it needs is computed from the index
;;; (macro-closure.scm) and evaluated in dependency order.  The previous model
;;; reacted to failures instead -- trap `&assertion`, parse "variable <name>
;;; is not bound" out of the message, evaluate the definition, retry -- which
;;; could not work for a missing *macro*: Chez's expander does not raise for
;;; an unbound identifier, it lowers it to ($primitive n $top-level-value), so
;;; (for (i l) ...) silently stayed a procedure call and `i' was reported as a
;;; free variable.
;;;
;;; Output: a human summary on stdout plus four TSV files, whose paths come
;;; from $TEXMACS_LINT_OUT (default ./macro-lint.tsv),
;;; $TEXMACS_LINT_DEPS_OUT (./macro-lint-deps.tsv),
;;; $TEXMACS_LINT_MODULES_OUT (./macro-lint-modules.tsv) and
;;; $TEXMACS_LINT_CLOSURE_OUT (./macro-closure.tsv).

;;; ---------------------------------------------------------------- preamble

;; TeXmacs rebinds `sort', `filter' and `string-join' at the top level of
;; texmacs-user (and its string-join needs a kernel module the linter does not
;; require).  Take the core procedures from the scheme environment instead.
(define (tm-lint-core name)
  (and (top-level-bound? name (scheme-environment))
       (top-level-value name (scheme-environment))))

(define chez-sort   (tm-lint-core 'sort))
(define chez-filter (tm-lint-core 'filter))

;; init-texmacs-chez.scm rebinds `eval' to a Guile-compatible wrapper.  Use the
;; raw evaluator: the wrapper rewrites quoted literals, which is harmless but
;; pointless here.
(define chez-eval (if (top-level-bound? 'tm-orig-eval) tm-orig-eval eval))

(define (tm-lint-env) (interaction-environment))

;;; -------------------------------------------------- the closure engine
;;
;; macro-closure.scm sits next to this file and is plain definitions: the
;; free-name walker, the syntax-rules template reader, and the DFS/SCC closure
;; over a definition index.  Loading it rather than importing it keeps the
;; linter loadable from a TeXmacs process, which has no library search path
;; into src/Scheme/Chez.

(define (tm-lint-script-dir)
  (let ((p (or (getenv "TEXMACS_LINT_SCRIPT")
               (let ((t (getenv "TEXMACS_PATH")))
                 (and t (string-append t "/../src/Scheme/Chez/linter.scm")))
               "src/Scheme/Chez/linter.scm")))
    (let loop ((i (- (string-length p) 1)))
      (cond ((< i 0) ".")
            ((char=? (string-ref p i) #\/) (substring p 0 i))
            (else (loop (- i 1)))))))

(define tm-lint-primitive-load
  (if (top-level-bound? 'primitive-load) (top-level-value 'primitive-load) load))

(tm-lint-primitive-load (string-append (tm-lint-script-dir) "/macro-closure.scm"))

(define (tm-lint-find pred xs)
  (cond ((null? xs) #f)
        ((pred (car xs)) (car xs))
        (else (tm-lint-find pred (cdr xs)))))

(define (string-prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(define (string-suffix? p s)
  (let ((n (string-length p)) (m (string-length s)))
    (and (>= m n) (string=? (substring s (- m n) m) p))))

(define (join-strings xs sep)
  (cond ((null? xs) "")
        ((null? (cdr xs)) (car xs))
        (else (string-append (car xs) sep (join-strings (cdr xs) sep)))))

(define (symbols->string xs sep) (join-strings (map symbol->string xs) sep))

(define (walk-each xs f)
  (let loop ((p xs)) (when (pair? p) (f (car p)) (loop (cdr p)))))

(define (leftmost-symbol x)
  (if (pair? x) (leftmost-symbol (car x)) x))

(define (quoted-symbol x)
  (and (pair? x) (eq? (car x) 'quote) (pair? (cdr x))
       (symbol? (cadr x)) (cadr x)))

;; (($primitive n op) args ...) or ($primitive n op) -> op
(define (prim-op x)
  (cond ((and (pair? x) (eq? (car x) '$primitive)) (car (last-pair x)))
        ((and (pair? x) (pair? (car x)) (eq? (caar x) '$primitive))
         (car (last-pair (car x))))
        (else #f)))

(define (formals->list f acc)
  (cond ((symbol? f) (cons f acc))
        ((pair? f) (formals->list (cdr f)
                                  (if (symbol? (car f)) (cons (car f) acc) acc)))
        (else acc)))

;;; ------------------------------------------------------- free name walker
;;
;; mc-free-names (macro-closure.scm) runs on two kinds of input.  On expanded
;; core AST -- phases 3-4 -- every lexical and module-internal binding has been
;; renamed to a gensym, so a plain non-gensym symbol is a reference to a
;; top-level binding and no scope tracking is needed.  On source forms --
;; phase 5 and the dependency closure -- nothing is expanded, so the walk has
;; to follow the binders itself, including the TeXmacs macros that bind a name
;; ((with v e body), (for (i l) body), (receive (a b) v body)).
;;
;; On source input the result is an over-approximation, which is what the
;; module graph wants: it may report a reference that never runs, but it
;; cannot miss one.

(define (free-names x) (mc-free-names x))

;; Subforms shaped (($primitive n define-top-level-syntax) 'name val).
(define (syntax-defs core)
  (define acc '())
  (define (walk x)
    (when (pair? x)
      (cond
        ((eq? (car x) 'quote) (void))
        ((eq? (prim-op x) 'define-top-level-syntax)
         (set! acc (cons x acc))
         (walk-each (cdr x) walk))
        (else (walk-each x walk)))))
  (walk core)
  (reverse acc))

;; Rebuild a transformer expression from the source form, for the definers whose
;; expansion hides the body.  One implementation, in macro-closure.scm, because
;; the closure needs exactly the same reading of a macro definition.
(define (transformer-expr form) (mc-transformer-expr form))

;;; ---------------------------------------------------------- file system

(define (tm-lint-root)
  (let ((p (getenv "TEXMACS_PATH")))
    (if (and p (file-exists? (string-append p "/progs")))
        (string-append p "/progs")
        "TeXmacs/progs")))

(define (walk-files dir)
  (define acc '())
  (define (walk rel)
    (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
      (if (file-directory? full)
          (for-each (lambda (n)
                      (unless (member n '("." ".."))
                        (walk (if (string=? rel "") n (string-append rel "/" n)))))
                    (directory-list full))
          (when (string-suffix? ".scm" rel) (set! acc (cons rel acc))))))
  (walk "")
  (chez-sort (lambda (a b) (string<? a b)) acc))

(define (read-all-forms path)
  "Read every datum in PATH.  Returns (values forms truncated?)."
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((f (guard (e (else 'read-error)) (read port))))
          (cond ((eof-object? f) (values (reverse acc) #f))
                ((eq? f 'read-error) (values (reverse acc) #t))
                (else (loop (cons f acc)))))))))

;;; ------------------------------------------------------ the hardcoded rule
;;
;; The rule is a fixed list of head symbols.  Nothing is inferred from names or
;; from the shape of a body: a form defines a macro iff its head is one of
;; these, and defines a value iff its head is one of those.

(define macro-definers
  '(define-syntax define-macro define-public-macro define-module-macro
    define-export-macro tm-define-macro))

(define value-definers
  '(define define-public provide-public tm-define))

;; A "site" is one definition:
;;   #(name kind inner-form top-form file module)
;; INNER-FORM is the define itself; TOP-FORM is the enclosing top-level form,
;; which is the unit that has to be expanded and evaluated to install it.
(define (site-name s)  (vector-ref s 0))
(define (site-kind s)  (vector-ref s 1))
(define (site-inner s) (vector-ref s 2))
(define (site-top s)   (vector-ref s 3))
(define (site-file s)  (vector-ref s 4))
(define (site-module s)(vector-ref s 5))

(define defs        (make-eq-hashtable))   ; name -> first site
(define top-ord     (make-eq-hashtable))   ; top form -> position in its file
(define duplicates  '())
(define index-count 0)
(define form-count  0)
(define truncated   '())

(define (record-def! name kind inner top file module)
  (set! index-count (+ index-count 1))
  (let ((site (vector name kind inner top file module)))
    (if (hashtable-ref defs name #f)
        (unless (memq name duplicates) (set! duplicates (cons name duplicates)))
        (hashtable-set! defs name site))))

;; Descend FORM looking for definer-headed subforms, attributing each to TOP,
;; the enclosing top-level form.  Quoted data, syntax templates (`#'` reads as
;; `(syntax ...)`, not `(quote ...)`), syntax-rules and quasiquote bodies are
;; all skipped: a (define-macro ...) written inside a template is generated
;; code, not a definition in this file.
(define (index-form! top form file module)
  (define (walk x)
    (when (pair? x)
      (cond
        ((memq (car x) '(quote syntax syntax-rules quasiquote quasisyntax))
         (void))
        (else
         (when (and (symbol? (car x))
                    (or (memq (car x) macro-definers)
                        (memq (car x) value-definers))
                    (pair? (cdr x)))
           (let ((n (leftmost-symbol (cadr x))))
             (when (symbol? n)
               (record-def! n
                            (if (memq (car x) macro-definers) 'macro 'value)
                            x top file module))))
         (walk-each x walk)))))
  (walk form))

(define (module-of forms)
  (let ((h (tm-lint-find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module)))
                         forms)))
    (if (and h (pair? (cdr h))) (cadr h) '(no-header))))

(define file-module (make-hashtable string-hash string=?))

(define (index-file! rel)
  (let* ((path (string-append *root* "/" rel))
         (forms (call-with-values (lambda () (read-all-forms path))
                   (lambda (fs trunc)
                     (when trunc (set! truncated (cons rel truncated)))
                     fs)))
         (mod (module-of forms)))
    (hashtable-set! file-module rel mod)
    (set! form-count (+ form-count (length forms)))
    (let loop ((fs forms) (i 0))
      (when (pair? fs)
        (hashtable-set! top-ord (car fs) i)
        (index-form! (car fs) (car fs) rel mod)
        (loop (cdr fs) (+ i 1))))))

;;; --------------------------------------------------------------- counters

(define n-cold-ok 0)
(define n-cold-fail 0)
(define n-warm-ok 0)
(define n-warm-fail 0)
(define n-eval-fail 0)
(define n-macro-installed 0)
(define n-helper-installed 0)
(define n-install-fail 0)

(define cold-buckets (make-hashtable equal-hash equal?))
(define warm-buckets (make-hashtable equal-hash equal?))

(define dep-users    (make-eq-hashtable))  ; dep name -> list of macro names
(define dep-count    (make-eq-hashtable))  ; dep name -> occurrence count
(define macro-deps   (make-eq-hashtable))  ; macro name -> list of dep names
(define site-status  (make-eq-hashtable))  ; site -> 'ok / 'fail

(define (note-dep! dep macro)
  (hashtable-update! dep-count dep (lambda (v) (+ v 1)) 0)
  (let ((u (hashtable-ref dep-users dep '())))
    (unless (memq macro u) (hashtable-set! dep-users dep (cons macro u))))
  (let ((d (hashtable-ref macro-deps macro '())))
    (unless (memq dep d) (hashtable-set! macro-deps macro (cons dep d)))))

(define (bucket! table c label)
  (let* ((irr (and (condition? c) (irritants-condition? c) (condition-irritants c)))
         (key (cond ((and irr (pair? irr) (symbol? (car irr)))
                     (string-append label (symbol->string (car irr))))
                    ((and irr (pair? irr))
                     (string-append label (format "~s" (car irr))))
                    (else
                     (let ((m (condition-message c)))
                       (string-append label
                                      (substring m 0 (min 48 (string-length m)))))))))
    (hashtable-update! table key (lambda (v) (+ v 1)) 0)))

;;; ------------------------------------------------------------- expansion

;; Attribute every transformer the expansion spelled out to the name it binds.
(define (harvest-core! core)
  (for-each
    (lambda (d)
      (let* ((n (quoted-symbol (cadr d)))
             (val (and (pair? (cddr d)) (caddr d))))
        (when (and (symbol? n) (pair? val) (eq? (car val) 'lambda))
          (for-each (lambda (x) (note-dep! x n)) (free-names val)))))
    (syntax-defs core)))

;; Rebuild the transformer from the source and expand that: define-syntax family
;; forms expand to (void), so the body is otherwise invisible.
(define (harvest-transformer! site)
  (let ((tx (transformer-expr (site-inner site))))
    (when tx
      (let ((tcore (guard (e (else #f)) (expand tx (tm-lint-env)))))
        (when tcore
          (for-each (lambda (n) (note-dep! n (site-name site)))
                    (free-names tcore)))))))

;;; --------------------------------------------------- phase 4: lazy install

(define installed  (make-eq-hashtable))
(define installing (make-eq-hashtable))
(define install-log '())

(define (macro? s)
  (and (symbol? s)
       (top-level-syntax? s (tm-lint-env))
       (procedure? (top-level-syntax s (tm-lint-env)))))

;; What a site needs: the definer that heads its top form, plus -- for a macro
;; -- the transformer body, which `expand' never shows (a define-macro form
;; expands to (void)).
(define (site-deps site)
  (let* ((top (site-top site))
         (head (and (pair? top) (car top)))
         (extra (if (and (symbol? head) (hashtable-ref defs head #f))
                    (list head)
                    '())))
    (append extra
            (if (eq? (site-kind site) 'macro)
                (or (mc-macro-deps (site-inner site)) '())
                (free-names top)))))

;; Is NAME bound at top level, as a value or as a macro?
;;
;; Neither Chez primitive answers this on its own: `top-level-bound?' is #f for
;; a *syntax* binding (so every macro looks unbound), and `top-level-syntax?'
;; is #t for any symbol at all (it does not check that anything is there).  The
;; one signal that discriminates is the syntax value: an installed macro is a
;; procedure, an unbound name yields a core transformer.
(define (live? name)
  (or (top-level-bound? name (tm-lint-env))
      (guard (c (else #f))
        (procedure? (top-level-syntax name (tm-lint-env))))))

;; PROACTIVE INSTALL.  No exception is ever trapped and no error message is
;; ever parsed: the dependencies come from the static index, before anything
;; runs.  Two rules make the walk terminate on a mutually recursive tree:
;;
;;   * `installing' is the "no revisit" stop rule -- a name already being
;;     installed is left alone rather than re-entered.  Evaluating a definition
;;     only allocates closures, so the order inside a cycle does not matter.
;;   * a name that is already live is skipped.  That is what keeps the kernel
;;     out of the work, and it is not optional: re-evaluating a working
;;     transformer from source gives its templates the wrong lexical context,
;;     which took phase 4 from 106 expansions to 7 when the test was wrong.
(define (ensure-installed! name)
  "Make NAME live, installing its dependencies first.  #t if it is live."
  (cond
    ((not (symbol? name)) #f)
    ((or (live? name) (hashtable-ref installed name #f)) #t)
    ((hashtable-ref installing name #f) #f)
    (else
     (let ((site (hashtable-ref defs name #f)))
       (cond
         ((not site) #f)
         ;; The kernel is already compiled and loaded; it is indexed only so a
         ;; dependency name can be classified, never evaluated.
         ((kernel-file? (site-file site)) #t)
         (else
          (begin
            (hashtable-set! installing name #t)
            (for-each ensure-installed! (site-deps site))
            (let ((ok? (guard (c (else
                                  (set! n-install-fail (+ n-install-fail 1))
                                  (bucket! warm-buckets c "install: ")
                                  #f))
                         (chez-eval (site-top site) (tm-lint-env))
                         #t)))
              (hashtable-delete! installing name)
              (when ok?
                (hashtable-set! installed name #t)
                (set! n-helper-installed (+ n-helper-installed 1))
                (set! install-log (cons name install-log)))
              ok?))))))))

;; The closure over every macro site, computed once: it is the install order,
;; the recorded dependency set, and the cycle report.
(define closure-order '())
(define closure-sets  (make-eq-hashtable))   ; macro name -> dependency set
(define closure-cycles '())
(define closure-back-edges 0)

(define (compute-closures)
  (let-values (((order sets cycles back)
                (mc-closures defs site-deps (map site-name macro-sites))))
    (set! closure-order order)
    (set! closure-sets sets)
    (set! closure-cycles cycles)
    (set! closure-back-edges back)))

;;; ------------------------------------------------------------------ report

(define (classify name)
  (let ((site (hashtable-ref defs name #f)))
    (cond ((macro? name) 'macro)
          ((and site (eq? (site-kind site) 'macro)) 'macro-not-installed)
          ((top-level-bound? name (tm-lint-env)) 'bound)
          (site 'procedure)
          (else 'unknown))))

(define (demand name) (length (hashtable-ref dep-users name '())))

(define (out-path env-var default)
  (let ((v (getenv env-var))) (if (and v (not (string=? v ""))) v default)))

(define (print-top table label limit)
  (let* ((ks (chez-sort (lambda (a b) (> (hashtable-ref table a 0)
                                         (hashtable-ref table b 0)))
                        (vector->list (hashtable-keys table))))
         (n (length ks)))
    (newline)
    (printf "--- ~a ---~n" label)
    (for-each (lambda (k) (printf "  ~5d  ~a~n" (hashtable-ref table k 0) k))
              (list-head ks (if (< n limit) n limit)))))

;;; -------------------------------------------------------------------- main

(define *root* (tm-lint-root))
(define macro-sites '())
(define top-cache (make-eq-hashtable))     ; top form -> core AST or 'failed
(define file-order (make-hashtable string-hash string=?))

;; The kernel is not analysed, for two independent reasons.
;;
;; 1. It is already compiled.  Every kernel module ships as a .so in the AOT
;;    bundle, it is loaded before anything else, and it can never be a
;;    scheduling choice for a later tier.  Analysing it produces no input to
;;    the build.  What the build needs is the dependency structure *between*
;;    the modules it still has to compile.
;;
;; 2. Re-evaluating kernel definitions is destructive.  Re-evaluating even one
;;    of the bootstrap's `define-syntax' forms replaces a working transformer
;;    with one that produces "invalid syntax" -- by `expand' or by `eval', it
;;    makes no difference, and re-evaluating a second time does not repair it.
;;
;;    Verified on boot-chez.scm's `with', which splices a caller-supplied
;;    identifier into binding position:
;;        #'(apply (lambda var body ...) val)
;;        #'(let ((var val)) body ...)
;;    Re-evaluating the transformer at top level gives its `#'` templates the
;;    evaluator's lexical context instead of the caller's, so the identifier
;;    it splices in carries mismatched marks and the expander rejects the
;;    result.  Ordinary macros are unaffected; this only bites when a pattern
;;    variable lands in a binding position.
;;
;;    It is not a local problem: `tm-define-macro' is written as
;;    (with macro-head (tm-macroify head) ...) and `define-public-macro' goes
;;    through `with-export-if-active', so breaking `with' alone took 276 of
;;    389 expansions down with it.
;;
;; Kernel definitions are therefore still *indexed* -- a dependency name has
;; to resolve to a module to know whether it is a kernel prerequisite or a
;; real edge -- but never expanded or evaluated.
(define (kernel-file? rel) (string-prefix? "kernel/" rel))

(define (collect-macro-sites)
  (let ((acc '()))
    (vector-for-each
      (lambda (n)
        (let ((s (hashtable-ref defs n #f)))
          (when (and s (eq? (site-kind s) 'macro)) (set! acc (cons s acc)))))
      (hashtable-keys defs))
    ;; stable order: kernel before the rest (as the kernel is loaded), then
    ;; file name, then position within the file
    (chez-sort (lambda (a b)
                 (let ((fa (hashtable-ref file-order (site-file a) 0))
                       (fb (hashtable-ref file-order (site-file b) 0)))
                   (if (= fa fb)
                       (< (hashtable-ref top-ord (site-top a) 0)
                          (hashtable-ref top-ord (site-top b) 0))
                       (< fa fb))))
               acc)))

(define (report-phase1 ordered)
  (printf "~n[1/5] indexing definitions ...~n")
  (let ((t0 (real-time)))
    (for-each index-file! ordered)
    (printf "      ~a files, ~a top-level forms, ~a definitions in ~a ms~n"
            (length ordered) form-count index-count (- (real-time) t0)))
  (when (pair? truncated)
    (printf "      ~a file(s) could not be read to the end: ~a~n"
            (length truncated) (join-strings (reverse truncated) " "))
    (printf "      (Guile-specific reader syntax; their definitions are missing)~n"))
  (printf "      duplicate names: ~a~n" (length duplicates))
  (let* ((names (vector->list (hashtable-keys defs)))
         (nm (length (chez-filter
                       (lambda (n) (eq? (site-kind (hashtable-ref defs n #f)) 'macro))
                       names))))
    (printf "      macros: ~a   values: ~a~n" nm (- (length names) nm))))

(define (report-phase2)
  (printf "~n[2/5] selecting macro definitions (hardcoded rule) ...~n")
  (printf "      ~a macro definition sites~n" (length macro-sites))
  (let ((by-def (make-hashtable equal-hash equal?)))
    (for-each (lambda (s) (hashtable-update! by-def (car (site-inner s))
                                             (lambda (v) (+ v 1)) 0))
              macro-sites)
    (for-each (lambda (k) (printf "        ~5d  ~a~n" (hashtable-ref by-def k 0) k))
              (chez-sort (lambda (a b) (> (hashtable-ref by-def a 0)
                                          (hashtable-ref by-def b 0)))
                         (vector->list (hashtable-keys by-def)))))
  (printf "      already installed as macros in env: ~a~n"
          (length (chez-filter (lambda (s) (macro? (site-name s))) macro-sites)))
  (let ((k (chez-filter (lambda (s) (kernel-file? (site-file s))) macro-sites)))
    (printf "      kernel (already compiled, indexed but not analysed): ~a~n"
            (length k))
    (printf "      analysed: ~a~n" (- (length macro-sites) (length k)))))

(define (report-phase3)
  (printf "~n[3/5] expanding with the kernel only, harvesting dependencies ...~n")
  (let ((t0 (real-time))
        (verbose (getenv "TEXMACS_LINT_VERBOSE")))
    (for-each
      (lambda (site)
        (unless (kernel-file? (site-file site))
          (let* ((top (site-top site))
                 (cached (hashtable-ref top-cache top 'unknown)))
            (when (eq? cached 'unknown)
              (let ((core (guard (c (else
                                     (bucket! cold-buckets c "")
                                     (when verbose
                                       (printf "      FAIL ~a (~a): "
                                               (site-name site) (site-file site))
                                       (display-condition c) (newline))
                                     'failed))
                            (expand top (tm-lint-env)))))
                (hashtable-set! top-cache top core)
                (set! cached core)))
            (if (eq? cached 'failed)
                (begin
                  (set! n-cold-fail (+ n-cold-fail 1))
                  (hashtable-set! site-status site 'fail))
                (begin
                  (set! n-cold-ok (+ n-cold-ok 1))
                  (harvest-core! cached)
                  (harvest-transformer! site))))))
      macro-sites)
    (printf "      expanded ~a, failed ~a in ~a ms~n"
            n-cold-ok n-cold-fail (- (real-time) t0)))
  (printf "      distinct dependency names: ~a~n" (hashtable-size dep-count)))

(define (report-phase4)
  (printf "~n[4/5] evaluating with the proactive closure ...~n")
  (compute-closures)
  (printf "      closure: ~a definitions, ~a cycle(s), stop rule fired ~a time(s)~n"
          (length closure-order) (length closure-cycles) closure-back-edges)
  ;; Install the whole closure first, in dependency order.  Doing it in one
  ;; pass instead of per site is what keeps the cost linear: each definition is
  ;; evaluated at most once, and nothing has to fail to be discovered.
  (let ((t0 (real-time)))
    (for-each ensure-installed! closure-order)
    (printf "      installed ~a definitions from the index in ~a ms~n"
            (hashtable-size installed) (- (real-time) t0)))
  (let ((t0 (real-time)))
    (for-each
      (lambda (site)
        (unless (kernel-file? (site-file site))
          (let ((top (site-top site))
                (name (site-name site))
                (was-macro? (macro? (site-name site))))
            (guard (c (else
                       (set! n-warm-fail (+ n-warm-fail 1))
                       (bucket! warm-buckets c "")
                       (hashtable-set! site-status site 'fail)))
              ;; the definer heading the form is part of site-deps, so a
              ;; (define-export-macro ...) site can no longer expand as a call
              (for-each ensure-installed! (site-deps site))
              (expand top (tm-lint-env))
              (set! n-warm-ok (+ n-warm-ok 1))
              (guard (c (else
                         (set! n-eval-fail (+ n-eval-fail 1))
                         (bucket! warm-buckets c "eval: ")))
                (chez-eval top (tm-lint-env))
                (unless was-macro?
                  (when (macro? name)
                    (set! n-macro-installed (+ n-macro-installed 1))))
                (hashtable-update! macro-deps name (lambda (d) (remq name d)) '()))))))
      macro-sites)
    (printf "      expanded ~a, failed ~a in ~a ms~n"
            n-warm-ok n-warm-fail (- (real-time) t0)))
  (printf "      eval failures (form expanded but did not evaluate): ~a~n"
          n-eval-fail)
  (printf "      macros newly installed: ~a~n" n-macro-installed)
  (printf "      definitions installed from the index: ~a (failed ~a)~n"
          n-helper-installed n-install-fail))

;;; ------------------------------------------- module dependency graph (5/5)
;;
;; This is what the analysis is for.  The kernel is already compiled and can
;; never be a scheduling choice, so the question is only: among the modules
;; still to be built, which must precede which?
;;
;; The graph is built SYNTACTICALLY, not by expanding.  Expanding every
;; top-level form of every module fails on more than half of them, because a
;; form can only be expanded in the module context it was written for:
;; (export ...) outside a module, (tm-define ...) without its option tables, a
;; macro whose helpers live in a module that is not loaded.  Chasing that means
;; re-implementing the loader.
;;
;; Reading the forms and collecting free names needs no environment at all,
;; covers every form, and errs only in the safe direction: it can see a
;; reference that never executes (a dead branch, or a local name that happens
;; to match a top-level definition), which may order two modules that could
;; have run in parallel.  It cannot miss one.  For a build schedule that is the
;; right direction to be wrong in.
;;
;; Each free name then resolves to a module:
;;   kernel      -> already compiled, always satisfied
;;   C++ glue    -> bound in env but defined nowhere in the tree, satisfied
;;   same module -> intra-module, no ordering constraint
;;   other       -> a real edge
;;   nothing     -> a local binding this walker does not model; discarded

(define mod-nodes  (make-hashtable equal-hash equal?))  ; node -> #t
(define mod-edges  (make-hashtable equal-hash equal?))  ; from -> (to ...) it needs
(define mod-rev    (make-hashtable equal-hash equal?))  ; to -> (from ...)
(define mod-via    (make-hashtable equal-hash equal?))  ; (from . to) -> (names ...)
(define mod-levels (make-hashtable equal-hash equal?))  ; node -> wave

(define n-kernel-refs 0)
(define n-external-refs 0)
(define n-intra-refs 0)
(define n-local-refs 0)    ; resolvable neither in the tree nor in env: a local name
(define n-macro-edges 0)

(define (site-key s) (site-module s))

;; hashtable-size counts keys, and a key here is a module with outgoing edges.
;; The edge count is the sum of the adjacency lists.
(define (count-edges)
  (let loop ((ks (vector->list (hashtable-keys mod-edges))) (n 0))
    (if (null? ks) n
        (loop (cdr ks) (+ n (length (hashtable-ref mod-edges (car ks) '())))))))

(define (note-edge! from to dep)
  (unless (equal? to from)
    (hashtable-set! mod-nodes to #t)
    (hashtable-update! mod-edges from
                       (lambda (l) (if (member to l) l (cons to l))) '())
    (hashtable-update! mod-rev to
                       (lambda (l) (if (member from l) l (cons from l))) '())
    (hashtable-update! mod-via (cons from to)
                       (lambda (l) (if (member dep l) l (cons dep l))) '())))

;; A syntactic walk cannot tell a local from a global, so a name that is
;; neither defined in the tree nor bound in env is almost certainly a local
;; binding form this walker does not model (`with', `for', `do', `receive',
;; ...).  Those are discarded rather than reported: a real dangling reference
;; is what phases 3-4 catch, and they find none.
(define (headerless? rel)
  (let ((m (hashtable-ref file-module rel #f)))
    (or (not m) (eq? (car m) 'no-header))))

(define (note-dep-edge! from dep)
  (let ((s (hashtable-ref defs dep #f)))
    (cond
      ((not s)
       (if (top-level-bound? dep (tm-lint-env))
           (set! n-external-refs (+ n-external-refs 1))
           (set! n-local-refs (+ n-local-refs 1))))
      ;; A file with no texmacs-module header is a bootstrap or init script,
      ;; not a module: it has no place in the build order.  Counting it as an
      ;; edge target makes init-linter.scm (which defines current-module and
      ;; module-name) a hub that every module appears to depend on.
      ((headerless? (site-file s))
       (set! n-external-refs (+ n-external-refs 1)))
      ((kernel-file? (site-file s))
       (set! n-kernel-refs (+ n-kernel-refs 1)))
      ((equal? (site-key s) from)
       (set! n-intra-refs (+ n-intra-refs 1)))
      (else (note-edge! from (site-key s) dep)))))

(define (note-form-refs! from form)
  (for-each (lambda (dep) (note-dep-edge! from dep)) (free-names form)))

(define (note-file-refs! rel)
  (unless (headerless? rel)
    (let* ((from (hashtable-ref file-module rel '(no-header)))
           (forms (call-with-values
                      (lambda () (read-all-forms (string-append *root* "/" rel)))
                    (lambda (fs _) fs))))
      (hashtable-set! mod-nodes from #t)
      (for-each (lambda (f) (note-form-refs! from f)) forms))))

(define (build-module-graph ordered)
  ;; the macro pass first, so its contribution can be reported separately
  (for-each
    (lambda (site)
      (unless (kernel-file? (site-file site))
        (let ((from (site-key site)))
          (hashtable-set! mod-nodes from #t)
          (for-each (lambda (d) (note-dep-edge! from d))
                    (hashtable-ref macro-deps (site-name site) '())))))
    macro-sites)
  (set! n-macro-edges (count-edges))
  (for-each (lambda (rel) (unless (kernel-file? rel) (note-file-refs! rel))) ordered))

;; Tarjan SCC over mod-edges.  TeXmacs modules are mutually recursive in
;; places, so the module graph is not a DAG and a plain topological sort is
;; impossible.  The unit that can be scheduled is the strongly connected
;; component: its members must be compiled together, but the condensation is
;; acyclic.
(define (compute-sccs)
  (let ((index    (make-hashtable equal-hash equal?))
        (low      (make-hashtable equal-hash equal?))
        (on-stack (make-hashtable equal-hash equal?))
        (stack '())
        (counter 0)
        (comps '()))
    (define (pop-until! v)
      (let loop ((acc '()))
        (let ((w (car stack)))
          (set! stack (cdr stack))
          (hashtable-set! on-stack w #f)
          (if (equal? w v) (cons w acc) (loop (cons w acc))))))
    (define (strongconnect! v)
      (hashtable-set! index v counter)
      (hashtable-set! low v counter)
      (set! counter (+ counter 1))
      (set! stack (cons v stack))
      (hashtable-set! on-stack v #t)
      (for-each
        (lambda (w)
          (cond
            ((not (hashtable-ref index w #f))
             (strongconnect! w)
             (hashtable-set! low v (min (hashtable-ref low v 0)
                                        (hashtable-ref low w 0))))
            ((hashtable-ref on-stack w #f)
             (hashtable-set! low v (min (hashtable-ref low v 0)
                                        (hashtable-ref index w 0))))))
        (hashtable-ref mod-edges v '()))
      (when (= (hashtable-ref low v 0) (hashtable-ref index v 0))
        (set! comps (cons (pop-until! v) comps))))
    (for-each (lambda (v) (unless (hashtable-ref index v #f) (strongconnect! v)))
              (vector->list (hashtable-keys mod-nodes)))
    comps))

;; Waves over the condensation: component n may start once every component it
;; depends on is done.
(define (condensation-waves comps)
  (let* ((comp-of (make-hashtable equal-hash equal?))
         (cid (make-hashtable equal-hash equal?))
         (cedges (make-hashtable equal-hash equal?))
         (crev (make-hashtable equal-hash equal?))
         (remaining (make-hashtable equal-hash equal?)))
    (let loop ((cs comps) (i 0))
      (when (pair? cs)
        (for-each (lambda (n) (hashtable-set! comp-of n i)) (car cs))
        (hashtable-set! cid i (car cs))
        (hashtable-set! cedges i '())
        (hashtable-set! crev i '())
        (loop (cdr cs) (+ i 1))))
    (for-each
      (lambda (from)
        (let ((cf (hashtable-ref comp-of from 0)))
          (for-each
            (lambda (to)
              (let ((ct (hashtable-ref comp-of to 0)))
                (unless (= cf ct)
                  (hashtable-update! cedges cf
                                     (lambda (l) (if (member ct l) l (cons ct l))) '())
                  (hashtable-update! crev ct
                                     (lambda (l) (if (member cf l) l (cons cf l))) '()))))
            (hashtable-ref mod-edges from '()))))
      (vector->list (hashtable-keys mod-edges)))
    (let ((ncomp (hashtable-size cid)))
      (for-each (lambda (i) (hashtable-set! remaining i
                                            (length (hashtable-ref cedges i '()))))
                (let loop ((i 0) (acc '()))
                  (if (= i ncomp) acc (loop (+ i 1) (cons i acc)))))
      (let loop ((placed '()) (wave 0) (waves '()))
        (let ((ready (chez-filter
                       (lambda (i)
                         (and (not (memv i placed))
                              (= 0 (hashtable-ref remaining i 0))))
                       (let inner ((i 0) (acc '()))
                         (if (= i ncomp) acc (inner (+ i 1) (cons i acc)))))))
          (cond
            ((null? ready)
             (values (reverse waves) (chez-filter (lambda (i) (not (memv i placed)))
                                                  (let inner ((i 0) (acc '()))
                                                    (if (= i ncomp) acc
                                                        (inner (+ i 1) (cons i acc)))))))
            (else
             (for-each
               (lambda (i)
                 (for-each (lambda (d)
                             (hashtable-update! remaining d
                                                (lambda (v) (if (> v 0) (- v 1) 0)) 0))
                           (hashtable-ref crev i '())))
               ready)
             (loop (append ready placed) (+ wave 1)
                   (cons (map (lambda (i) (hashtable-ref cid i #f)) ready) waves)))))))))

(define (show-list xs limit)
  (let ((n (length xs)))
    (if (<= n limit)
        (join-strings (map (lambda (x) (format "~s" x)) xs) " ")
        (string-append
          (join-strings (map (lambda (x) (format "~s" x)) (list-head xs limit)) " ")
          (format " ... (~a more)" (- n limit))))))

(define (report-module-graph ordered)
  (printf "~n[5/5] module dependency graph (non-kernel only) ...~n")
  (build-module-graph ordered)
  (printf "      nodes: ~a   edges: ~a   (edges from macro transformers alone: ~a)~n"
          (hashtable-size mod-nodes) (count-edges) n-macro-edges)
  (printf "      references: kernel ~a | C++ glue ~a | same module ~a | unresolved ~a~n"
          n-kernel-refs n-external-refs n-intra-refs n-local-refs)
  (let* ((comps (compute-sccs))
         (big (chez-filter (lambda (c) (> (length c) 1)) comps)))
    (printf "~n      strongly connected components: ~a, of which ~a have more than one~n"
            (length comps) (length big))
    (for-each
      (lambda (c)
        (printf "        ~a modules: ~a~n" (length c)
                (show-list (chez-sort (lambda (a b) (string<? (format "~s" a)
                                                              (format "~s" b))) c)
                           8)))
      (list-head (chez-sort (lambda (a b) (> (length a) (length b))) big)
                 (min 5 (length big))))
    (let-values (((waves stuck) (condensation-waves comps)))
      (cond
        ((pair? stuck)
         (printf "~n      WARNING: ~a component(s) could not be layered.~n" (length stuck)))
        (else
         (printf "~n      waves over the condensation: ~a (widths ~a)~n"
                 (length waves) (join-strings (map (lambda (w) (format "~a" (length w)))
                                                   waves) "/")))))
    (printf "~n      NOTE: this graph is a syntactic over-approximation.  It can see a~n")
    (printf "      reference that never runs, so the cycle structure is an upper~n")
    (printf "      bound on coupling, not a build plan.  The authoritative order~n")
    (printf "      comes from compile-texmacs.scm, which expands each module in its~n")
    (printf "      own context; this graph is a cross-check on it.~n")))


(define (report-summary)
  (newline)
  (printf "============================================================~n")
  (printf " SUMMARY~n")
  (printf "============================================================~n")
  (printf "macro definition sites        ~a~n" (length macro-sites))
  (printf "  kernel, not analysed        ~a~n"
          (length (chez-filter (lambda (s) (kernel-file? (site-file s))) macro-sites)))
  (printf "  analysed                    ~a~n"
          (length (chez-filter (lambda (s) (not (kernel-file? (site-file s))))
                               macro-sites)))
  (printf "  expanded, kernel-only env   ~a~n" n-cold-ok)
  (printf "  failed,   kernel-only env   ~a~n" n-cold-fail)
  (printf "  expanded, proactive closure ~a~n" n-warm-ok)
  (printf "  failed,   proactive closure ~a~n" n-warm-fail)
  (printf "distinct dependencies         ~a~n" (hashtable-size dep-count))
  (printf "definitions installed         ~a~n" n-helper-installed)
  (printf "closure: definitions / cycles ~a / ~a~n"
          (length closure-order) (length closure-cycles))
  (printf "closure: stop rule fired      ~a~n" closure-back-edges)
  (printf "module nodes / edges          ~a / ~a~n"
          (hashtable-size mod-nodes) (count-edges))
  (printf "  refs: kernel / glue / intra ~a / ~a / ~a~n"
          n-kernel-refs n-external-refs n-intra-refs)
  (printf "  refs: unresolved (locals)   ~a~n" n-local-refs)
  (let ((kinds (make-hashtable equal-hash equal?)))
    (for-each (lambda (n)
                (hashtable-update! kinds (classify n) (lambda (v) (+ v 1)) 0))
              (vector->list (hashtable-keys dep-count)))
    (newline)
    (printf "--- dependencies by kind ---~n")
    (for-each (lambda (k) (printf "  ~5d  ~a~n" (hashtable-ref kinds k 0) k))
              (chez-sort (lambda (a b) (> (hashtable-ref kinds a 0)
                                          (hashtable-ref kinds b 0)))
                         (vector->list (hashtable-keys kinds)))))
  (let ((top (chez-sort (lambda (a b) (> (demand a) (demand b)))
                        (vector->list (hashtable-keys dep-count)))))
    (newline)
    (printf "--- 25 most-demanded dependencies ---~n")
    (for-each (lambda (n) (printf "  ~5d  ~a  [~a]~n" (demand n) n (classify n)))
              (list-head top (if (< (length top) 25) (length top) 25))))
  (let ((unk (chez-filter (lambda (n) (eq? (classify n) 'unknown))
                          (vector->list (hashtable-keys dep-count)))))
    (newline)
    (printf "--- referenced but defined nowhere (external glue or a real bug) ---~n")
    (printf "  count: ~a~n" (length unk))
    (for-each (lambda (n) (printf "  ~5d  ~a~n" (demand n) n))
              (list-head (chez-sort (lambda (a b) (> (demand a) (demand b))) unk)
                         (if (< (length unk) 30) (length unk) 30))))
  (when (> (hashtable-size cold-buckets) 0)
    (print-top cold-buckets "phase 3 failure reasons (kernel only)" 12))
  (when (> (hashtable-size warm-buckets) 0)
    (print-top warm-buckets "phase 4 failure reasons (proactive closure)" 12))
)

(define (write-reports)
  (let ((p (out-path "TEXMACS_LINT_OUT" "macro-lint.tsv")))
    (when (file-exists? p) (delete-file p))
    (call-with-output-file p
      (lambda (port)
        (fprintf port "name\tdefiner\tfile\tmodule\tstatus\tdep-count\tdeps~n")
        (for-each
          (lambda (s)
            (let* ((n (site-name s))
                   (d (hashtable-ref macro-deps n '())))
              (fprintf port "~a\t~a\t~a\t~a\t~a\t~a\t~a~n"
                       n (car (site-inner s)) (site-file s) (site-module s)
                       (cond ((kernel-file? (site-file s)) "kernel")
                             ((eq? (hashtable-ref site-status s #f) 'fail) "FAIL")
                             (else "ok"))
                       (length d)
                       (if (null? d) "-" (symbols->string d ",")))))
          macro-sites)))
    (printf "~nWROTE ~a (~a rows)~n" p (length macro-sites)))
  (let ((p (out-path "TEXMACS_LINT_DEPS_OUT" "macro-lint-deps.tsv")))
    (when (file-exists? p) (delete-file p))
    (call-with-output-file p
      (lambda (port)
        (fprintf port "dependency\tkind\tdemand\tusers~n")
        (for-each
          (lambda (n)
            (fprintf port "~a\t~a\t~a\t~a~n" n (classify n) (demand n)
                     (symbols->string (hashtable-ref dep-users n '()) ",")))
          (chez-sort (lambda (a b) (string<? (symbol->string a)
                                             (symbol->string b)))
                     (vector->list (hashtable-keys dep-count))))))
    (printf "WROTE ~a (~a rows)~n" p (hashtable-size dep-count)))
  ;; The recorded closure: for every macro definition, the unique set of
  ;; in-tree names that must be live before it can be expanded.
  (let ((p (out-path "TEXMACS_LINT_CLOSURE_OUT" "macro-closure.tsv")))
    (when (file-exists? p) (delete-file p))
    (call-with-output-file p
      (lambda (port)
        (fprintf port "name\tdefiner\tfile\tmodule\tclosure-size\tclosure~n")
        (for-each
          (lambda (s)
            (let* ((n (site-name s))
                   (c (chez-sort (lambda (a b) (string<? (symbol->string a)
                                                         (symbol->string b)))
                                 (hashtable-ref closure-sets n '()))))
              (fprintf port "~a\t~a\t~a\t~a\t~a\t~a~n"
                       n (car (site-inner s)) (site-file s) (site-module s)
                       (length c)
                       (if (null? c) "-" (symbols->string c ",")))))
          macro-sites)))
    (printf "~nWROTE ~a (~a rows)~n" p (length macro-sites)))
  (let* ((p (out-path "TEXMACS_LINT_MODULES_OUT" "macro-lint-modules.tsv"))
         (rows (apply append
                      (map (lambda (from)
                             (map (lambda (to)
                                    (list from to (hashtable-ref mod-via (cons from to) '())))
                                  (hashtable-ref mod-edges from '())))
                           (vector->list (hashtable-keys mod-edges))))))
    (when (file-exists? p) (delete-file p))
    (call-with-output-file p
      (lambda (port)
        (fprintf port "from\tto\twave-from\twave-to\tvia-count\tvia~n")
        (for-each
          (lambda (r)
            (fprintf port "~s\t~s\t~a\t~a\t~a\t~a~n"
                     (car r) (cadr r)
                     (hashtable-ref mod-levels (car r) 0)
                     (hashtable-ref mod-levels (cadr r) 0)
                     (length (caddr r))
                     (symbols->string (caddr r) ",")))
          (chez-sort (lambda (a b)
                       (let ((ka (format "~s|~s" (car a) (cadr a)))
                             (kb (format "~s|~s" (car b) (cadr b))))
                         (string<? ka kb)))
                     rows))))
    (printf "WROTE ~a (~a rows)~n" p (length rows))))

(define (tm-run-linter)
  (let* ((all (walk-files *root*))
         ;; kernel first, then the rest: dependencies point "up" the tree, and
         ;; the lazy installer copes with everything else.
         (ordered (append (chez-filter (lambda (p) (string-prefix? "kernel/" p)) all)
                          (chez-filter (lambda (p) (not (string-prefix? "kernel/" p)))
                                       all))))
    (printf "~n============================================================~n")
    (printf " TeXmacs macro linter~n")
    (printf "============================================================~n")
    (printf "root    ~a~n" *root*)
    (printf "env     interaction-environment~n")
    (let loop ((fs ordered) (i 0))
      (when (pair? fs)
        (hashtable-set! file-order (car fs) i)
        (loop (cdr fs) (+ i 1))))
    (report-phase1 ordered)
    (set! macro-sites (collect-macro-sites))
    (report-phase2)
    (report-phase3)
    (report-phase4)
    (report-module-graph ordered)
    (report-summary)
    (write-reports)
    (newline)
    (printf "DONE~n")
    (flush-output-port (current-output-port))))
