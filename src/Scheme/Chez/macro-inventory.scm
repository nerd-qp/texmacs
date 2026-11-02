;;; macro-inventory.scm -- static inventory of macro definitions in TeXmacs Scheme.
;;;
;;;   chez --script src/Scheme/Chez/macro-inventory.scm [root] [out.tsv]
;;;
;;; Reads every .scm file under TeXmacs/progs (or $TEXMACS_SRC/TeXmacs/progs) and
;;; classifies definitions WITHOUT evaluating anything: pure read + tree walk.
;;;
;;; Three tiers, each less certain than the last:
;;;
;;;   1. CONFIRMED   the form's head is a known macro definer
;;;                  (define-syntax, define-macro, tm-define-macro, ...)
;;;   2. GENERATING  a macro whose own body contains a definition-shaped form,
;;;                  i.e. expanding it emits definitions.  Found by a static
;;;                  fixed point, no expansion needed.
;;;   3. VIA         a form headed by a tier-2 macro.  These *probably* define
;;;                  something, but the defined name may be manufactured
;;;                  (define-group emits foo-list, foo?, inside-foo?), so the
;;;                  name recorded here is the one written in the source, not
;;;                  necessarily the one bound.

(define (arg-ref i default)
  (let ((v (command-line-arguments)))
    (if (> (length v) i) (list-ref v i) default)))

