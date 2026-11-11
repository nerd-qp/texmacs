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
;; What remains is: interpreter primitives, the kernel, and then
;; src/Scheme/Chez/linter.scm.
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

;; Load foundational Chez Scheme boot definitions.  The kernel normally
;; already loaded them in initialize_scheme(); the fallback covers standalone
;; evaluation of this file.
(unless (top-level-bound? 'boot-chez-loaded?)
  (let ((boot-chez-path (string-append (or (getenv "TEXMACS_PATH") ".") "/progs/kernel/boot/boot-chez.scm")))
    (if (file-exists? boot-chez-path)
        (primitive-load boot-chez-path)
        (display (list 'WARNING-BOOT-CHEZ-NOT-FOUND boot-chez-path)))))

;; initialize_glue() ran after boot-chez.scm and replaced the Chez-native
;; tm-output / tm-errput with the C++ glue versions; put ours back in charge.
(tm-reinstall-io-hooks!)

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

;; Boot-directory search order, mirroring module-so-file in boot-chez.scm
;; ($TEXMACS_BOOT_PATH first) and adding the local development layout derived
;; from TEXMACS_PATH:
;;   <root>/texmacs/TeXmacs  ->  <root>/build-texmacos/boot
;;
;; TEXMACS_BOOT_PATH overrides everything.  Otherwise the first candidate that
;; actually holds a kernel wins; there is one build tree, and the check exists
;; so that a checkout with no compiled cache falls back to source loading
;; instead of pointing at a directory that is not there.
(define (tm-lint-boot-dir)
  (let* ((tm-path  (getenv "TEXMACS_PATH"))
         (build    (getenv "TEXMACS_BUILD_DIR"))
         (root     (and tm-path (tm-lint-parent-dir (tm-lint-parent-dir tm-path))))
         (explicit (getenv "TEXMACS_BOOT_PATH"))
         (cands    (list (and build (string-append build "/boot"))
                         (and tm-path (string-append tm-path "/boot"))
                         (and root (string-append root "/build-texmacos/boot"))
                         "build-texmacos/boot"
                         "../build-texmacos/boot")))
    (define (live? d)
      (or (file-exists? (string-append d "/texmacs-user.so"))
          (file-exists? (string-append d "/kernel"))))
    (cond
      (explicit explicit)
      (else
       (let loop ((c cands))
         (cond ((null? c) #f)
               ((and (car c) (live? (car c))) (car c))
               (else (loop (cdr c)))))))))

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

;;; ------------------------------------------------------------- run linter

(define tm-lint-boot (tm-lint-boot-dir))
(when tm-lint-boot
  ;; let the module loader find the compiled modules as well, so that the
  ;; fallback path below is as fast and as complete as the aggregate one
  (putenv "TEXMACS_BOOT_PATH" tm-lint-boot))

(define tm-lint-kernel-via
  (guard (e (else
             (printf "~nKERNEL LOAD FAILED~n")
             (display-condition e)
             (newline)
             (printf "~nThe kernel could not be brought up, so no analysis ran.~n")
             (printf "If this is a `variable ... is not bound` error from a~n")
             (printf "kernel module, the compiled boot cache is inconsistent:~n")
             (printf "rebuild it with  TeXmacs -recompile-modules~n")
             (flush-output-port (current-output-port))
             ;; exit non-zero: falling through would start a GUI boot, which
             ;; is never what -lint asked for
             (exit 3)))
    (cond
      ((and tm-lint-boot (tm-lint-load-aggregate! tm-lint-boot)) 'texmacs-user.so)
      (else (tm-lint-import-kernel-modules!) 'kernel-modules))))

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
