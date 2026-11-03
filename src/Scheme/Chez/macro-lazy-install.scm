;;; macro-lazy-install.scm -- expand macro definitions, installing helper
;;; definitions from the static index on demand.
;;;
;;;   chez --script src/Scheme/Chez/macro-lazy-install.scm [root]
;;;
;;; The previous attempt installed macros only, so 2,434 of 2,498 failures were
;;; "variable ... is not bound": the transformer called a kernel procedure that
;;; was never loaded.  This one uses the index that index-module-definitions
;;; already builds -- (module . name) -> defining form -- and evaluates the
;;; stored form when the expander asks for a name it does not have.
;;;
;;; That is exactly (expand-with-lazy-helpers expr env resolve) from
;;; static-analysis.scm, driven by a resolver that searches every module.

(library-directories (cons "src/Scheme/Chez" (library-directories)))
(import (chezscheme) (compiler-db) (compiler-scan) (compile-graph)
        (compile-inventory) (static-analysis))

(define root
  (if (and (getenv "TEXMACS_SRC")
           (file-exists? (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")))
      (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")
      "TeXmacs/progs"))

(define env (interaction-environment))
(define chez-sort sort)
(define chez-filter filter)

;;; ------------------------------------------------------------- bootstrap

;; ---- the three rewrites compile-texmacs.scm applies before eval --------

;; (define ((f a) b) body) -> (define (f a) (lambda (b) body))
(define (uncurry-def definer head body)
  (if (pair? (car head))
      (uncurry-def definer (car head) (list `(lambda ,(cdr head) ,@body)))
      `(,definer ,head ,@body)))

(define (tm-maybe-uncurry e)
  (if (and (pair? e) (memq (car e) '(define define-public provide-public))
           (pair? (cadr e)) (pair? (caadr e)))
      (uncurry-def (car e) (cadr e) (cddr e))
      e))

;; (define (f) "doc" body) -> (define (f) body)
(define (tm-strip-docstring e)
  (if (and (pair? e) (memq (car e) '(define define-public provide-public))
           (pair? (cadr e)) (pair? (cddr e)) (string? (caddr e)) (pair? (cdddr e)))
      (cons (car e) (cons (cadr e) (cdddr e)))
      e))

;; (if TEST (begin a b) (begin c d)) -> the chosen branch's forms
(define (tm-unwrap-conditional f)
  (if (and (pair? f) (eq? (car f) 'if) (pair? (cddr f)))
      (let* ((test (guard (e (#t #f)) (eval (cadr f) env)))
             (branch (if test (caddr f)
                         (if (pair? (cdddr f)) (cadddr f) #f))))
        (cond ((not branch) '())
              ((and (pair? branch) (eq? (car branch) 'begin)) (cdr branch))
              (else (list branch))))
      (list f)))

(define (shim f)
  (if (and (pair? f) (eq? (car f) 'define) (pair? (cdr f)) (symbol? (cadr f))
           (pair? (cddr f)) (pair? (caddr f))
           (eq? (car (caddr f)) 'foreign-procedure))
      `(define ,(cadr f) (lambda args #f))
      (tm-strip-docstring (tm-maybe-uncurry f))))

(define (eval-prepared f)
  (guard (e (#t (set! n-load-failed (+ n-load-failed 1))
                (printf "  LOAD-FAIL ~s : " (if (pair? f) (car f) f))
                (display-condition e) (newline)))
    (eval (shim f) env)))

(define (load-file path)
  (when (file-exists? path)
    (call-with-input-file path
      (lambda (port)
        (let loop ()
          (let ((f (guard (e (#t 'read-error)) (read port))))
            (cond ((eof-object? f) (void))
                  ((eq? f 'read-error) (void))
                  (else
                   (for-each eval-prepared (tm-unwrap-conditional f))
                   (loop)))))))))

(define n-load-failed 0)

(define-top-level-value 'tm-blackbox-guardian (make-guardian))
(load-file (string-append root "/kernel/boot/boot-chez.scm"))
(load-file (string-append root "/kernel/boot/debug.scm"))
;; `for` lives here; without it (for (x l) ...) stays a call and x looks unbound.
(load-file (string-append root "/kernel/boot/abbrevs.scm"))

;; ahash-table.scm cannot be used here: its dialect test
;; (vector? (make-hash-table 1)) picks the Guile branch under this bootstrap,
;; which needs hash-ref / hash-set! that Chez does not have.  Stub the two
;; entry points instead, before tm-define.scm needs them.
(unless (top-level-bound? 'ahash-ref env)
  (define-top-level-value 'ahash-ref
    (lambda (h k . d) (hashtable-ref h k (if (null? d) #f (car d))))))
(unless (top-level-bound? 'ahash-set! env)
  (define-top-level-value 'ahash-set! (lambda (h k v) (hashtable-set! h k v))))

(set! n-load-failed 0)
(load-file (string-append root "/kernel/texmacs/tm-define.scm"))
(printf "tm-define.scm: failures ~a, define-option-table bound? ~a~n"
        n-load-failed (top-level-bound? 'define-option-table env))

;; registries the C++ side normally provides
(for-each (lambda (n) (unless (top-level-bound? n env)
                        (define-top-level-value n (make-hashtable equal-hash equal?))))
          '(tm-defined-table tm-defined-name tm-defined-module))
(unless (top-level-bound? 'ahash-ref env)
  (define-top-level-value 'ahash-ref
    (lambda (h k . d) (hashtable-ref h k (if (null? d) #f (car d))))))
(unless (top-level-bound? 'ahash-set! env)
  (define-top-level-value 'ahash-set! (lambda (h k v) (hashtable-set! h k v))))
(unless (top-level-bound? 'module-name env)
  (define-top-level-value 'module-name (lambda (m) m)))
(unless (top-level-bound? 'current-module env)
  (define-top-level-value 'current-module (lambda () '(none))))

;;; ------------------------------------------------------------- file walk

(define (scm? p)
  (let ((n (string-length p)))
    (and (> n 4) (string=? (substring p (- n 4) n) ".scm"))))

(define (walk-files dir)
  (define acc '())
  (define (walk rel)
    (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
      (if (file-directory? full)
          (for-each (lambda (n) (unless (member n '("." ".."))
                                  (walk (if (string=? rel "") n (string-append rel "/" n)))))
                    (directory-list full))
          (when (scm? rel) (set! acc (cons rel acc))))))
  (walk "")
  (chez-sort (lambda (a b) (string<? a b)) acc))

(define (read-all-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((f (guard (e (#t 'read-error)) (read port))))
          (cond ((eof-object? f) (reverse acc))
                ((eq? f 'read-error) (reverse acc))
                (else (loop (cons f acc)))))))))

;; kernel/boot/* is already loaded by the bootstrap; walking it again
;; re-evaluates boot-chez and upsets the keyword bindings.
(define (boot-file? p)
  (and (>= (string-length p) 11) (string=? (substring p 0 11) "kernel/boot")))
;; The authoritative order is *source-files* in (compile-inventory):
;; *kernel-files* followed by tier2..tier7, as explicit lists.  The compiler-db
;; graph is not used for ordering there, and using it here is measurably worse,
;; because a module with no (:use ...) has no edges and can land before its
;; real dependencies.
(define (build-order) *source-files*)

(define all-files (chez-filter (lambda (p) (not (boot-file? p))) (walk-files root)))
(define files (chez-filter (lambda (p) (member p all-files)) (build-order)))
(printf "order: ~a files from *source-files* (~a on disk)~n" (length files) (length all-files))

;; Bind every :keyword token found in the sources to itself, the way
;; boot-chez does for its hardcoded list.  181 + 743 + 362 + ... failures
;; were keyword tokens that list does not include.
(define (keyword-sym? s)
  (and (symbol? s)
       (let ((str (symbol->string s)))
         (and (> (string-length str) 0) (char=? (string-ref str 0) #\:)))))

(define (bind-keywords! forms)
  (define (walk x)
    (cond
      ((symbol? x)
       (when (keyword-sym? x)
         (unless (top-level-bound? x env) (define-top-level-value x x))))
      ((pair? x)
       (unless (eq? (car x) 'quote)
         (let loop ((p x))
           (when (pair? p) (walk (car p)) (loop (cdr p))))))))
  (for-each walk forms))

(for-each (lambda (rel) (bind-keywords! (read-all-forms (string-append root "/" rel)))) files)

(define mods '())
(for-each
  (lambda (rel)
    (let ((h (find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module)))
                   (read-all-forms (string-append root "/" rel)))))
      (when h (set! mods (cons (cadr h) mods)))))
  files)

(printf "indexing ~a files / ~a modules ...~n" (length files) (length mods))
(define t0 (real-time))
(index-module-definitions root files)
(printf "indexed in ~a ms~n" (- (real-time) t0))

;; search every module, in a stable order
(define resolve (make-resolver '(none) mods))
(define lookup  (make-lookup  '(none) mods))

;;; ---------------------------------------------------------------- main

(define (macro? s)
  (and (symbol? s) (top-level-syntax? s env) (procedure? (top-level-syntax s env))))

(define installed (make-hashtable equal-hash equal?))
(define n-forms 0) (define n-ok 0) (define n-failed 0)
(define n-installed 0) (define n-install-failed 0)
(define n-lazy 0) (define lazy-names (make-hashtable equal-hash equal?))

(define buckets (make-hashtable equal-hash equal?))
(define (bucket! c)
  (let* ((irr (and (condition? c) (irritants-condition? c) (condition-irritants c)))
         (k (cond ((and irr (pair? irr) (symbol? (car irr)))
                   (format "unbound: ~a" (string->symbol (symbol->string (car irr)))))
                  ((and irr (pair? irr)) (format "other-irritant: ~s" (car irr)))
                  (else (let ((m (condition-message c)))
                          (substring m 0 (min 40 (string-length m))))))))
    (hashtable-update! buckets k (lambda (v) (+ v 1)) 0)))

(define (process form)
  (set! n-forms (+ n-forms 1))
  (guard (c (#t (set! n-failed (+ n-failed 1)) (bucket! c)))
    (let-values (((core used) (expand-with-lazy-helpers form env resolve)))
      (set! n-ok (+ n-ok 1))
      (for-each (lambda (s)
                  (hashtable-set! lazy-names s #t)
                  (set! n-lazy (+ n-lazy 1)))
                used)
      ;; INSTALL it, so later files can use it.  Without this the walk only
      ;; expands macros that some boot file happened to define.
      (guard (e (#t (set! n-install-failed (+ n-install-failed 1))))
        (eval form env)
        (set! n-installed (+ n-installed 1)))
      (when (pair? (cdr form))
        (let ((n (if (pair? (cadr form)) (car (cadr form)) (cadr form))))
          (when (and (symbol? n) (macro? n)) (hashtable-set! installed n #t))))
      core)))

(define (round! label)
  (set! n-forms 0) (set! n-ok 0) (set! n-failed 0) (set! n-lazy 0)
  (set! n-installed 0) (set! n-install-failed 0)
  (for-each
    (lambda (rel)
      (for-each (lambda (form)
                  (when (and (pair? form) (symbol? (car form)) (macro? (car form)))
                    (process form)))
                (read-all-forms (string-append root "/" rel))))
    files)
  (printf "~a: ~a forms, ok ~a, failed ~a, helpers ~a, installed ~a (fail ~a), macros ~a~n"
          label n-forms n-ok n-failed n-lazy n-installed n-install-failed
          (hashtable-size installed)))

;; One pass only: re-installing everything in later rounds re-evaluates macro
;; definitions and destabilises the environment (failures climb, `body` ends up
;; unbound), so a fixpoint is counter-productive here.
(round! "pass")

(printf "~n--- failure reasons (lazy run) ---~n")
(for-each (lambda (k) (printf "  ~a\t~a~n" (hashtable-ref buckets k 0) k))
          (let* ((ks (chez-sort (lambda (a b) (> (hashtable-ref buckets a 0) (hashtable-ref buckets b 0)))
                                (vector->list (hashtable-keys buckets))))
                 (n (length ks)))
            (list-head ks (if (< n 12) n 12))))
(printf "~nDISTINCT HELPERS PULLED FROM THE INDEX: ~a~n" (hashtable-size lazy-names))
(printf "MACROS INSTALLED: ~a~n" (hashtable-size installed))
(printf "~n--- sample of helpers installed on demand ---~n")
(let ((all (chez-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                      (vector->list (hashtable-keys lazy-names)))))
  (for-each (lambda (s) (printf "  ~a~n" s)) (list-head all 25)))
