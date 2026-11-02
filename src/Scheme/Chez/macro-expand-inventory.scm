;;; macro-expand-inventory.scm -- discover macro definitions by EXPANSION.
;;;
;;;   chez --script src/Scheme/Chez/macro-expand-inventory.scm [root] [out.tsv]
;;;
;;; No name-shape heuristics.  A macro is a macro because the expander says so:
;;;
;;;   (procedure? (top-level-syntax 'name env))  =>  #t
;;;
;;; Loop, as designed in discussion:
;;;   1. bootstrap boot-chez.scm + tm-define.scm so define-macro,
;;;      define-public-macro, define-module-macro, tm-define-macro exist
;;;   2. for each top-level form whose head is a macro, expand it
;;;      - define-syntax family: the expander installs the new macro as a
;;;        side effect, so the name simply appears in the environment
;;;      - tm-define-macro: the expansion emits
;;;        (($primitive n define-top-level-syntax) 'name val), which is a call,
;;;        so that subform is evaluated to install the syntax binding
;;;   3. repeat until no new macro appears

(define (arg-ref i default)
  (let ((v (command-line-arguments)))
    (if (> (length v) i) (list-ref v i) default)))

(define root
  (arg-ref 0 (if (and (getenv "TEXMACS_SRC")
                      (file-exists? (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")))
                 (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")
                 "TeXmacs/progs")))

(define out-path (arg-ref 1 "macro-expand.tsv"))
(define env (interaction-environment))

;; TeXmacs installs its own `sort` as a syntax binding; keep Chez's for the report.
(define chez-sort sort)
(define chez-filter filter)

;;; ------------------------------------------------------------ helpers

(define (string-prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(define (macro? s)
  (and (symbol? s)
       (top-level-syntax? s env)
       (procedure? (top-level-syntax s env))))

(define (leftmost-symbol x)
  (if (pair? x) (leftmost-symbol (car x)) x))

(define (walk-each xs f)
  (let loop ((p xs)) (when (pair? p) (f (car p)) (loop (cdr p)))))

(define (quoted-symbol x)
  (and (pair? x) (eq? (car x) 'quote) (pair? (cdr x)) (symbol? (cadr x)) (cadr x)))

(define (prim-op x)
  (cond ((and (pair? x) (eq? (car x) '$primitive)) (car (last-pair x)))
        ((and (pair? x) (pair? (car x)) (eq? (caar x) '$primitive)) (car (last-pair (car x))))
        (else #f)))

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
  acc)

;;; ------------------------------------------------------------ bootstrap

;; foreign-procedure needs the TeXmacs binary; stub those bindings.
(define (shim form)
  (if (and (pair? form) (eq? (car form) 'define)
           (pair? (cdr form)) (symbol? (cadr form))
           (pair? (cddr form)) (pair? (caddr form))
           (eq? (car (caddr form)) 'foreign-procedure))
      `(define ,(cadr form) (lambda args #f))
      form))

(define (load-shimmed path)
  (when (file-exists? path)
    (call-with-input-file path
      (lambda (port)
        (let loop ((n 0))
          (let ((f (guard (e (#t 'read-error)) (read port))))
            (cond ((eof-object? f) n)
                  ((eq? f 'read-error) n)
                  (else (guard (e (#t (void))) (eval (shim f) env)) (loop (+ n 1))))))))))

(define-top-level-value 'tm-blackbox-guardian (make-guardian))
(define-top-level-value 'tm-call-by-name (lambda (name args) #f))

(define boot-forms (load-shimmed (string-append root "/kernel/boot/boot-chez.scm")))
(define tmdef-forms (load-shimmed (string-append root "/kernel/texmacs/tm-define.scm")))

;;; ------------------------------------------------------------ files

(define (scm-file? p)
  (let ((n (string-length p)))
    (and (> n 4) (string=? (substring p (- n 4) n) ".scm"))))

(define (walk-files dir)
  (define acc '())
  (define (walk rel)
    (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
      (if (file-directory? full)
          (for-each (lambda (n)
                      (unless (member n '("." ".."))
                        (walk (if (string=? rel "") n (string-append rel "/" n)))))
                    (directory-list full))
          (when (scm-file? rel) (set! acc (cons rel acc))))))
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

;;; ------------------------------------------------------------ main

(define found (make-hashtable equal-hash equal?))
(define records '())
(define n-forms 0)
(define n-expanded 0)
(define n-expand-failed 0)
(define n-installed 0)
(define n-install-failed 0)

(define (note! name mod rel)
  (unless (hashtable-ref found name #f)
    (hashtable-set! found name mod)
    (set! records (cons (list mod name rel) records))))

(define bootstrap-files
  '("kernel/boot/boot-chez.scm" "kernel/texmacs/tm-define.scm"))

(define all-files (walk-files root))
(define ordered
  (chez-filter
    (lambda (p) (not (member p bootstrap-files)))
    (append (chez-filter (lambda (p) (string-prefix? "kernel/" p)) all-files)
            (chez-filter (lambda (p) (not (string-prefix? "kernel/" p))) all-files))))

(define (process-form form mod rel)
  (set! n-forms (+ n-forms 1))
  (when (and (pair? form) (symbol? (car form)) (macro? (car form)))
    (let* ((cand (and (pair? (cdr form)) (leftmost-symbol (cadr form))))
           (was-macro (and (symbol? cand) (macro? cand)))
           (core (guard (e (#t 'expand-failed))
                   (set! n-expanded (+ n-expanded 1))
                   (expand form env))))
      (if (eq? core 'expand-failed)
          (set! n-expand-failed (+ n-expand-failed 1))
          (begin
            ;; install the SYNTAX bindings the expansion spelled out; never
            ;; evaluate a procedure body
            (for-each
              (lambda (d)
                (let ((n (quoted-symbol (cadr d))))
                  (when (symbol? n)
                    (unless (macro? n)
                      (guard (e (#t (set! n-install-failed (+ n-install-failed 1))))
                        (eval d env)
                        (set! n-installed (+ n-installed 1))))
                    (when (macro? n) (note! n mod rel)))))
              (syntax-defs core))
            ;; names the expander installed itself: only if it was not a macro
            ;; before this expansion
            (when (and (symbol? cand) (not was-macro) (macro? cand))
              (note! cand mod rel)))))))

(define (process rel)
  (let* ((path (string-append root "/" rel))
         (forms (read-all-forms path))
         (header (find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module))) forms))
         (mod (if header (cadr header) '(no-header))))
    (for-each (lambda (form) (process-form form mod rel)) forms)))

(define (run-round round)
  (let ((before (hashtable-size found)))
    (for-each process ordered)
    (printf "ROUND ~a: ~a macros~n" round (hashtable-size found))
    (and (< round 6) (> (hashtable-size found) before))))

(let loop ((r 1)) (when (run-round r) (loop (+ r 1))))

;;; ------------------------------------------------------------ report

(printf "BOOTSTRAP ~a + ~a forms loaded~n" boot-forms tmdef-forms)
(printf "SCANNED   ~a files~n" (length ordered))
(printf "FORMS     ~a top-level forms~n" n-forms)
(printf "EXPANDED  ~a, failed ~a~n" n-expanded n-expand-failed)
(printf "INSTALLED ~a syntax bindings, failed ~a~n" n-installed n-install-failed)
(printf "MACROS    ~a unique names~n" (hashtable-size found))
(newline)
(printf "--- top defining modules ---~n")
(let ((by-mod (make-hashtable equal-hash equal?)))
  (for-each (lambda (r) (hashtable-update! by-mod (car r) (lambda (v) (+ v 1)) 0)) records)
  (for-each
    (lambda (m) (printf "  ~a\t~a~n" (hashtable-ref by-mod m 0) m))
    (list-head (chez-sort (lambda (a b) (> (hashtable-ref by-mod a 0) (hashtable-ref by-mod b 0)))
                          (vector->list (hashtable-keys by-mod)))
               12)))

(when (file-exists? out-path) (delete-file out-path))
(call-with-output-file out-path
  (lambda (port)
    (fprintf port "module\tname\tfile~n")
    (for-each (lambda (r) (fprintf port "~a\t~a\t~a~n" (car r) (cadr r) (caddr r)))
              (reverse records))))
(printf "~nWROTE ~a (~a rows)~n" out-path (length records))
