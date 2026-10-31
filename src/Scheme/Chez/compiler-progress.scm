;;; TODO: UNDER REVIEWED AI GENERATED CODE.
;;;
;;; compiler-progress.scm -- CMake-style progress lines for the Chez TeXmacs build.
;;;
;;; This library depends only on Chez Scheme. It does not load the TeXmacs
;;; runtime and does not touch the build itself: it formats and emits, nothing
;;; else.
;;;
;;; Keeping this out of compile-texmacs.scm is worth the extra file for one
;;; reason. The driver is exec'd into the TeXmacs top-level environment, so the
;;; procedures available there depend on what the boot script happened to set
;;; up. Inside a library the dependency is stated -- (import (chezscheme)) --
;;; rather than assumed, so `format`, `with-output-to-string` and
;;; `flush-output-port` are guaranteed to be there. It also makes the formatting
;;; testable on its own, without parsing the driver and fishing the definitions
;;; back out.

(library (compiler-progress)
  (export progress-start!
          progress-tick!
          emit-progress-line
          log-progress
          log-progress-pct
          log-note
          path-basename)
  (import (chezscheme))

  ;;; -------------------------------------------------------------------------
  ;;; Counter
  ;;; -------------------------------------------------------------------------
  ;;
  ;; One line per module -- `[  0%   1/452] Action path` -- with the percentage
  ;; and the index padded to fixed columns so the verbs and paths line up. No
  ;; `\r` and no ANSI escapes: the same bytes read correctly in an interactive
  ;; terminal, an Emacs compilation buffer, and a redirected CI log.
  ;;
  ;; The driver ticks once per module while walking the tiers, so index n is
  ;; always the nth module of the list it started with.

  (define total 0)
  (define current 0)

  (define (progress-start! n)
    (set! total n)
    (set! current 0))

  (define (progress-tick!)
    (set! current (+ current 1))
    current)

  ;;; -------------------------------------------------------------------------
  ;;; Formatting
  ;;; -------------------------------------------------------------------------

  ;; Last component of a path: the part after the final `/`, or the whole
  ;; string when there is none. Used so a progress line reads
  ;; `generic/document-edit.scm -> document-edit.so` instead of repeating the
  ;; directory that the source path already shows.
  (define (path-basename path)
    (let loop ((i (- (string-length path) 1)))
      (cond ((< i 0) path)
            ((char=? (string-ref path i) #\/)
             (substring path (+ i 1) (string-length path)))
            (else (loop (- i 1))))))

  (define (string-pad-left s width)
    (let ((n (- width (string-length s))))
      (if (> n 0) (string-append (make-string n #\space) s) s)))

  ;; Floor, so that only the last module reports 100%.
  (define (progress-pct idx n)
    (if (zero? n) 100 (quotient (* 100 idx) n)))

  (define (progress-pct-tag idx n)
    (string-pad-left (string-append (number->string (progress-pct idx n)) "%") 4))

  (define (format-progress-prefix idx n)
    (string-append "[" (progress-pct-tag idx n)
                   " " (string-pad-left (number->string idx)
                                        (string-length (number->string n)))
                   "/" (number->string n) "] "))

  ;;; -------------------------------------------------------------------------
  ;;; Output
  ;;; -------------------------------------------------------------------------

  ;; Flushed per line so a redirected CI log shows progress as it happens.
  (define (emit-progress-line text)
    (display text)
    (newline)
    (flush-output-port (current-output-port)))

  (define (log-progress action detail)
    (emit-progress-line
      (string-append (format-progress-prefix current total) action " " detail)))

  ;; Aggregate steps (the kernel snapshot, the dependency manifest) have no
  ;; index of their own; report the percentage only.
  (define (log-progress-pct action detail)
    (emit-progress-line
      (string-append "[" (progress-pct-tag current total) "] " action " " detail)))

  ;; Detail line belonging to the preceding progress line: error text, notices.
  (define (log-note text)
    (emit-progress-line
      (string-append "  " (if (string? text) text (format "~a" text)))))
  )
