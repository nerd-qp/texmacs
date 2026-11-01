;;; static-analysis.scm -- Lightweight static analysis for TeXmacs Scheme modules.
;;;
;;; This library expands a module's top-level forms and reports
;;;   * unbound global names (typos, missing (:use ...) declarations),
;;;   * which helpers a macro needs at expand time   (compile-uses),
;;;   * which globals a procedure needs at run time  (runtime-uses).
;;;
;;; It is environment-agnostic on purpose.  Building the environment a module
;;; expands in is the caller's job (see lint-modules.scm), because that step
;;; needs the transpiler's eager-evaluation rules and is not something this
;;; library can guess.  The single integration point is INSTALL!, a procedure
;;; (lambda (form env) ...) that makes a definition or macro live in ENV.
;;;
;;; Verified Chez behaviour this file depends on (measured, not assumed):
;;;
;;;   1. `expand' does NOT raise for an unbound top-level identifier.  It
;;;      lowers it to (($primitive 2 $top-level-value) 'name ...).  So unbound
;;;      detection can only come from the post-expansion walk, never from a
;;;      guard around `expand'.
;;;   2. A definition lowers to a $set-top-level-value! call:
;;;          (($primitive 3 $set-top-level-value!) 'name value)
;;;      while a *use* lowers to a $top-level-value call:
;;;          (($primitive 2 $top-level-value) 'name)
;;;      Both start with a ($primitive ...) head and carry a quoted symbol in
;;;      second position, so the predicate below must look at the LAST element
;;;      of the head list.  Matching on ($primitive ...) alone silently turns
;;;      every global reference into a definition.
;;;   3. `define', `define-public' and `provide-public' all lower to the same
;;;      $set-top-level-value! shape, so one clause covers them all.

(library (static-analysis)
  (export index-module-definitions
          reset-index!
          definition-name
          definer-form?
          make-lookup
          make-resolver
          expand-with-lazy-helpers
          walk-core-ast
          analyze-forms
          analyze-module
          report-finding
          definers)
  (import (chezscheme) (compiler-db) (compiler-scan))

  ;;; ---------------------------------------------------------------------
  ;;; 1. Definition index:  (mod-name . symbol) -> AST form | 'OVERLOAD
  ;;; ---------------------------------------------------------------------

  ;; One flat key beats a table of tables: a single lookup, no nested #f checks.
  (define *definitions* (make-hashtable equal-hash equal?))

  ;; Every form that introduces a top-level name.
  (define definers
    '(define define-public provide-public
      define-syntax define-macro define-public-macro define-module-macro
      define-export-macro define-menu define-widget
      tm-define tm-define-macro))

  ;; Only these two may legally repeat; a second occurrence is an overload.
  (define overload-definers '(tm-define tm-define-macro))

  (define (reset-index!)
    (hashtable-clear! *definitions*)
    (set! *kernel-mod-names* '()))

  (define (leftmost-symbol x)
    (if (pair? x) (leftmost-symbol (car x)) x))

  ;; Name introduced by a defining form, or #f for anything else.
  (define (definition-name form)
    (and (pair? form)
         (memq (car form) definers)
         (pair? (cdr form))
         (let ((name (leftmost-symbol (cadr form))))
           (and (symbol? name) name))))

  (define (definer-form? form)
    (and (definition-name form) #t))

  (define (find-header forms)
    (find (lambda (f) (and (pair? f) (eq? (car f) 'texmacs-module))) forms))

  (define (header-deps header mod-name)
    (let loop ((opts (cddr header)) (deps '()))
      (cond ((null? opts) (reverse deps))
            ((and (pair? (car opts)) (memq (caar opts) '(:use :inherit)))
             (loop (cdr opts)
                   (fold-left (lambda (acc s)
                                (if (or (equal? s mod-name) (member s acc))
                                    acc
                                    (cons s acc)))
                              deps
                              (cdar opts))))
            (else (loop (cdr opts) deps)))))

  (define (index-module-definitions progs-dir rel-paths)
    (for-each
      (lambda (rel-path)
        (let* ((forms (read-all-forms (string-append progs-dir "/" rel-path)))
               (header (find-header forms))
               (mod-name (and header (cadr header))))
          (when mod-name
            (note-mod-name! mod-name)
            (for-each
              (lambda (form)
                (let ((name (definition-name form)))
                  (when name
                    (let* ((key (cons mod-name name))
                           (old (hashtable-ref *definitions* key #f)))
                      (hashtable-set! *definitions* key
                                      (if (and old (memq (car form) overload-definers))
                                          'OVERLOAD
                                          form))))))
              forms))))
      rel-paths))

  ;;; ---------------------------------------------------------------------
  ;;; 2. Resolver: one closure per module, carrying its own scope
  ;;; ---------------------------------------------------------------------

  ;; Modules under kernel/ are visible to every module without a (:use ...)
  ;; declaration, so they form the third and last tier of the search.
  (define *kernel-mod-names* '())

  (define (note-mod-name! mod-name)
    (when (and (pair? mod-name)
               (eq? (car mod-name) 'kernel)
               (not (member mod-name *kernel-mod-names*)))
      (set! *kernel-mod-names* (cons mod-name *kernel-mod-names*))))

  ;; Quiet lookup: AST form, 'OVERLOAD, or #f.  Never raises, because a plain
  ;; *reference* to an overloaded tm-define is ordinary code, not an error.
  (define (make-lookup cur-mod-name deps)
    (define (lookup mod-name sym)
      (hashtable-ref *definitions* (cons mod-name sym) #f))
    (lambda (sym)
      (let loop ((mod-names (append (cons cur-mod-name deps) *kernel-mod-names*)))
        (and (pair? mod-names)
             (let ((def (lookup (car mod-names) sym)))
               (if def def (loop (cdr mod-names))))))))

  ;; Resolver for the lazy-helper path: same search, but an overloaded
  ;; tm-define cannot be evaluated at expand time and must fail loudly.
  (define (make-resolver cur-mod-name deps)
    (define lookup (make-lookup cur-mod-name deps))
    (lambda (sym)
      (let ((def (lookup sym)))
        (if (eq? def 'OVERLOAD)
            (error 'static-analysis
                   "macro expansion calls overloaded tm-define '~a in module ~a (unsupported)"
                   sym cur-mod-name)
            def))))

  ;;; ---------------------------------------------------------------------
  ;;; 3. Expansion with on-demand helper installation (Strategy A)
  ;;; ---------------------------------------------------------------------

  ;; Chez wraps unbound identifiers coming out of a procedural transformer as
  ;; uninterned gensyms; intern them so they can be matched against the index.
  (define (condition-symbol c)
    (and (irritants-condition? c)
         (pair? (condition-irritants c))
         (let ((x (car (condition-irritants c))))
           (and (symbol? x) (string->symbol (symbol->string x))))))

  ;; Returns (values core-ast compile-uses).  When a transformer calls a helper
  ;; that is not yet bound, the helper is evaluated from the index and the
  ;; expansion is retried; a helper that re-enters itself is a real cycle.
  (define (expand-with-lazy-helpers expr env resolve)
    (define installed '())                    ; helpers evaluated in this pass
    (define (install! sym def)
      (when (memq sym installed)
        (error 'static-analysis "circular macro helper dependency on '~a" sym))
      (set! installed (cons sym installed))
      (eval def env))
    (define (missing-helper c)                ; -> (sym . def-form) | #f
      (let ((sym (condition-symbol c)))
        (and sym
             (not (top-level-bound? sym env))
             (let ((def (resolve sym)))
               (and def (cons sym def))))))
    (let retry ()
      (guard (c ((missing-helper c)
                 => (lambda (pair)
                      (install! (car pair) (cdr pair))
                      (retry))))
        (values (expand expr env) (reverse installed)))))

  ;;; ---------------------------------------------------------------------
  ;;; 4. Core AST walk: definitions, runtime uses, unbound names
  ;;; ---------------------------------------------------------------------

  (define (quoted-symbol x)
    (and (pair? x)
         (eq? (car x) 'quote)
         (pair? (cdr x))
         (symbol? (cadr x))
         (cadr x)))

  ;; ($primitive <n> $set-top-level-value!) is a definition;
  ;; ($primitive <n> $top-level-value)    is a reference.  Compare the LAST
  ;; element of the head, never the first (see note 2 at the top).
  ;; ($primitive 3 $set-top-level-value!) -> $set-top-level-value!
  ;; (($primitive 2 $top-level-value) . rest) -> $top-level-value
  ;; Anything else -> #f.
  (define (primitive-operator x)
    (cond
      ((and (pair? x) (eq? (car x) '$primitive))
       (car (last-pair x)))
      ((and (pair? x) (pair? (car x)) (eq? (caar x) '$primitive))
       (car (last-pair (car x))))
      (else #f)))

  ;; After expansion every definition has one of two shapes:
  ;;   (($primitive 3 $set-top-level-value!) 'name value)   define / define-public
  ;;   (define-top-level-value 'name value)                 tm-define / tm-define-macro
  (define (core-definition-name x)
    (and (pair? x)
         (pair? (cdr x))
         (cond
           ((memq (car x) '(define-top-level-value define-top-level-syntax))
            (quoted-symbol (cadr x)))
           ((eq? (primitive-operator (car x)) '$set-top-level-value!)
            (quoted-symbol (cadr x)))
           (else #f))))

  ;; Core AST shape, as measured from Chez 10 (see note 2 at the top):
  ;;
  ;;   (($primitive 3 $set-top-level-value!) 'name value)   define / define-public
  ;;   (define-top-level-value 'name value)                 tm-define / tm-define-macro
  ;;   (set! name value)                                    redefine of a bound global
  ;;   ((($primitive 2 $top-level-value) 'name) args)        reference to a global
  ;;   (($primitive 2 +) args)                              primitive call
  ;;
  ;; Two facts drive the walker:
  ;;
  ;;   * The expander renames EVERY identifier it binds to a fresh uninterned
  ;;     symbol, and an identifier it cannot resolve to the same kind of
  ;;     symbol.  `gensym?' is true for both, so it cannot separate them.  The
  ;;     only reliable signal is scope: a renamed symbol that is not among the
  ;;     binders currently in force is an unresolved global, and its name is
  ;;     recoverable with `symbol->string'.
  ;;   * `let', `letrec', `if', `begin', `define' and `set!' survive as core
  ;;     syntax with a *symbol* head.  A global procedure call never does: it
  ;;     always goes through $top-level-value.  So a symbol head means core
  ;;     syntax, not a call.
  ;; KNOWN? is an optional predicate answering "does any module define this
  ;; name?".  It lets the caller decide unboundness from the source index
  ;; instead of from a loaded environment, so the linter needs no .so files.
  (define (walk-core-ast core-ast env defined . maybe-known?)
    (define known? (if (null? maybe-known?) (lambda (s) #f) (car maybe-known?)))
    (define unbound '())
    (define uses '())

    ;; Binders of `lambda' / `let' formals, including dotted rest arguments.
    (define (collect-formals formals acc)
      (cond ((symbol? formals) (cons formals acc))
            ((pair? formals)
             (collect-formals (cdr formals)
                              (if (symbol? (car formals))
                                  (cons (car formals) acc)
                                  acc)))
            (else acc)))

    (define (record-use! name)
      (unless (memq name uses) (set! uses (cons name uses)))
      (unless (or (top-level-bound? name env)
                  (hashtable-contains? defined name)
                  (known? name)
                  (memq name unbound))
        (set! unbound (cons name unbound))))

    (define (note-use! sym bound)
      (cond
        ((not (symbol? sym)) (void))
        ((memq sym bound) (void))                        ; lexical local
        ((gensym? sym)                                   ; unresolved global
         (record-use! (string->symbol (symbol->string sym))))
        (else (record-use! sym))))

    (define (note-definition! sym)
      (when (symbol? sym)
        (hashtable-set! defined (string->symbol (symbol->string sym)) #t)))

    (define (walk-all forms bound)
      (for-each (lambda (f) (walk f bound)) forms))

    (define (walk-bindings bindings bound)
      ;; ((name value) ...) or ((name init step) ...) for `do'
      (for-each (lambda (b)
                  (when (pair? b) (walk-all (cdr b) bound)))
                bindings))

    (define (walk x bound)
      (cond
        ((symbol? x) (note-use! x bound))
        ((pair? x)
         (let ((head (car x)))
           (cond
             ((eq? head 'quote) (void))                       ; literal: skip
             ((core-definition-name x)                        ; bind name, walk value
              => (lambda (name) (note-definition! name) (walk-all (cddr x) bound)))
             ((eq? head 'set!)
              (when (pair? (cdr x)) (note-definition! (cadr x)))
              (walk-all (cddr x) bound))
             ((eq? head 'lambda)
              (walk-all (cddr x) (collect-formals (cadr x) bound)))
             ((eq? head 'case-lambda)
              (for-each (lambda (clause)
                          (walk-all (cdr clause) (collect-formals (car clause) bound)))
                        (cdr x)))
             ((memq head '(let letrec letrec*))
              (let* ((bindings (and (pair? (cdr x)) (cadr x)))
                     (names (and (list? bindings)
                                 (collect-formals (map car bindings) bound))))
                (when (list? bindings)
                  (walk-bindings bindings (or names bound))
                  (walk-all (cddr x) (or names bound)))))
             ((eq? head 'define)                              ; internal definition
              (when (pair? (cdr x)) (note-definition! (cadr x)))
              (walk-all (cddr x) bound))
             ((eq? head 'do)                                  ; ((var init step) ...)
              (let ((bindings (and (pair? (cdr x)) (cadr x))))
                (if (list? bindings)
                    (let ((names (collect-formals (map car bindings) bound)))
                      (walk-bindings bindings bound)
                      (walk-all (cddr x) names))
                    (walk-all (cdr x) bound))))
             ((symbol? head) (walk-all (cdr x) bound))        ; if / begin / ...
             (else                                            ; operator is a primitive
              (let ((op (primitive-operator head)))
                (cond
                  ;; ((($primitive n $top-level-value) 'name) . args)
                  ((eq? op '$top-level-value)
                   (let ((name (and (pair? (cdr head)) (quoted-symbol (cadr head)))))
                     (when name (note-use! name bound)))
                   (walk-all (cdr x) bound))
                  (op (note-use! op bound) (walk-all (cdr x) bound))
                  (else (walk-all x bound))))))))))
    (walk core-ast '())
    (values (reverse unbound) (reverse uses)))

  ;;; ---------------------------------------------------------------------
  ;;; 5. Per-module analysis
  ;;; ---------------------------------------------------------------------

  ;; INSTALL! is supplied by the caller: (lambda (form env) ...).  It must make
  ;; a definition or macro live in ENV so that later forms expand correctly.
  ;;
  ;; Returns (values unbound runtime-uses compile-uses failures) where
  ;; FAILURES is a list of (index . condition) for forms the expander rejected.
  (define (analyze-forms forms env mod-name deps install!)
    (define resolve (make-resolver mod-name deps))
    ;; Unboundness is decided against the source index, not against a loaded
    ;; environment: a name defined by this module, by a declared dep, or by the
    ;; kernel is known even though nothing was ever loaded or compiled.
    (define lookup (make-lookup mod-name deps))
    (define (known? sym) (and (lookup sym) #t))
    (define defined (make-eq-hashtable))
    (define unbound '())
    (define runtime-uses '())
    (define compile-uses '())
    (define failures '())

    (define (merge! acc new) (append new acc))

    (let loop ((rest forms) (i 0))
      (unless (null? rest)
        (let ((form (car rest)))
          ;; A defining form must be live before the *next* form expands.
          (when (definer-form? form)
            (guard (e (else (set! failures (cons (cons i e) failures))))
              (install! form env)))
          (let-values (((core uses)
                        (guard (e (else (set! failures (cons (cons i e) failures))
                                        (values #f '())))
                          (expand-with-lazy-helpers form env resolve))))
            (set! compile-uses (merge! compile-uses uses))
            (when core
              (let-values (((u r) (walk-core-ast core env defined known?)))
                (set! unbound (merge! unbound u))
                (set! runtime-uses (merge! runtime-uses r)))))
          (loop (cdr rest) (+ i 1)))))

    (values unbound runtime-uses compile-uses (reverse failures)))

  ;; Convenience wrapper over analyze-forms: reads the file, splits header from
  ;; body, and resolves declared dependencies from the file itself.
  (define (analyze-module progs-dir rel-path env install!)
    (let* ((forms (read-all-forms (string-append progs-dir "/" rel-path)))
           (header (find-header forms)))
      (if (not header)
          (values '() '() '() '())                 ; not a module: nothing to lint
          (let ((mod-name (cadr header)))
            (analyze-forms (remq header forms) env mod-name
                           (header-deps header mod-name) install!)))))

  ;;; ---------------------------------------------------------------------
  ;;; 6. Reporting
  ;;; ---------------------------------------------------------------------

  (define (report-finding rel-path kind detail)
    (printf "~a  ~a  ~a~n" kind rel-path detail))
)
