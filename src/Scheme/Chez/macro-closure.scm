;;; macro-closure.scm -- transitive dependency closure for macro helpers.
;;;
;;; The linter's reactive model (call-with-lazy-deps) discovers a helper only
;;; after `expand' or `eval' has already failed on it: trap the condition,
;;; parse "variable <name> is not bound" out of the message, evaluate the
;;; definition, retry.  That cannot see a *macro* that is merely missing,
;;; because Chez's expander does not raise for an unbound identifier -- it
;;; lowers it to ($primitive n $top-level-value).  A subform like (for (i l)
;;; ...) therefore stays a procedure call, `i' looks like a free variable, and
;;; the form either fails for the wrong reason or analyses wrongly.
;;;
;;; This file answers the question ahead of time, without an environment:
;;;
;;;   given the static index of definitions and one target name, which
;;;   definitions must be live before the target can be expanded?
;;;
;;; The answer is computed by walking source forms, not by expanding them, so
;;; it needs no macros to be installed -- which is the whole point, since the
;;; set it returns is what gets installed.
;;;
;;; Everything here is a pure procedure.  No I/O, no environment access, no
;;; side effects at load time, so the file can be primitive-load-ed inside a
;;; TeXmacs process (linter.scm) and `load-ed from plain Chez (the test and the
;;; bench script).
;;;
;;; ---------------------------------------------------------------------
;;; The graph
;;; ---------------------------------------------------------------------
;;;
;;; A node is a name that the index resolves to a definition site.  An edge
;;; N -> M means "M's definition mentions N in a position that is evaluated
;;; when the definition is installed, or when a consumer of it is expanded".
;;;
;;; The walk is syntactic, so it over-approximates: a name can appear in a
;;; branch that never runs.  That is the safe direction.  A *missed* edge would
;;; leave a helper uninstalled, and a missing macro is silent (see above),
;;; while an extra edge only costs one redundant `eval'.
;;;
;;; ---------------------------------------------------------------------
;;; Cycles
;;; ---------------------------------------------------------------------
;;;
;;; TeXmacs definitions are genuinely mutually recursive in places, so the
;;; graph is not a DAG and a tree walk would not terminate.  Two independent
;;; mechanisms handle that:
;;;
;;;   1. The depth-first walk keeps a three-state mark per node and stops at
;;;      any node it has already entered (the "no revisit" rule).  That is
;;;      what makes the traversal terminate and what produces the linear
;;;      install order.
;;;
;;;   2. The recorded dependency *set* must be exact even inside a cycle, and
;;;      a memoised walk would return a different set depending on which
;;;      member it started from.  So the graph is condensed into strongly
;;;      connected components first; the condensation is acyclic, and the
;;;      per-name set is the union of the components reachable from the name's
;;;      component.  Every member of a cycle therefore reports the whole cycle,
;;;      which is the only correct answer -- none of them can be installed
;;;      before the others.
;;;
;;; ---------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------
;;;
;;;   (mc-free-references form [env] [self?])  free references via Chez expand
;;;   (mc-val-dependencies form is-macro? [e]) macro & runtime dependencies
;;;   (mc-transformer-expr inner)              transformer lambda of a macro site
;;;   (mc-macro-deps inner)                    names a macro definition needs
;;;   (mc-closures defs deps-of targets)       -> order, closure table, cycles
;;;
;;; DEFS is a hashtable name -> site (the caller's site representation is
;;; opaque here).  DEPS-OF is (lambda (site) ...) -> list of symbols.

;;; ---------------------------------------------------------------- basics

(unless (top-level-bound? 'tarjan-scc/comp-of)
  (let loop ((dirs '("." "src/Scheme/Chez" "texmacs/src/Scheme/Chez" "../src/Scheme/Chez")))
    (cond
      ((null? dirs)
       (guard (e (#t #f)) (eval '(import (tarjan)))))
      ((file-exists? (string-append (car dirs) "/tarjan.scm"))
       (load (string-append (car dirs) "/tarjan.scm"))
       (guard (e (#t #f)) (eval '(import (tarjan)))))
      (else (loop (cdr dirs))))))


(define (mc-walk-each xs f)
  (let loop ((p xs)) (when (pair? p) (f (car p)) (loop (cdr p)))))

(define (mc-filter pred xs)
  (let loop ((p xs) (acc '()))
    (cond ((null? p) (reverse acc))
          ((pred (car p)) (loop (cdr p) (cons (car p) acc)))
          (else (loop (cdr p) acc)))))

(define (mc-leftmost-symbol x)
  (if (pair? x) (mc-leftmost-symbol (car x)) x))

(define (mc-quoted-symbol x)
  (and (pair? x) (eq? (car x) 'quote) (pair? (cdr x))
       (symbol? (cadr x)) (cadr x)))

;; (($primitive n op) args ...) or ($primitive n op) -> op
(define (mc-prim-op x)
  (cond ((and (pair? x) (eq? (car x) '$primitive)) (car (last-pair x)))
        ((and (pair? x) (pair? (car x)) (eq? (caar x) '$primitive))
         (car (last-pair (car x))))
        (else #f)))

;; The walker must be total: source forms are arbitrary data, and a truncated
;; (with x) or (do) must not crash the analysis.
(define (mc-cadr x)
  (let ((d (if (pair? x) (cdr x) '()))) (if (pair? d) (car d) #f)))

;; Auxiliary syntax: never a reference to a top-level binding.
(define mc-aux-syntax '(else => ... _ unquote unquote-splicing))

;;; --------------------------------- expand-based value & function analysis

(define mc-core-syntax
  '(lambda if set! begin let letrec letrec* case-lambda quote void $primitive))

;; Extract or normalize a value/function definition to an evaluable expression (lambda or value expr)
(define (mc-normalize-expr form)
  (cond
    ((not (pair? form)) form)
    ((eq? (car form) 'lambda) form)
    ((and (memq (car form) '(define define-public provide-public tm-define))
          (pair? (cdr form)))
     (let ((spec (cadr form))
           (body (cddr form)))
       (let ((clean-body (if (and (pair? body) (string? (car body)) (pair? (cdr body)))
                             (cdr body)
                             body)))
         (cond
           ;; (define (f x y) ...) or curried (define ((f x) y) ...)
           ((pair? spec)
            (if (pair? (car spec))
                (mc-normalize-expr `(define ,(car spec) (lambda ,(cdr spec) ,@clean-body)))
                `(lambda ,(cdr spec) ,@clean-body)))
           ;; (define x expr)
           ((and (symbol? spec) (pair? clean-body))
            (car clean-body))
           (else form)))))
    (else form)))

;; Extract the defined symbol name from definition forms
(define (mc-definition-name form)
  (cond
    ((not (pair? form)) #f)
    ((and (memq (car form) '(define define-public provide-public tm-define))
          (pair? (cdr form)))
     (let ((spec (cadr form)))
       (cond
         ((symbol? spec) spec)
         ((pair? spec)
          (let loop ((s spec))
            (if (pair? (car s)) (loop (car s)) (car s))))
         (else #f))))
    (else #f)))

;; Free references of a value or function definition using Chez Scheme's expander
(define (mc-free-references form . opt-args)
  "Extract all free variable and procedure calls from FORM using Chez expand.
   Optional arguments:
     ENV           - environment to expand in (default: interaction-environment)
     EXCLUDE-SELF  - whether to omit recursive self-references (default: #t)"
  (let* ((env (if (pair? opt-args) (car opt-args) (interaction-environment)))
         (exclude-self? (if (and (pair? opt-args) (pair? (cdr opt-args)))
                            (cadr opt-args)
                            #t))
         (self-name (and exclude-self? (mc-definition-name form)))
         (expr (mc-normalize-expr form))
         (expanded (guard (e (else #f)) (expand expr env))))
    (if (not expanded)
        '()
        (let ((runtime-refs '()))
          (letrec
              ((add-ref!
                (lambda (s)
                  (let ((clean (string->symbol (symbol->string s))))
                    (when (and (not (memq clean mc-core-syntax))
                               (not (and self-name (eq? clean self-name)))
                               (not (memq clean runtime-refs)))
                      (set! runtime-refs (cons clean runtime-refs))))))
               (walk
                (lambda (x)
                  (cond
                    ;; Plain non-gensym symbol: free variable / function call
                    ((and (symbol? x) (not (gensym? x)))
                     (add-ref! x))
                    ((pair? x)
                     (let ((op (mc-prim-op x)))
                       (cond
                         ;; Chez ($primitive n $top-level-value) 'sym lookup
                         ((eq? op '$top-level-value)
                          (let ((s (mc-quoted-symbol (if (pair? (cdr x)) (cadr x) #f))))
                            (when (symbol? s) (add-ref! s))))
                         ;; Mutation: do not report target symbol as a read dependency
                         ((eq? op '$set-top-level-value!)
                          (when (pair? (cddr x)) (walk (caddr x))))
                         ;; Literals and quoted data
                         ((memq (car x) '(quote syntax datum)) (void))
                         (else
                          (walk (car x))
                          (walk (cdr x))))))
                    (else (void))))))
            (walk expanded)
            (reverse runtime-refs))))))


;; Extract any known macros referenced in the source form
(define (mc-extract-macro-references form is-macro?)
  (let ((macros '()))
    (define (walk x)
      (cond
        ((pair? x)
         (let ((head (car x)))
           (when (and (symbol? head) (is-macro? head))
             (unless (memq head macros)
               (set! macros (cons head macros))))
           (walk (car x))
           (walk (cdr x))))
        (else (void))))
    (walk form)
    (reverse macros)))

;; Combined dependencies for a value/function definition:
;; 1. Any macros invoked in the source AST (expand-time dependencies)
;; 2. Any runtime procedure calls in the expanded body (runtime dependencies)
(define (mc-val-dependencies form is-macro? . opt-env)
  (let* ((env (if (pair? opt-env) (car opt-env) (interaction-environment)))
         (macros (if is-macro? (mc-extract-macro-references form is-macro?) '()))
         (runtime (mc-free-references form env #t)))
    (let loop ((rest runtime) (acc macros))
      (cond
        ((null? rest) (reverse acc))
        ((memq (car rest) acc) (loop (cdr rest) acc))
        (else (loop (cdr rest) (cons (car rest) acc)))))))

;;; --------------------------------------------- macro transformer bodies
;;
;; `define-syntax' and the define-macro family expand to (void), so the body
;; never appears in the expansion.  Rebuild it from the source form.

