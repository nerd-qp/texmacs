;;; -*- mode: scheme -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : build-glue-chez.scm
;; DESCRIPTION : Generate the native Chez Scheme FFI glue layer
;; COPYRIGHT   : (C) 2026
;;
;; This software falls under the GNU general public license version 3 or
;; later. It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the
;; file LICENSE in the root directory or
;; <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; The legacy glue path installs the ~1,170 C++ routines that TeXmacs exposes
;; to Scheme one at a time at run time (initialize_glue() ->
;; tmscm_install_procedure() -> Scall3 (tm-install-procedure! ...)).  That
;; path cannot run before Sbuild_heap(), so nothing evaluated during heap
;; construction -- notably a secondary boot file such as texmacs.boot -- can
;; see any glue at all.
;;
;; This generator replaces it with static registration.  It reads the same
;; declarative specifications that build-glue.scm consumes and emits two
;; artefacts:
;;
;;   src/Scheme/Chez/glue_chez.cpp
;;       forward declarations for every tmg_* entry point, exception-safe
;;       tmgc_* shims around them, and initialize_glue_chez(), which records
;;       each shim in Chez's foreign symbol table with Sforeign_symbol().
;;       That table is pure C, so it can be populated from custom_init()
;;       inside Sbuild_heap(), before any boot file is evaluated.
;;
;;   TeXmacs/progs/kernel/boot/glue-chez.scm
;;       one (foreign-procedure ...) binding per entry point, which the Chez
;;       compiler turns into a direct call to the C function.  boot-chez.scm
;;       includes it, so every name initialize_glue() used to define exists
;;       by the time any later boot file or module runs.
;;
;; Signature classification.  A routine is bound "raw" (no transcoding at
;; all) when neither its result nor any of its arguments can carry a
;; bytevector across the boundary; everything else gets the UTF-8 wrappers
;; that the old tm-install-procedure! path applied:
;;
;;     (recur-utf8->string (c-fn (recur-string->utf8 arg) ...))
;;
;; The classification is derived from the declared types rather than copied
;; from raw-ffi-table.scm, so it stays correct when a signature changes.  It
;; reproduces that table exactly: of its 441 entries, the 436 that survive the
;; exclusion list below come out raw here, and nothing outside it does.  That
;; equality is the check to re-run after touching *tm-string-types*.
;;
;; Usage:
;;   scheme --script src/Scheme/Chez/build-glue-chez.scm [repo-root]
;;
;; repo-root defaults to the current directory, then its ancestors.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(import (chezscheme))

;;; ---------------------------------------------------------------------------
;;; Configuration
;;;
;;; Top-level constants carry earmuffs, as elsewhere in the kernel
;;; (*raw-ffi-table*, *boot-chez-loaded*, *traced-so-files*).
;;; ---------------------------------------------------------------------------

;; The declarative specifications, in the order initialize_glue() installs
;; them (glue_basic, glue_editor, glue_server).
(define *spec-relative-paths*
  '("src/Scheme/Glue/build-glue-basic.scm"
    "src/Scheme/Glue/build-glue-editor.scm"
    "src/Scheme/Glue/build-glue-server.scm"))

(define *out-cpp-relative-path* "src/Scheme/Chez/glue_chez.cpp")
(define *out-scm-relative-path* "TeXmacs/progs/kernel/boot/glue-chez.scm")

;; Routines the C++ side does not provide for Chez Scheme, because their
;; definitions and/or registrations in src/Scheme/Glue/glue_basic.cpp sit
;; inside
;;     #if !defined(TEXMACS_ENGINE_CHEZ) && !defined(CHEZ_SCHEME)
;;     #ifndef TEXMACS_ENGINE_CHEZ
;; blocks.  Emitting a binding for any of them would either fail to link or
;; shadow the definition the kernel already has:
;;
;;   tm-output, tm-errput                  defined by boot-chez.scm
;;   string-load                           defined by boot-chez.scm
;;   string-search-{forwards,backwards}    defined by chez-compat.scm
;;
;; The five os-*? predicates used to be on this list.  Their guard has been
;; removed from glue_basic.cpp, so they are now ordinary glue like everything
;; else: generated here and installed by initialize_glue() on the legacy path.
(define *chez-unsupported-names*
  '(tm-output tm-errput
    string-load string-search-forwards string-search-backwards))

