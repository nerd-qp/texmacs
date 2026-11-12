;;; macro-closure-test.scm -- Self-contained tests for the mc-* walkers
;;; in compiler-oracle.scm.
;;;
;;; Runs under plain Chez Scheme, no TeXmacs runtime needed:
;;;
;;;   chez --script src/Scheme/Chez/macro-closure-test.scm
;;;
;;; Exits 0 when every check passes, 1 otherwise.

(define here
  (let loop ((d (current-directory)))
    (cond ((file-exists? (string-append d "/compiler-oracle.scm")) d)
          ((file-exists? (string-append d "/src/Scheme/Chez/compiler-oracle.scm"))
           (string-append d "/src/Scheme/Chez"))
          ((file-exists? (string-append d "/texmacs/src/Scheme/Chez/compiler-oracle.scm"))
           (string-append d "/texmacs/src/Scheme/Chez"))
          ((file-exists? (string-append d "/../src/Scheme/Chez/compiler-oracle.scm"))
           (string-append d "/../src/Scheme/Chez"))
          (else d))))

(define progs-dir
  (cond ((file-exists? (string-append here "/../../../TeXmacs/progs"))
         (string-append here "/../../../TeXmacs/progs"))
        ((file-exists? (string-append here "/../../TeXmacs/progs"))
         (string-append here "/../../TeXmacs/progs"))
        ((file-exists? "TeXmacs/progs") "TeXmacs/progs")
        (else #f)))

(load (string-append here "/tarjan.scm"))
(load (string-append here "/compiler-oracle.scm"))

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

(define (check-set! label expected got)
  "Compare two lists as sets."
  (check! label (sort-syms expected) (sort-syms got)))

(define (sort-syms xs)
  (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) xs))

;;; ---------------------------------------------------------------------------
;;; 1. free-reference & dependency analysis (expand-based)
;;; ---------------------------------------------------------------------------

(check-set! "lambda binds its formals"
            '(f) (mc-free-references '(lambda (x) (f x))))
(check-set! "lambda rest argument is bound"
            '(f) (mc-free-references '(lambda (x . r) (f r))))
(check-set! "let binds, initialisers stay free"
            '(f g) (mc-free-references '(let ((x (f))) (g x))))
(check-set! "named let binds the loop name"
            '(f) (mc-free-references '(let lp ((i (f))) (lp i))))
(check-set! "let* binds sequentially"
            '(f g) (mc-free-references '(let* ((x (f)) (y (g))) y)))
(check-set! "define binds the head and formals"
            '(g) (mc-free-references '(define (f x) (g x))))
(check-set! "recursive define does not report itself"
            '(g) (mc-free-references '(define (f x) (if (g) (f x) #f))))
(check-set! "define of a plain value binds the name"
            '(f) (mc-free-references '(define x (f))))
(check-set! "quote is data"
            '() (mc-free-references '(quote (f g h))))
(check-set! "quasiquote keeps unquotes (Chez lowers to list)"
            '(f list) (mc-free-references '(quasiquote (a (unquote (f))))))
(check-set! "quasiquote ignores the literal part"
            '() (mc-free-references '(quasiquote (a b c))))
(check-set! "set! target is a reference"
            '(f x) (mc-free-references '(begin (set! x (f)))))
