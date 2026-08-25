
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : tm-keywords.scm
;; DESCRIPTION : additional rendering macros written in scheme
;; COPYRIGHT   : (C) 2007  Joris van der Hoeven
;;
;; This software falls under the GNU general public license version 3 or later.
;; It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
;; in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(texmacs-module (utils misc tm-keywords))

(define-syntax include-tm-mode-keywords
  (lambda (stx)
    (let* ((progs-dir (cond ((getenv "TEXMACS_PATH") (string-append (getenv "TEXMACS_PATH") "/progs"))
                            ((file-exists? "TeXmacs/progs") "TeXmacs/progs")
                            (else "TeXmacs/progs")))
           (el-file (string-append progs-dir "/tm-mode.el"))
           (kws (if (file-exists? el-file)
                    (with-input-from-file el-file
                      (lambda ()
                        (let loop ((acc '()))
                          (let ((x (read)))
                            (if (eof-object? x) (reverse acc) (loop (cons x acc)))))))
                    '()))
           (defs (let loop ((l kws))
                   (cond ((null? l) '())
                         ((and (pair? (car l)) (eq? (caar l) 'setq))
                          (cons (cons 'define-public (cdar l)) (loop (cdr l))))
                         (else (loop (cdr l)))))))
      (datum->syntax (car (syntax->list stx)) (cons 'begin defs)))))

(include-tm-mode-keywords)

(define indent-arity-table (make-ahash-table))

(define (indent-set-arity x nr)
  (cond ((symbol? x) (indent-set-arity (symbol->string x) nr))
	((string? x) (ahash-set! indent-arity-table x nr))
	((list? x) (for-each (cut indent-set-arity <> nr) x))))

(indent-set-arity nullary-indent 0)
(indent-set-arity unary-indent   1)
(indent-set-arity binary-indent  2)
(indent-set-arity ternary-indent 3)

(tm-define (indent-get-arity s)
  (:synopsis "get indentation arity of keyword @s")
  (if (symbol? s)
      (indent-get-arity (symbol->string s))
      (ahash-ref indent-arity-table s)))
