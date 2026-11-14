;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : initial-foreign-proc.scm
;; DESCRIPTION : Early C++ foreign procedures registered before glue initialization
;; COPYRIGHT   : (C) 2026
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This software falls under the GNU general public license version 3 or
;; later. It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the
;; file LICENSE in the root directory or
;; <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; --- Foreign Procedure Hooks for C++ Blackbox Objects -----------------------
(define c-delete-blackbox
  (foreign-procedure "tmscm_delete_blackbox" (uptr) void))

(define c-blackbox-equal?
  (foreign-procedure "tmscm_blackbox_equal" (scheme-object scheme-object) scheme-object))

(define c-blackbox-hash
  (foreign-procedure "tmscm_blackbox_hash" (scheme-object) iptr))

;; --- Dynamic Invocation & Fast Trampolines -----------------------------------
(define raw-tm-call-by-name
  (foreign-procedure "tm-call-by-name" (string scheme-object) scheme-object))

(define tm-fast-call-0  (foreign-procedure "tm_fast_call_0"  (int) scheme-object))
(define tm-fast-call-1  (foreign-procedure "tm_fast_call_1"  (int scheme-object) scheme-object))
(define tm-fast-call-2  (foreign-procedure "tm_fast_call_2"  (int scheme-object scheme-object) scheme-object))
(define tm-fast-call-3  (foreign-procedure "tm_fast_call_3"  (int scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-4  (foreign-procedure "tm_fast_call_4"  (int scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-5  (foreign-procedure "tm_fast_call_5"  (int scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-6  (foreign-procedure "tm_fast_call_6"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-7  (foreign-procedure "tm_fast_call_7"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-8  (foreign-procedure "tm_fast_call_8"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-9  (foreign-procedure "tm_fast_call_9"  (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))
(define tm-fast-call-10 (foreign-procedure "tm_fast_call_10" (int scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object scheme-object) scheme-object))

;; --- OS Predicates -----------------------------------------------------------
;; Registered directly via Sforeign_symbol in C++ register_foreign_symbols()
(define-public os-win32? (foreign-procedure "os_win32" () boolean))
(define-public os-mingw? (foreign-procedure "os_mingw" () boolean))
(define-public os-mingw64? (foreign-procedure "os_mingw64" () boolean))
(define-public os-macos? (foreign-procedure "os_macos" () boolean))
(define-public os-android? (foreign-procedure "os_android" () boolean))