(define root
  (arg-ref 0 (if (and (getenv "TEXMACS_SRC")
                      (file-exists? (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")))
                 (string-append (getenv "TEXMACS_SRC") "/TeXmacs/progs")
                 "TeXmacs/progs")))

(define out-path (arg-ref 1 "macro-inventory.tsv"))

;;; ---------------------------------------------------------------- definers

(define macro-definers
  '(define-syntax define-macro define-public-macro define-module-macro
    define-export-macro tm-define-macro))

(define value-definers
  '(define define-public provide-public tm-define))

;;; ------------------------------------------------------------- file system

(define (scm-file? p)
  (let ((n (string-length p)))
    (and (> n 4) (string=? (substring p (- n 4) n) ".scm"))))

(define (walk-files dir)
  (define acc '())
  (define (walk rel)
    (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
      (if (file-directory? full)
          (for-each
            (lambda (name)
              (unless (member name '("." ".."))
                (walk (if (string=? rel "") name (string-append rel "/" name)))))
            (directory-list full))
          (when (scm-file? rel) (set! acc (cons rel acc))))))
  (walk "")
  (sort (lambda (a b) (string<? a b)) acc))

(define (read-all-forms path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((acc '()))
        (let ((form (guard (e (#t 'read-error)) (read port))))
          (cond ((eof-object? form) (reverse acc))
                ((eq? form 'read-error) (reverse acc))
                (else (loop (cons form acc)))))))))

;;; ------------------------------------------------------------- tree walk

(define (leftmost-symbol x)
  (if (pair? x) (leftmost-symbol (car x)) x))

(define (walk-each xs f)
  (let loop ((p xs))
    (when (pair? p) (f (car p)) (loop (cdr p)))))

(define (defined-name form definers)
  (and (pair? form)
       (memq (car form) definers)
       (pair? (cdr form))
       (let ((n (leftmost-symbol (cadr form))))
         (and (symbol? n) n))))

;; All (name . definer) pairs for known macro definers, at any depth.
;; Never descends into quoted data, syntax-rules templates, or quasiquote
;; bodies: a (define-macro ...) written inside a template is generated code,
;; not a definition in this file.
(define (collect-defs form definers)
  (define acc '())
  (define (walk x)
    (when (pair? x)
      (cond
        ((memq (car x) '(quote syntax-rules quasiquote)) (void))
        (else
         (let ((n (defined-name x definers)))
           (when n (set! acc (cons (cons n (car x)) acc))))
         (walk-each x walk)))))
  (walk form)
  (reverse acc))

(define (collect-macros form) (collect-defs form macro-definers))
(define (collect-values form) (collect-defs form value-definers))

;; Does this form's body emit a MACRO definition (not just a procedure)?
;; Local definitions inside a lambda are ignored: they are not top-level.
(define (contains-definition? form)
  (define found #f)
  (define (walk x)
    (when (and (pair? x) (not found))
      (cond
        ((eq? (car x) 'quote) (void))
        ((memq (car x) '(lambda case-lambda)) (void))
        (else
         (when (and (symbol? (car x))
                    (memq (car x) macro-definers))
           (set! found #t))
         (walk-each x walk)))))
  (walk form)
  found)

;; Heads of TOP-LEVEL forms only, descending through `begin`.
;; Local bindings and data literals are deliberately excluded: a (pre-macro ...)
;; inside a let*, or an (attach-macro ...) inside a symbol table, is not a form.
(define (top-heads form)
  (define acc '())
  (define (walk f)
    (when (pair? f)
      (cond ((eq? (car f) 'begin) (for-each walk (cdr f)))
            ((symbol? (car f)) (set! acc (cons (car f) acc)))
            (else (void)))))
  (walk form)
  (reverse acc))

(define (string-prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(define (string-suffix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s (- (string-length s) (string-length p)) (string-length s)) p)))

(define (definer-shaped? s)
  (and (symbol? s)
       (let ((str (symbol->string s)))
         (or (string-prefix? "define-" str) (string-suffix? "-macro" str)))))

(define (find-header forms)
  (find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module))) forms))

;;; ------------------------------------------------------------------ state

(define generating (make-hashtable equal-hash equal?))   ; macro name -> #t
(define by-definer (make-hashtable equal-hash equal?))
(define per-module (make-hashtable equal-hash equal?))
(define heads (make-hashtable equal-hash equal?))
(define macro-names (make-hashtable equal-hash equal?))
(define value-names (make-hashtable equal-hash equal?))
(define records '())
(define macro-defs '())      ; (module name definer body-form)

(define files (walk-files root))

;;; ------------------------------------------------- pass 1: literal macros

(define modules '())

(for-each
  (lambda (rel)
    (let* ((forms (read-all-forms (string-append root "/" rel)))
           (header (find-header forms))
           (mod-name (if header (cadr header) '(no-header))))
      (set! modules (cons mod-name modules))
      (for-each
        (lambda (form)
          (for-each
            (lambda (pair)
              (set! macro-defs (cons (list mod-name (car pair) (cdr pair) form) macro-defs)))
            (collect-macros form))
          (for-each
            (lambda (pair) (hashtable-set! value-names (car pair) #t))
            (collect-values form))
          (for-each
            (lambda (h)
              (when (definer-shaped? h)
                (hashtable-update! heads h (lambda (v) (+ v 1)) 0)))
            (top-heads form)))
        forms)))
  files)

;;; --------------------------------- pass 2: static fixed point on generators

(define (macro-definition-forms)
  (reverse macro-defs))

;; One pass: a macro is a generator if its body literally emits a macro definition.
(for-each
  (lambda (d)
    (let ((name (cadr d)) (form (cadddr d)))
      (when (contains-definition? (cddr form))
        (hashtable-set! generating name #t))))
  (macro-definition-forms))

;;; --------------------------------- pass 3: forms headed by a generator

(for-each
  (lambda (rel)
    (let* ((forms (read-all-forms (string-append root "/" rel)))
           (header (find-header forms))
           (mod-name (if header (cadr header) '(no-header))))
      (for-each
        (lambda (form)
          (when (and (pair? form)
                     (symbol? (car form))
                     (hashtable-ref generating (car form) #f)
                     (not (memq (car form) macro-definers))
                     (pair? (cdr form)))
            (let ((n (leftmost-symbol (cadr form))))
              (when (symbol? n)
                (set! records (cons (list mod-name n (car form)) records))))))
        forms)))
  files)

;;; ---------------------------------------------------------------- report

(define (sorted-keys ht)
  (sort (lambda (a b) (string<? (format "~a" a) (format "~a" b)))
        (vector->list (hashtable-keys ht))))

(for-each
  (lambda (d)
    (hashtable-update! by-definer (caddr d) (lambda (v) (+ v 1)) 0)
    (hashtable-update! per-module (car d) (lambda (v) (+ v 1)) 0)
    (hashtable-set! macro-names (cadr d) #t))
  macro-defs)

(printf "SCANNED   ~a files, ~a module headers, root=~a~n" (length files) (length modules) root)
(printf "CONFIRMED ~a macro definitions (known definer form)~n" (length macro-defs))
(printf "GENERATING ~a macros that emit definitions~n" (hashtable-size generating))
(printf "VIA       ~a forms headed by a generating macro~n" (length records))
(newline)

(printf "--- confirmed macros by definer ---~n")
(for-each
  (lambda (k) (printf "  ~a\t~a~n" (hashtable-ref by-definer k 0) k))
  (sort (lambda (a b) (> (hashtable-ref by-definer a 0) (hashtable-ref by-definer b 0)))
        (vector->list (hashtable-keys by-definer))))

(newline)
(printf "--- generating macros (expand to definitions) ---~n")
(let ((g (sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
               (vector->list (hashtable-keys generating)))))
  (for-each (lambda (s) (printf "  ~a~n" s)) g))

(newline)
(printf "--- top 15 modules by confirmed macro count ---~n")
(for-each
  (lambda (k) (printf "  ~a\t~a~n" (hashtable-ref per-module k 0) k))
  (list-head (sort (lambda (a b) (> (hashtable-ref per-module a 0) (hashtable-ref per-module b 0)))
                   (vector->list (hashtable-keys per-module)))
             15))

(newline)
(printf "--- definer-shaped heads NOT in the macro set, classified ---~n")
(let* ((unknown (filter (lambda (h)
                          (and (not (memq h macro-definers))
                               (not (memq h value-definers))
                               (not (hashtable-ref macro-names h #f))))
                        (sorted-keys heads)))
       (procs (filter (lambda (h) (hashtable-ref value-names h #f)) unknown))
       (rest (filter (lambda (h) (not (hashtable-ref value-names h #f))) unknown))
       (builtins (filter (lambda (h) (top-level-bound? h (interaction-environment))) rest))
       (real (filter (lambda (h) (not (top-level-bound? h (interaction-environment)))) rest)))
  (printf "  defined as a procedure in the tree (not a syntax definer): ~a~n" (length procs))
  (for-each (lambda (h) (printf "    ~a\t~a~n" (hashtable-ref heads h 0) h)) procs)
  (printf "  Chez builtin or core form: ~a~n" (length builtins))
  (for-each (lambda (h) (printf "    ~a\t~a~n" (hashtable-ref heads h 0) h)) builtins)
  (printf "  UNRESOLVED -- neither defined here nor a Chez builtin: ~a~n" (length real))
  (for-each (lambda (h) (printf "    ~a\t~a~n" (hashtable-ref heads h 0) h)) real))

;;; TSV

(when (file-exists? out-path) (delete-file out-path))
(call-with-output-file out-path
  (lambda (port)
    (fprintf port "tier\tmodule\tname\tdefiner~n")
    (for-each
      (lambda (d) (fprintf port "confirmed\t~a\t~a\t~a~n" (car d) (cadr d) (caddr d)))
      (reverse macro-defs))
    (for-each
      (lambda (r) (fprintf port "via\t~a\t~a\t~a~n" (car r) (cadr r) (caddr r)))
      (reverse records))))
(printf "~nWROTE  ~a (~a rows)~n" out-path (+ (length macro-defs) (length records)))
