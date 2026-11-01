;;; static-analysis-test.scm -- Self-contained tests for (static-analysis).
;;;
;;; Runs under plain Chez Scheme, no TeXmacs runtime needed:
;;;
;;;   chez --script src/Scheme/Chez/static-analysis-test.scm
;;;
;;; Exits 0 when every check passes, 1 otherwise.

(library-directories
  (cons (let loop ((d (current-directory)))
          (let ((here (string-append d "/src/Scheme/Chez")))
            (cond ((file-exists? (string-append here "/static-analysis.scm")) here)
                  ((file-exists? (string-append d "/../src/Scheme/Chez/static-analysis.scm"))
                   (string-append d "/../src/Scheme/Chez"))
                  (else d))))
        (library-directories)))

(import (chezscheme) (compiler-db) (compiler-scan) (static-analysis))

;;; ---------------------------------------------------------------------------
;;; Harness
;;; ---------------------------------------------------------------------------

(define failures 0)
(define checks 0)

(define (check! label expected got)
  (set! checks (+ checks 1))
  (unless (equal? expected got)
    (set! failures (+ failures 1))
    (printf "FAIL  ~a\n        expected ~s\n        got      ~s\n" label expected got)))

(define (check-true! label got) (check! label #t (and got #t)))

(define (check-raises! label thunk)
  (set! checks (+ checks 1))
  (unless (guard (e (else #t)) (thunk) #f)
    (set! failures (+ failures 1))
    (printf "FAIL  ~a\n        expected an exception, none raised\n" label)))

;;; ---------------------------------------------------------------------------
;;; Fixtures: two small modules on disk
;;; ---------------------------------------------------------------------------

(define tmp (string-append "/tmp/static-analysis-test-" (number->string (get-process-id))))

(define (write-fixture! rel text)
  (let ((path (string-append tmp "/" rel)))
    (call-with-output-file path
      (lambda (out) (display text out))
      '(replace))
    rel))

(unless (file-exists? tmp) (mkdir tmp))

(define mod-a
  (write-fixture! "mod-a.scm"
    "(texmacs-module (test a) (:use (test b)))\n\
     (define-public (shared-fn x) x)\n\
     (define (lazy-helper v) (* v 2))\n\
     (tm-define (multi y) y)\n\
     (tm-define (multi y z) z)\n\
     (define (init) 1)\n"))

(define mod-b
  (write-fixture! "mod-b.scm"
    "(texmacs-module (test b))\n\
     (define-public (other-fn) 2)\n\
     (define (init) 99)\n"))

(index-module-definitions tmp (list mod-a mod-b))

;;; ---------------------------------------------------------------------------
;;; 1. Indexer and resolver scope order
;;; ---------------------------------------------------------------------------

(define resolve-a (make-resolver '(test a) '((test b))))
(define resolve-b (make-resolver '(test b) '()))

(check! "local definition wins over the same name in a dep"
        '(define (init) 1)
        (resolve-a 'init))

(check! "dep definition is reachable through (:use ...)"
        '(define-public (other-fn) 2)
        (resolve-a 'other-fn))

(check! "a module does not see a module it does not import"
        #f
        (resolve-b 'shared-fn))

(check! "unknown symbol resolves to #f"
        #f
        (resolve-a 'no-such-symbol))

(check-raises! "overloaded tm-define fails fast"
               (lambda () (resolve-a 'multi)))

(check! "definition-name handles curried heads"
        'curried
        (definition-name '(define ((curried a) b) a)))

(check! "definition-name rejects non-definers"
        #f
        (definition-name '(display 1)))

(check! "definer-form? separates definitions from expressions"
        '(#t #f)
        (list (definer-form? '(define-public (f) 1))
              (definer-form? '(f 1))))

;; A module under kernel/ needs no (:use ...) declaration to be visible.
(define mod-k
  (write-fixture! "kernel-helper.scm"
    "(texmacs-module (kernel test helper))\n\
     (define-public (kernel-helper) 1)\n"))
(index-module-definitions tmp (list mod-k))

(check! "kernel modules are visible without (:use ...)"
        '(define-public (kernel-helper) 1)
        ((make-lookup '(test c) '()) 'kernel-helper))

(check! "an unimported module is still not visible"
        #f
        ((make-lookup '(test c) '()) 'shared-fn))

;;; ---------------------------------------------------------------------------
;;; 2. Lazy helper installation through a gensym irritant
;;;
;;; The transformer raises once with an *uninterned* symbol, exactly as Chez
;;; does when a procedural macro touches an unbound identifier.  The resolver
;;; must intern it, find lazy-helper in the index, install it, and retry.
;;; ---------------------------------------------------------------------------

(define lazy-env (copy-environment (interaction-environment) #t))

(eval '(define raised-count 0) lazy-env)
(eval '(define-syntax lazy-macro
         (lambda (stx)
           (when (= raised-count 0)
             (set! raised-count 1)
             (raise (condition
                     (make-irritants-condition
                      (list (string->uninterned-symbol "lazy-helper"))))))
           (syntax-case stx ()
             ((_ v) #'(+ v 1)))))
      lazy-env)

(check! "lazy-helper is not bound before expansion"
        #f
        (top-level-bound? 'lazy-helper lazy-env))

(let-values (((core uses)
              (expand-with-lazy-helpers '(lazy-macro 1) lazy-env resolve-a)))
  (check! "gensym irritant is interned and the helper is recorded"
          '(lazy-helper)
          uses)
  (check-true! "expansion succeeds after the helper is installed"
               (pair? core))
  (check! "the installed helper is now bound"
          #t
          (top-level-bound? 'lazy-helper lazy-env)))

;;; ---------------------------------------------------------------------------
;;; 3. Core AST walk, driven by the real expander
;;;
;;; Expectations are derived from what Chez actually emits, so an expander
;;; change shows up here instead of as silent misreporting.
;;; ---------------------------------------------------------------------------

(define ast-env (copy-environment (interaction-environment) #t))
(define (ast-of form) (expand form ast-env))

(let-values (((unbound uses) (walk-core-ast (ast-of '(define (foo-a x) (+ x 1)))
                                           ast-env (make-eq-hashtable))))
  (check! "a definition binds its name instead of reporting it"
          '()
          unbound)
  (check! "a definition body still reports its references"
          '(+ void)
          uses))

(let-values (((unbound uses) (walk-core-ast (ast-of '(undefined-typo 3))
                                           ast-env (make-eq-hashtable))))
  (check! "a global reference to a typo is reported"
          '(undefined-typo)
          unbound)
  (check! "a global reference is recorded as a use"
          '(undefined-typo)
          uses))

(let-values (((unbound uses) (walk-core-ast (ast-of '(lambda (y) (+ y 1)))
                                           ast-env (make-eq-hashtable))))
  (check! "lambda formals are not reported"
          '()
          unbound)
  (check! "lambda body references are kept"
          '(+)
          uses))

(let-values (((unbound uses) (walk-core-ast (ast-of '(let ((z 1)) (+ z 2)))
                                           ast-env (make-eq-hashtable))))
  (check! "let bindings are not reported"
          '()
          unbound)
  (check! "let body references are kept"
          '(+)
          uses))

(let ((form '(letrec ((lp (lambda (n) (lp n)))) (lp 1))))
  (let-values (((unbound uses) (walk-core-ast (ast-of form) ast-env (make-eq-hashtable))))
    (check! "named let does not report its loop variable"
            '()
            unbound)))

(let-values (((unbound uses) (walk-core-ast (ast-of '(do ((i 0 (+ i 1))) ((> i 3) i)))
                                           ast-env (make-eq-hashtable))))
  (check! "do loop variables are not reported"
          '()
          unbound))

;; A name the source index knows is not unbound, even though nothing was
;; loaded: this is what lets the linter run before any compilation.
(let-values (((unbound uses) (walk-core-ast (ast-of '(other-fn 1))
                                           ast-env (make-eq-hashtable)
                                           (lambda (sym) (eq? sym 'other-fn)))))
  (check! "known? suppresses a name the source index defines"
          '()
          unbound)
  (check! "a known name is still recorded as a use"
          '(other-fn)
          uses))

(let-values (((unbound uses) (walk-core-ast (ast-of '(quote (a b c)))
                                           ast-env (make-eq-hashtable))))
  (check! "quoted data is not walked"
          '()
          unbound)
  (check! "quoted data records no uses"
          '()
          uses))

;;; ---------------------------------------------------------------------------
;;; 4. analyze-forms: end to end over a form list
;;; ---------------------------------------------------------------------------

(define forms-env (copy-environment (interaction-environment) #t))
(define installed '())

;; Plain `define' forms here on purpose: the analysis library assumes the
;; caller's environment already supplies the TeXmacs macros (define-public,
;; tm-define, ...).  Plain Chez does not, so the fixture stays macro-free.
(let-values (((unbound runtime compile fails)
              (analyze-forms
               '((define (local-helper v) v)
                 (define public-fn (lambda (v) (local-helper v)))
                 (undefined-typo 3))
               forms-env
               '(test a)
               '()
               (lambda (form env)
                 (set! installed (cons (definition-name form) installed))
                 (guard (e (else #f)) (eval form env))))))
  (check! "analyze-forms installs every defining form in order"
          '(local-helper public-fn)
          (reverse installed))
  (check! "analyze-forms reports the typo and nothing else"
          '(undefined-typo)
          unbound)
  (check! "analyze-forms reports no expansion failures"
          '()
          fails)
  (check-true! "analyze-forms collected runtime uses"
               (and (memq 'local-helper runtime) #t))
  (check! "analyze-forms returns compile-uses as a list"
          #t
          (list? compile)))

;; Names from a declared dependency resolve from source, so they are not
;; reported; only the genuine typo is.
(let-values (((unbound runtime compile fails)
              (analyze-forms
               '((define (local) 1)
                 (undefined-typo 2)
                 (other-fn))
               (copy-environment (interaction-environment) #t)
               '(test a)
               '((test b))
               (lambda (form env) (guard (e (else #f)) (eval form env))))))
  (check! "a name from a declared dep is not reported unbound"
          '(undefined-typo)
          unbound))

;;; ---------------------------------------------------------------------------
;;; 5. analyze-module over a real file
;;; ---------------------------------------------------------------------------

(let-values (((unbound runtime compile fails)
              (analyze-module tmp mod-a
                              (copy-environment (interaction-environment) #t)
                              (lambda (form env) (guard (e (else #f)) (eval form env))))))
  (check! "analyze-module returns four values"
          4
          (length (list unbound runtime compile fails)))
  (check! "analyze-module reports no expansion failures on a clean module"
          '()
          fails))

;;; ---------------------------------------------------------------------------
;;; Summary
;;; ---------------------------------------------------------------------------

(printf "\n~a checks, ~a failure~a\n"
        checks failures (if (= failures 1) "" "s"))
(if (= failures 0)
    (begin (printf "STATIC-ANALYSIS-TESTS-OK\n") (exit 0))
    (begin (printf "STATIC-ANALYSIS-TESTS-FAILED\n") (exit 1)))
