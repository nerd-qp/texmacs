;;; macro-closure-test.scm -- Self-contained tests for macro-closure.scm.
;;;
;;; Runs under plain Chez Scheme, no TeXmacs runtime needed:
;;;
;;;   chez --script src/Scheme/Chez/macro-closure-test.scm
;;;
;;; Exits 0 when every check passes, 1 otherwise.

(define here
  (let loop ((d (current-directory)))
    (cond ((file-exists? (string-append d "/macro-closure.scm")) d)
          ((file-exists? (string-append d "/src/Scheme/Chez/macro-closure.scm"))
           (string-append d "/src/Scheme/Chez"))
          ((file-exists? (string-append d "/../src/Scheme/Chez/macro-closure.scm"))
           (string-append d "/../src/Scheme/Chez"))
          (else d))))

(load (string-append here "/macro-closure.scm"))

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
;;; 1. free-name walker
;;; ---------------------------------------------------------------------------

(check-set! "lambda binds its formals"
            '(f) (mc-free-names '(lambda (x) (f x))))
(check-set! "lambda rest argument is bound"
            '(f) (mc-free-names '(lambda (x . r) (f r))))
(check-set! "let binds, initialisers stay free"
            '(f g) (mc-free-names '(let ((x (f))) (g x))))
(check-set! "named let binds the loop name"
            '(f) (mc-free-names '(let lp ((i (f))) (lp i))))
(check-set! "let* binds sequentially"
            '(f g) (mc-free-names '(let* ((x (f)) (y (g))) y)))
(check-set! "define binds the head and formals"
            '(g) (mc-free-names '(define (f x) (g x))))
(check-set! "recursive define does not report itself"
            '(g) (mc-free-names '(define (f x) (if (g) (f x) #f))))
(check-set! "define of a plain value binds the name"
            '(f) (mc-free-names '(define x (f))))
(check-set! "quote is data"
            '() (mc-free-names '(quote (f g h))))
(check-set! "quasiquote keeps unquotes"
            '(f) (mc-free-names '(quasiquote (a (unquote (f))))))
(check-set! "quasiquote ignores the literal part"
            '() (mc-free-names '(quasiquote (a b c))))
(check-set! "set! target is a reference"
            '(f x) (mc-free-names '(begin (set! x (f)))))
(check-set! "cond/else/=> are not references"
            '(f g) (mc-free-names '(cond ((f) => g) (else #f))))

;; TeXmacs binding macros: an unmodelled binder turns into a false dependency.
(check-set! "with binds its variable and is itself a dependency"
            '(with e f) (mc-free-names '(with v e (f v))))
(check-set! "for binds the head of its spec"
            '(for f l) (mc-free-names '(for (i l) (f i))))
(check-set! "for with a range spec"
            '(for f) (mc-free-names '(for (i 0 10) (f i))))
(check-set! "receive binds its formals"
            '(receive f g) (mc-free-names '(receive (a b) (f) (g a b))))
(check-set! "guard binds its variable"
            '(f) (mc-free-names '(guard (e (#t (f e))))))
(check-set! "do binds its variables"
            '(f) (mc-free-names '(do ((i 0)) ((f) i))))

;; Expanded core AST: a global reference is a quoted $top-level-value lookup.
(check-set! "core AST top-level reference"
            '(f) (mc-free-names '((($primitive 2 $top-level-value) 'f) 1)))
(check-set! "core AST definition binds its name"
            '(g) (mc-free-names '((($primitive 3 $set-top-level-value!) 'f
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
;;; Summary
;;; ---------------------------------------------------------------------------

(printf "\n~a checks, ~a failure~a\n"
        checks failures (if (= failures 1) "" "s"))
(if (= failures 0)
    (begin (printf "MACRO-CLOSURE-TESTS-OK\n") (exit 0))
    (begin (printf "MACRO-CLOSURE-TESTS-FAILED\n") (exit 1)))
