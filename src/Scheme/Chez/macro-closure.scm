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
;;;   (mc-free-names form [binders])      free top-level names of a form
;;;   (mc-transformer-expr inner)         transformer lambda of a macro site
;;;   (mc-macro-deps inner)               names a macro definition needs
;;;   (mc-closures defs deps-of targets)  -> order, closure table, cycles
;;;
;;; DEFS is a hashtable name -> site (the caller's site representation is
;;; opaque here).  DEPS-OF is (lambda (site) ...) -> list of symbols.

;;; ---------------------------------------------------------------- basics

;; TeXmacs rebinds `keyword?' in boot-chez.scm; plain Chez has no such
;; procedure, so the test and bench scripts would die on the first call.
(define (mc-keyword? x)
  (and (symbol? x)
       (let ((s (symbol->string x)))
         (and (> (string-length s) 0) (char=? (string-ref s 0) #\:)))))

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

(define (mc-caddr x)
  (let ((d (mc-cddr x))) (if (pair? d) (car d) #f)))

(define (mc-cddr x)
  (let ((d (if (pair? x) (cdr x) '()))) (if (pair? d) (cdr d) '())))

(define (mc-cdddr x)
  (let ((d (mc-cddr x))) (if (pair? d) (cdr d) '())))

(define (mc-binding-names bs)
  (map (lambda (b) (if (pair? b) (car b) #f)) bs))

;; (name init) or (name init step); a malformed binding contributes nothing.
(define (mc-binding-inits bs)
  (map (lambda (b) (if (pair? b) (cdr b) '())) bs))

(define (mc-formals->list f acc)
  (cond ((symbol? f) (cons f acc))
        ((pair? f) (mc-formals->list (cdr f)
                                     (if (symbol? (car f)) (cons (car f) acc) acc)))
        (else acc)))

;; Auxiliary syntax: never a reference to a top-level binding.
(define mc-aux-syntax '(else => ... _ unquote unquote-splicing))

(define mc-value-definers
  '(define define-public provide-public tm-define))

(define mc-macro-definers
  '(define-syntax define-macro define-public-macro define-module-macro
    define-export-macro tm-define-macro))

;;; ------------------------------------------------------- free name walker
;;
;; Runs on two kinds of input.
;;
;;   * Source forms (what the closure is built from).  Nothing is expanded, so
;;     the walk has to follow the binders itself.  Besides the core forms it
;;     models the TeXmacs macros that bind a name -- (with v e body),
;;     (for (i l) body), (receive (a b) v body), (guard (e ...) body) -- because
;;     an unmodelled binder turns its variable into a false dependency.
;;
;;   * Expanded core AST (linter phases 3-4).  There every lexical and
;;     module-internal binding has been renamed to a gensym, so a plain
;;     interned symbol is a top-level reference and no scope tracking is
;;     needed; a global reference also shows up as
;;     (($primitive n $top-level-value) 'name).
;;
;; The result is an over-approximation on source input: it can report a
;; reference that never runs, but it cannot miss one.

(define (mc-free-names form . seed)
  (let ((acc '()))
    (define (add s)
      (unless (memq s acc) (set! acc (cons s acc))))
    (define (add-ref s b)
      (unless (or (memq s b) (mc-keyword? s) (memq s mc-aux-syntax))
        (add (string->symbol (symbol->string s)))))
    (define (walk-all xs b) (mc-walk-each xs (lambda (x) (walk x b))))

    ;; ``x -- only the unquoted parts are code.
    (define (walk-quasi x b depth)
      (cond
        ((pair? x)
         (let ((h (car x)))
           (cond
             ((and (symbol? h) (eq? h 'unquote))
              (if (= depth 0)
                  (walk-all (cdr x) b)
                  (walk-quasi (cdr x) b (- depth 1))))
             ((and (symbol? h) (eq? h 'unquote-splicing))
              (if (= depth 0)
                  (walk-all (cdr x) b)
                  (walk-quasi (cdr x) b (- depth 1))))
             ((and (symbol? h) (eq? h 'quasiquote))
              (walk-quasi (cdr x) b (+ depth 1)))
             (else (walk-quasi (car x) b depth)
                   (walk-quasi (cdr x) b depth)))))
        (else (void))))

    (define (walk x b)
      (cond
        ((symbol? x) (add-ref x b))
        ((pair? x)
         (let ((h (car x)))
           (cond
             ;; ---------------- expanded core AST --------------------------
             ((and (symbol? h) (eq? h '$primitive)) (void))
             ((eq? (mc-prim-op x) '$top-level-value)
              (let ((s (mc-quoted-symbol (mc-cadr x))))
                (when (symbol? s) (add-ref s b))))
             ((eq? (mc-prim-op x) '$set-top-level-value!)
              (let ((s (mc-quoted-symbol (mc-cadr x))))
                (when (pair? (mc-cddr x))
                  (walk (mc-caddr x) (if (symbol? s) (cons s b) b)))))
             ((mc-prim-op x) (walk-all (cdr x) b))
             ;; ---------------- data, not code -----------------------------
             ((and (symbol? h) (memq h '(quote syntax syntax-rules quasisyntax)))
              (void))
             ((and (symbol? h) (eq? h 'quasiquote)) (walk-quasi (cdr x) b 0))
             ;; A macro definition is analysed from its transformer, not from
             ;; here: walking the template would report its names as uses.
             ((and (symbol? h) (memq h mc-macro-definers)) (void))
             ;; ---------------- definitions --------------------------------
             ((and (symbol? h) (memq h mc-value-definers))
              (cond
                ((and (pair? (cdr x)) (pair? (mc-cadr x)))
                 ;; (define (f . args) body) -- f and args are binders
                 (let* ((head (mc-cadr x))
                        (self (and (pair? head) (car head)))
                        (names (mc-formals->list
                                 (cdadr x)
                                 (if (symbol? self) (cons self b) b))))
                   (walk-all (mc-cddr x) names)))
                ((and (pair? (cdr x)) (symbol? (mc-cadr x)))
                 (walk-all (mc-cddr x) (cons (mc-cadr x) b)))
                (else (void))))
             ;; ---------------- core binding forms -------------------------
             ((and (symbol? h) (eq? h 'lambda))
              (walk-all (mc-cddr x) (mc-formals->list (mc-cadr x) b)))
             ((and (symbol? h) (eq? h 'case-lambda))
              (for-each (lambda (cl)
                          (when (pair? cl)
                            (walk-all (cdr cl) (mc-formals->list (car cl) b))))
                        (cdr x)))
             ((and (symbol? h) (memq h '(let letrec letrec*))
                   (if (and (pair? (cdr x)) (symbol? (mc-cadr x)))
                       (pair? (mc-cdddr x))
                       (pair? (mc-cddr x))))
              (let* ((named? (and (pair? (cdr x)) (symbol? (mc-cadr x))))
                     (bs (if named? (mc-caddr x) (mc-cadr x)))
                     (body (if named? (mc-cdddr x) (mc-cddr x)))
                     (names (mc-formals->list
                              (if (list? bs) (mc-binding-names bs) '())
                              (if named? (cons (mc-cadr x) b) b)))
                     ;; letrec initialisers already see every name; a plain
                     ;; let's do not.
                     (init-scope (if (eq? h 'let) b names)))
                (when (list? bs) (walk-all (mc-binding-inits bs) init-scope))
                (walk-all body names)))
             ((and (symbol? h) (eq? h 'let*)
                   (pair? (mc-cddr x)))
              ;; each initialiser sees the names bound before it
              (let ((bs (and (pair? (cdr x)) (mc-cadr x))))
                (if (list? bs)
                    (let loop ((p bs) (scope b))
                      (cond ((null? p) (walk-all (mc-cddr x) scope))
                            (else
                             (when (pair? (car p)) (walk-all (cdar p) scope))
                             (loop (cdr p)
                                   (if (and (pair? (car p)) (symbol? (caar p)))
                                       (cons (caar p) scope)
                                       scope)))))
                    (walk-all (mc-cddr x) b))))
             ((and (symbol? h) (memq h '(let-values let*-values)))
              (let* ((bs (and (pair? (cdr x)) (mc-cadr x)))
                     (names (if (list? bs)
                                (mc-formals->list (mc-binding-names bs) b)
                                b)))
                (when (list? bs) (walk-all (mc-binding-inits bs) b))
                (walk-all (mc-cddr x) names)))
             ((and (symbol? h) (eq? h 'do))
              (let* ((bs (and (pair? (cdr x)) (mc-cadr x)))
                     (names (if (list? bs) (mc-formals->list (mc-binding-names bs) b) b)))
                ;; the init forms see the outer scope, the steps see the loop
                ;; variables; binding them throughout is the safe direction
                (when (list? bs) (walk-all (mc-binding-inits bs) names))
                (walk-all (mc-cddr x) names)))
             ;; ---------------- TeXmacs binding macros ---------------------
             ;; These are macros, not syntax, so the head is itself a
             ;; dependency: the form cannot expand unless `with' / `for' /
             ;; `receive' is installed.
             ;; (with var val body ...)          -- abbrevs.scm
             ((and (symbol? h) (eq? h 'with))
              (add-ref h b)
              (let* ((var (and (pair? (cdr x)) (mc-cadr x)))
                     (val (and (pair? (mc-cddr x)) (mc-caddr x))))
                (when (pair? (mc-cddr x)) (walk val b))
                (walk-all (mc-cdddr x) (if (symbol? var) (cons var b) b))))
             ;; (for (i lst ...) body ...)       -- abbrevs.scm; binds (car spec)
             ((and (symbol? h) (eq? h 'for))
              (add-ref h b)
              (let* ((spec (and (pair? (cdr x)) (mc-cadr x)))
                     (var (and (pair? spec) (car spec))))
                (when (pair? spec) (walk-all (cdr spec) b))
                (walk-all (mc-cddr x) (if (symbol? var) (cons var b) b))))
             ;; (receive formals val body ...)   -- srfi.scm
             ((and (symbol? h) (eq? h 'receive))
              (add-ref h b)
              (let* ((fs (and (pair? (cdr x)) (mc-cadr x)))
                     (val (and (pair? (mc-cddr x)) (mc-caddr x))))
                (when (pair? (mc-cddr x)) (walk val b))
                (walk-all (mc-cdddr x) (mc-formals->list fs b))))
             ;; (guard (var clause ...) body ...) -- the clauses are code too
             ((and (symbol? h) (eq? h 'guard))
              (let* ((spec (and (pair? (cdr x)) (mc-cadr x)))
                     (var (and (pair? spec) (car spec)))
                     (names (if (symbol? var) (cons var b) b)))
                (when (pair? spec) (walk-all (cdr spec) names))
                (walk-all (mc-cddr x) names)))
             ;; ---------------- core syntax with a non-reference head --------
             ;; (begin ...) (if ...) (set! v e) and friends: the head is
             ;; syntax, not a call to a top-level binding.
             ((and (symbol? h)
                   (memq h '(begin if set! and or when unless cond case
                             parameterize while)))
              (walk-all (cdr x) b))
             ;; ---------------- everything else ----------------------------
             (else (walk-all x b)))))
        (else (void))))

    (walk form (if (null? seed) '() (car seed)))
    (reverse acc)))

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

;; A syntax-rules template is hygienic, but the identifiers it splices in that
;; are *not* pattern variables still have to resolve when a consumer expands
;; the macro.  Those are the macro's real dependencies, and they are invisible
;; to the definer-headed walk above, which skips the whole form.
(define (mc-syntax-rules-deps spec)
  ;; spec = (syntax-rules (literal ...) (pattern template ...) ...)
  (let* ((has-lits (and (pair? (cdr spec)) (list? (cadr spec))))
         (lits (if has-lits (cadr spec) '()))
         (clauses (if has-lits (cddr spec) (cdr spec))))
    (apply append
           (map (lambda (cl)
                  (and (pair? cl)
                       (mc-free-names (cdr cl) (mc-pattern-vars (car cl) lits))))
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
                 (mc-free-names v))
                (else '()))))
           ;; (define-macro (m . args) body ...) and its relatives
           ((memq head '(define-macro define-public-macro
                         define-module-macro define-export-macro
                         tm-define-macro))
            (let ((tx (mc-transformer-expr inner)))
              (if tx (mc-free-names tx) '())))
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
    (define comps '())                        ; reverse order of discovery
    (define comp-of (make-eq-hashtable))
    (define idx (make-eq-hashtable))
    (define low (make-eq-hashtable))
    (define on (make-eq-hashtable))
    (define stack '())
    (define counter 0)
    (define (pop-until! v)
      (let loop ((acc '()))
        (let ((w (car stack)))
          (set! stack (cdr stack))
          (hashtable-set! on w #f)
          (if (eq? w v) (cons w acc) (loop (cons w acc))))))
    (define (strongconnect! v)
      (hashtable-set! idx v counter)
      (hashtable-set! low v counter)
      (set! counter (+ counter 1))
      (set! stack (cons v stack))
      (hashtable-set! on v #t)
      (for-each
        (lambda (w)
          (cond
            ((not (hashtable-ref idx w #f))
             (strongconnect! w)
             (hashtable-set! low v (min (hashtable-ref low v 0)
                                        (hashtable-ref low w 0))))
            ((hashtable-ref on w #f)
             (hashtable-set! low v (min (hashtable-ref low v 0)
                                        (hashtable-ref idx w 0))))))
        (node-deps v))
      (when (= (hashtable-ref low v 0) (hashtable-ref idx v 0))
        (let ((c (pop-until! v)))
          (for-each (lambda (n) (hashtable-set! comp-of n (length comps))) c)
          (set! comps (cons c comps)))))
    (for-each (lambda (v) (unless (hashtable-ref idx v #f) (strongconnect! v)))
              (vector->list (hashtable-keys defs)))
    (values (list->vector (reverse comps)) comp-of))

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
