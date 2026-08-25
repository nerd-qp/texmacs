;;; transpile_boot.scm -- Transpiles TeXmacs boot modules into native Chez Scheme modules
;;;
;;; Usage:
;;;   scheme -q src/Scheme/Chez/transpile_boot.scm

(define (spec->symbol spec)
  (let* ((parts (if (pair? spec)
                    (map symbol->string spec)
                    (list (symbol->string spec))))
         (joined (let loop ((p parts))
                   (if (null? (cdr p))
                       (car p)
                       (string-append (car p) ":" (loop (cdr p)))))))
    (string->symbol joined)))

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

(define (transpile-module in-file out-file)
  (let* ((forms (read-all-forms in-file))
         (has-header? (and (pair? forms)
                           (pair? (car forms))
                           (eq? (caar forms) 'texmacs-module)))
         (hdr (if has-header? (car forms) #f))
         (body (if has-header? (cdr forms) forms)))
    (if (not has-header?)
        (begin
          (display (list 'SKIP in-file "no texmacs-module header")) (newline))
        (let* ((mod-spec (cadr hdr))
               (mod-sym (spec->symbol mod-spec))
               (options (cddr hdr))
               (import-forms '())
               (export-forms '()))
          ;; Parse header options: :use and :inherit
          (for-each
            (lambda (opt)
              (when (pair? opt)
                (let ((kind (car opt))
                      (specs (cdr opt)))
                  (cond
                    ((eq? kind ':use)
                     (for-each
                       (lambda (s)
                         (let ((s-sym (spec->symbol s)))
                           (set! import-forms
                             (cons `(import (for ,s-sym run expand)) import-forms))))
                       specs))
                    ((eq? kind ':inherit)
                     (for-each
                       (lambda (s)
                         (let ((s-sym (spec->symbol s)))
                           (set! import-forms
                             (cons `(import (for ,s-sym run expand)) import-forms))
                           (set! export-forms
                             (cons `(export (import ,s-sym)) export-forms))))
                       specs))))))
            options)
          (set! import-forms (reverse import-forms))
          (set! export-forms (reverse export-forms))

          ;; Write the transformed module
          (let ((out-p (open-output-file out-file 'replace)))
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                ;; Write module wrapper
                (display ";;; Auto-generated native Chez Scheme module from " out-p)
                (display in-file out-p) (newline out-p)
                (write `(module ,mod-sym ()
                          ,@import-forms
                          ,@export-forms
                          ,@body)
                       out-p)
                (newline out-p)
                ;; Write publishing import for top-level interaction environment
                (write `(import ,mod-sym) out-p)
                (newline out-p))
              (lambda () (close-port out-p))))
          (display (list 'TRANSPILED in-file '-> out-file))
          (newline)))))
