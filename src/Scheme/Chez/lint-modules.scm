;;; lint-modules.scm -- Driver for `TeXmacs -lint-modules`.
;;;
;;; Analyses every TeXmacs Scheme module from SOURCE, before anything is
;;; compiled, and reports
;;;   * global names that no module defines (typos, missing (:use ...)),
;;;   * which helpers a macro needs at expand time  (compile-uses),
;;;   * which globals a procedure needs at run time (runtime-uses).
;;;
;;; No .so file is read and no code is generated.  Unboundness is decided
;;; against the source index built in Pass 1 (this module, its declared deps,
;;; and everything under kernel/), so the answer is available on a clean tree.
;;;
;;; Usage:
;;;   TeXmacs -lint-modules [script]

(define *lint-progs-dir*
  (cond ((and (getenv "TEXMACS_PATH") (file-exists? (string-append (getenv "TEXMACS_PATH") "/progs")))
         (string-append (getenv "TEXMACS_PATH") "/progs"))
        ((file-exists? "TeXmacs/progs") "TeXmacs/progs")
        ((file-exists? "texmacs/TeXmacs/progs") "texmacs/TeXmacs/progs")
        (else "TeXmacs/progs")))

(define *lint-chez-dir*
  (cond ((file-exists? "static-analysis.scm") ".")
        ((file-exists? "src/Scheme/Chez/static-analysis.scm") "src/Scheme/Chez")
        ((file-exists? "texmacs/src/Scheme/Chez/static-analysis.scm") "texmacs/src/Scheme/Chez")
        (else (error 'lint-modules "cannot locate src/Scheme/Chez"))))

(library-directories (cons *lint-chez-dir* (library-directories)))

(import (chezscheme) (compiler-db) (compiler-scan) (compile-graph) (static-analysis))

;;; ---------------------------------------------------------------------------
;;; Source discovery
;;; ---------------------------------------------------------------------------

(define (lint-scm? path)
  (let ((n (string-length path)))
    (and (> n 4) (string=? (substring path (- n 4) n) ".scm"))))

;; Relative paths of every .scm below DIR.
(define (lint-find-sources dir)
  (define acc '())
  (define (walk rel)
    (let ((full (if (string=? rel "") dir (string-append dir "/" rel))))
      (if (file-directory? full)
          (for-each
            (lambda (name)
              (unless (member name '("." ".."))
                (walk (if (string=? rel "") name (string-append rel "/" name)))))
            (directory-list full))
          (when (lint-scm? rel) (set! acc (cons rel acc))))))
  (walk "")
  (sort (lambda (a b) (string<? a b)) acc))

;; Install a definition or macro into ENV so the next form expands with it
;; available.  A form that will not evaluate is not a lint finding by itself:
;; it usually means a macro helper the linter has not bootstrapped yet.
(define (lint-install! form env)
  (guard (e (else #f))
    (eval form env)))

;;; ---------------------------------------------------------------------------
;;; Report
;;; ---------------------------------------------------------------------------

(define *lint-total* 0)
(define *lint-clean* 0)
(define *lint-dirty* 0)
(define *lint-failed* 0)
(define *lint-findings* 0)

(define (lint-report rel unbound compile-uses runtime-uses failures)
  (set! *lint-total* (+ *lint-total* 1))
  (if (null? unbound)
      (set! *lint-clean* (+ *lint-clean* 1))
      (set! *lint-dirty* (+ *lint-dirty* 1)))

  (for-each
    (lambda (sym)
      (set! *lint-findings* (+ *lint-findings* 1))
      (printf "UNBOUND  ~a  ~a~n" rel sym))
    unbound)

  (for-each
    (lambda (failure)
      (set! *lint-failed* (+ *lint-failed* 1))
      (printf "EXPAND-FAILED  ~a  form ~a  ~a~n"
              rel (car failure)
              (if (condition? (cdr failure))
                  (condition-message (cdr failure))
                  (cdr failure))))
    failures)

  (when (and (null? unbound) (null? failures))
    (printf "OK  ~a  compile-uses=~a runtime-uses=~a~n"
            rel (length compile-uses) (length runtime-uses))))

;;; ---------------------------------------------------------------------------
;;; Main
;;; ---------------------------------------------------------------------------

(define (lint-all!)
  (let* ((sources (lint-find-sources *lint-progs-dir*))
         (db (scan-source-files->db *lint-progs-dir* sources))
         (graph (make-compile-graph-from-db db))
         ;; topological-sort returns strongly connected components, each a list
         ;; of mod-names; flatten so every module is analysed once, in order.
         (order (apply append (compile-graph-topological-sort graph))))

    (printf "LINT-SCAN  ~a sources, ~a modules, ~a cycles~n"
            (length sources) (length order)
            (length (compile-graph-cycles graph)))

    ;; Pass 1: index every definition in every module, from source alone.
    (index-module-definitions *lint-progs-dir* sources)

    ;; Pass 2: expand each module in a fresh environment and walk the result.
    (for-each
      (lambda (mod-name)
        (let ((info (compiler-db-ref db mod-name)))
          (when info
            (let ((rel (module-info-path info)))
              (guard (e (else
                         (printf "LINT-ERROR  ~a  ~a~n" rel
                                 (if (condition? e) (condition-message e) e))))
                (let-values (((unbound runtime compile failures)
                              (analyze-module *lint-progs-dir* rel
                                              (copy-environment (interaction-environment) #t)
                                              lint-install!)))
                  (lint-report rel unbound compile runtime failures)))))))
      order)

    (printf "~nLINT-SUMMARY  total=~a clean=~a with-unbound=~a expand-failed=~a findings=~a~n"
            *lint-total* *lint-clean* *lint-dirty* *lint-failed* *lint-findings*)))

(lint-all!)