(define (mc-transformer-expr inner)
  (and (pair? inner) (pair? (cdr inner))
       (let ((head (car inner)) (spec (cadr inner)))
         (cond
           ((and (memq head '(define-macro define-public-macro
                              define-module-macro define-export-macro
                              tm-define-macro))
                 (pair? spec))
            `(lambda ,(cdr spec) ,@(cddr inner)))
           ((and (eq? head 'define-syntax) (symbol? spec) (pair? (cddr inner)))
            (let ((v (caddr inner)))
              (and (pair? v) (eq? (car v) 'lambda) v)))
           (else #f)))))

;; Pattern variables of one syntax-rules pattern: every symbol that is not a
;; literal, not `_' and not the ellipsis.
(define (mc-pattern-vars pat lits)
  (let ((acc '()))
    (define (add s) (unless (memq s acc) (set! acc (cons s acc))))
    (define (walk p)
      (cond
        ((symbol? p) (unless (memq p lits) (unless (memq p mc-aux-syntax) (add p))))
        ((vector? p) (vector-for-each walk p))
        ((pair? p) (walk (car p)) (walk (cdr p)))
        (else (void))))
    (walk pat)
    acc))

(define (mc-strip-ellipsis x)
  (cond
    ((null? x) '())
    ((pair? x)
     (if (eq? (car x) '...)
         (mc-strip-ellipsis (cdr x))
         (cons (mc-strip-ellipsis (car x)) (mc-strip-ellipsis (cdr x)))))
    ((eq? x '...) '())
    (else x)))

;; A syntax-rules template is hygienic, but the identifiers it splices in that
;; are *not* pattern variables still have to resolve when a consumer expands
;; the macro.  Those are the macro's real dependencies.
(define (mc-syntax-rules-deps spec)
  ;; spec = (syntax-rules (literal ...) (pattern template ...) ...)
  (let* ((has-lits (and (pair? (cdr spec)) (list? (cadr spec))))
         (lits (if has-lits (cadr spec) '()))
         (clauses (if has-lits (cddr spec) (cdr spec))))
    (apply append
           (map (lambda (cl)
                  (if (pair? cl)
                      (let* ((pat-vars (mc-pattern-vars (car cl) lits))
                             (tmpl-body (mc-strip-ellipsis (cdr cl)))
                             (fn `(lambda ,pat-vars ,@tmpl-body)))
                        (mc-free-references fn))
                      '()))
                clauses))))

;; Everything a macro definition needs in order to be *installed* and in order
;; for its consumers to *expand*.
(define (mc-macro-deps inner)
  (and (pair? inner) (pair? (cdr inner))
       (let ((head (car inner)) (name (cadr inner)))
         (cond
           ;; (define-syntax name (syntax-rules (lits) clause ...))
           ;; (define-syntax name (lambda (form) ...))
           ((and (eq? head 'define-syntax) (symbol? name) (pair? (cddr inner)))
            (let ((v (caddr inner)))
              (cond
                ((and (pair? v) (eq? (car v) 'syntax-rules))
                 (mc-syntax-rules-deps v))
                ((and (pair? v) (eq? (car v) 'lambda))
                 (mc-free-references v))
                (else '()))))
           ;; (define-macro (m . args) body ...) and its relatives
           ((memq head '(define-macro define-public-macro
                         define-module-macro define-export-macro
                         tm-define-macro))
            (let ((tx (mc-transformer-expr inner)))
              (if tx (mc-free-references tx) '())))
           (else '())))))


;;; ------------------------------------------------------------ closure

(define (mc-union a b)
  (cond ((null? b) a)
        ((memq (car b) a) (mc-union a (cdr b)))
        (else (mc-union (cons (car b) a) (cdr b)))))

;; (mc-closures defs deps-of targets)
;;
;;   defs    : hashtable  name -> site
;;   deps-of : procedure  site -> list of symbols
;;   targets : list of names to compute closures for
;;
;; Returns (values ORDER CLOSURES CYCLES BACK-EDGES):
;;
;;   ORDER       every reachable name, dependencies before dependents.  A valid
;;               install order: evaluating a definition only allocates closures,
;;               so a forward reference is harmless as long as the referent is
;;               bound before it is *called*.  Members of a cycle appear in the
;;               order the walk reached them; they cannot be ordered, by
;;               definition.
;;   CLOSURES    hashtable name -> the transitive dependency set of NAME, for
;;               every name in ORDER (in-tree names only, NAME excluded).  Every
;;               member of a cycle reports the same set.
;;   CYCLES      list of strongly connected components with more than one member.
;;   BACK-EDGES  how often the "no revisit" rule fired, i.e. how many times the
;;               walk met a node it was already inside.
(define (mc-closures defs deps-of targets)
  ;; ---- 1. in-tree dependency lists, self edges dropped -------------------
  (define dep-cache (make-eq-hashtable))
  (define (node-deps name)
    (let ((hit (hashtable-ref dep-cache name 'mc-miss)))
      (if (eq? hit 'mc-miss)
          (let* ((site (hashtable-ref defs name #f))
                 (raw (if site (deps-of site) '()))
                 (d (mc-filter (lambda (x)
                                 (and (symbol? x)
                                      (not (eq? x name))
                                      (hashtable-ref defs x #f)))
                               raw)))
            (hashtable-set! dep-cache name d)
            d)
          hit)))

  ;; ---- 2. depth-first post-order, stopping at any revisit ----------------
  ;; This is the rule that makes the walk terminate on a cyclic graph, and it
  ;; is also the ordering step: a node is emitted after every dependency the
  ;; walk could reach without re-entering a node it is already inside.
  (define state (make-eq-hashtable))          ; name -> 'active | 'done
  (define order '())
  (define n-back-edges 0)
  (define (visit name)
    (let ((s (hashtable-ref state name #f)))
      (cond
        ((eq? s 'done) (void))
        ((eq? s 'active) (set! n-back-edges (+ n-back-edges 1)))
        (else
         (hashtable-set! state name 'active)
         (for-each visit (node-deps name))
         (hashtable-set! state name 'done)
         (set! order (cons name order))))))
  (define (run-dfs!)
    (for-each (lambda (t) (when (hashtable-ref defs t #f) (visit t))) targets))

  ;; ---- 3. Tarjan SCC: the condensation is acyclic ------------------------
  ;; Returns (values COMPONENTS COMP-OF).  COMPONENTS is a vector of name
  ;; lists; COMP-OF maps a name to its component index.
  (define (tarjan)
    (let-values (((comps comp-of)
                  (tarjan-scc/comp-of (hashtable-keys defs)
                                      node-deps
                                      make-eq-hashtable)))
      (values (list->vector comps) comp-of)))

  ;; ---- 4+5. exact closure sets over the condensation ---------------------
  ;; Reachability is memoised over the condensed graph, which has no cycle, so
  ;; a memo entry is never computed from itself.  That is what makes every
  ;; member of a cycle report the same set.
  (define (closure-table cv comp-of names)
    (define ncomp (vector-length cv))
    (define cedges (make-vector ncomp '()))
    (define reach (make-vector ncomp #f))
    (define table (make-eq-hashtable))
    (define (comp-reach c)
      (let ((hit (vector-ref reach c)))
        (cond
          ((eq? hit #f)
           (vector-set! reach c 'mc-pending)
           (let loop ((ds (vector-ref cedges c)) (acc (list c)))
             (if (null? ds)
                 (begin (vector-set! reach c acc) acc)
                 (loop (cdr ds) (mc-union acc (comp-reach (car ds)))))))
          ((eq? hit 'mc-pending) '())
          (else hit))))
    (vector-for-each
      (lambda (name)
        (let ((c (hashtable-ref comp-of name 0)))
          (for-each
            (lambda (d)
              (let ((cd (hashtable-ref comp-of d 0)))
                (unless (or (= c cd) (memv cd (vector-ref cedges c)))
                  (vector-set! cedges c (cons cd (vector-ref cedges c))))))
            (node-deps name))))
      (hashtable-keys defs))
    (for-each
      (lambda (name)
        (let ((c (hashtable-ref comp-of name #f)))
          (when c
            (let ((names (apply append (map (lambda (i) (vector-ref cv i))
                                            (comp-reach c)))))
              (hashtable-set! table name
                             (mc-filter (lambda (x) (not (eq? x name))) names))))))
      names)
    table)

  ;; ---- run -------------------------------------------------------------
  (run-dfs!)
  (let-values (((cv comp-of) (tarjan)))
    (values (reverse order)
            (closure-table cv comp-of order)
            (mc-filter (lambda (c) (> (length c) 1))
                       (vector->list cv))
            n-back-edges)))