;; Routines redirected to early-boot safe implementations in glue_overrides.cpp
;; (scheme-name . c-function-override)
(define *chez-override-cfns*
  '(("set-font-rules"          . "tmg_chez_set_font_rules")
    ("set-variant-keys"        . "tmg_chez_set_variant_keys")
    ("set-printing-command"    . "tmg_chez_set_printing_command")
    ("set-printer-paper-type"  . "tmg_chez_set_printer_paper_type")
    ("set-printer-dpi"         . "tmg_chez_set_printer_dpi")))

;; The glue type names whose values are Scheme objects holding a TeXmacs
;; string -- a raw 8-bit bytevector on the C++ side, a Scheme string on the
;; Scheme side.  Every argument and result of one of these types needs
;; transcoding at the boundary; every other type is either a number or an
;; opaque blackbox and crosses untouched.
;;
;;   string       bytevector on the C++ side (string_to_tmscm)
;;   scheme_tree  may hold quoted strings, which scheme_tree_to_tmscm turns
;;                into bytevectors
;;   content      tmscm_to_content accepts a string
;;   object       an untyped Scheme object handle, so anything
;;   url          tmscm_to_url accepts a string and turns it into a url
;;   array_url    same, element-wise
;;   array_string, list_string  arrays and lists of strings
;;
;; Opaque handles that never carry text -- tree, path, patch, modification,
;; observer, widget, promise_widget, command, tree_label -- are not listed:
;; they cross the boundary as blackboxes, which recur-*-transcode leaves
;; alone, so transcoding them would only walk the structure for nothing.
(define *tm-string-types*
  '(string scheme_tree content object url array_url array_string list_string))

;; The seven core predicates are not part of the declarative specifications:
;; initialize_glue() installs them directly from src/Scheme/Scheme/glue.cpp.
;; Each entry is (scheme-name . c-function).
(define *core-predicates*
  '(("tree?"         . "treeP")
    ("tm?"           . "contentP")
    ("observer?"     . "observerP")
    ("url?"          . "urlP")
    ("modification?" . "modificationP")
    ("patch?"        . "patchP")
    ("blackbox?"     . "blackboxP")))

;;; ---------------------------------------------------------------------------
;;; Locating the source tree
;;; ---------------------------------------------------------------------------

(define (root-candidate? dir)
  (file-exists? (string-append dir "/" (car *spec-relative-paths*))))

