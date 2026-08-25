
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : tm-states.scm
;; DESCRIPTION : Dynamic states around (tm-define)-d functions
;; COPYRIGHT   : (C) 2007  Joris van der Hoeven and Henri Lesourd
;;
;; This software falls under the GNU general public license version 3 or later.
;; It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
;; in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(texmacs-module (kernel texmacs tm-states))

;; Low-level API
(define-public (state-create slotlist)
;; slotlist === ((<SLOT-DESCR>*) (<PROP-DESCR>*) (<COMPILED-PROP>*) (<SETTERS>*) (<GETTERS>*))
  slotlist)

(define (state-slots sr)
  (car sr))

(define (state-props sr)
  (cadr sr))

(define (state-cprops sr)
  (caddr sr))

(define (state-csetters sr)
  (list-ref sr 3))

(define (state-cgetters sr)
  (list-ref sr 4))

(define (slotlist-load l setters)
  (for-each (lambda (e set-val!) (set-val! (cadr e))) l setters))

(define (proplist-load l funcs b)
  (if b
      (for-each (lambda (f) (f)) funcs)))

(define (slotlist-save l getters)
  (for-each (lambda (e get-val) (set-car! (cdr e) (get-val))) l getters))

;; User-level API
(define current-state #f)

(define-public (state-synchronize)
  (with old-current current-state
    (set! current-state #f)
    (state-save old-current)))
  
(define-public (state-load sr . opt)
  (if sr
      (begin
        (if (not (eq? sr current-state))
            (begin
              (state-synchronize)
              (slotlist-load (state-slots sr) (state-csetters sr))))
        (proplist-load (state-props sr) (state-cprops sr) (null? opt))
        (set! current-state sr))))

(define-public (state-save sr)
  (if (and sr (not (eq? sr current-state)))
      (slotlist-save (state-slots sr) (state-cgetters sr))))

(define (state-slotnames sr)
  (map car (state-slots sr)))

(define (state-propnames sr)
  (map car (state-props sr)))

(define-public (state-names sr)
  (append (state-slotnames sr) (state-propnames sr)))

(define-public (state-type sr name)
  (cond ((in? name (state-slotnames sr))
         'slot)
        ((in? name (state-propnames sr))
         'prop)
        (else #f)))

(define (seek-pred? pred? l)
  (define res #f)
  (for (e l)
     (if (pred? (car e))
         (set! res e)))
  res)

(define (state-entry sr name)
  (define ref #f)
  (set! ref (seek-pred? (lambda (x) (eq? x name)) (state-slots sr)))
  (if (not ref)
      (set! ref (seek-pred? (lambda (x) (eq? x name)) (state-props sr))))
  ref)

(define-public (state-read sr name)
  (define ref #f)
  (set! ref (state-entry sr name))
  (if ref
      (cadr ref)))

(define-public (state-write sr name val)
  (define ref #f)
  (set! ref (state-entry sr name))
  (if ref
      (set-car! (cdr ref) val)))

(define-public-macro (define-state name . slotlists)
;; slotlists === ((slots ((<NAME-SLOT1> <INIT1>) ... (<NAME-SLOTN> <INITN>)))
;;                (props ((<NAME-PROP1> <PROP1>) ... (<NAME-PROPN> <PROPN>))))
  (let* ((theslots (copy-tree slotlists))
         (slots-clause (assoc 'slots theslots))
         (props-clause (assoc 'props theslots))
         (raw-slots (if (and slots-clause (pair? (cdr slots-clause))) (cadr slots-clause) '()))
         (props (if (and props-clause (pair? (cdr props-clause))) (cadr props-clause) '()))
         (cprops   (map (lambda (x) `(lambda () (set! ,(car x) ,(cadr x)))) props))
         (csetters (map (lambda (x) `(lambda (val) (set! ,(car x) val))) raw-slots))
         (cgetters (map (lambda (x) `(lambda () ,(car x))) raw-slots))
         (cslots   (map (lambda (s) `(list ',(car s) ,(cadr s))) raw-slots)))
    `(begin
       ,@(map (lambda (s) `(define-public ,(car s) ,(cadr s))) raw-slots)
       ,@(map (lambda (p) `(define-public ,(car p) #f)) props)
       (define-public ,name
         (state-create
           (list (list ,@cslots)
                 ',props
                 (list ,@cprops)
                 (list ,@csetters)
                 (list ,@cgetters)))))))

(define-public-macro (with-state sr . body)
 `(begin
     (state-load ,sr)
     (with res (begin . ,body)
       (state-save ,sr)
       res)))

(define-public-macro (with-state-by-name name . body)
 `(with sr ,name
     (with-state sr . ,body)))

(define-public-macro (with-state-slots sr . body)
 `(begin
     (state-load ,sr #f)
     (with res (begin . ,body)
       (state-save ,sr)
       res)))

(define-public-macro (with-state-slots-by-name name . body)
 `(with sr ,name
     (with-state-slots sr . ,body)))
