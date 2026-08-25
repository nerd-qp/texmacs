;;; build_kernel_modules.scm -- Compile all TeXmacs kernel modules into native Chez modules
;;;
;;; Usage via headless TeXmacs:
;;;   TEXMACS_PATH="$(pwd)/TeXmacs" ../build-texmacos/TeXmacs.app/Contents/MacOS/TeXmacs -H -x '(load "src/Scheme/Chez/build_kernel_modules.scm")'

(define (convert-name spec)
  (let* ((parts (if (pair? spec)
                    (map symbol->string spec)
                    (list (symbol->string spec))))
         (joined (let loop ((p parts))
                   (if (null? (cdr p))
                       (car p)
                       (string-append (car p) ":" (loop (cdr p)))))))
    (string->symbol joined)))

(define (convert-path spec)
  (let* ((parts (if (pair? spec)
                    (map symbol->string spec)
                    (list (symbol->string spec))))
         (joined (let loop ((p parts))
                   (if (null? (cdr p))
                       (car p)
                       (string-append (car p) "/" (loop (cdr p)))))))
    (string-append joined ".scm")))

(define *kernel-specs*
  '(
    ;; Group 1: kernel boot
    (kernel boot compat)
    (kernel boot abbrevs)
    (kernel boot debug)
    (kernel boot srfi)
    (kernel boot ahash-table)
    (kernel boot prologue)

    ;; Group 2: kernel library
    (kernel library base)
    (kernel library list)
    (kernel library tree)
    (kernel library content)
    (kernel library patch)

    ;; Group 3: kernel regexp
    (kernel regexp regexp-match)
    (kernel regexp regexp-select)

    ;; Group 4: kernel logic (submodules bind & unify first)
    (kernel logic logic-bind)
    (kernel logic logic-unify)
    (kernel logic logic-rules)
    (kernel logic logic-query)
    (kernel logic logic-data)

    ;; Group 5: kernel texmacs
    (kernel texmacs tm-define)
    (kernel texmacs tm-preferences)
    (kernel texmacs tm-modes)
    (kernel texmacs tm-plugins)
    (kernel texmacs tm-secure)
    (kernel texmacs tm-convert)
    (kernel texmacs tm-dialogue)
    (kernel texmacs tm-language)
    (kernel texmacs tm-file-system)
    (kernel texmacs tm-states)

    ;; Group 6: kernel gui
    (kernel gui gui-markup)
    (kernel gui menu-define)
    (kernel gui menu-widget)
    (kernel gui kbd-define)
    (kernel gui speech-define)
    (kernel gui kbd-handlers)
    (kernel gui menu-test)
    (kernel old-gui old-gui-widget)
    (kernel old-gui old-gui-factory)
    (kernel old-gui old-gui-form)
    (kernel old-gui old-gui-test)
   ))

