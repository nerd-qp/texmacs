
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : prologue.scm
;; DESCRIPTION : subroutines which are not well implemented in guile
;; COPYRIGHT   : (C) 2003  Joris van der Hoeven
;;
;; This software falls under the GNU general public license version 3 or later.
;; It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
;; in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(texmacs-module (kernel boot prologue)
  (:use (kernel boot ahash-table)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Additional support for loading modules
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define module-loaded-table (make-ahash-table))

(define-public (module->url module)
  (let* ((aux (lambda (s) (string-append "/" (symbol->string s))))
	 (name* (apply string-append (map aux module)))
	 (name (substring name* 1 (string-length name*)))
	 (u (url-unix "$GUILE_LOAD_PATH" (string-append name ".scm")))
	 ;; FIXME: should use %load-path instead of $GUILE_LOAD_PATH
	 )
    u))

(define-public (list->module module)
  (url-materialize (module->url module) "r"))

;; In Chez Scheme, module-load is defined globally in boot-chez.scm
;; during bootstrap and is accessible in (interaction-environment).
;(define-public (module-load which)
;  (when (and (list? which)
;             (not (module-loaded? which))
;             (not (ahash-ref *module-loading-stack* which)))
;    (ahash-set! *module-loading-stack* which #t)
;    (for-each module-load (module-dependencies which))
;    (ahash-remove! *module-loading-stack* which)
;    (ahash-set! *texmacs-modules-loaded* which #t)
;    (let ((so (module-so-file which)))
;      (if so
;          (begin
;            (primitive-load so)
;            (guard (e (else #f))
;              (eval `(import ,(module-spec->symbol which)) (interaction-environment))))
;          (let ((fname (module-file-name which)))
;            (when (file-exists? fname)
;              (tm-load-file fname)))))))

;; FIXME: why does this not work?
;(define-public (module-load name)
;  (module-use! (current-module) (resolve-module name)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Work around broken 'symbol-property'
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define symbol-procedure-table (make-ahash-table))
(define symbol-property-table (make-ahash-table))

(define-public (set-symbol-procedure! symb proc)
  (ahash-set! symbol-procedure-table symb proc))

(define-public (symbol-procedure symb)
  (ahash-ref symbol-procedure-table symb))

(define-public (set-symbol-prop! symb prop val)
  (ahash-set! symbol-property-table (list symb prop) val))

(define-public (symbol-prop symb prop)
  (ahash-ref symbol-property-table (list symb prop)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Sorting lists
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (list-sort-merge l1 l2 comp?)
  (cond ((null? l1) l2)
	((null? l2) l1)
	((comp? (car l1) (car l2))
	 (cons (car l1) (list-sort-merge (cdr l1) l2 comp?)))
	(else (cons (car l2) (list-sort-merge l1 (cdr l2) comp?)))))

(define-public (list-sort l comp?)
  "Merge sort of @l using the comparison @comp?."
  (with n (length l)
    (if (< n 2) l
	(let* ((m  (quotient n 2))
	       (ll (list-sort (list-head l m) comp?))
	       (rl (list-sort (list-tail l m) comp?)))
	  (list-sort-merge ll rl comp?)))))
