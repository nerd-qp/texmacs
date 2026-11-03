;;; linter.scm -- four-phase static analysis of TeXmacs's macro layer.
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
;;;
;;; Phases 3 and 4 are deliberately separate runs over the same forms: phase 3
;;; sees only what the kernel provides, phase 4 is allowed to pull definitions
;;; out of the index on demand.  The difference between the two is the point of
;;; the report -- it is the set of macros that cannot be expanded without help
;;; from outside the kernel.
;;;
;;; Output: a human summary on stdout plus two TSV files, whose paths come from
;;; $TEXMACS_LINT_OUT (default ./macro-lint.tsv) and $TEXMACS_LINT_DEPS_OUT
;;; (default ./macro-lint-deps.tsv).

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
;; pointless here, and it resolves `current-module-env' on every call.
(define chez-eval (if (top-level-bound? 'tm-orig-eval) tm-orig-eval eval))

(define (tm-lint-env) (interaction-environment))

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
;; `expand` renames every lexical and module-internal binding to a gensym, so a
;; plain (non-gensym) symbol left in the core AST is a reference to a top-level
;; binding.  That is the entire dependency rule: no scope tracking needed.

(define (free-names core)
  (define acc '())
  (define (add s) (unless (memq s acc) (set! acc (cons s acc))))
  (define (walk-all xs b) (walk-each xs (lambda (x) (walk x b))))
  (define (walk x b)
    (cond
      ((symbol? x)
       (unless (or (memq x b) (gensym? x) (keyword? x)) (add x)))
      ((pair? x)
       (let ((h (car x)))
         (cond
           ;; primitive reference, not a call
           ((and (symbol? h) (eq? h '$primitive)) (void))
           ;; (($primitive n $top-level-value) 'name) -- a top-level lookup
           ((eq? (prim-op x) '$top-level-value)
            (let ((s (quoted-symbol (cadr x))))
              (when (symbol? s) (add s))))
           ;; other primitive call: skip the operator, walk the arguments
           ((prim-op x) (walk-all (cdr x) b))
           ((eq? h 'quote) (void))
           ((and (symbol? h) (eq? h 'lambda))
            (walk-all (cddr x) (formals->list (cadr x) b)))
           ((and (symbol? h) (eq? h 'case-lambda))
            (for-each (lambda (clause)
                        (walk-all (cdr clause) (formals->list (car clause) b)))
                      (cdr x)))
           ((and (symbol? h) (memq h '(let letrec letrec*)))
            (let* ((bs (cadr x))
                   (names (formals->list (map car bs) b)))
              (walk-all (map cdr bs) b)
              (walk-all (cddr x) names)))
           ((and (symbol? h) (memq h '(let-values let*-values)))
            (walk-all (cddr x) b))
           ((and (symbol? h) (memq h '(begin if set! define and or when unless
                                       do cond)))
            (walk-all (cdr x) b))
           (else (walk-all x b)))))
      (else (void))))
  (walk core '())
  (reverse acc))

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
;; expansion hides the body.
(define (transformer-expr form)
  (and (pair? form) (pair? (cdr form))
       (let ((head (car form)) (spec (cadr form)))
         (cond
           ((and (memq head '(define-macro define-public-macro
                              define-module-macro define-export-macro
                              tm-define-macro))
                 (pair? spec))
            `(lambda ,(cdr spec) ,@(cddr form)))
           ((and (eq? head 'define-syntax) (symbol? spec) (pair? (cddr form)))
            (let ((v (caddr form)))
              (and (pair? v) (eq? (car v) 'lambda) v)))
           (else #f)))))

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
;; the enclosing top-level form.  Quoted data, syntax-rules templates and
;; quasiquote bodies are skipped: a (define-macro ...) written inside a
;; template is generated code, not a definition in this file.
(define (index-form! top form file module)
  (define (walk x)
    (when (pair? x)
      (cond
        ((memq (car x) '(quote syntax-rules quasiquote)) (void))
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

(define (index-file! rel)
  (let* ((path (string-append *root* "/" rel))
         (forms (call-with-values (lambda () (read-all-forms path))
                   (lambda (fs trunc)
                     (when trunc (set! truncated (cons rel truncated)))
                     fs)))
         (mod (module-of forms)))
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

(define (unbound-symbol c)
  "The symbol named by an unbound-variable condition, or #f."
  (and (condition? c)
       (let ((irr (and (irritants-condition? c) (condition-irritants c))))
         (cond
           ((and (pair? irr) (symbol? (car irr)) (car irr)))
           (else
            (let ((m (and (message-condition? c) (condition-message c))))
              (and (string? m)
                   (let* ((len (string-length m))
                          (p (let loop ((i 0))
                               (cond ((> (+ i 9) len) #f)
                                     ((string=? (substring m i (+ i 9)) "variable ")
                                      (+ i 9))
                                     (else (loop (+ i 1)))))))
                     (and p
                          (let loop ((j p))
                            (cond ((>= j len) #f)
                                  ((char=? (string-ref m j) #\space)
                                   (string->symbol (substring m p j)))
                                  (else (loop (+ j 1))))))))))))))

(define (call-with-lazy-deps thunk)
  "Run THUNK, installing indexed definitions for every unbound name it hits."
  (let retry ((tries 0))
    (guard (c (#t (let ((s (unbound-symbol c)))
                    (if (and s
                             (< tries 400)
                             (hashtable-ref defs s #f)
                             (not (hashtable-ref installing s #f)))
                        (begin (install-def! s) (retry (+ tries 1)))
                        (raise c)))))
      (thunk))))

(define (install-def! name)
  "Evaluate the defining form of NAME, pulling in its own helpers as needed."
  (cond
    ((hashtable-ref installed name #f) #t)
    ((hashtable-ref installing name #f) #f)      ; circular: give up quietly
    (else
     (let ((site (hashtable-ref defs name #f)))
       (if (not site) #f
           (begin
             (hashtable-set! installing name #t)
             (let ((ok? (guard (c (else
                                   (set! n-install-fail (+ n-install-fail 1))
                                   (bucket! warm-buckets c "install: ")
                                   #f))
                          (call-with-lazy-deps
                            (lambda () (chez-eval (site-top site) (tm-lint-env))))
                          #t)))
               (hashtable-delete! installing name)
               (when ok?
                 (hashtable-set! installed name #t)
                 (set! n-helper-installed (+ n-helper-installed 1))
                 (set! install-log (cons name install-log)))
               ok?)))))))

(define (ensure-head-macro! site)
  "If SITE's top form is headed by a known macro that is not installed yet,
   install it.  Without this a (define-export-macro ...) site silently expands
   as an ordinary call."
  (let ((top (site-top site)))
    (when (pair? top)
      (let ((head (car top)))
        (when (and (symbol? head) (not (macro? head)))
          (let ((s (hashtable-ref defs head #f)))
            (when (and s (eq? (site-kind s) 'macro))
              (install-def! head))))))))

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

;; kernel/boot is the compiler's own substrate: boot-chez.scm defines
;; define-macro / with / define-public-macro, and boot.scm conditionally
;; *redefines* them for other dialects.  Expanding those forms re-runs the
;; bootstrap and rewrites the macro layer under our feet, which turns every
;; later expansion into an "invalid syntax" error.  The bootstrap is already
;; loaded, so its macros are indexed (for dependency resolution) but never
;; re-expanded.
(define (boot-file? rel) (string-prefix? "kernel/boot/" rel))

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
  (printf "~n[1/4] indexing definitions ...~n")
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
  (printf "~n[2/4] selecting macro definitions (hardcoded rule) ...~n")
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
  (let ((boot (chez-filter (lambda (s) (boot-file? (site-file s))) macro-sites)))
    (printf "      bootstrap (kernel/boot) definitions, indexed but not re-expanded: ~a~n"
            (length boot))
    (printf "        ~a~n"
            (join-strings (map (lambda (s) (symbol->string (site-name s)))
                               (chez-sort (lambda (a b)
                                            (string<? (symbol->string (site-name a))
                                                      (symbol->string (site-name b))))
                                          boot))
                          " "))
    (printf "        (the bootstrap redefines `with', `with-define' and~n")
    (printf "         `define-public-macro' non-hygienically in abbrevs.scm/boot.scm;~n")
    (printf "         re-expanding it replaces the hygienic versions that~n")
    (printf "         tm-define-macro's own body depends on, after which every~n")
    (printf "         later expansion fails with \"invalid syntax\")~n")))

(define (report-phase3)
  (printf "~n[3/4] expanding with the kernel only, harvesting dependencies ...~n")
  (let ((t0 (real-time))
        (verbose (getenv "TEXMACS_LINT_VERBOSE")))
    (for-each
      (lambda (site)
        (unless (boot-file? (site-file site))
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
  (printf "~n[4/4] evaluating with lazy dependency installation ...~n")
  (let ((t0 (real-time)))
    (for-each
      (lambda (site)
        (unless (boot-file? (site-file site))
          (let ((top (site-top site))
                (name (site-name site))
                (was-macro? (macro? (site-name site))))
            (guard (c (else
                       (set! n-warm-fail (+ n-warm-fail 1))
                       (bucket! warm-buckets c "")
                       (hashtable-set! site-status site 'fail)))
              (ensure-head-macro! site)
              (call-with-lazy-deps (lambda () (expand top (tm-lint-env))))
              (set! n-warm-ok (+ n-warm-ok 1))
              (guard (c (else
                         (set! n-eval-fail (+ n-eval-fail 1))
                         (bucket! warm-buckets c "eval: ")))
                (call-with-lazy-deps (lambda () (chez-eval top (tm-lint-env))))
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
  (printf "      helper definitions pulled from the index: ~a (failed ~a)~n"
          n-helper-installed n-install-fail))

(define (report-summary)
  (newline)
  (printf "============================================================~n")
  (printf " SUMMARY~n")
  (printf "============================================================~n")
  (printf "macro definition sites        ~a~n" (length macro-sites))
  (printf "  expanded, kernel only       ~a~n" n-cold-ok)
  (printf "  failed,   kernel only       ~a~n" n-cold-fail)
  (printf "  expanded, lazy install      ~a~n" n-warm-ok)
  (printf "  failed,   lazy install      ~a~n" n-warm-fail)
  (printf "distinct dependencies         ~a~n" (hashtable-size dep-count))
  (printf "helpers installed on demand   ~a~n" n-helper-installed)
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
    (print-top warm-buckets "phase 4 failure reasons (lazy install)" 12)))

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
                       (cond ((boot-file? (site-file s)) "boot")
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
    (printf "WROTE ~a (~a rows)~n" p (hashtable-size dep-count))))

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
    (report-summary)
    (write-reports)
    (newline)
    (printf "DONE~n")
    (flush-output-port (current-output-port))))
