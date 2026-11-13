(when (top-level-bound? '*boot-chez-loaded*)
  (display "WARNING: boot-chez.scm loaded more than once!\n"))
(define *boot-chez-loaded* #t)

;;; ---------------------------------------------------------------------------
;;; Engine globals
;;;
;;; These must exist before anything else in this file runs.  The kernel
;;; caches them by symbol right after the load (marked [C++] below), and
;;; reap-blackboxes! -- installed as the collect-request handler a few forms
;;; down -- reads tm-blackbox-guardian, so a GC during this very file would
;;; otherwise raise "variable tm-blackbox-guardian is not bound".
;;; ---------------------------------------------------------------------------

;; [C++] the value of '(): the kernel calls tmscm_null() for every empty list
(define tmscm-null '())

;; [C++] guardian that collects the addresses of unreachable blackbox objects
(define tm-blackbox-guardian (make-guardian))

;; The environment every dynamically evaluated TeXmacs form lands in.
(define tm-user-env (interaction-environment))

;; [C++] root of the Scheme-object handle stack (src/Scheme/Scheme/object.cpp):
;; a pair whose car is the list of live handles.  object.cpp mutates the car.
(define object-stack '(()))

(define compilation-environment
  (if (top-level-bound? 'compilation-environment)
      compilation-environment
      (make-parameter (interaction-environment))))

;; Guile's primitive loader
(unless (top-level-bound? 'primitive-load)
  (define-top-level-value 'primitive-load
    (top-level-value 'load (scheme-environment))))
(unless (top-level-bound? 'load)
  (define-top-level-value 'load primitive-load))

;; --- Guile eval/defined?/filter semantics ----------------------------------
;; Guile's eval accepts 1 argument (current module); R6RS eval requires 2.
(define primitive-eval (if (top-level-bound? 'primitive-eval) primitive-eval (top-level-value 'eval (scheme-environment))))

(define (tm-quote-eval-literals x)
  (cond ((or (box? x) (procedure? x)) (list 'quote x))
        ((pair? x)
         (if (eq? (car x) 'quote)
             x
             (let* ((a (car x))
                    (d (cdr x))
                    (a* (tm-quote-eval-literals a))
                    (d* (tm-quote-eval-literals d)))
               (if (and (eq? a a*) (eq? d d*))
                   x
                   (cons a* d*)))))
        (else x)))

;;; ---------------------------------------------------------------------------
;;; Redefined `eval` with fast-path lookup
;;;
;;; In Chez Scheme, `eval` is 2-argument (form, environment), whereas Guile's
;;; `eval` defaults to the current module environment. Furthermore, Chez's
;;; native `eval` invokes the syntax-case expander on every form before
;;; `compile-interpret-simple` interprets simple variable references (~2.6 µs
;;; and syntax-object allocation).
;;;
;;; During interactive editing, menu generation, and cursor updates, TeXmacs
;;; frequently calls `eval` on bare symbols (e.g. `(menu-expand-link p)` on
;;; `'file-menu`, or focus-tag lookups in `generic-menu.scm`), self-evaluating
;;; literals, quoted data, and 0-argument dynamic generator calls `(generator)`.
;;;
;;; Fast-path:
;;; 1. Bound symbols: resolved via `top-level-value` in ~14 ns (direct value-cell
;;;    dereference, ~200x faster than native `eval`, zero GC allocation).
;;; 2. Self-evaluating literals (numbers, strings, booleans, procedures, chars, '()):
;;;    returned as-is immediately without quote-walking or expansion.
;;; 3. (quote datum): unwrapped directly to `datum` in ~4 ns (660x faster, 0 alloc).
;;; 4. Nullary calls: `(proc)` where `proc` is a bound top-level procedure executes
;;;    the procedure directly in native machine code, bypassing the expander.
;;; 5. General forms: sanitized via non-allocating `tm-quote-eval-literals` and
;;;    forwarded to native `primitive-eval`.
;;; ---------------------------------------------------------------------------
(define eval
  (lambda (form . env)
    (let ((e (if (null? env) tm-user-env (car env))))
      (cond
        ;; 1. Bound symbols (fast variable lookup)
        ((and (symbol? form) (top-level-bound? form e))
         (top-level-value form e))
        ;; 2. Self-evaluating literals
        ((or (number? form) (string? form) (boolean? form) (procedure? form) (char? form) (null? form))
         form)
        ;; 3. (quote datum)
        ((and (pair? form) (eq? (car form) 'quote) (pair? (cdr form)) (null? (cddr form)))
         (cadr form))
        ;; 4. Nullary procedure call: (proc)
        ((and (pair? form) (null? (cdr form)) (symbol? (car form)) (top-level-bound? (car form) e))
         (let ((p (top-level-value (car form) e)))
           (if (procedure? p)
               (p)
               (let ((form* (tm-quote-eval-literals form)))
                 (primitive-eval form* e)))))
        ;; 5. General fallback
        (else
         (let ((form* (if (or (box? form) (procedure? form) (pair? form))
                          (tm-quote-eval-literals form)
                          form)))
           (primitive-eval form* e)))))))

(if (not (top-level-bound? 'select))
    (eval '(define (select . args)
             (error "select" "POSIX select is not available on this Scheme dialect"))
          tm-user-env))

;;; Foundational helpers & Guile compatibility primitives
;; Guile's `noop` is a pass-through: it returns its first argument when
;; called with one, and #f when called with none.  The previous Chez version
;; discarded all arguments, which broke callers that use `noop` as an
;; identity decoder (for example `stm-table-decode-format` for `cell-halign`).
(define (noop . args)
  (if (null? args) #f (car args)))

;; Foreign procedure hooks for C++ blackbox objects (Box representation + Guardian)
(define c-delete-blackbox
  (foreign-procedure "tmscm_delete_blackbox" (uptr) void))

(define c-blackbox-equal?
  (foreign-procedure "tmscm_blackbox_equal" (scheme-object scheme-object) scheme-object))

(define c-blackbox-hash
  (foreign-procedure "tmscm_blackbox_hash" (scheme-object) iptr))

(define (reap-blackboxes!)
  (let loop ()
    (let ((b (tm-blackbox-guardian)))
      (when b
        (let ((addr (unbox b)))
          (when (not (= addr 0))
            (c-delete-blackbox addr)
            (set-box! b 0)))
        (loop)))))

(let ((old-crh (collect-request-handler)))
  (collect-request-handler
    (lambda ()
      (old-crh)
      (reap-blackboxes!))))

(define chez:equal?
  (if (top-level-bound? 'chez:equal?) chez:equal? (top-level-value 'equal? (scheme-environment))))
(define (equal? a b)
  (cond ((eq? a b) #t)
        ((and (box? a) (box? b))
         (if (and (top-level-bound? 'blackbox?)
                  (blackbox? a)
                  (blackbox? b))
             (c-blackbox-equal? a b)
             (chez:equal? (unbox a) (unbox b))))
        ((and (pair? a) (pair? b))
         (and (equal? (car a) (car b))
              (equal? (cdr a) (cdr b))))
        (else (chez:equal? a b))))

(define (tm-equal-hash x)
  (cond ((and (box? x)
              (top-level-bound? 'blackbox?)
              (blackbox? x))
         (c-blackbox-hash x))
        ((pair? x)
         (+ (tm-equal-hash (car x)) (tm-equal-hash (cdr x))))
        (else (equal-hash x))))

(define (make-hash-table . _) (make-hashtable tm-equal-hash equal?))
(define (make-ahash-table . _) (make-hashtable tm-equal-hash equal?))

(define (keyword? x)
  (and (symbol? x)
       (let ((s (symbol->string x)))
         (and (> (string-length s) 0) (char=? (string-ref s 0) #\:)))))
(define (keyword->symbol k)
  (string->symbol (substring (symbol->string k) 1 (string-length (symbol->string k)))))
(define (symbol->keyword s)
  (string->symbol (string-append ":" (symbol->string s))))

;; Pre-bind common TeXmacs option keywords so unquoted keywords evaluate without error
(for-each
  (lambda (k)
    (unless (top-level-bound? k)
      (define-top-level-value k k)))
  '(:profile :mode :require :applicable :type :synopsis :synopsis* :returns :note
    :argument :arguments :default :proposals :secure :check-mark :interactive :balloon
    :or :and :not :repeat :group :quote :exclude :range :and-not :match :replace :all :*
    :same :up :down :first :last :next :previous :notes :footnotes :current
    :state :state-slots :prioritary :idle :pause :every :refresh :while :clean :permanent :do
    :name :quit :side :bottom :title :side-centered :bottom-indent :auto :any :free
    :bottom-left :bottom-right :transient-bottom :transient-left :transient-right :left :right :top
    :strict :strict* :manual :cmd :here :distill :other :format :syntax :limits :middle
    :highlight :pattern :gradient :picture :fallback-on-pictures :latex-annotations :mathml :mathjax
    :penalty :option :mixed :inline :block :empty :collapse :element :elem :pre :raw :terms
    :transparent :atomic :focus :selectable :operator :spacing :args :leaf :char :cursor
    :one :several :preamble :uninit :on-cpu-idle :shell
    :- :1 :advanced :always :answer :apply :approx :attached :background :basic-theme
    :bbb :beamer-theme :beamer-title-theme :big :black :bold :boolean? :box-color :box-shape :braces
    :brackets :button-color :button-shape :cal :calc :case :category :cell :cell-halign :cell-lsep
    :cmdline :code :column :comma :commander :comment-by-list :comment-list :comment-type-list :comments-in-buffer :commit
    :completes :compress :condensed :contains :created :cut :dead :declaration :denominator :device
    :dides :difference :directory :end :environment :error :expand :factor :family :file
    :fillp :filter-in :fold :font-shape :frak :function :function-with-options :global :glyphs :gpg-decrypted-style
    :gpg-empty :gpg-mismatch :handler :hidden :hide :in-row :in-row-group :initialize :integer? :interrupted
    :it :italic :keep-folded :keep-unfolded :language :lasprat :launch :left-margin :lhw :light
    :link :literal :loaded :loading :loasc :loc :local :lodes :loh :ltac
    :lvw :macpath :mag :math-correct :math-display :math-input :medium :menu-item :menu-item-list :menu-label
    :menu-wide-item :menu-wide-label :modified :mono :multiply :must-recognize :new :new-window :none :normal
    :now :numerator :oblique :off :order :ornament- :ornament-border :ornament-color :ornament-extra-color :ornament-hpadding
    :ornament-shadow-color :ornament-shape :ornament-sunny-color :ornament-swell :ornament-title-style :ornament-vpadding :out-row :out-row-group :out-table :over
    :overwrite :packages :paragraph :pasprat :poster-theme :poster-title-style :preferences :prefix :preformatted :pretty
    :procedure :program :program-theme :promptrepl :pseudos :question :recognize :recurse :remove-folded :remove-unfolded
    :removed :required :right-margin :rotate-backward :rotate-forward :row :sansserif :save-directory :save-file :saved
    :scale :scripts :section :serializer :serif :session :session-theme :setup :short-over :short-subscript
    :short-superscript :short-width :show :silent :similar :simplify-output :size :slant :small :smallcaps
    :socket :sort :space :sqrt :ss :start :stretch :string? :strong :style
    :subscript :suffix :superscript :tab-completion :test-input-done :texmacs :theorem-decorations :thin :this :timings
    :toplvl :translatable? :tt :tuple? :typeset_math_string :typewriter :uhw :unchanged :unfold :up-to-date
    :upc :update :uph :upw :users :uvw :var-compress :var-expand :var-first :var-last
    :var-next :var-previous :vcnt :vernac :versions :visible :void :weight :wide :wildcard
    :winpath
    :< :> :/ :<lsub :<lsup :<lprime :<rsub :<rsup :<rprime :<not :<long-arrow :<Prefix :<Postfix :<left :<right :<mid :<big :<around :<around* :<row :<big-around :<frac :<sqrt :<wide :<table))

(define (tm-catch-runtime key handler thunk)
  (guard (e (else
             (let* ((msg (if (condition? e) (condition-message e) e))
                    (irr (if (and (condition? e) (condition-irritants e))
                             (condition-irritants e)
                             '()))
                    (payload (list key #f msg irr '())))
               (if (procedure? handler) (apply handler payload) #f))))
    (thunk)))
(define-syntax catch
  (syntax-rules ()
    ((_ key thunk handler) (tm-catch-runtime key handler thunk))))
(define-syntax lazy-catch
  (syntax-rules ()
    ((_ key thunk handler) (tm-catch-runtime key handler thunk))))
(define (throw key . args)
  (raise (condition
           (make-error)
           (make-message-condition
             (if (and (pair? args) (string? (car args)))
                 (car args)
                 (format "~s" (cons key args))))
           (make-irritants-condition args))))

(define (defined? sym) (top-level-bound? sym))

(define-syntax with
  (lambda (x)
    (syntax-case x ()
      ((_ var val body ...)
       (let ((v (syntax->datum #'var)))
         (if (and (or (pair? v) (null? v))
                  (not (and (pair? v)
                            (symbol? (car v))
                            (let ((s (symbol->string (car v))))
                              (and (> (string-length s) 0)
                                   (char=? (string-ref s 0) #\:))))))
             #'(apply (lambda var body ...) val)
             #'(let ((var val)) body ...)))))))

;; `with' must stay: abbrevs.scm deliberately leaves its own copy commented out
;; so that this hygienic transformer is the one in use (see the long note at
;; abbrevs.scm:98).  `and-with', `with-define' and `with-result' are NOT here --
;; they are define-public-macros in kernel/boot/abbrevs.scm, which is loaded
;; right after this file and whose equivalent definitions shadowed these copies
;; anyway.
(define-syntax while
  (syntax-rules ()
    ((_ test body ...)
     (let loop ()
       (when test
         body ...
         (loop))))))


;; Guile compatibility shims that are only needed once a module is running now
;; live in kernel/boot/chez-compat.scm: the list helpers (`map-in-order',
;; `symbol-append'), the port and file helpers (`open-file',
;; `OPEN_READ'/`OPEN_WRITE', the `call-with-*-string' pair), the char-set
;; constructors, symbolic record field names (`record-accessor' /
;; `record-modifier' with a symbol instead of an index), `server-mode?',
;; `scm-error', `random', `hash' and the macro-expansion helpers.  `filter',
;; `last-pair', `1+' and `1-' were not moved but dropped: `(chezscheme)' already
;; exports all four with identical semantics.

(define-syntax with-wallet
  (syntax-rules ()
    ((_ body ...)
     (if (and (top-level-bound? 'wallet-initialized?)
              (wallet-initialized?)
              (wallet-persistent-status-on?)
              (wallet-off?))
         (wallet-dialogue-turn-on (lambda (x) body ...))
         (begin body ...)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Classical Lisp/Guile macro definitions under Chez Scheme
;;
;; In Chez Scheme, `module` bodies enforce strict R6RS internal definition grammar:
;;   (module Name () defs ... exprs ...)
;; All definitions MUST precede all expressions.
;;
;; Standard macros (`define-macro`, `define-public-macro`) are pure syntax transformers
;; and emit only definitions (`define-syntax` and `export`).
;;
;; Stateful macros that mutate intra-compiler tables or require dynamic overloading
;; (e.g. `tm-define`, `tm-define-overloaded`, `tm-define-macro`, `tm-property`) are
;; handled by the transpiler itself: it expands them in interpreter style, partitions
;; the resulting S-expression trace into pure definitions and expressions, and emits a
;; compliant compilable unit for Chez's `compile-file`.  (This used to be routed through
;; a `define-public-macro-trace` / `'macro-transformer` property; both were removed on
;; 2026-11-05 — nothing read the property and no module used the macro.)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; The transformer body is applied *lexically* rather than `eval`ed in
;; `(compilation-environment)`.
;;
;; The old shape -- (eval `(apply (lambda formals body ...) ',datum) env) --
;; re-interprets the body in the interaction environment every time the macro
;; is used, so a transformer can only reach a helper that happens to be a
;; top-level binding.  Applied lexically, the body is compiled in the module
;; that defines the macro, and its free identifiers resolve through that
;; module's imports -- including `(import (for <helpers> run expand))'.
;; Phasing then works the way PHASED_HELPERS_PLAN.md describes, with nothing
;; published into a shared environment.
;;
;; A body that calls `eval' or `top-level-value' itself is unaffected.  A body
;; that relied on the *caller's* environment is not supported; that is the
;; point.
(define-syntax define-macro
  (lambda (x)
    (syntax-case x ()
      ((_ (nm . formals) body ...)
       #'(define-syntax nm
           (lambda (stx)
             (datum->syntax (car (syntax->list stx))
               (apply (lambda formals body ...)
                      (cdr (syntax->datum stx)))))))
      ((_ nm (lambda formals body ...))
       #'(define-syntax nm
           (lambda (stx)
             (datum->syntax (car (syntax->list stx))
               (apply (lambda formals body ...)
                      (cdr (syntax->datum stx)))))))
      ((_ nm proc)
       #'(define-syntax nm
           (lambda (stx)
             (datum->syntax (car (syntax->list stx))
               (apply proc (cdr (syntax->datum stx))))))))))

;; The Guile macro-expansion helpers (`ca*r', `ca*adr', `apply*', `listify',
;; `and*', `begin*', `unlambda') and `fresh-tm-dummy' are in chez-compat.scm.
;; `lambda*' is not among them: kernel/texmacs/tm-define.scm owns and exports it.
;;
;; The `guile-*?' dialect predicates cannot move: the transpiler evaluates a
;; top-level `(if (guile-c?) ...)' as a compile-time test while it walks the
;; sources (abbrevs.scm:63), which happens before any module has been loaded.
(define (guile-a?) #f)
(define (guile-b?) #f)
(define (guile-c?) #f)
(define (guile-b-c?) #f)

;; Stays here for the same reason: tm-preferences.scm replaces it with a
;; top-level `(set! has-look-and-feel? test-look-and-feel)', which only reaches
;; the interaction-environment cell that boot-chez.scm defines.  boot.scm writes
;; this as `(== x "emacs")', abbrevs' alias for `equal?'; abbrevs is not loaded
;; yet at this point, so the primitive is used directly.
(define has-look-and-feel? (lambda (x) (equal? x "emacs")))

(define chez:sort (if (top-level-bound? 'chez:sort) chez:sort (top-level-value 'sort (scheme-environment))))
(define original-display (if (top-level-bound? 'original-display) original-display (top-level-value 'display (scheme-environment))))
(define original-write (if (top-level-bound? 'original-write) original-write (top-level-value 'write (scheme-environment))))

;; `display-to-string' and `object->string' live in kernel/boot/chez-compat.scm.
;; The io hooks below cannot use them: they are installed by this file and must
;; work before any module exists.  The module loader, for instance, reports a
;; missing module-deps.scm through `display' while it is still loading
;; chez-compat itself.  Capturing into a string port directly keeps the
;; bootstrap closed; chez-compat.scm exposes the same two procedures publicly.

(define (tm-output s)
  (original-display s))

(define (tm-errput s)
  (original-display s (console-error-port)))

(define (display . l)
  (if (or (null? l) (not (null? (cdr l))))
      (apply original-display l)
      (tm-output (call-with-string-output-port
                  (lambda (p) (original-display (car l) p))))))
(define (write . l)
  (if (or (null? l) (not (null? (cdr l))))
      (apply original-write l)
      (tm-output (call-with-string-output-port
                  (lambda (p) (original-write (car l) p))))))

(define-syntax provide-public
  (syntax-rules ()
    ((_ (name . args) body ...) (define-public (name . args) body ...))
    ((_ name val) (define-public name val))))

;; Called from C++ (src/Texmacs/Server/tm_server.cpp, tm_debug.cpp), so this
;; cell is part of the bootstrap contract and stays here.  The `on-entry' /
;; `on-exit' macros that mutate it are in chez-compat.scm.
(define (quit-TeXmacs-scheme) (noop))

;; Controls the export keyword, which is not permitted in run-time.
(define compile-export-mode? (make-parameter #f))

(define-syntax with-export-if-active
  (lambda (x)
    (syntax-case x ()
      ((_ id def-form)
       (if (compile-export-mode?)
           #'(begin (export id) def-form)
           #'def-form))
      ((_ (id ...) def-form)
       (if (compile-export-mode?)
           #'(begin (export id ...) def-form)
           #'def-form)))))

(define-syntax with-module-export-if-active
  (lambda (x)
    (syntax-case x ()
      ((_ macro-name (helpers ...) def-form)
       (if (compile-export-mode?)
           #'(begin
               (export macro-name)
               (indirect-export macro-name helpers ...)
               def-form)
           #'def-form)))))

(define-syntax define-public
  (syntax-rules ()
    ((_ (name . args) body ...)
     (with-export-if-active name (define (name . args) body ...)))
    ((_ name val)
     (with-export-if-active name (define name val)))))


(meta define (recolor-syntax x helpers module-scope call-scope)
  (cond
    [(and (symbol? x) (memq x helpers))
     (datum->syntax module-scope x)]
    [(pair? x)
     (cons (recolor-syntax (car x) helpers module-scope call-scope)
           (recolor-syntax (cdr x) helpers module-scope call-scope))]
    [(vector? x)
     (vector-map (lambda (e) (recolor-syntax e helpers module-scope call-scope)) x)]
    [else
     (datum->syntax call-scope x)]))

(define-syntax define-module-macro
  (syntax-rules ()
    [(_ (macro-name . args) (helpers ...) . body)
     (with-module-export-if-active macro-name (helpers ...)
       (define-syntax macro-name
         (lambda (call-stx)
           (define module-scope #'macro-name)
           (define call-scope (car (syntax->list call-stx)))
           (define helper-list '(helpers ...))
           (syntax-case call-stx ()
             [(_ . call-args)
              ;; Applied lexically, for the same reason as `define-macro'.
              (let ((raw (apply (lambda args . body)
                                (syntax->datum #'call-args))))
                (recolor-syntax raw helper-list module-scope call-scope))]))))]))

(define-syntax define-public-macro
  (syntax-rules ()
    ((_ (nm . formals) body ...)
     (with-export-if-active nm (define-macro (nm . formals) body ...)))
    ((_ nm val)
     (with-export-if-active nm (define-macro nm val)))))


(define *texmacs-modules-loaded* (make-ahash-table))

(define (module-file-name which)
  (let ((ps (map symbol->string which)))
    (string-append (getenv "TEXMACS_PATH") "/progs/"
                   (apply string-append
                          (map (lambda (p) (string-append "/" p)) ps))
                   ".scm")))

(define (module-loaded? m)
  (hashtable-ref *texmacs-modules-loaded* m #f))

(define (module-so-file which)
  (let* ((ps (map symbol->string which))
         (rel (let loop ((l ps))
                (if (null? (cdr l)) (car l)
                    (string-append (car l) "/" (loop (cdr l))))))
         (so-name (string-append rel ".so"))
         (boot-env (getenv "TEXMACS_BOOT_PATH"))
         (tm-path (getenv "TEXMACS_PATH"))
         (candidates
           (append
             (if boot-env (list (string-append boot-env "/" so-name)) '())
             (if tm-path (list (string-append tm-path "/boot/" so-name)) '())
             (list (string-append "boot/" so-name)))))
    (let loop ((c candidates))
      (cond ((null? c) #f)
            ((file-exists? (car c)) (car c))
            (else (loop (cdr c)))))))

(define (module-spec->symbol which)
  (let* ((ps (map symbol->string which))
         (joined (let loop ((l ps))
                   (if (null? (cdr l)) (car l)
                       (string-append (car l) ":" (loop (cdr l)))))))
    (string->symbol joined)))

(define *module-deps-table* #f)
(define *module-loading-stack* (make-ahash-table))

(define (module-deps-file)
  (let* ((boot-env (getenv "TEXMACS_BOOT_PATH"))
         (tm-path (getenv "TEXMACS_PATH"))
         (candidates
           (append
             (if boot-env (list (string-append boot-env "/module-deps.scm")) '())
             (if tm-path (list (string-append tm-path "/boot/module-deps.scm")) '())
             (list "boot/module-deps.scm"))))
    (let loop ((c candidates))
      (cond ((null? c) #f)
            ((file-exists? (car c)) (car c))
            (else (loop (cdr c)))))))

(define (read-file-safely path)
  (if (and path (file-exists? path))
      (call-with-input-file path read)
      (begin
        (display (string-append "ERROR: file not found: " (or path "#f") "\n"))
        #f)))

(define (load-module-deps-table!)
  (unless *module-deps-table*
    (set! *module-deps-table* (make-ahash-table))
    (let ((entries (read-file-safely (module-deps-file))))
      (when (list? entries)
        (for-each
          (lambda (entry)
            (when (and (pair? entry) (pair? (cdr entry)))
              (hashtable-set! *module-deps-table* (car entry) (cadr entry))))
          entries)))))

(define (parse-module-header-deps fname which)
  (guard (e (else
             (display (string-append "ERROR: parse-module-header-deps failed for " fname "\n"))
             (display-condition e)
             (newline)
             '()))
    (call-with-input-file fname
      (lambda (p)
        (let loop ()
          (let ((form (read p)))
            (cond
              ((eof-object? form) '())
              ((and (pair? form) (eq? (car form) 'texmacs-module))
               (let ((deps '()))
                 (for-each
                   (lambda (opt)
                     (when (and (pair? opt) (memq (car opt) '(:use :inherit)))
                       (for-each
                         (lambda (s)
                           (unless (or (equal? s which) (member s deps))
                             (set! deps (cons s deps))))
                         (cdr opt))))
                   (cddr form))
                 (reverse deps)))
              (else (loop)))))))))

(define (module-dependencies which)
  (load-module-deps-table!)
  (or (hashtable-ref *module-deps-table* which #f)
      (let* ((fname (module-file-name which))
             (deps (if (file-exists? fname)
                       (parse-module-header-deps fname which)
                       '())))
        (hashtable-set! *module-deps-table* which deps)
        deps)))

(define (load-module-file which)
  (let ((so (module-so-file which)))
    (if so
        (begin
          (primitive-load so)
          (guard (e (else (display (list 'IMPORT-FAIL (module-spec->symbol which) (tm-error-message e))) (newline) #f))
            (eval `(import ,(module-spec->symbol which)) (interaction-environment))))
        (let ((fname (module-file-name which)))
          (when (file-exists? fname)
            (tm-load-file fname))))))

(define (module-load which)
  (when (and (list? which)
             (not (module-loaded? which))
             (not (hashtable-ref *module-loading-stack* which #f)))
    (hashtable-set! *module-loading-stack* which #t)
    (for-each module-load (module-dependencies which))
    (hashtable-delete! *module-loading-stack* which)
    (hashtable-set! *texmacs-modules-loaded* which #t)
    (load-module-file which)))

(define (module-provide m)
  ;; During AOT compilation (compile-export-mode? #t), compile_kernel.scm
  ;; compiles and loads every module in strict topological order.
  ;; Injected (module-provide '<dep>) calls in .so files are intended for
  ;; runtime dynamic dependency loading; executing them during compile-time
  ;; verification loads would prematurely load forward/deferred circular
  ;; dependencies or stale .so files left on disk from previous builds.
  (when (and (not (compile-export-mode?))
             (not (module-loaded? m)))
    (module-load m)))

(define (resolve-module m)
  (module-provide m)
  m)


(define-syntax use-modules
  (syntax-rules ()
    ((_ mod ...)
     (begin (module-provide 'mod) ...))))

(define-syntax inherit-modules
  (syntax-rules ()
    ((_ mod ...)
     (begin (module-provide 'mod) ...))))

(define-syntax import-from
  (syntax-rules ()
    ((_ mod ...)
     (begin (module-provide 'mod) ...))))

(define-syntax texmacs-module
  (syntax-rules ()
    ((_ name options ...)
     (tm-process-module 'name '(options ...)))))

(define (tm-process-module name options)
  (hashtable-set! *texmacs-modules-loaded* name #t)
  (for-each
    (lambda (action)
      (if (pair? action)
          (cond ((equal? (car action) ':use)
                 (for-each module-provide (cdr action)))
                ((equal? (car action) ':inherit)
                 (for-each module-provide (cdr action)))
                ((equal? (car action) ':export)
                 (display "Warning] :export no longer supported\n")))))
    options))


;; Chez Scheme retains no source for compiled procedures and, unlike Guile
;; 1.8's memoizer, exposes no hook to capture it.  Source is therefore recorded
;; explicitly by the macro layer that *creates* the procedure -- the
;; source-record! calls in $>, $symbol (kernel/gui/gui-markup.scm) and
;; kbd-map-one (kernel/gui/kbd-define.scm) -- and kept in a weak table keyed by
;; procedure, so entries die with the closures they describe.
(define procedure-source-table (make-weak-eq-hashtable))

(define (source-record! proc form)
  "Attach the source form FORM to PROC and return PROC."
  (if (procedure? proc) (hashtable-set! procedure-source-table proc form))
  proc)

;; Total, like the stub it replaces: a miss yields #f, never an error.
(define (procedure-source p)
  (if (procedure? p) (hashtable-ref procedure-source-table p #f) #f))

(define (promise-source action)
  (and (procedure? action)
       (let ((source (procedure-source action)))
         (and (pair? source)
              (equal? (car source) 'lambda)
              (equal? (cadr source) '())
              (null? (cdddr source))
              (caddr source)))))


(define texmacs-user
  (if (top-level-bound? 'texmacs-user)
      texmacs-user
      tm-user-env))

(define texmacs-user-kernel tm-user-env)

(define developer-mode?
  (if (top-level-bound? 'developer-mode?)
      developer-mode?
      (and (top-level-bound? 'cpp-get-preference)
           (equal? (cpp-get-preference "developer tool" "off") "on"))))

(unless (top-level-bound? 'notify-preferences-booted)
  (define-top-level-value 'notify-preferences-booted (lambda () (noop))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Engine bootstrap
;;;
;;; This section used to be the C string literal `init_prg' in
;;; src/Scheme/Chez/chez_tm.cpp, which initialize_scheme() evaluated form by
;;; form before any progs file was read.  chez_tm.cpp now carries no Scheme
;;; source at all: it registers the foreign entry points declared here and
;;; loads this file.
;;;
;;; Consequence: this file is evaluated BEFORE initialize_glue(), i.e. before a
;;; single C++ glue procedure exists.  Nothing below may call glue at load
;;; time.  The names the kernel caches by symbol are marked [C++].
;;;
;;; The kernel also needs a `load' that predates tm-load-file (which is defined
;;; here), so it loads this file with Chez's primitive `load'.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Chez's own condition messages are format strings; capture the kernel format
;; before the progs shims can rebind it, so messages render with irritants.
(define tm-format format)

(define (tm-safe-irritants e)
  (guard (_ (else '()))
    (cond ((syntax-violation? e)
           (list (syntax-violation-form e) (syntax-violation-subform e)))
          ((condition? e) (condition-irritants e))
          (else '()))))

(define (tm-error-message e)
  (cond ((condition? e)
         (let ((m (condition-message e)) (irr (tm-safe-irritants e)))
           (if (pair? irr)
               (guard (_ (else m)) (apply tm-format m irr))
               m)))
        (else (call-with-string-output-port
                (lambda (p) (display e p))))))

(import (rnrs io ports))

;;; ---------------------------------------------------------------------------
;;; Cork Encoding & FFI Transcoding
;;; Raw 8-bit Cork bytes (0x00-0xFF) are tunneled through Chez Scheme strings via
;;; `latin-1-codec` with `(eol-style none)` to preserve Guile 1.8 compatibility
;;; (`string-length`, `substring`, `string=?`) without EOL translation of 0x0D (‚).
;;; Detailed rationale, traps, and bytevector roadmap: see docs/chez/README.md §5.9b.
;;; ---------------------------------------------------------------------------

(define *latin1-tc* (make-transcoder (latin-1-codec) (eol-style none)))

(define (cork-bytes->string bv) (bytevector->string bv *latin1-tc*))
(define (string->cork-bytes s)  (string->bytevector s *latin1-tc*))
(define (utf8-bytes->string bv) (utf8->string bv))
(define (string->utf8-bytes s)  (string->utf8 s))

(define (recur-transcode-bytevector transform)
  (lambda (x)
    (let loop ((x x))
      (cond
        ((bytevector? x) (transform x))
        ((pair? x)
         (let ((a (loop (car x)))
               (d (loop (cdr x))))
           (if (and (eq? a (car x)) (eq? d (cdr x)))
               x
               (cons a d))))
        ((vector? x)
         (let* ((n (vector-length x))
                (v2 (make-vector n))
                (changed? #f))
           (let vloop ((i 0))
             (if (= i n)
                 (if changed? v2 x)
                 (let ((val (loop (vector-ref x i))))
                   (unless (eq? val (vector-ref x i))
                     (set! changed? #t))
                   (vector-set! v2 i val)
                   (vloop (+ i 1)))))))
        (else x)))))

(define (recur-transcode-string transform)
  (lambda (x)
    (let loop ((x x))
      (cond
        ((string? x) (transform x))
        ((pair? x)
         (let ((a (loop (car x)))
               (d (loop (cdr x))))
           (if (and (eq? a (car x)) (eq? d (cdr x)))
               x
               (cons a d))))
        ((vector? x)
         (let* ((n (vector-length x))
                (v2 (make-vector n))
                (changed? #f))
           (let vloop ((i 0))
             (if (= i n)
                 (if changed? v2 x)
                 (let ((val (loop (vector-ref x i))))
                   (unless (eq? val (vector-ref x i))
                     (set! changed? #t))
                   (vector-set! v2 i val)
                   (vloop (+ i 1)))))))
        (else x)))))

(define recur-utf8->string (recur-transcode-bytevector utf8-bytes->string))
(define recur-string->utf8 (recur-transcode-string     string->utf8-bytes))

;; NOTE on Cork transcoders:
;; The Scheme string handled by `recur-string->cork` and `recur-cork->string` does
;; not store a semantic Unicode string, but raw 8-bit Cork encoding packed inside
;; a 32-bit Unicode string (code points U+0000-U+00FF).
(define recur-cork->string (recur-transcode-bytevector cork-bytes->string))
(define recur-string->cork (recur-transcode-string     string->cork-bytes))

;;; ---------------------------------------------------------------------------
;;; Native file loading
;;;
;;; `string-load' is not registered by initialize_glue() for Chez (see the
;;; TEXMACS_ENGINE_CHEZ guard in src/Scheme/Glue/glue_basic.cpp).  The C++
;;; glue can only hand back a raw bytevector, which forced the bridge above to
;;; guess whether the payload was text or binary.  Reading the file here lets
;;; us decide properly: valid UTF-8 becomes a native Scheme string, anything
;;; else is returned as an R6RS bytevector -- exactly what string-save, the
;;; artwork/tmfs handlers and embedded-edit.scm need for PNG/JPEG/font data.
;;;
;;; Chez's native transcoder uses the REPLACE error-handling mode, so
;;; `call-with-input-file' + `get-string-all' silently substitutes U+FFFD for
;;; invalid bytes and never raises an i/o-decoding-error.  An explicit RAISE
;;; transcoder is required to be able to detect a binary file at all.
;;; ---------------------------------------------------------------------------

(define tm-text-transcoder
  (make-transcoder (utf-8-codec) (native-eol-style) 'raise))

;; Return an OS path only for a URL that resolves to an existing file.
;; url-exists? must be checked first: materialize() raises a C++ FAILED error
;; (a full crash report) for an unresolvable URL, and C++ exceptions cannot be
;; caught from Scheme.  The old C++ string_load() just returned "" in that case.
(define (tm-load-path u)
  (cond ((string? u) (and (file-exists? u) u))
        ((url-exists? u) (url-materialize u "r"))
        (else #f)))

(define (tm-loadable? path)
  (and (string? path) (> (string-length path) 0) (file-exists? path)))

;; Read raw bytes for the binary fallback (PNG, JPEG, fonts).
(define (tm-load-bytes path)
  (guard (e (else #vu8()))
    (if (tm-loadable? path)
        (call-with-port (open-file-input-port path)
          (lambda (p) (or (get-bytevector-all p) #vu8())))
        #vu8())))


;; TODO: The current approach is load byte if failing utf8 loading.
;; Change it to something smarter like looking at the file suffix.
(define (string-load u)
  (let ((path (tm-load-path u)))
    (if (not path)
      ""
      (guard (e
               ((i/o-decoding-error? e) (tm-load-bytes path))
               (else
                 ;; Mirrors C++ string_load(): a failed load yields ""
                 ;; rather than aborting, but is still reported.
                 (display (list 'STRING-LOAD-ERROR u
                            (if (condition? e)
                              (condition-message e)
                              e))
                   (console-error-port))
                 (newline (console-error-port))
                 ""))
        (if (tm-loadable? path)
          (call-with-port
            (open-file-input-port path (file-options) 'block
              tm-text-transcoder)
            (lambda (p) (or (get-string-all p) "")))
          "")))))

;; [C++] (tm-eval-string s): read one form and evaluate it in tm-user-env.
;; eval_scheme() routes every C++-side evaluation through this.
(define (tm-eval-string s)
  (guard (e (else (begin
    (display (list 'EVAL-ERROR s (tm-error-message e)
                   (tm-safe-irritants e)))
    (newline)
    (cons #t (list (tm-error-message e))))))
    (let ((x (read (open-input-string s))))
      (if (eof-object? x) x (recur-string->utf8 (eval x tm-user-env))))))

;; [C++] (tm-load-file f): the engine's file loader.  Calls the primitive
;; `load' bound at definition time, not the Guile-compatible `load' that
;; init-texmacs-chez.scm installs afterwards (which calls back into here).
(define (tm-load-file f)
  (guard (e (else (begin
             (display-condition e)
             (newline)
             (tm-backtrace e)
             (display (list 'LOAD-ERROR f (tm-error-message e)
                            (tm-safe-irritants e)))
             (newline)
             (cons #t (list (tm-error-message e))))))
    (primitive-load f)))

(define (tm-backtrace c)
  (guard (e (else (display (list 'BT-ERR (tm-error-message e))) (newline)))
    (if (continuation-condition? c)
        (let* ((k (condition-continuation c))
               (ko (inspect/object k)))
          (let loop ((i 0))
            (guard (e (else #f))
              (let* ((link (ko 'link* i))
                     (co (guard (e (else #f)) (link 'code)))
                     (name (and co (guard (e (else #f)) (co 'name))))
                     (so (guard (e (else #f)) (link 'source)))
                     (sval (and so (guard (e (else #f)) (so 'value))))
                     (sp (guard (e (else #f))
                           (call-with-values (lambda () (link 'source-path))
                             (lambda v v)))))
                (display (list 'FRAME i 'CODE name 'SRC sval 'LOC sp))
                (newline)
                (when (< i 25) (loop (+ i 1)))))))
        (display "no continuation in condition\n"))))

;; [C++] Fixed-arity entry points for call_scheme.
;; Resolves symbols to top-level procedures and contains exceptions without
;; allocating Scheme argument lists or performing redundant full-tree transcodings.
(define (tm-handle-call-error e fun args)
  (display (list 'TM-CALL-ERROR (tm-error-message e) 'FUN: fun 'ARGS: args))
  (newline)
  (display-condition e)
  (newline)
  (tm-backtrace e)
  (cons #t (list (tm-error-message e))))

(define (tm-call-0 fun)
  (guard (e (else (tm-handle-call-error e fun '())))
    (let ((proc (if (symbol? fun) (top-level-value fun (interaction-environment)) fun)))
      (proc))))

(define (tm-call-1 fun a1)
  (guard (e (else (tm-handle-call-error e fun (list a1))))
    (let ((proc (if (symbol? fun) (top-level-value fun (interaction-environment)) fun)))
      (proc a1))))

(define (tm-call-2 fun a1 a2)
  (guard (e (else (tm-handle-call-error e fun (list a1 a2))))
    (let ((proc (if (symbol? fun) (top-level-value fun (interaction-environment)) fun)))
      (proc a1 a2))))

(define (tm-call-3 fun a1 a2 a3)
  (guard (e (else (tm-handle-call-error e fun (list a1 a2 a3))))
    (let ((proc (if (symbol? fun) (top-level-value fun (interaction-environment)) fun)))
      (proc a1 a2 a3))))

(define (tm-call-4 fun a1 a2 a3 a4)
  (guard (e (else (tm-handle-call-error e fun (list a1 a2 a3 a4))))
    (let ((proc (if (symbol? fun) (top-level-value fun (interaction-environment)) fun)))
      (proc a1 a2 a3 a4))))

(define (tm-call-n fun args)
  (guard (e (else (tm-handle-call-error e fun args)))
    (let ((proc (if (symbol? fun) (top-level-value fun (interaction-environment)) fun)))
      (apply proc args))))

(define (tm-apply fun args)
  (tm-call-n fun args))

;; The C++ glue dispatcher.  Every procedure installed with
;; tmscm_install_procedure() is a closure over its own name that forwards the
;; argument list here, so the kernel never has to build Scheme source text.
(define raw-tm-call-by-name
  (foreign-procedure "tm-call-by-name" (string scheme-object) scheme-object))

;; Fast fixed-arity trampolines into C++ glue array table
(define tm-fast-call-0  (foreign-procedure "tm_fast_call_0"  (int) scheme-object))
(define tm-fast-call-1  (foreign-procedure "tm_fast_call_1"  (int scheme-object) scheme-object))
(define tm-fast-call-2  (foreign-procedure "tm_fast_call_2"  (int scheme-object scheme-object) scheme-object))
(define tm-fast-call-3  (foreign-procedure "tm_fast_call_3"  (int scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-4  (foreign-procedure "tm_fast_call_4"  (int scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-5  (foreign-procedure "tm_fast_call_5"  (int scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-6  (foreign-procedure "tm_fast_call_6"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-7  (foreign-procedure "tm_fast_call_7"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-8  (foreign-procedure "tm_fast_call_8"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-9  (foreign-procedure "tm_fast_call_9"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-10 (foreign-procedure "tm_fast_call_10" (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))

(define (tm-call-by-name name args)
  (let* ((in-trans
          (cond
            ((member name '("cork->utf8" "cork->sourcecode" "escape-to-ascii"))
             recur-string->cork)
            (else recur-string->utf8)))
         (out-trans
          (cond
            ((member name '("utf8->cork" "sourcecode->cork"))
             recur-cork->string)
            (else recur-utf8->string))))
    (out-trans (raw-tm-call-by-name name (in-trans args)))))

(define *raw-ffi-table* (make-eq-hashtable))
(let* ((tm-path (or (getenv "TEXMACS_PATH") "."))
       (candidates
        (list
         (string-append tm-path "/progs/kernel/boot/raw-ffi-table.scm")
         "TeXmacs/progs/kernel/boot/raw-ffi-table.scm"
         "progs/kernel/boot/raw-ffi-table.scm")))
  (let loop ((c candidates))
    (cond
     ((null? c) #f)
     ((file-exists? (car c))
      (primitive-load (car c)))
     (else (loop (cdr c))))))

;; [C++] Called once per C++ glue function from chez_install_procedure().
;; Failure is loud and per-name rather than aborting the whole glue pass.
;; Procedures with strictly non-string signatures are routed directly to
;; fixed-arity tm_fast_call_N with zero string/bytevector transcoding and zero
;; rest-arg list allocation overhead.
(define (tm-install-procedure! name . rest)
  (guard (e (else (begin
                   (display (list 'INSTALL-FAILED name (tm-error-message e)))
                   (newline)
                   #f)))
    (let ((sym (string->symbol name))
          (id (and (not (getenv "TEXMACS_NO_FAST_FFI")) (pair? rest) (car rest)))
          (arity (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
      (define-top-level-value sym
        (if (hashtable-ref *raw-ffi-table* sym #f)
            (if id
                (case arity
                  ((0) (lambda () (tm-fast-call-0 id)))
                  ((1) (lambda (a1) (tm-fast-call-1 id a1)))
                  ((2) (lambda (a1 a2) (tm-fast-call-2 id a1 a2)))
                  ((3) (lambda (a1 a2 a3) (tm-fast-call-3 id a1 a2 a3)))
                  ((4) (lambda (a1 a2 a3 a4) (tm-fast-call-4 id a1 a2 a3 a4)))
                  ((5) (lambda (a1 a2 a3 a4 a5) (tm-fast-call-5 id a1 a2 a3 a4 a5)))
                  ((6) (lambda (a1 a2 a3 a4 a5 a6) (tm-fast-call-6 id a1 a2 a3 a4 a5 a6)))
                  ((7) (lambda (a1 a2 a3 a4 a5 a6 a7) (tm-fast-call-7 id a1 a2 a3 a4 a5 a6 a7)))
                  ((8) (lambda (a1 a2 a3 a4 a5 a6 a7 a8) (tm-fast-call-8 id a1 a2 a3 a4 a5 a6 a7 a8)))
                  ((9) (lambda (a1 a2 a3 a4 a5 a6 a7 a8 a9) (tm-fast-call-9 id a1 a2 a3 a4 a5 a6 a7 a8 a9)))
                  ((10) (lambda (a1 a2 a3 a4 a5 a6 a7 a8 a9 a10) (tm-fast-call-10 id a1 a2 a3 a4 a5 a6 a7 a8 a9 a10)))
                  (else (lambda args (raw-tm-call-by-name name args))))
                (lambda args (raw-tm-call-by-name name args)))
            ;; For non-raw procedures, also use fast fixed-arity call where applicable
            (if id
                (let* ((in-trans
                        (cond
                          ((member name '("cork->utf8" "cork->sourcecode" "escape-to-ascii"))
                           recur-string->cork)
                          (else recur-string->utf8)))
                       (out-trans
                        (cond
                          ((member name '("utf8->cork" "sourcecode->cork"))
                           recur-cork->string)
                          (else recur-utf8->string))))
                  (case arity
                    ((0) (lambda () (out-trans (tm-fast-call-0 id))))
                    ((1) (lambda (a1) (out-trans (tm-fast-call-1 id (in-trans a1)))))
                    ((2) (lambda (a1 a2) (out-trans (tm-fast-call-2 id (in-trans a1) (in-trans a2)))))
                    ((3) (lambda (a1 a2 a3) (out-trans (tm-fast-call-3 id (in-trans a1) (in-trans a2) (in-trans a3)))))
                    ((4) (lambda (a1 a2 a3 a4) (out-trans (tm-fast-call-4 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4)))))
                    ((5) (lambda (a1 a2 a3 a4 a5) (out-trans (tm-fast-call-5 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4) (in-trans a5)))))
                    ((6) (lambda (a1 a2 a3 a4 a5 a6) (out-trans (tm-fast-call-6 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4) (in-trans a5) (in-trans a6)))))
                    ((7) (lambda (a1 a2 a3 a4 a5 a6 a7) (out-trans (tm-fast-call-7 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4) (in-trans a5) (in-trans a6) (in-trans a7)))))
                    ((8) (lambda (a1 a2 a3 a4 a5 a6 a7 a8) (out-trans (tm-fast-call-8 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4) (in-trans a5) (in-trans a6) (in-trans a7) (in-trans a8)))))
                    ((9) (lambda (a1 a2 a3 a4 a5 a6 a7 a8 a9) (out-trans (tm-fast-call-9 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4) (in-trans a5) (in-trans a6) (in-trans a7) (in-trans a8) (in-trans a9)))))
                    ((10) (lambda (a1 a2 a3 a4 a5 a6 a7 a8 a9 a10) (out-trans (tm-fast-call-10 id (in-trans a1) (in-trans a2) (in-trans a3) (in-trans a4) (in-trans a5) (in-trans a6) (in-trans a7) (in-trans a8) (in-trans a9) (in-trans a10)))))
                    (else (lambda args (tm-call-by-name name args)))))
                (lambda args (tm-call-by-name name args))))
        (interaction-environment)))
    #t))

;; The version string is compiled into the C++ side (TEXMACS_VERSION); ask the
;; glue for it rather than duplicating the number here.  An unrecognised
;; selector makes texmacs_version() return TEXMACS_VERSION itself.
(define (texmacs-version)
  (texmacs-version-release "version"))


(define-top-level-value 'boot-chez-loaded? #t)