(define (locate-root)
  (let* ((args (if (top-level-bound? 'command-line-arguments)
                   (command-line-arguments)
                   '()))
         (explicit (if (and (pair? args) (string? (car args)))
                       (list (car args))
                       '()))
         (candidates (append explicit
                             '("." ".." "../.." "../../.." "../../../.."))))
    (let loop ((c candidates))
      (cond ((null? c)
             (error 'build-glue-chez
                    "cannot locate the TeXmacs source tree; "
                    "pass its root as the first argument"))
            ((root-candidate? (car c)) (car c))
            (else (loop (cdr c)))))))

(define *root* (locate-root))

(define (under rel) (string-append *root* "/" rel))

;;; ---------------------------------------------------------------------------
;;; Name mangling
;;;
;;; Identical to translate-name in src/Scheme/Glue/build-glue.scm, so the
;;; tmg_* names emitted here are exactly the ones build-glue.scm already put
;;; into glue_basic.cpp / glue_editor.cpp / glue_server.cpp.
;;; ---------------------------------------------------------------------------

(define (translate-name-char c)
  (case c
    ((#\?) #\P)
    ((#\!) #\S)
    ((#\<) #\F)
    ((#\>) #\2)
    ((#\-) #\_)
    ((#\=) #\Q)
    (else c)))

(define (mangle name)
  (let* ((name (if (and (> (string-length name) 0)
                        (char=? (string-ref name (- (string-length name) 1)) #\*))
                   (string-append (substring name 0 (- (string-length name) 1))
                                  "_dot")
                   name)))
    (string-append "tmg_"
                   (list->string
                     (map translate-name-char (string->list name))))))

;;; ---------------------------------------------------------------------------
;;; Reading the specifications
;;; ---------------------------------------------------------------------------

(define (read-file-forms fname)
  (call-with-input-file fname
    (lambda (ip)
      (let loop ((acc '()))
        (let ((x (read ip)))
          (if (eof-object? x)
              (reverse acc)
              (loop (cons x acc))))))))

;; A specification is
;;     (build "<c++ prefix>" "<init function>" (name routine (ret . args)) ...)
;; Only the entries are of interest: the C++ prefix is already baked into the
;; generated tmg_* names, and the init function is not used by this path.
(define (spec-entries rel-path)
  (let loop ((forms (read-file-forms (under rel-path))) (acc '()))
    (cond
      ((null? forms) (reverse acc))
      ((and (pair? (car forms)) (eq? (car (car forms)) 'build))
       (let* ((form (car forms))
              (entries (cdddr form))
              (parsed (map (lambda (e)
                             (let ((name (car e))
                                   (types (caddr e)))
                               (list (symbol->string name)
                                     (car types)
                                     (cdr types))))
                           entries)))
         (loop (cdr forms) (append (reverse parsed) acc))))
      (else (loop (cdr forms) acc)))))

;;; ---------------------------------------------------------------------------
;;; Entries
;;;
;;; A resolved entry is
;;;     (scheme-name c-function foreign-symbol return-type arg-types)
;;; e.g.
;;;     ("version-before?" "tmg_version_beforeP" "tmg_version_beforeP"
;;;      bool (string string))
;;;
;;; c-function and foreign-symbol differ only for the core predicates, whose C
;;; functions (treeP, urlP, ...) predate the tmg_ convention while their
;;; foreign symbols still follow it.
;;; ---------------------------------------------------------------------------

(define (e-name e) (car e))
(define (e-cfn  e) (cadr e))
(define (e-sym  e) (caddr e))
(define (e-ret  e) (cadddr e))
(define (e-args e) (car (cddddr e)))
(define (e-arity e) (length (e-args e)))

(define (core-predicate-name? name)
  (let loop ((c *core-predicates*))
    (cond ((null? c) #f)
          ((string=? (car (car c)) name) #t)
          (else (loop (cdr c))))))

;; Does this glue type name denote a tm string?
(define (tm-string-type? type)
  (and (memq type *tm-string-types*) #t))

;; Does any argument or the result of this entry hold a tm string, and so
;; need transcoding at the boundary?
(define (uses-tm-string? entry)
  ;; The core predicates are the exception: they accept any Scheme object and
  ;; only inspect its type tag, so transcoding cannot change what they return
  ;; and the plan binds them raw (GLUE_CHEZ_PLAN.md §3.3).
  (and (not (core-predicate-name? (e-name entry)))
       (or (tm-string-type? (e-ret entry))
           (let loop ((a (e-args entry)))
             (cond ((null? a) #f)
                   ((tm-string-type? (car a)) #t)
                   (else (loop (cdr a))))))))

;;; ---------------------------------------------------------------------------
;;; Output helpers
;;; ---------------------------------------------------------------------------

(define (write-text path text)
  (call-with-output-file path
    (lambda (op) (display text op))
    'replace))

(define (join sep n make-item)
  (let loop ((i 1) (acc ""))
    (if (> i n)
        acc
        (loop (+ i 1)
              (string-append acc (if (= i 1) "" sep) (make-item i))))))

;; C++ parameter lists separate with commas; Scheme ones with spaces.
(define (cpp-formals n) (join ", " n (lambda (i) "tmscm")))
(define (cpp-named-formals n)
  (join ", " n (lambda (i) (string-append "tmscm a" (number->string i)))))
(define (cpp-actuals n) (join ", " n (lambda (i) (string-append "a" (number->string i)))))

(define (scheme-formals n)
  (join " " n (lambda (i) (string-append "a" (number->string i)))))
(define (scheme-ffi-types n) (join " " n (lambda (i) "scheme-object")))
(define (scheme-transcoded-actuals n)
  (join " " n (lambda (i) (string-append "(recur-string->utf8 a" (number->string i) ")"))))

;;; ---------------------------------------------------------------------------
;;; C++ artefact
;;; ---------------------------------------------------------------------------

(define (cpp-banner entries raw-count)
  (string-append "
/******************************************************************************
* MODULE     : glue_chez.cpp
* DESCRIPTION: Native Chez Scheme FFI registration of the C++ glue layer
* COPYRIGHT  : (C) 2026
*******************************************************************************
* This software falls under the GNU general public license version 3 or later.
* It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
* in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
******************************************************************************/

/******************************************************************************
* This file is generated by src/Scheme/Chez/build-glue-chez.scm from
*   src/Scheme/Glue/build-glue-basic.scm
*   src/Scheme/Glue/build-glue-editor.scm
*   src/Scheme/Glue/build-glue-server.scm
* Do not edit it by hand; re-run the generator instead.
*
* WHAT IT REPLACES
* ----------------
* initialize_glue() (src/Scheme/Scheme/glue.cpp) installs every C++ routine
* into Scheme at run time: one tmscm_install_procedure() per routine, each of
* which is a Scall3 into (tm-install-procedure! name id arity), which interns
* a symbol and allocates a closure.  Two consequences matter here:
*
*   - it costs ~" (number->string entries) " round trips into the interpreter during
*     every start-up, plus the resulting nursery churn;
*   - it needs a live Scheme heap, so it cannot run before Sbuild_heap()
*     returns.  Any boot file evaluated during heap construction -- a
*     secondary boot file such as texmacs.boot -- therefore sees no glue.
*
* This file replaces that with pure C registration.  Sforeign_symbol() records
* an entry in Chez's foreign symbol table, which is a plain C array: no heap,
* no interning, no Scheme call.  initialize_glue_chez() can therefore run from
* custom_init() inside Sbuild_heap(), before a single boot file is evaluated,
* and TeXmacs/progs/kernel/boot/glue-chez.scm -- included by boot-chez.scm --
* binds the same names with (foreign-procedure ...), which the Chez compiler
* emits as a direct call to the C function instead of a table lookup.
*
* WHY THE tmgc_ SHIMS
* -------------------
* The generated tmg_* routines are ordinary C++ and may throw (tm_throw,
* FAILED, and the kernel's string exceptions).  Letting a C++ exception unwind
* through Chez's foreign-call frame would abort the process, so each entry
* point is wrapped in a tmgc_ shim that contains the throw and returns the
* (cons #t (cons msg '())) error pair the kernel already handles -- exactly
* what tm_fast_call_N did on the legacy path.  The shim also records the
* routine name for the diagnostics in chez_tm.hpp.
*
* " (number->string entries) " routines: " (number->string raw-count) " bound raw, "
   (number->string (- entries raw-count)) " with UTF-8 transcoding.
******************************************************************************/

#include \"chez_tm.hpp\"
#include \"basic.hpp\"
#include \"string.hpp\"

#include <string>

/* ---------------------------------------------------------------------------
 * Error containment
 *
 * Mirrors the catch chain of tm_fast_call_N in chez_tm.cpp: the kernel error
 * pair (tag . (message)) is what TeXmacs Scheme code already expects back
 * from a failing glue routine.
 * ------------------------------------------------------------------------- */

static tmscm
tmg_error_literal (const char* msg, iptr n) {
  return Scons (Sboolean (1), Scons (Sstring_of_length (msg, n), tm_null));
}

/* TeXmacs throws its own string class (basic.cpp: throw string (msg)), which
   is unrelated to std::string, so both have to be caught explicitly. */
static tmscm
tmg_error_texmacs (const string& e) {
  c_string _e (e);
  return tmg_error_literal (_e, (iptr) N (e));
}

static tmscm
tmg_error_std (const std::string& e) {
  return tmg_error_literal (e.c_str (), (iptr) e.size ());
}

/* ---------------------------------------------------------------------------
 * Exception-safe shims
 *
 * One macro per arity, because a foreign-procedure call has a fixed arity and
 * the shim has to forward it positionally.  Arity 10 is the largest the
 * specifications use.
 * ------------------------------------------------------------------------- */

#define TMG_GUARD_BODY(NAME, FN, CALL)                                   \\
  current_glue_proc= NAME;                                               \\
  try { return FN CALL; }                                                \\
  catch (const string& e) { return tmg_error_texmacs (e); }              \\
  catch (const std::string& e) { return tmg_error_std (e); }             \\
  catch (...) { return tmg_error_literal (\"<exception>\", 11); }
"))

(define (cpp-guard-macro n)
  (string-append
    "\n#define TMG_GUARDED_" (number->string n) "(NAME, FN) \\\n"
    "  static tmscm tmgc_##FN (" (cpp-named-formals n) ") { \\\n"
    "    TMG_GUARD_BODY (NAME, FN, (" (cpp-actuals n) ")) \\\n"
    "  }\n"))

(define (cpp-externs all)
  (string-append
    "\n/* ---------------------------------------------------------------------------\n"
    " * Entry points generated into src/Scheme/Glue/glue_{basic,editor,server}.cpp,\n"
    " * plus the core predicates that initialize_glue() installs from\n"
    " * src/Scheme/Scheme/glue.cpp.\n"
    " * ------------------------------------------------------------------------- */\n"
    (apply string-append
      (map (lambda (e)
             (string-append "extern tmscm " (e-cfn e) " ("
                            (cpp-formals (e-arity e)) ");\n"))
           all))))

(define (cpp-shims all)
  (string-append
    "\n/* ---------------------------------------------------------------------------\n"
    " * Shims\n"
    " * ------------------------------------------------------------------------- */\n"
    (apply string-append
      (map (lambda (e)
             (string-append "TMG_GUARDED_" (number->string (e-arity e))
                            " (\"" (e-name e) "\", " (e-cfn e) ")\n"))
           all))))

(define (cpp-table all)
  (string-append
    "\n/* ---------------------------------------------------------------------------\n"
    " * Foreign symbol table\n"
    " *\n"
    " * The name is what glue-chez.scm passes to foreign-procedure; the pointer is\n"
    " * the shim, not the raw tmg_* entry point.\n"
    " * ------------------------------------------------------------------------- */\n"
    "\nstruct tmg_entry {\n"
    "  const char* name;\n"
    "  void*       fn;\n"
    "};\n"
    "\nstatic const tmg_entry tmg_entries[]= {\n"
    (apply string-append
      (map (lambda (e)
             (string-append "  { \"" (e-sym e) "\", (void*) tmgc_" (e-cfn e) " },\n"))
           all))
    "};\n"
    "\nstatic const int tmg_entry_count=\n"
    "  (int) (sizeof (tmg_entries) / sizeof (tmg_entries[0]));\n"
    "\nstatic_assert (sizeof (tmg_entries) / sizeof (tmg_entries[0]) <= 4096,\n"
    "               \"Chez Scheme: glue foreign symbol table overflow\");\n"))

(define (cpp-registration entries)
  (string-append
    "\n/* ---------------------------------------------------------------------------\n"
    " * Registration\n"
    " * ------------------------------------------------------------------------- */\n"
    "\nstatic bool tmg_registered= false;\n"
    "\n/* Called from custom_init(), i.e. inside Sbuild_heap() before the boot files\n"
    "   are evaluated.  That placement is the point of this file: it is what makes\n"
    "   the glue visible to boot-chez.scm and to any secondary boot file loaded\n"
    "   during heap construction. */\n"
    "void\n"
    "initialize_glue_chez () {\n"
    "  if (tmg_registered) return;\n"
    "  tmg_registered= true;\n"
    "  for (int i= 0; i < tmg_entry_count; i++)\n"
    "    Sforeign_symbol (tmg_entries[i].name, tmg_entries[i].fn);\n"
    "}\n"
    "\nint\n"
    "chez_glue_procedure_count () {\n"
    "  return tmg_entry_count;\n"
    "}\n"))

;;; ---------------------------------------------------------------------------
;;; Scheme artefact
;;; ---------------------------------------------------------------------------

(define (scm-banner entries raw-count)
  (string-append
    ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;\n"
    ";;\n"
    ";; MODULE      : glue-chez.scm\n"
    ";; DESCRIPTION : Native FFI bindings for the C++ glue layer\n"
    ";; COPYRIGHT   : (C) 2026\n"
    ";;\n"
    ";; This software falls under the GNU general public license version 3 or\n"
    ";; later. It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the\n"
    ";; file LICENSE in the root directory or\n"
    ";; <http://www.gnu.org/licenses/gpl-3.0.html>.\n"
    ";;\n"
    ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;\n"
    ";;\n"
    ";; Generated by src/Scheme/Chez/build-glue-chez.scm from\n"
    ";;   src/Scheme/Glue/build-glue-basic.scm\n"
    ";;   src/Scheme/Glue/build-glue-editor.scm\n"
    ";;   src/Scheme/Glue/build-glue-server.scm\n"
    ";; Do not edit it by hand; re-run the generator instead.\n"
    ";;\n"
    ";; boot-chez.scm includes this file, so every name initialize_glue() used to\n"
    ";; define at run time exists before any later boot file or module is loaded.\n"
    ";; The C side of each binding is registered by initialize_glue_chez()\n"
    ";; (src/Scheme/Chez/glue_chez.cpp) from custom_init(), i.e. during\n"
    ";; Sbuild_heap(), so foreign-procedure can resolve it while this file is\n"
    ";; being loaded -- and, when boot-chez.scm is compiled, while it is expanded.\n"
    ";;\n"
    ";; Plain define, not define-public: boot-chez.scm is loaded and compiled with\n"
    ";; compile-export-mode? off, where define-public expands to define anyway, and\n"
    ";; define at the top level of the interaction environment is already global.\n"
    ";;\n"
    ";; Two groups:\n"
    ";;\n"
    ";;   raw        no argument or result can carry a string, so the binding is\n"
    ";;              the foreign procedure itself: one direct call, no allocation.\n"
    ";;\n"
    ";;   transcoded arguments and results may carry a TeXmacs string, which the\n"
    ";;              kernel represents as a raw 8-bit bytevector.  The wrapper\n"
    ";;              converts Scheme strings to bytevectors on the way in and back\n"
    ";;              on the way out, exactly as tm-install-procedure! did.\n"
    ";;\n"
    ";; " (number->string entries) " routines: " (number->string raw-count)
    " raw, " (number->string (- entries raw-count)) " transcoded.\n"
    ";;\n"
    ";;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;\n"
    "\n"))

(define (scm-raw-binding entry)
  (string-append
    "(define " (e-name entry) "\n"
    "  (foreign-procedure \"" (e-sym entry) "\" ("
    (scheme-ffi-types (e-arity entry)) ") scheme-object))\n"))

(define (scm-transcoded-binding entry)
  (let* ((name (e-name entry))
         (c-fn (e-cfn entry))
         ;; Drop the tmg_ prefix: c-glue-<mangled> cannot collide with any
         ;; kernel binding, while c-<mangled> could.
         (alias (string-append "c-glue-" (substring c-fn 4 (string-length c-fn))))
         (n (e-arity entry))
         (args (scheme-transcoded-actuals n)))
    (string-append
      "(define " alias "\n"
      "  (foreign-procedure \"" (e-sym entry) "\" (" (scheme-ffi-types n) ") scheme-object))\n"
      "\n"
      "(define (" name (if (= n 0) "" " ") (scheme-formals n) ")\n"
      "  (recur-utf8->string (" alias (if (= n 0) "" " ") args ")))\n"
      "\n")))

;;; ---------------------------------------------------------------------------
;;; Main
;;; ---------------------------------------------------------------------------

;; Stop on the first repeat in `keys`.  A repeat means two spec entries claim
;; one binding: the generated C++ would define a symbol twice, or two
;; Sforeign_symbol calls would fight over one foreign name -- both of which only
;; surface at link or load time, far from the cause.  The C-function check is
;; the one that can actually fire, because mangle is lossy (? -> P, - -> _,
;; > -> 2, < -> F): "a-b" and "a_b" both become tmg_a_b.
(define (assert-unique! what keys)
  (let loop ((l keys) (seen '()))
    (cond ((null? l) #t)
          ((member (car l) seen)
           (error 'build-glue-chez
                  (string-append "duplicate " what ": " (car l))))
          (else (loop (cdr l) (cons (car l) seen))))))

(define (build!)
  (let* ((all (apply append (map spec-entries *spec-relative-paths*)))
         (kept (filter (lambda (e)
                         (not (memq (string->symbol (car e))
                                    *chez-unsupported-names*)))
                       all))
         ;; (scheme-name c-function foreign-symbol return-type arg-types).
         ;; spec-entries still yields the raw (name return-type arg-types)
         ;; shape at this point.
         (entries (map (lambda (e)
                         (let* ((name (car e))
                                (m (mangle name))
                                (cfn (cond ((assoc name *chez-override-cfns*) => cdr)
                                           (else m))))
                           (list name cfn m (cadr e) (caddr e))))
                       kept))
         ;; The core predicates keep their historical C function names but are
         ;; registered under the same tmg_<mangled> convention as everything
         ;; else, so glue-chez.scm needs no special case for them.
         (core (map (lambda (cp)
                      (let ((name (car cp)) (cfn (cdr cp)))
                        (list name cfn (mangle name) 'bool (list 'object))))
                    *core-predicates*))
         (all-entries (append entries core))
         (raw (filter (lambda (e) (not (uses-tm-string? e))) all-entries))
         (wrapped (filter uses-tm-string? all-entries))
         (total (length all-entries)))

    ;; Three name spaces, one check each.  This runs before anything is
    ;; written, so a collision leaves the artefacts untouched.
    (assert-unique! "Scheme name" (map e-name all-entries))
    (assert-unique! "C function name" (map e-cfn all-entries))
    (assert-unique! "foreign symbol name" (map e-sym all-entries))

    (let* ((cpp-text
            (string-append
              (cpp-banner total (length raw))
              (apply string-append (map cpp-guard-macro '(0 1 2 3 4 5 6 7 8 9 10)))
              (cpp-externs all-entries)
              (cpp-shims all-entries)
              (cpp-table all-entries)
              (cpp-registration all-entries)))
           (scm-text
            (string-append
              (scm-banner total (length raw))
              ";;; --- Raw bindings: no transcoding, one direct call each -----------\n"
              "\n"
              (apply string-append (map scm-raw-binding raw))
              "\n"
              ";;; --- Transcoded bindings: UTF-8 at the boundary -------------------\n"
              "\n"
              (apply string-append (map scm-transcoded-binding wrapped)))))

      (write-text (under *out-cpp-relative-path*) cpp-text)
      (write-text (under *out-scm-relative-path*) scm-text)

      (display "build-glue-chez: ")
      (display (number->string total))
      (display " routines (")
      (display (number->string (length raw)))
      (display " raw, ")
      (display (number->string (length wrapped)))
      (display " transcoded, ")
      (display (number->string (length core)))
      (display " core predicates), ")
      (display (number->string (- (length all) (length kept))))
      (display " skipped for Chez\n")
      (display "  -> ") (display (under *out-cpp-relative-path*)) (newline)
      (display "  -> ") (display (under *out-scm-relative-path*)) (newline))))

(build!)
