
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

(texmacs-module (utils misc tm-keywords)
  (:use (kernel library base) (kernel boot ahash-table)))

;; Parsing tm-mode.el via `kw-eval` instead of `eval` is required for
;; texmacs.boot: during Sbuild_heap(), runtime eval of compound setq forms
;; crashes with unbound identifier errors before the interactive REPL exists.

(define kws (string-load (unix->url "$TEXMACS_PATH/progs/tm-mode.el")))
(define kwo (string->object (string-append "(" kws ")")))

(define kw-env (make-ahash-table))
(define (kw-eval x)
  (cond ((symbol? x) (ahash-ref kw-env x))
        ((and (pair? x) (eq? (car x) 'quote)) (cadr x))
        ((and (pair? x) (eq? (car x) 'append)) (apply append (map kw-eval (cdr x))))
        (else x)))

(define indent-arity-table (make-ahash-table))

(define (indent-set-arity x nr)
  (cond ((symbol? x) (indent-set-arity (symbol->string x) nr))
	((string? x) (ahash-set! indent-arity-table x nr))
	((list? x) (for-each (cut indent-set-arity <> nr) x))))

(for-each
  (lambda (form)
    (when (and (pair? form) (eq? (car form) 'setq))
      (let ((var (cadr form))
            (val (kw-eval (caddr form))))
        (ahash-set! kw-env var val)
        (define-top-level-value var val (interaction-environment)))))
  kwo)

(indent-set-arity (or (ahash-ref kw-env 'nullary-indent) '()) 0)
(indent-set-arity (or (ahash-ref kw-env 'unary-indent) '())   1)
(indent-set-arity (or (ahash-ref kw-env 'binary-indent) '())  2)
(indent-set-arity (or (ahash-ref kw-env 'ternary-indent) '()) 3)

(tm-define (indent-get-arity s)
  (:synopsis "get indentation arity of keyword @s")
  (if (symbol? s)
      (indent-get-arity (symbol->string s))
      (ahash-ref indent-arity-table s)))