(define (read-all-forms file-path)
  (let ((port (open-input-file file-path)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let loop ((acc '()))
          (let ((x (read port)))
            (if (eof-object? x)
                (reverse acc)
                (loop (cons x acc))))))
      (lambda () (close-port port)))))

(define (ensure-parent-dir path)
  (let loop ((i (- (string-length path) 1)))
    (when (>= i 0)
      (if (char=? (string-ref path i) #\/)
          (let ((dir (substring path 0 i)))
            (unless (file-exists? dir)
              (system (string-append "mkdir -p \"" dir "\""))))
          (loop (- i 1))))))

(define (def-form? x)
  (and (pair? x)
       (memq (car x) '(define define-syntax define-public define-public-macro
                       provide-public define-macro tm-define tm-define-macro
                       tm-define-overloaded tm-property lazy-define
                       define-group define-preferences
                       texmacs-modes define-table extend-table
                       define-collection extend-collection
                       tm-widget tm-menu define-menu
                       tm-build tm-build-macro tm-build-widget tm-build-table
                       import export eval-when))))

(define (cond-def? x)
  (and (pair? x)
       (eq? (car x) 'if)
       (pair? (cdr x))
       (pair? (cddr x))
       (pair? (caddr x))
       (or (memq (car (caddr x)) '(define define-public))
           (and (eq? (car (caddr x)) 'begin)
                (let loop ((es (cdr (caddr x))))
                  (and (pair? es)
                       (or (and (pair? (car es)) (memq (caar es) '(define define-public)))
                           (loop (cdr es)))))))))

(define *dummy-counter* 0)
(define (fresh-dummy)
  (set! *dummy-counter* (+ *dummy-counter* 1))
  (string->symbol (string-append "_tm_init_" (number->string *dummy-counter*))))

(define (prepare-module-form x)
  (cond
    ((cond-def? x)
     (let ((test (cadr x))
           (then-branch (caddr x))
           (has-else? (and (pair? (cdddr x)) (pair? (cadddr x))))
           (else-branch (if (and (pair? (cdddr x)) (pair? (cadddr x))) (cadddr x) #f)))
       (if (eq? (car then-branch) 'begin)
           ;; Conditional block of definitions (e.g. ahash-table.scm)
           (let ((test-res (guard (e (else #f))
                             (eval test (interaction-environment)))))
             (if test-res
                 (apply append (map prepare-module-form (cdr then-branch)))
                 (if else-branch
                     (if (eq? (car else-branch) 'begin)
                         (apply append (map prepare-module-form (cdr else-branch)))
                         (prepare-module-form else-branch))
                     '())))
           (let* ((def-kind (car then-branch))
                  (head (cadr then-branch))
                  (then-body (cddr then-branch))
                  (else-body (if else-branch (cddr else-branch) '((noop)))))
             (list `(,def-kind ,head
                     (if ,test
                         (begin ,@then-body)
                         (begin ,@else-body))))))))
    ((and (pair? x)
          (memq (car x) '(define-macro define-public-macro))
          (pair? (cdr x))
          (pair? (cadr x)))
     (let* ((kind (car x))
            (head (cadr x))
            (body (cddr x))
            (nm (car head))
            (formals (cdr head))
            (syn-def
              `(define-syntax ,nm
                 (lambda (stx)
                   (datum->syntax (car (syntax->list stx))
                     (eval (list 'apply
                                 (cons 'lambda (cons ',formals ',body))
                                 (list 'quote (cdr (syntax->datum stx))))
                           (interaction-environment)))))))
       (if (eq? kind 'define-public-macro)
           `((export ,nm) ,syn-def)
           `(,syn-def))))
    ((and (pair? x)
          (memq (car x) '(define define-public))
          (pair? (cdr x))
          (pair? (cadr x)))
     (let ((head (cadr x))
           (body (cddr x)))
       (guard (e (else #f))
         (eval `(define ,(car head) (lambda ,(cdr head) ,@body))
               (interaction-environment)))
       (list x)))
    ((and (pair? x)
          (memq (car x) '(define define-public))
          (pair? (cdr x))
          (symbol? (cadr x)))
     (guard (e (else #f))
       (eval `(define ,(cadr x) ,@(cddr x))
             (interaction-environment)))
     (list x))
    ((def-form? x)
     (list x))
    ((and (pair? x) (eq? (car x) 'begin))
     (apply append (map prepare-module-form (cdr x))))
    (else
     ;; Wrap top-level expressions as dummy definitions to preserve definition context
     (list `(define ,(fresh-dummy) (begin ,x (void)))))))

(define (transpile-spec spec in-path out-path)
  (let* ((forms (read-all-forms in-path))
         (has-header? (and (pair? forms)
                           (pair? (car forms))
                           (eq? (caar forms) 'texmacs-module)))
         (hdr (if has-header? (car forms) #f))
         (body (if has-header? (cdr forms) forms))
         (mod-sym (convert-name spec))
         (options (if has-header? (cddr hdr) '()))
         (import-forms '())
         (export-forms '()))
    (for-each
      (lambda (opt)
        (when (pair? opt)
          (let ((kind (car opt))
                (specs (cdr opt)))
            (cond
              ((eq? kind ':use)
               (for-each
                 (lambda (s)
                   (let ((s-sym (convert-name s)))
                     (if (memq s-sym compiled-specs)
                         (set! import-forms
                           (cons `(import (for ,s-sym run expand)) import-forms))
                         (begin
                           (display (list 'DEFER-CIRCULAR-IMPORT mod-sym '-> s-sym))
                           (newline)))))
                 specs))
              ((eq? kind ':inherit)
               (for-each
                 (lambda (s)
                   (let ((s-sym (convert-name s)))
                     (set! import-forms
                       (cons `(import (for ,s-sym run expand)) import-forms))
                     (set! export-forms
                       (cons `(export (import ,s-sym)) export-forms))))
                 specs))))))
      options)
    (set! import-forms (reverse import-forms))
    (set! export-forms (reverse export-forms))

    (let* ((prepared-body (apply append (map prepare-module-form body)))
           (out-p (open-output-file out-path 'replace)))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (display ";;; Auto-generated native Chez Scheme module from " out-p)
          (display in-path out-p) (newline out-p)
          (write `(module ,mod-sym ()
                    ,@import-forms
                    ,@export-forms
                    ,@prepared-body)
                 out-p)
          (newline out-p)
          (write `(import ,mod-sym) out-p)
          (newline out-p))
        (lambda () (close-port out-p))))
    mod-sym))

(display "\n========================================================\n")
(display "  Building TeXmacs Kernel via Native Chez Modules\n")
(display "========================================================\n")

(define compiled-specs '())
(define failed-specs '())

(for-each
  (lambda (spec)
    (let* ((rel-path (convert-path spec))
           (mod-sym (convert-name spec))
           (src-file (string-append "TeXmacs/progs/" rel-path))
           (out-scm (string-append "build-texmacos/boot/" rel-path))
           (out-so (string-append (substring out-scm 0 (- (string-length out-scm) 4)) ".so")))
      (ensure-parent-dir out-scm)
      (transpile-spec spec src-file out-scm)
      (call/cc
        (lambda (k)
          (with-exception-handler
            (lambda (e)
              (if (warning? e)
                  (begin
                    (display-condition e)
                    (newline))
                  (begin
                    (display (list 'FAIL rel-path)) (newline)
                    (display-condition e) (newline)
                    (set! failed-specs (cons (cons rel-path e) failed-specs))
                    (k #f))))
            (lambda ()
              (compile-file out-scm out-so)
              (load out-so)
              (set! compiled-specs (cons mod-sym compiled-specs))
              (display (list 'OK rel-path)) (newline)))))))
  *kernel-specs*)

(newline)
(if (null? failed-specs)
    (begin
      (display "--------------------------------------------------------\n")
      (display "  Aggregating all kernel modules into texmacs-user\n")
      (display "--------------------------------------------------------\n")
      (let* ((user-scm "build-texmacos/boot/texmacs-user.scm")
             (user-so "build-texmacos/boot/texmacs-user.so")
             (all-mods (reverse compiled-specs))
             (exports (map (lambda (m) `(export (import ,m))) all-mods))
             (imports (map (lambda (m) `(import (for ,m run expand))) all-mods))
             (p (open-output-file user-scm 'replace)))
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (display ";;; Unified kernel aggregate and snapshot\n" p)
            (write `(module texmacs-user ()
                      ,@exports)
                   p)
            (newline p)
            (write `(module texmacs-user-kernel ()
                      (export (import texmacs-user)))
                   p)
            (newline p)
            (write `(import texmacs-user-kernel) p)
            (newline p)
            (write `(define texmacs-user-kernel-env
                      (let ((env (copy-environment (interaction-environment) #t)))
                        (eval '(import texmacs-user-kernel) env)
                        env))
                   p)
            (newline p))
          (lambda () (close-port p)))
        (display (list 'COMPILE user-scm '-> user-so)) (newline)
        (compile-file user-scm user-so)
        (load user-so)
        (display "========================================================\n")
        (display "  SUCCESS: 100% OF KERNEL MODULES COMPILED & SNAPSHOTTED!\n")
        (display "========================================================\n")))
    (begin
      (display "--------------------------------------------------------\n")
      (display (list "FAILED MODULE COUNT:" (length failed-specs))) (newline)
      (for-each (lambda (f) (display (list "  - " (car f))) (newline)) failed-specs)
      (display "--------------------------------------------------------\n")))
