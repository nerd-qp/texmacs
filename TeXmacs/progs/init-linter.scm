;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : init-linter.scm
;; DESCRIPTION : Chez Scheme bootstrap for static analysis (`TeXmacs -lint')
;; COPYRIGHT   : (C) 2026
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This software falls under the GNU general public license version 3 or
;; later. It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the
;; file LICENSE in the root directory or
;; <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; A trimmed copy of init-texmacs-chez.scm.  Everything up to and including the
;; kernel import is kept verbatim, because the linter needs a working module
;; system and the same Guile-compatibility shims the editor uses.  Everything
;; after it -- the ~350 lazy-define / lazy-menu / use-modules entries that make
;; up the editor program -- is dropped: the linter never opens a buffer, never
;; builds a menu and never renders anything, and loading the program would
;; swamp the analysis with definitions it does not need.
;;
;; What remains is: interpreter primitives, the tm-module record, the kernel,
;; and then src/Scheme/Chez/linter.scm.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(when (top-level-bound? '*init-linter-loaded*)
  (display "WARNING: init-linter.scm loaded more than once!\n"))
(define *init-linter-loaded* #t)

;; TeXmacs's initialization scripts were written against Guile, where the
;; following names are interpreter builtins (module system, debugger knobs,
;; reader hooks). Chez lacks them, so we provide early stand-ins here; the
;; real module machinery is installed later by kernel/boot/boot.scm, which
;; rebinds these names.

;; Guile's primitive loader; Chez's 1-argument load is close enough for the
;; aliasing that init-texmacs.scm does with it.
;;
;; NOTE: Loading init-texmacs-chez.scm twice will cause an infinite recursion loop:
;; on first boot, 'load' is Chez's native loader. Later in this file, 'load' is
;; redefined to 'tm-load-file'. If this file is evaluated a second time,
;; (define primitive-load load) would re-bind primitive-load to tm-load-file.
;; Because tm-load-file delegates to primitive-load to load compiled .so files,
;; this would create an infinite mutual recursion loop. Preserve native load.
(unless (top-level-bound? 'primitive-load)
  (define-top-level-value 'primitive-load
    (top-level-value 'load (scheme-environment))))

;; Load foundational Chez Scheme boot definitions
(let ((boot-chez-path (string-append (or (getenv "TEXMACS_PATH") ".") "/progs/kernel/boot/boot-chez.scm")))
  (if (file-exists? boot-chez-path)
      (primitive-load boot-chez-path)
      (display (list 'WARNING-BOOT-CHEZ-NOT-FOUND boot-chez-path))))

;; --- Guile eval/defined?/filter semantics ----------------------------------
;;
;; Guile's eval accepts 1 argument (current module); R6RS eval requires 2.
;; define shadows the immutable import; set! would not, hence no set! usage.
(define tm-orig-eval (if (top-level-bound? 'tm-orig-eval) tm-orig-eval (top-level-value 'eval (scheme-environment))))
(define primitive-eval tm-orig-eval)

(define (tm-quote-eval-literals x)
  (cond ((or (box? x) (procedure? x)) (list 'quote x))
        ((pair? x)
         (if (eq? (car x) 'quote)
             x
             (cons (tm-quote-eval-literals (car x)) (tm-quote-eval-literals (cdr x)))))
        (else x)))
(define tm-quote-boxes tm-quote-eval-literals)

(define eval
  (lambda (form . env)
    (let ((form* (if (or (box? form) (procedure? form) (pair? form))
                     (tm-quote-eval-literals form)
                     form)))
      (if (null? env)
          (tm-orig-eval form* (if (top-level-bound? 'current-module-env)
                                  (current-module-env)
                                  tm-user-env))
          (tm-orig-eval form* (car env))))))

;; Guile exports POSIX select (fd multiplexing) from its default module;
;; Chez does not.  regexp-select.scm aliases it as guile-select before
;; redefining select itself, so a placeholder must exist.  Nothing in the
;; progs tree actually calls the fd-based variant; raise if ever reached.
(if (not (top-level-bound? 'select))
    (eval '(define (select . args)
             (error "select" "POSIX select is not available on this Scheme dialect"))
          tm-user-env))

;; Guile compatibility load-module: delegates to Chez module-load for specs, or tm-load-file for paths.
(define (load-module m)
  (if (list? m)
      (module-load m)
      (tm-load-file m)))


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

(define (procedure-documentation p) #f)
(define (func? p kind) (procedure? p))

(define (procedure-arity p)
  (if (procedure? p)
      (let ((mask (procedure-arity-mask p)))
        (let loop ((i 0) (m mask))
          (cond ((odd? m) i)
                ((= m 0) -1)
                (else (loop (+ i 1) (quotient m 2))))))
      -1))

;; module introspection: looks up exported/bound symbol in mod's environment
(define (module-ref mod sym . default)
  (let* ((m (cond ((and (top-level-bound? 'tm-module?) (tm-module? mod)) mod)
                  ((and (top-level-bound? '*modules*)
                        (hashtable-ref *modules* mod #f)) => (lambda (x) x))
                  (else #f)))
         (env (if (and m (top-level-bound? 'tm-module-env))
                  (tm-module-env m)
                  (if (top-level-bound? '*base-kernel-env*) *base-kernel-env* tm-user-env))))
    (if (top-level-bound? sym env)
        (top-level-value sym env)
        (if (null? default)
            (texmacs-error "module-ref" "~s is not exported" sym)
            (car default)))))

;; --- Small Guile/SRFI helpers ----------------------------------------------

;; --- Module-system context required by boot-chez.scm ------------------------

(define *base-kernel-env* tm-user-env)

;; In pure interpreter mode, init-texmacs-chez.scm is evaluated once in the same
;; process, generating a single runtime Record-Type Descriptor (RTD). However,
;; during ahead-of-time compilation (compile-file), separate compilation units
;; compile .scm files into distinct .so binaries. Without `nongenerative`, Chez
;; generates a fresh, distinct RTD in each compilation unit, causing `tm-module?`
;; to fail across .so files and runtime boundaries. `(nongenerative tm-module-uid)`
;; assigns a deterministic global UID, ensuring all compiled units and runtime
;; instances share the identical record descriptor.
(define-record-type tm-module
  (nongenerative tm-module-uid)
  (fields name env (mutable exports) (mutable importers) (mutable imported)))

(define *modules*
  (if (top-level-bound? '*modules*)
      *modules*
      (make-hashtable equal-hash equal?)))

(define texmacs-user
  (if (top-level-bound? 'texmacs-user)
      texmacs-user
      (let ((u (make-tm-module 'texmacs-user *base-kernel-env* '() '() (make-eq-hashtable))))
        (hashtable-set! *modules* 'texmacs-user u)
        u)))

(define *current-module*
  (if (top-level-bound? '*current-module*)
      *current-module*
      texmacs-user))

;; Returns a quoted token/name: the macro layer splices ,(current-module) into
;; generated code, so the value must be valid syntax.
(define (current-module) (list 'quote (tm-module-name *current-module*)))
(define (current-module-object) *current-module*)
(define (current-module-env) (tm-module-env *current-module*))
(define (tm-current-eval-env)
  (if (top-level-bound? 'current-module-env)
      (current-module-env)
      tm-user-env))

(define (module-name m)
  (cond ((tm-module? m) (tm-module-name m))
        (else m)))

(define (set-current-module m)
  (let ((mod (cond ((tm-module? m) m)
                   ((hashtable-ref *modules* m #f) => (lambda (x) x))
                   (else #f))))
    (if mod (set! *current-module* mod))))

(define developer-mode?
  (if (top-level-bound? 'developer-mode?)
      developer-mode?
      (and (top-level-bound? 'cpp-get-preference)
           (equal? (cpp-get-preference "developer tool" "off") "on"))))

;; --- Chain to the standard initialization ------------------------------------
;;
;; Route every subsequent load through the engine's guarded per-form loader,
;; so failures are reported per form (LOAD-SUMMARY / FORM-FAILED) instead of
;; aborting a whole subtree silently.

(define load
  (lambda (f . ignore-env)
    (tm-load-file f)))


;;; ---------------------------------------------------------- kernel bootstrap
;;
;; A normal boot continues into progs/init-texmacs.scm, which pulls in the
;; whole editor: menus, keyboards, widgets, converters, plugins, fonts.  None
;; of that is needed to analyse the macro layer, and loading it costs minutes.
;;
;; All we need is the kernel: the module system, the define/menu/keyboard macro
;; layers and the library modules.  compile-texmacs.scm already builds exactly
;; that as the aggregate bundle `texmacs-user.so' (one primitive-load per kernel
;; .so, plus a `texmacs-user' module that re-exports them all), so a single
;; load + import replaces the ~40 use-modules calls of the full boot.
;;
;; If the bundle is not available the kernel is imported module by module
;; instead, through the same use-modules list the full boot uses.  That path
;; works from either .so or .scm sources, depending on whether the boot
;; directory could be located.

(define (tm-lint-suffix? suf s)
  (let ((n (string-length s)) (m (string-length suf)))
    (and (>= n m) (string=? (substring s (- n m) n) suf))))

(define (tm-lint-parent-dir path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) #f)
          ((char=? (string-ref path i) #\/) (substring path 0 i))
          (else (loop (- i 1))))))

(define (tm-lint-strip-suffix s suf)
  (let ((n (string-length s)) (m (string-length suf)))
    (if (and (>= n m) (string=? (substring s (- n m) n) suf))
        (substring s 0 (- n m))
        s)))

(define (tm-lint-string-index hay needle)
  "First index of NEEDLE in HAY, or #f."
  (let ((n (string-length hay)) (m (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring hay i (+ i m)) needle) i)
            (else (loop (+ i 1)))))))

;; Same candidate order as tm-so-candidates in chez_tm.cpp, plus the local
;; development layout derived from TEXMACS_PATH:
;;   <root>/texmacs/TeXmacs  ->  <root>/build-texmacos/boot
(define (tm-lint-boot-dir)
  (let* ((tm-path (getenv "TEXMACS_PATH"))
         (build   (getenv "TEXMACS_BUILD_DIR"))
         (root    (and tm-path (tm-lint-parent-dir (tm-lint-parent-dir tm-path))))
         (cands   (list (getenv "TEXMACS_BOOT_PATH")
                        (and build (string-append build "/boot"))
                        (and tm-path (string-append tm-path "/boot"))
                        (and root (string-append root "/build-texmacos/boot"))
                        "build-texmacos/boot"
                        "../build-texmacos/boot")))
    (let loop ((c cands))
      (cond ((null? c) #f)
            ((not (car c)) (loop (cdr c)))
            ((file-exists? (string-append (car c) "/texmacs-user.so")) (car c))
            ((file-exists? (string-append (car c) "/kernel")) (car c))
            (else (loop (cdr c)))))))

;; The bundle embeds the boot directory that existed at *compile* time
;; ("build-texmacos/boot/kernel/boot/chez-compat.so"), so the load has to run
;; from the directory that makes those relative paths resolve.  Recover that
;; directory from the generated texmacs-user.scm sitting next to the bundle.
(define (tm-lint-aggregate-cwd boot)
  (let ((scm (string-append boot "/texmacs-user.scm")))
    (and (file-exists? scm)
         (call-with-input-file scm
           (lambda (port)
             (let ((f (guard (e (else #f)) (read port))))
               (and (pair? f) (eq? (car f) 'primitive-load)
                    (pair? (cdr f)) (string? (cadr f))
                    (let* ((path (cadr f))
                           (k (tm-lint-string-index path "/kernel/")))
                      (and k
                           (> k 0)
                           (let ((prefix (substring path 0 k))
                                 (blen (string-length boot)))
                             (and (not (char=? (string-ref prefix 0) #\/))
                                  (>= blen (string-length prefix))
                                  (string=? (substring boot
                                                       (- blen (string-length prefix))
                                                       blen)
                                            prefix)
                                  (tm-lint-strip-suffix
                                    (substring boot 0 (- blen (string-length prefix)))
                                    "/"))))))))))))

;; How many .scm files under DIR are newer than FILE.
(define (tm-lint-count-newer file dir)
  (define n 0)
  (define (walk d)
    (if (file-directory? d)
        (for-each (lambda (x)
                    (unless (member x '("." ".."))
                      (walk (string-append d "/" x))))
                  (directory-list d))
        (when (and (tm-lint-suffix? ".scm" d)
                   (time>? (file-modification-time d) (file-modification-time file)))
          (set! n (+ n 1)))))
  (when (file-exists? dir) (walk dir))
  n)

(define (tm-lint-load-aggregate! boot)
  (let ((so (string-append boot "/texmacs-user.so")))
    (cond
      ((not (file-exists? so)) #f)
      (else
       (let ((stale (tm-lint-count-newer so (string-append (getenv "TEXMACS_PATH")
                                                           "/progs/kernel"))))
         (when (> stale 0)
           (printf "      note: ~a kernel source file(s) newer than texmacs-user.so~n"
                   stale)))
       (let ((cwd (current-directory))
             (target (tm-lint-aggregate-cwd boot)))
         (dynamic-wind
           void
           (lambda ()
             (guard (e (else
                        (display "      aggregate load failed: ")
                        (display-condition e) (newline)
                        #f))
               (when target (current-directory target))
               (primitive-load so)
               #t))
           (lambda () (current-directory cwd))))))))

(define (tm-lint-import-kernel-modules!)
  (eval
    '(begin
       (use-modules (kernel boot chez-compat)
                    (kernel boot compat) (kernel boot abbrevs)
                    (kernel boot debug) (kernel boot srfi)
                    (kernel boot ahash-table) (kernel boot prologue))
       (use-modules (kernel library base) (kernel library list)
                    (kernel library tree) (kernel library content)
                    (kernel library patch))
       (use-modules (kernel regexp regexp-match) (kernel regexp regexp-select))
       (use-modules (kernel logic logic-bind) (kernel logic logic-unify)
                    (kernel logic logic-rules) (kernel logic logic-query)
                    (kernel logic logic-data))
       (use-modules (kernel texmacs tm-define)
                    (kernel texmacs tm-preferences) (kernel texmacs tm-modes)
                    (kernel texmacs tm-plugins) (kernel texmacs tm-secure)
                    (kernel texmacs tm-convert) (kernel texmacs tm-dialogue)
                    (kernel texmacs tm-language) (kernel texmacs tm-file-system)
                    (kernel texmacs tm-states))
       (use-modules (kernel gui gui-markup)
                    (kernel gui menu-define) (kernel gui menu-widget)
                    (kernel gui kbd-define)
                    (kernel gui speech-define)
                    (kernel gui kbd-handlers)
                    (kernel gui menu-test)
                    (kernel old-gui old-gui-widget)
                    (kernel old-gui old-gui-factory)
                    (kernel old-gui old-gui-form)
                    (kernel old-gui old-gui-test)))
    (interaction-environment)))

;; ---------------------------------------------------------------------------
;; Runtime definitions for dynamic Scheme evaluation (slotlist-load, REPL, scripts)
;;
;; In Chez Scheme, evaluating `(export ...)` outside of a module or library raises:
;; `Exception in export: export form outside of a module or library ()`.
;; We therefore provide runtime top-level definitions of define-public,
;; define-public-macro, define-module-macro, and indirect-export that expand directly
;; without (export ...) forms so dynamic loading runs cleanly in (interaction-environment).
;; ---------------------------------------------------------------------------
(eval '(define-syntax define-public
         (syntax-rules ()
           ((_ (name . args) body ...)
            (define (name . args) body ...))
           ((_ name val)
            (define name val))))
      (interaction-environment))
(eval '(define-syntax indirect-export
         (syntax-rules ()
           ((_ id ...) (noop))))
      (interaction-environment))
(eval '(define-syntax define-public-macro
         (syntax-rules ()
           ((_ (nm . formals) body ...)
            (define-macro (nm . formals) body ...))
           ((_ nm val)
            (define-macro nm val))))
      (interaction-environment))
(eval '(define-syntax define-macro-trace
         (lambda (x)
           (syntax-case x ()
             ((_ (nm . formals) body ...)
              #'(define-macro (nm . formals) body ...)))))
      (interaction-environment))
(eval '(define-syntax define-public-macro-trace
         (lambda (x)
           (syntax-case x ()
             ((_ (nm . formals) body ...)
              #'(define-public-macro (nm . formals) body ...)))))
      (interaction-environment))

;;; ------------------------------------------------------------- run linter

(define tm-lint-boot (tm-lint-boot-dir))
(when tm-lint-boot
  ;; let the module loader find the compiled modules as well, so that the
  ;; fallback path below is as fast and as complete as the aggregate one
  (putenv "TEXMACS_BOOT_PATH" tm-lint-boot))

(define tm-lint-kernel-via
  (cond
    ((and tm-lint-boot (tm-lint-load-aggregate! tm-lint-boot)) 'texmacs-user.so)
    (else (tm-lint-import-kernel-modules!) 'kernel-modules)))

(define (tm-lint-script-path)
  (or (getenv "TEXMACS_LINT_SCRIPT")
      (let ((p (getenv "TEXMACS_PATH")))
        (and p (string-append p "/../src/Scheme/Chez/linter.scm")))
      "src/Scheme/Chez/linter.scm"))

(printf "boot    ~a~n" (if tm-lint-boot tm-lint-boot "(not found)"))
(printf "kernel  ~a~n" tm-lint-kernel-via)

;; primitive-load, not load: this file redefines `load' to tm-load-file above,
;; and tm-load-file itself calls `load'.
(let ((path (tm-lint-script-path)))
  (if (file-exists? path)
      (begin
        (primitive-load path)
        (tm-run-linter)
        (flush-output-port (current-output-port))
        (exit 0))
      (begin
        (display (list 'LINTER-NOT-FOUND path))
        (newline)
        (exit 2))))
