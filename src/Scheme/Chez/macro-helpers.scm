;;; macro-helpers.scm -- for every macro, record the definitions its
;;; transformer actually needs.
;;;
;;;   chez --script src/Scheme/Chez/macro-helpers.scm [root] [out.tsv]
;;;
;;; Two outcomes per macro definition, and both are logged:
;;;
;;;   A. the macro installs, and we read its transformer body out of the
;;;      expansion, or rebuild it from the source form and expand that;
;;;   B. the expansion fails, and we log the failure instead of guessing.
;;;
;;; From the transformer's core AST we take every free top-level name:
;;;
;;;   (($primitive n $top-level-value) '#{name ...})   -> name
;;;   an interned symbol that is not a current binder    -> name
;;;
;;; Those names are the macro's helpers.  They are accumulated in a table
;;; name -> {count, users}, then classified:
;;;
;;;   macro        installed syntax binding
;;;   procedure    defined by define / define-public / tm-define in the tree
;;;   unknown      neither: an external (C++) binding, or a real bug

(define (arg-ref i default)
  (let ((v (command-line-arguments)))
    (if (> (length v) i) (list-ref v i) default)))

(define root
  (arg-ref 0 (if (and (getenv "TEXMACS_SRC")
                      (file-exists? (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")))
                 (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")
                 "TeXmacs/progs")))

(define out-path (arg-ref 1 "macro-helpers.tsv"))
(define env (interaction-environment))
(define chez-sort sort)
(define chez-filter filter)

;;; ------------------------------------------------------------- utilities

(define (string-prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(define (macro? s)
  (and (symbol? s) (top-level-syntax? s env)
       (procedure? (top-level-syntax s env))))

(define (leftmost-symbol x) (if (pair? x) (leftmost-symbol (car x)) x))

(define (walk-each xs f)
  (let loop ((p xs)) (when (pair? p) (f (car p)) (loop (cdr p)))))

(define (quoted-symbol x)
  (and (pair? x) (eq? (car x) 'quote) (pair? (cdr x)) (symbol? (cadr x)) (cadr x)))

(define (prim-op x)
  (cond ((and (pair? x) (eq? (car x) '$primitive)) (car (last-pair x)))
        ((and (pair? x) (pair? (car x)) (eq? (caar x) '$primitive)) (car (last-pair (car x))))
        (else #f)))

(define (formals->list f acc)
  (cond ((symbol? f) (cons f acc))
        ((pair? f) (formals->list (cdr f) (if (symbol? (car f)) (cons (car f) acc) acc)))
        (else acc)))

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

;; Free top-level names in a core AST.
(define (free-names core)
  (define acc '())
  (define (add s) (unless (memq s acc) (set! acc (cons s acc))))
  (define (walk-all xs b) (walk-each xs (lambda (x) (walk x b))))
  (define (walk x b)
    (cond
      ((symbol? x) (unless (or (memq x b) (gensym? x)) (add x)))
      ((pair? x)
       (let ((h (car x)))
         (cond
           ((and (symbol? h) (eq? h '$primitive)) (void))
           ((eq? (prim-op x) '$top-level-value)
            (let ((s (quoted-symbol (cadr x))))
              (when (symbol? s) (add (string->symbol (symbol->string s))))))
           ((prim-op x) (walk-all (cdr x) b))
           ((and (symbol? h) (eq? h 'quote)) (void))
           ((and (symbol? h) (memq h '(lambda case-lambda)))
            (walk-all (cddr x) (formals->list (cadr x) b)))
           ((and (symbol? h) (memq h '(let letrec letrec*)))
            (let* ((bs (cadr x)) (names (formals->list (map car bs) b)))
              (walk-all (map cdr bs) b)
              (walk-all (cddr x) names)))
           ((and (symbol? h) (memq h '(begin if set! define and or when unless)))
            (walk-all (cdr x) b))
           (else (walk-all x b)))))
      (else (void))))
  (walk core '())
  acc)

;; (define-macro (name . args) body ...) -> (lambda args body ...)
(define (transformer-expr form)
  (and (pair? form) (pair? (cdr form))
       (let ((spec (cadr form)))
         (cond ((pair? spec) `(lambda ,(cdr spec) ,@(cddr form)))
               ((and (symbol? spec) (pair? (cddr form))) (caddr form))
               (else #f)))))

;;; ------------------------------------------------------------- bootstrap

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
        (let loop ()
          (let ((f (guard (e (#t 'read-error)) (read port))))
            (cond ((eof-object? f) (void))
                  ((eq? f 'read-error) (void))
                  (else (guard (e (#t (void))) (eval (shim f) env)) (loop)))))))))

(define-top-level-value 'tm-blackbox-guardian (make-guardian))
(define-top-level-value 'tm-call-by-name (lambda (name args) #f))
(load-shimmed (string-append root "/kernel/boot/boot-chez.scm"))
(load-shimmed (string-append root "/kernel/texmacs/tm-define.scm"))

;;; --------------------------------------------------------------- files

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

;;; ------------------------------------------- static index of procedures

(define proc-names (make-hashtable equal-hash equal?))
(define value-definers '(define define-public provide-public tm-define))

(define (index-procedures! forms)
  (define (walk x)
    (when (pair? x)
      (cond
        ((memq (car x) '(quote syntax-rules quasiquote)) (void))
        (else
         (when (and (memq (car x) value-definers) (pair? (cdr x)))
           (let ((n (leftmost-symbol (cadr x))))
             (when (symbol? n) (hashtable-set! proc-names n #t))))
         (walk-each x walk)))))
  (for-each walk forms))

;;; ---------------------------------------------------------------- state

(define helpers (make-hashtable equal-hash equal?))   ; name -> count
(define users (make-hashtable equal-hash equal?))     ; name -> list of macros
(define installed (make-hashtable equal-hash equal?))
(define n-defs 0)
(define n-expanded 0)
(define n-expand-failed 0)
(define n-body-expanded 0)
(define n-body-failed 0)

(define (note-helper! name macro)
  (hashtable-update! helpers name (lambda (v) (+ v 1)) 0)
  (let ((u (hashtable-ref users name '())))
    (unless (memq macro u) (hashtable-set! users name (cons macro u)))))

(define (harvest! names macro)
  (for-each (lambda (n) (note-helper! n macro)) names))

;;; ----------------------------------------------------------------- main

(define files (walk-files root))
(define bootstrap-files '("kernel/boot/boot-chez.scm" "kernel/texmacs/tm-define.scm"))

;; pass 0: index procedure names so helpers can be classified
(for-each (lambda (rel)
            (index-procedures! (read-all-forms (string-append root "/" rel))))
          files)

(define (process-form form mod rel)
  (when (and (pair? form) (symbol? (car form)) (macro? (car form)))
    (set! n-defs (+ n-defs 1))
    (let* ((cand (and (pair? (cdr form)) (leftmost-symbol (cadr form))))
           (was (and (symbol? cand) (macro? cand)))
           (core (guard (e (#t 'expand-failed))
                   (set! n-expanded (+ n-expanded 1))
                   (expand form env))))
      (if (eq? core 'expand-failed)
          (set! n-expand-failed (+ n-expand-failed 1))
          (begin
            ;; A. for tm-define-macro the transformer lambda appears inside
            ;;    (($primitive n define-top-level-syntax) 'name <lambda>)
            (for-each
              (lambda (d)
                (let ((val (and (pair? (cddr d)) (caddr d))))
                  (when (and (pair? val) (eq? (car val) 'lambda))
                    (harvest! (free-names val) cand))))
              (syntax-defs core))
            ;; B. rebuild the transformer and expand it separately, since a
            ;;    define-syntax family form expands to (void) and hides the body
            (let ((tx (transformer-expr form)))
              (when tx
                (let ((tcore (guard (e (#t 'body-failed))
                               (set! n-body-expanded (+ n-body-expanded 1))
                               (expand tx env))))
                  (if (eq? tcore 'body-failed)
                      (set! n-body-failed (+ n-body-failed 1))
                      (harvest! (free-names tcore) cand)))))
            ;; install the macro if the expansion revealed it
            (when (and (symbol? cand) (not was) (macro? cand))
              (hashtable-set! installed cand mod)))))))

(define (process rel)
  (let* ((path (string-append root "/" rel))
         (forms (read-all-forms path))
         (header (find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module))) forms))
         (mod (if header (cadr header) '(no-header))))
    (for-each (lambda (form) (process-form form mod rel)) forms)))

(define (run-round round)
  (let ((before (hashtable-size installed)))
    (for-each process files)
    (printf "ROUND ~a: ~a macros installed, ~a helper names~n"
            round (hashtable-size installed) (hashtable-size helpers))
    (and (< round 4) (> (hashtable-size installed) before))))

(let loop ((r 1)) (when (run-round r) (loop (+ r 1))))

;;; --------------------------------------------------------------- report

(define (classify n)
  (cond ((macro? n) 'macro)
        ((top-level-bound? n env) 'bound)
        ((hashtable-ref proc-names n #f) 'procedure)
        (else 'unknown)))

;; demand = number of distinct macros that need this helper
(define (demand n) (length (hashtable-ref users n '())))

(define names (chez-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                         (vector->list (hashtable-keys helpers))))

(printf "~nMACRO DEFINITIONS expanded ~a (failed ~a)~n" n-expanded n-expand-failed)
(printf "TRANSFORMER BODIES expanded ~a (failed ~a)~n" n-body-expanded n-body-failed)
(printf "MACROS INSTALLED ~a~n" (hashtable-size installed))
(printf "HELPER NAMES ~a~n" (length names))

(let ((by-kind (make-hashtable equal-hash equal?)))
  (for-each (lambda (n) (hashtable-update! by-kind (classify n) (lambda (v) (+ v 1)) 0)) names)
  (newline)
  (printf "--- helpers by kind ---~n")
  (for-each (lambda (k) (printf "  ~a\t~a~n" (hashtable-ref by-kind k 0) k))
            (vector->list (hashtable-keys by-kind))))

(newline)
(printf "--- 20 most-demanded helpers ---~n")
(for-each (lambda (n) (printf "  ~a\t~a\t~a~n" (demand n) (classify n) n))
          (list-head (chez-sort (lambda (a b) (> (demand a) (demand b)))
                                names)
                     20))

(newline)
(printf "--- helpers never defined in the tree (external or bug) ---~n")
(let ((unk (chez-filter (lambda (n) (eq? (classify n) 'unknown)) names)))
  (printf "  count: ~a~n" (length unk))
  (for-each (lambda (n) (printf "  ~a\t~a~n" (demand n) n))
            (list-head (chez-sort (lambda (a b) (> (demand a) (demand b)))
                                  unk)
                       25)))

(when (file-exists? out-path) (delete-file out-path))
(call-with-output-file out-path
  (lambda (port)
    (fprintf port "helper\tkind\tdemand\tusers~n")
    (for-each (lambda (n)
                (fprintf port "~a\t~a\t~a\t~a~n" n (classify n) (demand n)
                         (hashtable-ref users n '())))
              names)))
(printf "~nWROTE ~a (~a rows)~n" out-path (length names))
