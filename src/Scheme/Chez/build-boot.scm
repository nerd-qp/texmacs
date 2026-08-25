;;; build-boot.scm -- Ahead-Of-Time compilation of TeXmacs core into texmacs.boot
;;; Run inside headless TeXmacs:
;;;   TeXmacs -H -x '(load "texmacs/src/Scheme/Chez/build-boot.scm")'

(define-top-level-value 'texmacs-chez-compiling? #t)
(define-top-level-value 'boot-kernel-loaded? #t)
(define native-load (top-level-value 'load (scheme-environment)))

(let* ((manifest-file "src/Scheme/Chez/boot_files.scm"))

  ;; 1. Load the manifest of boot files
  (unless (file-exists? manifest-file)
    (error 'build-boot "Manifest file not found" manifest-file))
  (load manifest-file)

  (let* ((texmacs-path (or (getenv "TEXMACS_PATH") "texmacs/TeXmacs"))
         (progs-dir (string-append texmacs-path "/progs"))
         (build-dir (or (getenv "TEXMACS_BUILD_DIR") "build-texmacos"))
         (cache-dir (string-append build-dir "/boot-cache"))
         (target-boot (string-append build-dir "/texmacs.boot"))
         (t0 (texmacs-time))
         (succeeded 0)
         (failed 0)
         (so-files '()))

    (display "========================================================\n")
    (display "  Building TeXmacs Boot Image: texmacs.boot\n")
    (display "========================================================\n")
    (display (list "Source directory:" progs-dir)) (newline)
    (display (list "Cache directory :" cache-dir)) (newline)
    (display (list "Target boot file:" target-boot)) (newline)
    (display (list "Total modules   :" (length *texmacs-boot-files*))) (newline)
    (newline)

    ;; 2. Compile each Scheme file in topological order
    ;; Note: *texmacs-boot-files* must follow strict DFS post-order (callees before callers),
    ;; ensuring all macro definitions and module dependencies are loaded into the compilation
    ;; session before dependent files are compiled and loaded. In the future, this list should
    ;; be generated automatically via post-order load hooks or static dependency analysis.
    (for-each
      (lambda (rel-path)
        (let* ((src (string-append progs-dir "/" rel-path))
               (rel-root (path-root rel-path))
               (pre (string-append cache-dir "/" rel-root ".pre.scm"))
               (dst (string-append cache-dir "/" rel-root ".so"))
               (parent-dir (path-parent dst)))
          (unless (file-exists? parent-dir)
            (system (string-append "mkdir -p \"" parent-dir "\"")))
          (display (list 'COMPILE rel-path '-> dst)) (newline)
          (let ((ok (guard (e (else
                               (display (list 'COMPILE-FAIL rel-path
                                              (tm-error-message e)
                                              (if (who-condition? e) (condition-who e) 'no-who)
                                              (if (irritants-condition? e) (condition-irritants e) 'no-irritants)))
                               (newline)
                               (display-condition e)
                               (newline)
                               #f))
                      ;; 1. Preprocess and determine target module environment.
                      ;; Note: tm-prepare-form strips docstrings, uncurries definitions,
                      ;; rewrites conditional defs, and wraps top-level (define ...) in
                      ;; (eval-when (compile load eval) ...) so intra-file helper procedures
                      ;; are evaluated into target-env during compile-file (Phase 1), allowing
                      ;; intra-file macros to invoke them during expansion.
                      (let* ((in-p (open-input-file src))
                             (forms (dynamic-wind
                                      (lambda () #f)
                                      (lambda () (tm-read-all-forms in-p))
                                      (lambda () (close-port in-p))))
                             (has-mod? (and (pair? forms)
                                            (pair? (car forms))
                                            (eq? (caar forms) 'texmacs-module)
                                            (cadar forms)))
                             (prepared (cond ((string=? rel-path "init-texmacs-chez.scm")
                                              ;; Native Chez Scheme bootstrap script: must not be rewritten
                                              ;; by tm-prepare-form because tm-prepare-form converts top-level
                                              ;; conditionals into (eval '... (tm-current-eval-env)). Since
                                              ;; init-texmacs-chez.scm defines tm-current-eval-env later in
                                              ;; the file (line 606), rewriting would cause premature calls to
                                              ;; an unbound procedure during Sbuild_heap. Raw forms are passed
                                              ;; directly to compile-file without modification.
                                              forms)
                                             (has-mod?
                                              (map (lambda (f)
                                                     (let ((pf (tm-prepare-form f)))
                                                       (if (and (pair? pf)
                                                                (eq? (car pf) 'define)
                                                                (pair? (cdr pf))
                                                                (or (pair? (cadr pf))
                                                                    (and (pair? (cddr pf))
                                                                         (pair? (caddr pf))
                                                                         (eq? (caaddr pf) 'make-ahash-table))))
                                                           `(eval-when (compile load eval) ,pf)
                                                           pf)))
                                                   forms))
                                             (else
                                              (map tm-prepare-form forms))))
                             (mod (and has-mod?
                                       (top-level-bound? 'tm-get-or-create-module)
                                       (tm-get-or-create-module has-mod?)))
                             (is-user-init? (or (string=? rel-path "kernel/boot/boot-chez.scm")
                                                (string=? rel-path "init-texmacs.scm")
                                                (string=? rel-path "init-texmacs-chez.scm")))
                             (target-env (cond (mod (tm-module-env mod))
                                               (is-user-init? (if (and (top-level-bound? 'texmacs-user)
                                                                       (top-level-bound? 'tm-module?)
                                                                       (tm-module? (top-level-value 'texmacs-user)))
                                                                  (tm-module-env (top-level-value 'texmacs-user))
                                                                  (interaction-environment)))
                                               ((and (top-level-bound? 'current-module-env)
                                                     (top-level-bound? '*current-module*)
                                                     (top-level-bound? 'tm-module?)
                                                     (tm-module? (top-level-value '*current-module*)))
                                                (current-module-env))
                                               (else (interaction-environment)))))
                        (when (file-exists? pre)
                          (delete-file pre))
                        (let ((out-p (open-output-file pre)))
                          (dynamic-wind
                            (lambda () #f)
                            (lambda ()
                              (for-each
                                (lambda (f)
                                  (write f out-p)
                                  (newline out-p))
                                prepared))
                            (lambda () (close-port out-p))))
                        (cond (mod (set-current-module mod))
                              (is-user-init? (when (and (top-level-bound? 'texmacs-user)
                                                        (top-level-bound? 'tm-module?)
                                                        (tm-module? (top-level-value 'texmacs-user)))
                                               (set-current-module texmacs-user))))
                        ;; 2. Compile preprocessed buffer file into .so and load inside target-env
                        (display (list 'START-COMPILE pre)) (newline)
                        (display (list 'DIAG rel-path
                                       'target-env-export:
                                       (guard (e (else 'ERR)) (top-level-syntax 'export target-env))
                                       'texmacs-user-export:
                                       (guard (e (else 'ERR)) (top-level-syntax 'export (tm-module-env texmacs-user)))
                                       'inter-export:
                                       (guard (e (else 'ERR)) (top-level-syntax 'export (interaction-environment)))))
                        (newline)
                        (parameterize ((interaction-environment target-env))
                          (compile-file pre dst)
                          (display (list 'START-LOAD dst)) (newline)
                          (native-load dst))
                        (display (list 'LOAD-DONE dst)) (newline)
                        #t))))
            (if ok
                (begin
                  (set! succeeded (+ succeeded 1))
                  (set! so-files (cons dst so-files)))
                (set! failed (+ failed 1))))))
      *texmacs-boot-files*)

    (set! so-files (reverse so-files))

    (display "\n--------------------------------------------------------\n")
    (display (list "Compilation summary: Succeeded:" succeeded "Failed:" failed))
    (newline)

    ;; 3. Link into texmacs.boot if all succeeded
    (if (= failed 0)
        (begin
          (display "==> Linking compiled modules into texmacs.boot...\n")
          (let* ((chez-boot-dir (cond ((file-exists? "chez-macos/tarm64osx/petite.boot")
                                       "chez-macos/tarm64osx")
                                      ((file-exists? "build-chez-macos/tarm64osx/boot/tarm64osx/petite.boot")
                                       "build-chez-macos/tarm64osx/boot/tarm64osx")
                                      ((file-exists? "../build-chez-macos/tarm64osx/boot/tarm64osx/petite.boot")
                                       "../build-chez-macos/tarm64osx/boot/tarm64osx")
                                      ((file-exists? "../chez-macos/tarm64osx/petite.boot")
                                       "../chez-macos/tarm64osx")
                                      (else ".")))
                 (base-boots (list (string-append chez-boot-dir "/petite.boot")
                                   (string-append chez-boot-dir "/scheme.boot"))))
            (apply make-boot-file target-boot base-boots so-files))
          (let* ((elapsed (- (texmacs-time) t0))
                 (sz (let* ((p (open-file-input-port target-boot))
                            (len (file-length p)))
                       (close-port p)
                       len)))
            (display "========================================================\n")
            (display "  SUCCESS: texmacs.boot generated successfully!\n")
            (display "========================================================\n")
            (display (list "Location :" target-boot)) (newline)
            (display (list "Size     :" sz "bytes" (format "(~,2f MB)" (/ sz 1048576.0)))) (newline)
            (display (list "Total time:" elapsed "ms")) (newline)))
        (begin
          (display "========================================================\n")
          (display "  ERROR: Boot image creation aborted due to failures.\n")
          (display "========================================================\n")))

    (exit (if (= failed 0) 0 1))))