(check-set! "cond/else/=> are not references"
            '(f g) (mc-free-references '(cond ((f) => g) (else #f))))

;; TeXmacs binding macros: with macro environment installed, binders are lexical
(define test-env (copy-environment (scheme-report-environment 5)))
(eval '(define-syntax with (syntax-rules () ((_ v e b ...) (let ((v e)) b ...)))) test-env)
(eval '(define-syntax for
         (syntax-rules ()
           ((_ (i lst) body ...) (for-each (lambda (i) body ...) lst))
           ((_ (i start stop) body ...) (let loop ((i start)) (when (< i stop) body ... (loop (+ i 1))))))) test-env)
(eval '(define-syntax receive
         (syntax-rules ()
           ((_ formals producer body ...)
            (call-with-values (lambda () producer) (lambda formals body ...))))) test-env)

(define (test-macro? s) (memq s '(with for receive)))

(check-set! "with binds its variable and is itself a dependency"
            '(with e f)
            (mc-val-dependencies '(with v e (f v)) test-macro? test-env))
(check-set! "for binds the head of its spec"
            '(for for-each f l)
            (mc-val-dependencies '(for (i l) (f i)) test-macro? test-env))
(check-set! "for with a range spec"
            '(for when r6rs:< f +)
            (mc-val-dependencies '(for (i 0 10) (f i)) test-macro? test-env))
(check-set! "receive binds its formals"
            '(receive call-with-values f g)
            (mc-val-dependencies '(receive (a b) (f) (g a b)) test-macro? test-env))
(check-set! "do binds its variables"
            '(f) (mc-free-references '(do ((i 0)) ((f) i))))

;; Expanded core AST: a global reference is a quoted $top-level-value lookup.
(check-set! "core AST top-level reference"
            '(f) (mc-free-references '((($primitive 2 $top-level-value) 'f) 1)))
(check-set! "core AST definition binds its name"
            '(g) (mc-free-references '((($primitive 3 $set-top-level-value!) 'f
                                  (lambda (x) ((($primitive 2 $top-level-value) 'g) x))))))

;;; ---------------------------------------------------------------------------
;;; 2. macro dependency extraction
;;; ---------------------------------------------------------------------------

(check-set! "define-macro transformer body"
            '(helper)
            (mc-macro-deps '(define-macro (m . args) (helper args))))
(check-set! "define-public-macro transformer body"
            '(helper)
            (mc-macro-deps '(define-public-macro (m x . body) (helper x))))
(check-set! "syntax-rules template references a helper"
            '(helper)
            (mc-macro-deps '(define-syntax m
                              (syntax-rules ()
                                ((_ x) (helper x))))))
(check-set! "syntax-rules pattern variables are not dependencies"
            '(helper)
            (mc-macro-deps '(define-syntax m
                              (syntax-rules ()
                                ((_ x y) (helper x y))))))
(check-set! "syntax-rules literals are not dependencies"
            '(helper)
            (mc-macro-deps '(define-syntax m
                              (syntax-rules (=>)
                                ((_ x => y) (helper x y))))))
(check-set! "syntax-rules template binders are not dependencies"
            '(helper)
            (mc-macro-deps '(define-syntax m
                              (syntax-rules ()
                                ((_ x) (let ((tmp x)) (helper tmp)))))))
(check-set! "syntax-rules ellipsis is not a dependency"
            '(helper)
            (mc-macro-deps '(define-syntax m
                              (syntax-rules ()
                                ((_ x ...) (helper x ...))))))

;;; ---------------------------------------------------------------------------
;;; 3. closure over a synthetic index
;;; ---------------------------------------------------------------------------

;; A site here is just its dependency list, so DEPS-OF is the identity.
(define (site-deps site) site)

(define (make-defs table)
  (let ((h (make-eq-hashtable)))
    (for-each (lambda (k) (hashtable-set! h (car k) (cdr k))) table)
    h))

(define (closure defs target)
  (let-values (((order closures cycles back) (mc-closures defs site-deps (list target))))
    (values order (hashtable-ref closures target '()) cycles back)))

;; --- chain: a -> b -> c
(let-values (((order clos cycles back)
              (closure (make-defs '((a b) (b c) (c))) 'a)))
  (check! "chain: install order is dependencies first" '(c b a) order)
  (check-set! "chain: closure of a" '(b c) clos)
  (check! "chain: no cycle" '() cycles))

;; --- diamond: a -> b, a -> c, b -> d, c -> d
(let-values (((order clos cycles back)
              (closure (make-defs '((a b c) (b d) (c d) (d))) 'a)))
  (check! "diamond: d appears once in the order" 1
          (let loop ((l order) (n 0))
            (cond ((null? l) n)
                  ((eq? (car l) 'd) (loop (cdr l) (+ n 1)))
                  (else (loop (cdr l) n)))))
  (check! "diamond: order keeps d before b and c" #t
          (let ((i (lambda (x) (let loop ((l order) (n 0))
                                 (cond ((null? l) -1)
                                       ((eq? (car l) x) n)
                                       (else (loop (cdr l) (+ n 1))))))))
            (and (< (i 'd) (i 'b)) (< (i 'd) (i 'c)) (< (i 'b) (i 'a)))))
  (check-set! "diamond: closure has each name once" '(b c d) clos)
  (check! "diamond: no cycle" '() cycles))

;; --- mutual recursion: a <-> b
(let-values (((order clos cycles back)
              (closure (make-defs '((a b) (b a))) 'a)))
  (check! "cycle: the walk terminates" 2 (length order))
  (check-set! "cycle: a sees b" '(b) clos)
  (check! "cycle: reported as one component" 1 (length cycles))
  (check! "cycle: component holds both names" 2 (length (car cycles)))
  (check! "cycle: the stop rule fired" 1 back))

;; --- three-way cycle a -> b -> c -> a
(let-values (((order clos cycles back)
              (closure (make-defs '((a b) (b c) (c a))) 'a)))
  (check! "3-cycle: terminates" 3 (length order))
  (check-set! "3-cycle: a sees b and c" '(b c) clos)
  (check! "3-cycle: one component" 1 (length cycles))
  (check! "3-cycle: component size 3" 3 (length (car cycles))))

;; --- every member of a cycle reports the whole cycle
(let ((defs (make-defs '((a b) (b c) (c a)))))
  (let-values (((order closures cycles back) (mc-closures defs site-deps '(a))))
    (check-set! "3-cycle: b reports a and c"
                '(a c) (hashtable-ref closures 'b '()))
    (check-set! "3-cycle: c reports a and b"
                '(a b) (hashtable-ref closures 'c '()))))

;; --- self reference is not a cycle
(let-values (((order clos cycles back)
              (closure (make-defs '((a a b) (b))) 'a)))
  (check-set! "self edge is dropped" '(b) clos)
  (check! "self edge is not a cycle" '() cycles))

;; --- names outside the index are leaves, not dependencies
(let-values (((order clos cycles back)
              (closure (make-defs '((a b kernel-thing) (b))) 'a)))
  (check-set! "unknown names are not in the closure" '(b) clos)
  (check! "unknown names are not in the order" '(b a) order))

;; --- an unreachable node is not reported
(let-values (((order clos cycles back)
              (closure (make-defs '((a b) (b) (z y) (y))) 'a)))
  (check-set! "unreachable nodes stay out" '(b) clos)
  (check! "unreachable nodes stay out of the order" 2 (length order)))

;; --- cycle plus tail: a -> b <-> c, b -> d
(let-values (((order clos cycles back)
              (closure (make-defs '((a b) (b c d) (c b) (d))) 'a)))
  (check-set! "cycle+tail: closure covers both" '(b c d) clos)
  (check! "cycle+tail: one component" 1 (length cycles))
  (check! "cycle+tail: d precedes the cycle" #t
          (let ((i (lambda (x) (let loop ((l order) (n 0))
                                 (cond ((null? l) -1)
                                       ((eq? (car l) x) n)
                                       (else (loop (cdr l) (+ n 1))))))))
            (< (i 'd) (i 'b)))))

;;; ---------------------------------------------------------------------------
;;; 4. the closure is a valid install order
;;; ---------------------------------------------------------------------------
;;
;; Simulate installation: walk ORDER, and for each site require that every
;; dependency it declares is already installed.  A DAG must produce an empty
;; violation list; a cycle cannot, and the violations are exactly the edges
;; that make it a cycle -- which is why the recorded *set* (step 3) is the
;; usable answer and the order alone is not.

(define (install-check table target)
  (let* ((defs (make-defs table))
         (env (make-eq-hashtable)))
    (let-values (((order closures cycles back) (mc-closures defs site-deps (list target))))
      (define missing '())
      (for-each
        (lambda (name)
          (for-each (lambda (d)
                      (unless (hashtable-ref env d #f)
                        (set! missing (cons (cons name d) missing))))
                    (cdr (assq name table)))
          (hashtable-set! env name #t))
        order)
      (sort (lambda (a b) (string<? (format "~s" a) (format "~s" b))) missing))))

(check! "chain installs cleanly" '() (install-check '((a b) (b c) (c)) 'a))
(check! "diamond installs cleanly" '() (install-check '((a b c) (b d) (c d) (d)) 'a))
(check! "a cycle leaves exactly its back edge unsatisfied"
        '((b . a))
        (install-check '((a b) (b a)) 'a))

;;; ---------------------------------------------------------------------------
;;; 5. drive test over real TeXmacs source files
;;; ---------------------------------------------------------------------------

(when progs-dir
  (let ()
    (define (read-all-forms file)
      (call-with-input-file file
        (lambda (p)
          (let loop ((acc '()))
            (let ((x (read p)))
              (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

    (define (drive-test-file rel-path)
      (let* ((full-path (string-append progs-dir "/" rel-path))
             (forms (read-all-forms full-path))
             (val-defs (filter (lambda (f)
                                 (and (pair? f)
                                      (memq (car f) '(define define-public tm-define))
                                      (pair? (cdr f))))
                               forms)))
        (check-true! (string-append "drive-test found definitions in " rel-path)
                     (> (length val-defs) 0))
        (let ((clean? #t))
          (for-each
            (lambda (form)
              (let ((refs (guard (e (else #f))
                            (mc-free-references form test-env #t))))
                (unless (list? refs)
                  (set! clean? #f))))
            val-defs)
          (check-true! (string-append "drive-test all definitions analyze cleanly in " rel-path)
                       clean?))))

    (drive-test-file "kernel/library/list.scm")
    (drive-test-file "kernel/boot/abbrevs.scm")
    (drive-test-file "kernel/library/base.scm")))

;;; ---------------------------------------------------------------------------
;;; Summary
;;; ---------------------------------------------------------------------------

(printf "\n~a checks, ~a failure~a\n"
        checks failures (if (= failures 1) "" "s"))
(if (= failures 0)
    (begin (printf "MACRO-CLOSURE-TESTS-OK\n") (exit 0))
    (begin (printf "MACRO-CLOSURE-TESTS-FAILED\n") (exit 1)))
