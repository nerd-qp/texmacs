;;; TODO: UNDER REVIEWED AI GENERATED CODE.
;;;
;;; compiler-scan.scm -- Scan TeXmacs Scheme sources into compiler-db records.
;;;
;;; This library depends only on compiler-db and Chez Scheme. It does not load
;;; the TeXmacs runtime.

(library (compiler-scan)
  (export scan-source-file
          scan-source-files
          scan-source-files->db)
  (import (chezscheme) (compiler-db))

  ;;; -------------------------------------------------------------------------
  ;;; File and form helpers
  ;;; -------------------------------------------------------------------------

  (define (scan-scm-file? path)
    (let ((n (string-length path)))
      (and (> n 4)
           (string=? (substring path (- n 4) n) ".scm"))))

  (define (scan-read-forms path)
    (guard (e (else #f))
      (call-with-input-file path
        (lambda (port)
          (let loop ((acc '()))
            (let ((x (read port)))
              (if (eof-object? x)
                  (reverse acc)
                  (loop (cons x acc)))))))))

  (define (scan-read-text path)
    (guard (e (else #f))
      (call-with-input-file path
        (lambda (port)
          (get-string-all port)))))

  (define (scan-header forms)
    (let loop ((rest forms))
      (cond ((null? rest) #f)
            ((and (pair? (car rest))
                  (eq? (caar rest) 'texmacs-module))
             (car rest))
            (else (loop (cdr rest))))))

  (define (scan-header->deps header mod-spec)
    (let ((deps '()))
      (for-each
       (lambda (opt)
         (when (and (pair? opt) (memq (car opt) '(:use :inherit)))
           (for-each
            (lambda (s)
              (unless (or (equal? s mod-spec) (member s deps))
                (set! deps (cons s deps))))
            (cdr opt))))
       (cddr header))
      (reverse deps)))

  (define (scan-leftmost-symbol x)
    (cond ((symbol? x) x)
          ((pair? x) (scan-leftmost-symbol (car x)))
          (else #f)))

  (define (scan-defined-name form head)
    (or (scan-leftmost-symbol head)
        (error 'compiler-scan
               "declaration has no valid name"
               form)))

  (define (scan-macro-impl-name name)
    (string->symbol (string-append (symbol->string name) "$impl")))

  (define (scan-flatten-begins forms)
    (let loop ((rest forms) (acc '()))
      (cond ((null? rest) (reverse acc))
            ((and (pair? (car rest)) (eq? (caar rest) 'begin))
             (loop (append (cdr (car rest)) (cdr rest)) acc))
            (else
             (loop (cdr rest) (cons (car rest) acc))))))

  ;;; -------------------------------------------------------------------------
  ;;; Declaration collection
  ;;; -------------------------------------------------------------------------

  (define (scan-collect forms)
    (let loop ((rest (scan-flatten-begins forms))
               (exports '())
               (globals '())
               (macros '())
               (impls '()))
      (if (null? rest)
          (values (reverse exports)
                  (reverse globals)
                  (reverse macros)
                  (reverse impls))
          (let* ((form (car rest))
                 (head (and (pair? form) (car form)))
                 (arg (and (pair? form) (pair? (cdr form)) (cadr form))))
            (case head
              ((define-public provide-public define-public-macro)
               (loop (cdr rest)
                     (cons (scan-defined-name form arg) exports)
                     globals macros impls))
              ((tm-define)
               (loop (cdr rest)
                     exports
                     (cons (scan-defined-name form arg) globals)
                     macros impls))
              ((tm-define-macro)
               (let* ((name (scan-defined-name form arg))
                      (impl (scan-macro-impl-name name)))
                 (loop (cdr rest)
                       exports
                       globals
                       (cons name macros)
                       (cons impl impls))))
              (else
               (loop (cdr rest) exports globals macros impls)))))))

  ;;; -------------------------------------------------------------------------
  ;;; Canonical hashes
  ;;; -------------------------------------------------------------------------

  (define (scan-sort-symbols syms)
    (sort (lambda (a b)
            (string<? (symbol->string a) (symbol->string b)))
          syms))

  (define (scan-canonical-symbols syms)
    (let loop ((rest (scan-sort-symbols syms)) (acc ""))
      (cond ((null? rest) acc)
            (else
             (loop (cdr rest)
                   (string-append acc (symbol->string (car rest)) "\n"))))))

  (define (scan-interface-hash exports global-macros macro-impls)
    (string-hash
     (string-append "E\n" (scan-canonical-symbols exports)
                    "G\n" (scan-canonical-symbols global-macros)
                    "M\n" (scan-canonical-symbols macro-impls))))

  (define (scan-source-hash text)
    (and text (string-hash text)))

  ;;; -------------------------------------------------------------------------
  ;;; One file
  ;;; -------------------------------------------------------------------------

  (define (scan-source-file progs-dir rel-path)
    (let* ((full (string-append progs-dir "/" rel-path))
           (forms (scan-read-forms full)))
      (cond
       ((not forms)
        (display "SCAN-SKIP read-error " (current-error-port))
        (display rel-path (current-error-port))
        (newline (current-error-port))
        #f)
       (else
        (let ((header (scan-header forms)))
          (cond
           ((not header)
            (display "SCAN-SKIP no-header " (current-error-port))
            (display rel-path (current-error-port))
            (newline (current-error-port))
            #f)
           (else
            (let* ((mod-spec (cadr header))
                   (deps (scan-header->deps header mod-spec))
                   (text (scan-read-text full)))
              (call-with-values
               (lambda () (scan-collect forms))
               (lambda (exports globals macros impls)
                 (make-module-info
                  mod-spec
                  rel-path
                  exports
                  globals
                  macros
                  impls
                  deps
                  '()                          ; compile-uses
                  '()                          ; runtime-uses
                  (scan-interface-hash exports macros impls)
                  (scan-source-hash text)
                  #f                           ; artifact-hash
                  (time-second (current-time)))))))))))))

  ;;; -------------------------------------------------------------------------
  ;;; Multiple files and trees
  ;;; -------------------------------------------------------------------------

  (define (scan-source-files progs-dir rel-paths)
    (let loop ((rest rel-paths) (acc '()))
      (cond ((null? rest) (reverse acc))
            (else
             (let ((info (scan-source-file progs-dir (car rest))))
               (loop (cdr rest)
                     (if info (cons info acc) acc)))))))

  (define (scan-source-files->db progs-dir rel-paths)
    (let ((db (make-empty-compiler-db)))
      (for-each
       (lambda (rel-path)
         (let ((info (scan-source-file progs-dir rel-path)))
           (when info
             (compiler-db-set! db info))))
       rel-paths)
      db))
)
