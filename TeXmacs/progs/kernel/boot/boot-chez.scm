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
  (if (top-level-bound? 'chez:equal?) chez:equal? equal?))
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

(define (procedure-name p) #f)
(define (procedure-documentation p) #f)
(define (make-soft-port . _) #f)

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

(define-syntax and-with
  (syntax-rules ()
    ((_ var val body ...)
     (with var val (and var (begin body ...))))))

(define-syntax while
  (syntax-rules ()
    ((_ test body ...)
     (let loop ()
       (when test
         body ...
         (loop))))))

(define-syntax with-define
  (syntax-rules ()
    ((_ (name . args) fun-body body ...)
     (let ((name (lambda args fun-body)))
       body ...))))

(define-syntax with-result
  (syntax-rules ()
    ((_ result body ...)
     (let* ((return result)
            (dummy (begin body ...)))
       return))))


(define (filter pred? l)
  (apply append (map (lambda (x) (if (pred? x) (list x) (list))) l)))

(define OPEN_READ "r")
(define OPEN_WRITE "w")
(define (open-file file mode)
  (cond ((or (string=? mode "r") (string=? mode "rb"))
         (open-input-file file))
        ((or (string=? mode "w") (string=? mode "wb"))
         (if (file-exists? file) (delete-file file))
         (open-output-file file))
        (else (open-input-file file))))
(define (flush-all-ports) (noop))

(define (map-in-order f . ls)
  (if (or (null? ls) (null? (car ls))) '()
      (cons (apply f (map car ls))
            (apply map-in-order f (map cdr ls)))))
(define (last-pair l)
  (if (pair? (cdr l)) (last-pair (cdr l)) l))
(define (symbol-append . syms)
  (string->symbol
   (apply string-append (map symbol->string syms))))

(define (call-with-input-string str proc)
  (proc (open-input-string str)))

(define (call-with-output-string proc)
  (let ((p (open-output-string)))
    (proc p)
    (get-output-string p)))

(define (char-set? x) (or (list? x) (procedure? x) (char? x)))
(define (string->char-set str)
  (let loop ((l (string->list str)) (acc '()))
    (cond ((null? l) (reverse acc))
          ((memv (car l) acc) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

(define (char-set-adjoin cs . chars)
  (let loop ((chars chars) (res (if (list? cs) cs (list cs))))
    (cond ((null? chars) res)
          ((memv (car chars) res) (loop (cdr chars) res))
          (else (loop (cdr chars) (cons (car chars) res))))))

(define (char-set-contains? cs c) (char-in-set? c cs))
(define (char-set . chars) (apply char-set-adjoin '() chars))
(define (char-set-union . sets)
  (let loop ((sets sets) (acc '()))
    (if (null? sets) acc (loop (cdr sets) (apply char-set-adjoin acc (car sets))))))

(define old-record-accessor (top-level-value 'record-accessor (scheme-environment)))
(define (record-accessor rtd field)
  (if (integer? field)
      (old-record-accessor rtd field)
      (let* ((fields (record-type-field-names rtd))
             (idx (let loop ((i 0))
                    (cond ((>= i (vector-length fields)) #f)
                          ((eq? (vector-ref fields i) field) i)
                          (else (loop (+ i 1)))))))
        (if idx
            (old-record-accessor rtd idx)
            (error 'record-accessor "invalid field specifier" field)))))

(define old-record-mutator (top-level-value 'record-mutator (scheme-environment)))
(define (record-modifier rtd field)
  (if (integer? field)
      (old-record-mutator rtd field)
      (let* ((fields (record-type-field-names rtd))
             (idx (let loop ((i 0))
                    (cond ((>= i (vector-length fields)) #f)
                          ((eq? (vector-ref fields i) field) i)
                          (else (loop (+ i 1)))))))
        (if idx
            (old-record-mutator rtd idx)
            (error 'record-modifier "invalid field specifier" field)))))

(define-syntax with-wallet
  (syntax-rules ()
    ((_ body ...)
     (if (and (top-level-bound? 'wallet-initialized?)
              (wallet-initialized?)
              (wallet-persistent-status-on?)
              (wallet-off?))
         (wallet-dialogue-turn-on (lambda (x) body ...))
         (begin body ...)))))

(define (server-mode?)
  (if (top-level-bound? 'server-started?)
      (server-started?)
      #f))

(define (scm-error key subr message args rest)
  (if (and (string? message) (list? args))
      (apply error subr message args)
      (error subr (format "~a: ~a" key message))))

(define (seed->random-state . s)
  (if (null? s) 1 (car s)))

(define chez-sys-random
  (if (top-level-bound? 'random (scheme-environment))
      (top-level-value 'random (scheme-environment))
      (lambda (n) (modulo (abs (texmacs-time)) n))))

(define (random n . state)
  (chez-sys-random n))

;; Guile builtin: hash value of obj bounded by n. Only used for hash tables,
;; so any deterministic well-distributed value works.
(define hash
  (lambda (obj n)
    (if (= n 0) 0
        (modulo (abs (equal-hash obj)) n))))


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

(define-syntax define-macro
  (lambda (x)
    (syntax-case x ()
      ((_ (nm . formals) body ...)
       #'(define-syntax nm
           (lambda (stx)
             (datum->syntax (car (syntax->list stx))
               (eval `(apply (lambda formals body ...)
                             ',(cdr (syntax->datum stx)))
                     (compilation-environment))))))
      ((_ nm (lambda formals body ...))
       #'(define-syntax nm
           (lambda (stx)
             (datum->syntax (car (syntax->list stx))
               (eval `(apply (lambda formals body ...)
                             ',(cdr (syntax->datum stx)))
                     (compilation-environment))))))
      ((_ nm proc)
       #'(define-syntax nm
           (lambda (stx)
             (datum->syntax (car (syntax->list stx))
               (eval `(apply proc ',(cdr (syntax->datum stx)))
                     (compilation-environment)))))))))

(define temp-module #f)
(define temp-value #f)
(define (guile-a?) #f)
(define (guile-b?) #f)
(define (guile-c?) #f)
(define (guile-b-c?) #f)
(define (ca*r x) (if (pair? x) (ca*r (car x)) x))
(define (ca*adr x) (ca*r (cadr x)))
(define (apply* fun head)
  (cond ((list? head)
         `(,(apply* fun (car head)) ,@(cdr head)))
        ((pair? head)
         `(apply ,(apply* fun (car head)) (cons* ,@(listify (cdr head)))))
        (else fun)))
(define (lambda* head body)
  (if (pair? head)
      (lambda* (car head) `((lambda ,(cdr head) ,@body)))
      (car body)))
(define (listify args)
  (if (pair? args)
      (cons (car args) (listify (cdr args)))
      (list args)))
(define (and* conds)
  (if (and (pair? conds) (null? (cdr conds))) (car conds) `(and ,@conds)))
(define (begin* conds)
  (if (and (pair? conds) (null? (cdr conds))) (car conds) `(begin ,@conds)))
(define (unlambda pred?)
  (if (and (pair? pred?) (eq? (car pred?) 'lambda))
      (caddr pred?)
      (list pred?)))
(define chez:sort (if (top-level-bound? 'chez:sort) chez:sort sort))
;; (define cur-conds '())
;; (define cur-props '())
;; (define (property-rewrite l)
;;   `(property-set! ,@l (list ,@cur-conds)))
(define *tm-dummy-counter* 0)
(define (fresh-tm-dummy)
  (set! *tm-dummy-counter* (+ *tm-dummy-counter* 1))
  (string->symbol (string-append "_tm_def_" (number->string *tm-dummy-counter*))))

(define has-look-and-feel? (lambda (x) (equal? x "emacs")))
(define original-display (if (top-level-bound? 'original-display) original-display (top-level-value 'display (scheme-environment))))
(define original-write (if (top-level-bound? 'original-write) original-write (top-level-value 'write (scheme-environment))))

(define (display-to-string x)
  (call-with-string-output-port
    (lambda (p) (original-display x p))))

(define (object->string x)
  (call-with-string-output-port
    (lambda (p) (original-write x p))))

(define (tm-output s)
  (original-display s))

(define (tm-errput s)
  (original-display s (console-error-port)))

(define (display . l)
  (if (or (null? l) (not (null? (cdr l))))
      (apply original-display l)
      (tm-output (display-to-string (car l)))))
(define (write . l)
  (if (or (null? l) (not (null? (cdr l))))
      (apply original-write l)
      (tm-output (object->string (car l)))))

(define-syntax provide-public
  (syntax-rules ()
    ((_ (name . args) body ...) (define-public (name . args) body ...))
    ((_ name val) (define-public name val))))

(define (quit-TeXmacs-scheme) (noop))

(define-syntax on-entry
  (syntax-rules ()
    ((_ cmd ...) (begin cmd ...))))

(define-syntax on-exit
  (syntax-rules ()
    ((_ cmd ...)
     (let ((old-quit quit-TeXmacs-scheme))
       (set! quit-TeXmacs-scheme
         (lambda ()
           cmd ...
           (old-quit)))))))

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
              (let ((raw (eval `(apply (lambda args . body)
                                       ',(syntax->datum #'call-args))
                               (compilation-environment))))
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

(define (module-available? module-name)
  (or (module-loaded? module-name)
      (and (module-so-file module-name) #t)
      (file-exists? (module-file-name module-name))))

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

(meta define (tm-mod-spec->symbol k spec-stx)
  (let* ((datum (syntax->datum spec-stx))
         (parts (if (pair? datum)
                    (map symbol->string datum)
                    (list (symbol->string datum))))
         (joined (let loop ((p parts))
                   (if (null? (cdr p))
                       (car p)
                       (string-append (car p) ":" (loop (cdr p)))))))
    (datum->syntax k (string->symbol joined))))

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

(define-syntax with-module
  (syntax-rules ()
    ((_ module body ...) (begin body ...))))

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

(define (tm-syntax-context s) s)

;; TODO: to rewrite in here.
;; (define *procedure-sources* (make-weak-eq-hashtable))

;; (define-syntax lambda/source
;;   (syntax-rules ()
;;     [(_ formals body1 body2 ...)
;;      (let ([proc (lambda formals body1 body2 ...)])
;;        (hashtable-set! *procedure-sources* proc '(lambda formals body1 body2 ...))
;;        proc)]))

;; (define (procedure-source proc)
;;   (hashtable-ref *procedure-sources* proc #f))

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

(define (recur-string->utf8 x)
  (cond
    ((string? x) (string->utf8 x))
    ((pair? x)   (cons (recur-string->utf8 (car x))
                       (recur-string->utf8 (cdr x))))
    ((vector? x) (vector-map recur-string->utf8 x))
    (else x)))

(define (recur-utf8->string x)
  (cond
    ((bytevector? x) (utf8->string x))
    ((pair? x)       (cons (recur-utf8->string (car x))
                           (recur-utf8->string (cdr x))))
    ((vector? x)     (vector-map recur-utf8->string x))
    (else x)))

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

;; Dedicated binary loader, also usable directly by callers that know they
;; want a bytevector rather than a string.
(define (binary-load u)
  (tm-load-bytes (tm-load-path u)))


;; TODO: to review carefully.
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
    (load f)))

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

;; [C++] (tm-apply fun args): the engine's call entry point.  A symbol is
;; resolved in the top-level environment, so call("name", ...) can pass a
;; symbol instead of an evaluated expression.
(define (tm-apply fun args)
  (guard (e (else (begin (display (list 'TM-APPLY-ERROR (tm-error-message e) 'FUN: fun 'ARGS: args)) (newline) (display-condition e) (newline) (tm-backtrace e) (cons #t (list (tm-error-message e))))))
    (let ((proc (if (symbol? fun)
                    (top-level-value fun (interaction-environment))
                    fun)))
      (recur-string->utf8 (apply proc (recur-utf8->string args))))))

;; The C++ glue dispatcher.  Every procedure installed with
;; tmscm_install_procedure() is a closure over its own name that forwards the
;; argument list here, so the kernel never has to build Scheme source text.
(define tm-call-by-name
  (foreign-procedure "tm-call-by-name" (string scheme-object) scheme-object))

;; [C++] Called once per C++ glue function from chez_install_procedure().
;; Failure is loud and per-name rather than aborting the whole glue pass.
(define (tm-install-procedure! name)
  (guard (e (else (begin
                   (display (list 'INSTALL-FAILED name (tm-error-message e)))
                   (newline)
                   #f)))
    (define-top-level-value (string->symbol name)
      (lambda args
        (recur-utf8->string (tm-call-by-name name (recur-string->utf8 args))))
      (interaction-environment))
    #t))

;; [C++] -compile-modules / -recompile-modules set this before any progs file
;; is read; init-texmacs-chez.scm and compile-texmacs.scm both consult it.
(define (tm-set-compiling-mode! on?)
  (define-top-level-value 'texmacs-chez-compiling? on? (interaction-environment)))

;; The version string is compiled into the C++ side (TEXMACS_VERSION); ask the
;; glue for it rather than duplicating the number here.  An unrecognised
;; selector makes texmacs_version() return TEXMACS_VERSION itself.
(define (texmacs-version)
  (texmacs-version-release "version"))

;; `tm-output' and `tm-errput' are also C++ glue procedures (glue_basic.cpp)
;; and initialize_glue() runs *after* this file, so it replaces the writers
;; above with ones that push strings through the byte-oriented
;; tmscm_to_string bridge.  init-texmacs-chez.scm calls this once glue is up
;; to put the Chez-native writers back in charge.
(define (tm-reinstall-io-hooks!)
  (define-top-level-value 'tm-output
    (lambda (s) (original-display s)) (interaction-environment))
  (define-top-level-value 'tm-errput
    (lambda (s) (original-display s (console-error-port))) (interaction-environment)))

(define-top-level-value 'boot-chez-loaded? #t)
