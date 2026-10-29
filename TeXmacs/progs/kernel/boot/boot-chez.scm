(when (top-level-bound? '*boot-chez-loaded*)
  (display "WARNING: boot-chez.scm loaded more than once!\n"))
(define *boot-chez-loaded* #t)

(define compilation-environment
  (if (top-level-bound? 'compilation-environment)
      compilation-environment
      (make-parameter (interaction-environment))))

;;; Foundational helpers & Guile compatibility primitives
(define (noop . _) #f)

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

(define (== a b) (equal? a b))
(define (!= a b) (not (equal? a b)))

(define (1+ x) (+ x 1))
(define (1- x) (- x 1))

(define (first l) (car l))
(define (second l) (cadr l))
(define (third l) (caddr l))
(define (fourth l) (cadddr l))

(define (delq! x l) (remq! x l))
(define (delv! x l) (remv! x l))
(define (delete! x l) (remove! x l))
(define (delq x l) (remq x l))

(define (acons k v l) (cons (cons k v) l))

;; Guile-compatible sort: Guile uses (sort seq less?), Chez Scheme uses (sort less? seq)
(define chez:sort (if (top-level-bound? 'chez:sort) chez:sort sort))
(define (sort a b)
  (let ((seq (if (procedure? a) b a))
        (pred (if (procedure? a) a b)))
    (if (vector? seq)
        (vector-sort pred seq)
        (chez:sort pred seq))))
(define (sort! a b)
  (sort a b))

(define (procedure-name p) #f)
(define (procedure-documentation p) #f)

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

(define (hash-ref t k . default)
  (if (hashtable-contains? t k)
      (hashtable-ref t k #f)
      (if (null? default) #f (car default))))
(define (hash-set! t k v) (hashtable-set! t k v) v)
(define (hash-remove! t k) (hashtable-delete! t k))
(define (hash-get-handle t k)
  (if (hashtable-contains? t k) (cons k (hashtable-ref t k #f)) #f))
(define (hash-fold proc init t)
  (let-values (((ks vs) (hashtable-entries t)))
    (let loop ((i 0) (acc init))
      (if (= i (vector-length ks)) acc
          (loop (+ i 1) (proc (vector-ref ks i) (vector-ref vs i) acc))))))

(define (ahash-ref t k . default) (apply hash-ref t k default))
(define (ahash-set! t k v) (hash-set! t k v))
(define (ahash-remove! t k) (hash-remove! t k))
(define (ahash-get-handle t k) (hash-get-handle t k))
(define (ahash-fold proc init t) (hash-fold proc init t))
(define (ahash-table->list t)
  (ahash-fold (lambda (k v acc) (cons (cons k v) acc)) '() t))

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

(define (assoc-ref alist key) (cond ((assoc key alist) => cdr) (else #f)))
(define (assoc-set! alist key val)
  (let ((entry (assoc key alist)))
    (if entry (begin (set-cdr! entry val) alist) (cons (cons key val) alist))))
(define (assoc-remove! alist key)
  (let loop ((l alist) (prev #f))
    (cond ((null? l) alist)
          ((equal? (caar l) key)
           (if prev (begin (set-cdr! prev (cdr l)) alist) (cdr l)))
          (else (loop (cdr l) l)))))

(define (assq-ref alist key) (cond ((assq key alist) => cdr) (else #f)))
(define (assq-set! alist key val)
  (let ((entry (assq key alist)))
    (if entry (begin (set-cdr! entry val) alist) (cons (cons key val) alist))))
(define (assq-remove! alist key)
  (let loop ((l alist) (prev #f))
    (cond ((null? l) alist)
          ((eq? (caar l) key)
           (if prev (begin (set-cdr! prev (cdr l)) alist) (cdr l)))
          (else (loop (cdr l) l)))))

(define (copy-tree obj)
  (cond ((pair? obj) (cons (copy-tree (car obj)) (copy-tree (cdr obj))))
        ((vector? obj) (vector-map copy-tree obj))
        (else obj)))

(define (make-soft-port . _) #f)

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

(define-syntax with-global
  (lambda (x)
    (syntax-case x ()
      ((_ var val body ...)
       (with-syntax ((old (generate-temporaries '(var)))
                     (new (generate-temporaries '(var))))
         #'(let ((old var))
             (set! var val)
             (let ((new (begin body ...)))
               (set! var old)
               new)))))))

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

(define (getpid)
  (cond ((top-level-bound? 'get-process-id) (get-process-id))
        (else 1000)))

(define (read-line . opt)
  (get-line (if (null? opt) (current-input-port) (car opt))))

(define (force-output . opt)
  (flush-output-port (if (null? opt) (current-output-port) (car opt))))

(define (char-in-set? c cs)
  (cond ((char? cs) (char=? c cs))
        ((procedure? cs) (cs c))
        ((list? cs) (memv c cs))
        (else #f)))

(define (string-index s cs . opt)
  (let* ((start (if (null? opt) 0 (car opt)))
         (end (if (or (null? opt) (null? (cdr opt))) (string-length s) (cadr opt))))
    (let loop ((i start))
      (cond ((>= i end) #f)
            ((char-in-set? (string-ref s i) cs) i)
            (else (loop (+ i 1)))))))

(define (string-rindex s cs . opt)
  (let* ((start (if (null? opt) 0 (car opt)))
         (end (if (or (null? opt) (null? (cdr opt))) (string-length s) (cadr opt))))
    (let loop ((i (- end 1)))
      (cond ((< i start) #f)
            ((char-in-set? (string-ref s i) cs) i)
            (else (loop (- i 1)))))))

(define char-set:whitespace (string->list " \t\n\r\f\v"))
(define char-set:digit (string->list "0123456789"))
(define char-set:lower-case (string->list "abcdefghijklmnopqrstuvwxyz"))
(define char-set:upper-case (string->list "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
(define char-set:letter (append char-set:lower-case char-set:upper-case))
(define char-set:letter+digit (append char-set:letter char-set:digit))

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

(define (check-arg-type pred arg caller)
  (if (pred arg) arg
      (error caller "Wrong type argument: ~S" arg)))
(define (check-arg-number pred num caller)
  (if (pred num) num
      (error caller "Wrong number of arguments: ~A" num)))
(define (check-arg-range pred arg caller)
  (if (pred arg) arg
      (error caller "Argument out of range: ~S" arg)))

(define (scm-error key subr message args rest)
  (if (and (string? message) (list? args))
      (apply error subr message args)
      (error subr (format "~a: ~a" key message))))

(define chez:current-time (if (top-level-bound? 'chez:current-time) chez:current-time (top-level-value 'current-time (scheme-environment))))
(define (current-time)
  (time-second (chez:current-time)))

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
;; (e.g. `tm-define`, `tm-define-overloaded`, `tm-define-macro`, `tm-property`)
;; are defined via `define-public-macro-trace`. That macro records its raw procedural
;; transformer on `(putprop 'nm 'macro-transformer ...)` using an internal definition
;; wrapper so the transpiler can intercept and expand them in interpreter style,
;; partition the resulting S-expression trace into pure definitions and expressions,
;; and emit a compliant compilable unit for Chez's `compile-file`.
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
(define cur-conds '())
(define cur-props '())
(define (property-rewrite l)
  `(property-set! ,@l (list ,@cur-conds)))
(define *tm-dummy-counter* 0)
(define (fresh-tm-dummy)
  (set! *tm-dummy-counter* (+ *tm-dummy-counter* 1))
  (string->symbol (string-append "_tm_def_" (number->string *tm-dummy-counter*))))
(define (texmacs-mode-pred mode)
  (let* ((mode-str (symbol->string mode))
         (mode-root (substring mode-str 0 (- (string-length mode-str) 1)))
         (pred-str (string-append mode-root "?")))
    (string->symbol pred-str)))
(define (texmacs-mode item)
  (let* ((mode (car item))
         (action (cadr item))
         (deps (cddr item))
         (pred (texmacs-mode-pred mode))
         (deps* (map list (map texmacs-mode-pred deps)))
         (l (if (equal? action #t) deps* (cons action deps*)))
         (test (if (null? l) #t (if (null? (cdr l)) (car l) (cons 'and l))))
         (defn (if (equal? mode 'always%)
                   `(define ,(fresh-tm-dummy) (void))
                   `(define-public (,pred) ,test)))
         (rules (map (lambda (dep) (list dep mode)) deps))
         (logic-cmd `(logic-rules ,@rules))
         (arch1 `(set-symbol-procedure! ',mode ,pred))
         (arch2 `(set-symbol-procedure! ',pred ,pred))
         (side-effects
           `(define ,(fresh-tm-dummy)
              (begin
                ,arch1
                ,arch2
                ,@(if (null? deps) '() (list logic-cmd))
                (void)))))
    (list 'begin defn side-effects)))
(define (define-preference x)
  (let ((which (car x))
        (value (cadr x))
        (call-back (caddr x)))
    `(if (not (ahash-ref preferences-default ,which))
         (ahash-set! preferences-default ,which ,value))))
(define (define-preference-call-back x)
  (let ((which (car x))
        (value (cadr x))
        (call-back (caddr x)))
    `(begin
       (ahash-set! preferences-call-back ,which ,call-back)
       (notify-preference ,which))))
(define (delayed-sub body)
  (cond ((or (not (pair? body)) (not (list? (car body))) (not (keyword? (caar body))))
         `(lambda () ,@body #t))
        ((eq? (caar body) :pause)
         `(let* ((start (texmacs-time))
                 (proc ,(delayed-sub (cdr body))))
            (lambda ()
              (let ((left (- (+ start ,(cadar body)) (texmacs-time))))
                (if (> left 0) left
                    (begin
                      (set! start (texmacs-time))
                      (proc)))))))
        ((eq? (caar body) :every)
         `(let* ((time (+ (texmacs-time) ,(cadar body)))
                 (proc ,(delayed-sub (cdr body))))
            (lambda ()
              (let ((left (- time (texmacs-time))))
                (if (> left 0) left
                    (begin
                      (set! time (+ (texmacs-time) ,(cadar body)))
                      (proc)))))))
        ((eq? (caar body) :idle)
         `(let ((proc ,(delayed-sub (cdr body))))
            (lambda ()
              (let ((left (- ,(cadar body) (idle-time))))
                (if (> left 0) left
                    (proc))))))
        ((eq? (caar body) :on-cpu-idle)
         `(let* ((interval ,(cadar body))
                 (next (+ (texmacs-time) interval))
                 (proc ,(delayed-sub (cdr body))))
            (lambda ()
              (cond ((< (texmacs-time) next)
                     (- next (texmacs-time)))
                    ((>= (cpu-idle-time) 30000)
                     (proc)
                     (set! next (+ (texmacs-time) interval))
                     0)
                    (else
                     1000)))))
        ((eq? (caar body) :refresh)
         (let ((sym (gensym)))
           `(let* ((,sym #f)
                   (proc ,(delayed-sub (cdr body))))
              (lambda ()
                (if (not (equal? ,sym (change-time))) 0
                    (let ((left (- ,(cadar body) (idle-time))))
                      (if (> left 0) left
                          (begin
                            (set! ,sym (change-time))
                            (proc)))))))))
        ((eq? (caar body) :require)
         `(let ((proc ,(delayed-sub (cdr body))))
            (lambda ()
              (if (not ,(cadar body)) 0
                  (proc)))))
        ((eq? (caar body) :while)
         `(let ((proc ,(delayed-sub (cdr body))))
            (lambda ()
              (if (not ,(cadar body)) #t
                  (let ((left (proc)))
                    (if (eq? left #t) 0 left))))))
        ((eq? (caar body) :clean)
         `(let ((proc ,(delayed-sub (cdr body))))
            (lambda ()
              (let ((left (proc)))
                (if (not (eq? left #t)) left
                    (begin ,(cadar body) #t))))))
        ((eq? (caar body) :permanent)
         `(let ((proc ,(delayed-sub (cdr body))))
            (lambda ()
              (let ((left (proc)))
                (if (not (eq? left #t)) left
                    (let ((next ,(cadar body)))
                      (if (not (eq? next #t)) #t
                          0)))))))
        ((eq? (caar body) :do)
         `(let ((proc ,(delayed-sub (cdr body))))
            (lambda ()
              ,(cadar body)
              (proc))))
        (else (delayed-sub (cdr body)))))
(define has-look-and-feel? (lambda (x) (== x "emacs")))
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


;; NOTE on `define-public-macro-trace`:
;; Stateful and syntax-generating macros in TeXmacs (such as `tm-define-macro`,
;; `tm-menu`, `tm-widget`, `menu-bind`, etc.) are defined through `define-public-macro-trace`.
;; This macro attributes the symbol with the `'macro-transformer` property holding its raw
;; transformer procedure in `(compilation-environment)`.
;; During ahead-of-time compilation, the transpiler intercepts all calls to these macros
;; in source order, executes the transformer directly in Scheme, captures the emitted
;; S-expression trace, and expands it ahead of Chez Scheme's compiler.
;; This guarantees that dynamic compile-time table side-effects and macro nesting are fully
;; resolved before Chez Scheme's strict phase-separated compiler processes the forms.
(define-syntax define-macro-trace
  (lambda (x)
    (syntax-case x ()
      ((_ (nm . formals) body ...)
       #'(begin
           (define-syntax nm
             (lambda (stx)
               (datum->syntax (car (syntax->list stx))
                 (eval `(apply (lambda formals body ...)
                               ',(cdr (syntax->datum stx)))
                       (compilation-environment)))))
           (putprop 'nm 'macro-transformer (lambda formals body ...))))
      ((_ nm (lambda formals body ...))
       #'(begin
           (define-syntax nm
             (lambda (stx)
               (datum->syntax (car (syntax->list stx))
                 (eval `(apply (lambda formals body ...)
                               ',(cdr (syntax->datum stx)))
                       (compilation-environment)))))
           (putprop 'nm 'macro-transformer (lambda formals body ...))))
      ((_ nm proc)
       #'(begin
           (define-syntax nm
             (lambda (stx)
               (datum->syntax (car (syntax->list stx))
                 (eval `(apply proc ',(cdr (syntax->datum stx)))
                       (compilation-environment)))))
           (putprop 'nm 'macro-transformer proc))))))

(define-syntax define-public-macro-trace
  (syntax-rules ()
    ((_ (nm . formals) body ...)
     (with-export-if-active nm (define-macro-trace (nm . formals) body ...)))
    ((_ nm val)
     (with-export-if-active nm (define-macro-trace nm val)))))

(define *texmacs-modules-loaded* (make-ahash-table))

(define (module-file-name which)
  (let ((ps (map symbol->string which)))
    (string-append (getenv "TEXMACS_PATH") "/progs/"
                   (apply string-append
                          (map (lambda (p) (string-append "/" p)) ps))
                   ".scm")))

(define (module-loaded? m)
  (ahash-ref *texmacs-modules-loaded* m))

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
             (if tm-path
                 (list (string-append tm-path "/../../build-texmacos/boot/" so-name)
                       (string-append tm-path "/../build-texmacos/boot/" so-name)
                       (string-append tm-path "/boot/" so-name))
                 '())
             (list (string-append "build-texmacos/boot/" so-name)
                   (string-append "../build-texmacos/boot/" so-name)
                   (string-append "../../build-texmacos/boot/" so-name)
                   (string-append "texmacs/build-texmacos/boot/" so-name)
                   (string-append "boot/" so-name)))))
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
             (if tm-path
                 (list (string-append tm-path "/../../build-texmacos/boot/module-deps.scm")
                       (string-append tm-path "/../build-texmacos/boot/module-deps.scm")
                       (string-append tm-path "/boot/module-deps.scm"))
                 '())
             (list "build-texmacos/boot/module-deps.scm"
                   "../build-texmacos/boot/module-deps.scm"
                   "../../build-texmacos/boot/module-deps.scm"
                   "texmacs/build-texmacos/boot/module-deps.scm"
                   "boot/module-deps.scm"))))
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
              (ahash-set! *module-deps-table* (car entry) (cadr entry))))
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
  (or (ahash-ref *module-deps-table* which)
      (let* ((fname (module-file-name which))
             (deps (if (file-exists? fname)
                       (parse-module-header-deps fname which)
                       '())))
        (ahash-set! *module-deps-table* which deps)
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
             (not (ahash-ref *module-loading-stack* which)))
    (ahash-set! *module-loading-stack* which #t)
    (for-each module-load (module-dependencies which))
    (ahash-remove! *module-loading-stack* which)
    (ahash-set! *texmacs-modules-loaded* which #t)
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
  (ahash-set! *texmacs-modules-loaded* name #t)
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
(define-top-level-value 'boot-chez-loaded? #t)
