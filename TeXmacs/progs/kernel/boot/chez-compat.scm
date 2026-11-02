;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : chez-compat.scm
;; DESCRIPTION : Guile compatibility primitives for Chez Scheme
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(texmacs-module (kernel boot chez-compat))

;;; Numeric helpers
(define-public (1+ x) (+ x 1))
(define-public (1- x) (- x 1))

;;; Character sets
(define-public char-set:whitespace (string->list " \t\n\r\f\v"))
(define-public char-set:digit (string->list "0123456789"))
(define-public char-set:lower-case (string->list "abcdefghijklmnopqrstuvwxyz"))
(define-public char-set:upper-case (string->list "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
(define-public char-set:letter (append char-set:lower-case char-set:upper-case))
(define-public char-set:letter+digit (append char-set:letter char-set:digit))

;;; List mutators

(define-public (delq! x l) (remq! x l))
(define-public (delv! x l) (remv! x l))
(define-public (delete! x l) (remove! x l))
(define-public (delq x l) (remq x l))

(define-public (acons k v l) (cons (cons k v) l))

;;; Association lists
(define-public (assoc-ref alist key) (cond ((assoc key alist) => cdr) (else #f)))
(define-public (assoc-set! alist key val)
  (let ((entry (assoc key alist)))
    (if entry (begin (set-cdr! entry val) alist) (cons (cons key val) alist))))
(define-public (assoc-remove! alist key)
  (let loop ((l alist) (prev #f))
    (cond ((null? l) alist)
          ((equal? (caar l) key)
           (if prev (begin (set-cdr! prev (cdr l)) alist) (cdr l)))
          (else (loop (cdr l) l)))))

(define-public (assq-ref alist key) (cond ((assq key alist) => cdr) (else #f)))
(define-public (assq-set! alist key val)
  (let ((entry (assq key alist)))
    (if entry (begin (set-cdr! entry val) alist) (cons (cons key val) alist))))
(define-public (assq-remove! alist key)
  (let loop ((l alist) (prev #f))
    (cond ((null? l) alist)
          ((eq? (caar l) key)
           (if prev (begin (set-cdr! prev (cdr l)) alist) (cdr l)))
          (else (loop (cdr l) l)))))

;;; Tree operations
(define-public (copy-tree obj)
  (cond ((pair? obj) (cons (copy-tree (car obj)) (copy-tree (cdr obj))))
        ((vector? obj) (vector-map copy-tree obj))
        (else obj)))

;;; Sorting (Guile argument order: (sort seq less?))
(define-public (sort a b)
  (let ((seq (if (procedure? a) b a))
        (pred (if (procedure? a) a b)))
    (if (vector? seq)
        (vector-sort pred seq)
        (chez:sort pred seq))))

(define-public (sort! a b)
  (sort a b))

;;; I/O primitives
(define-public (display* . l)
  "Display all objects in @l."
  (for-each display l))

(define-public (write* . l)
  "Write all objects in @l to standard output."
  (for-each write l))

(define-public (read-line . opt)
  (get-line (if (null? opt) (current-input-port) (car opt))))

(define-public (force-output . opt)
  (flush-output-port (if (null? opt) (current-output-port) (car opt))))

(define-public (make-soft-port . _) #f)

;;; Introspection
(define-public (procedure-name p) #f)
(define-public (procedure-documentation p) #f)

;;; POSIX compatibility
(define-public (getpid)
  (cond ((top-level-bound? 'get-process-id) (get-process-id))
        (else 1000)))

(define chez:current-time (top-level-value 'current-time (scheme-environment)))

(define-public (current-time)
  (time-second (chez:current-time)))

(define-public (getpwnam id)
  (vector (or (getenv "USER") "user") "" 1000 1000
          (or (getenv "USER") "Default User")
          (or (getenv "HOME") "") "/bin/sh"))

(define-public (getpwuid id) (getpwnam id))

(define-public (passwd:name pw)
  (if (vector? pw) (vector-ref pw 0) (or (getenv "USER") "Default User")))

(define-public (passwd:gecos pw)
  (if (vector? pw) (vector-ref pw 4) ""))

(define-public (gecos:name g)
  (if (string? g)
      (let ((parts (string-split g #\,)))
        (if (null? parts) "" (car parts)))
      "Default User"))

;;; String and character set compatibility
(define-public (char-in-set? c cs)
  (cond ((char? cs) (char=? c cs))
        ((procedure? cs) (and (cs c) #t))
        ((list? cs) (and (memv c cs) #t))
        ((string? cs)
         (let ((len (string-length cs)))
           (let loop ((i 0))
             (cond ((>= i len) #f)
                   ((char=? (string-ref cs i) c) #t)
                   (else (loop (+ i 1)))))))
        (else #f)))

(define-public (string-index s cs . opt)
  (let* ((start (if (null? opt) 0 (car opt)))
         (end (if (or (null? opt) (null? (cdr opt))) (string-length s) (cadr opt))))
    (let loop ((i start))
      (cond ((>= i end) #f)
            ((char-in-set? (string-ref s i) cs) i)
            (else (loop (+ i 1)))))))

(define-public (string-rindex s cs . opt)
  (let* ((start (if (null? opt) 0 (car opt)))
         (end (if (or (null? opt) (null? (cdr opt))) (string-length s) (cadr opt))))
    (let loop ((i (- end 1)))
      (cond ((< i start) #f)
            ((char-in-set? (string-ref s i) cs) i)
            (else (loop (- i 1)))))))

(define-public (string-split s cs)
  (let ((len (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((>= i len)
             (reverse (cons (substring s start len) acc)))
            ((char-in-set? (string-ref s i) cs)
             (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else
             (loop (+ i 1) start acc))))))

(define-public (string-count s cs . opt)
  (let* ((start (if (null? opt) 0 (car opt)))
         (end (if (or (null? opt) (null? (cdr opt))) (string-length s) (cadr opt))))
    (let loop ((i start) (cnt 0))
      (cond ((>= i end) cnt)
            ((char-in-set? (string-ref s i) cs)
             (loop (+ i 1) (+ cnt 1)))
            (else
             (loop (+ i 1) cnt))))))

;;; Hash tables (Guile compatibility)
(define-public (hash-ref t k . default)
  (if (hashtable-contains? t k)
      (hashtable-ref t k #f)
      (if (null? default) #f (car default))))

(define-public (hash-set! t k v)
  (hashtable-set! t k v)
  v)

(define-public (hash-remove! t k)
  (hashtable-delete! t k))

(define-public (hash-get-handle t k)
  (if (hashtable-contains? t k)
      (cons k (hashtable-ref t k #f))
      #f))

(define-public (hash-fold proc init t)
  (let-values (((ks vs) (hashtable-entries t)))
    (let loop ((i 0) (acc init))
      (if (= i (vector-length ks))
          acc
          (loop (+ i 1) (proc (vector-ref ks i) (vector-ref vs i) acc))))))


