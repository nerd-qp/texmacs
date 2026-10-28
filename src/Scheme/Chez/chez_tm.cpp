
/******************************************************************************
 * MODULE     : chez_tm.cpp
 * DESCRIPTION: Interface to the Chez Scheme kernel (C API)
 * COPYRIGHT  : (C) 2026
 *******************************************************************************
 * This software falls under the GNU general public license version 3 or later.
 * It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
 * in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
 ******************************************************************************/

#include "chez_tm.hpp"
#include "blackbox.hpp"
#include "file.hpp"
#include "../Scheme/glue.hpp"

#include <map>
#include <mutex>
#include <string.h>
#include <cstdio>  /* CHEZDBG temporary boot instrumentation */

extern bool compile_modules_mode;

/* ------------------------------------------------------------------------
 * Global engine state
 * ---------------------------------------------------------------------- */

tmscm tm_null= 0;
tmscm tm_blackbox_guardian= 0;
static ptr tm_install_guarded= 0;   /* CHEZDBG debug aid */
tmscm tm_eval_string_proc= 0;
tmscm tm_load_file_proc= 0;
tmscm tm_apply_proc= 0;
tmscm tm_list_pred= 0;
tmscm tm_equal_pred= 0;
tmscm object_stack= 0;

/* All entry points into the Chez kernel are serialized with this recursive
   mutex: the kernel is not re-entrant across threads, but re-entrant calls
   from within the kernel (Scheme -> C++ callback -> Scheme) must not
   deadlock, hence recursive. */
static std::recursive_mutex chez_mutex;

class chez_lock {
  std::lock_guard<std::recursive_mutex> guard;
public:
  chez_lock (): guard (chez_mutex) {}
};

/* Threaded kernel: ANY thread that allocates or calls into the kernel must
   first be registered with Sactivate_thread.  The Chez FFI does this
   automatically for foreign-procedure calls, but our C++->Scheme entry
   points (eval_scheme / call_scheme / eval_scheme_file) are plain C++
   functions -- TeXmacs happily invokes them from the Qt event-loop thread
   (delayed queue, timers), which the kernel has never seen.  Allocating
   there without activation corrupts the heap: observed as faults inside
   S_dirty_set and later "misplaced pair" aborts during GC.
   Deactivation on scope exit is safe under the single-engine-thread model:
   while we hold chez_lock no other thread can be running a collection, so
   no GC can move anything between our deactivation and the next entry. */
class chez_activate {
  bool activated;
public:
  chez_activate (): activated (Sactivate_thread () == 1) {}
  ~chez_activate () { if (activated) Sdeactivate_thread (); }
};

/* ------------------------------------------------------------------------
 * Basic list/equality predicates (need cached Scheme procedures)
 * ---------------------------------------------------------------------- */

bool
tmscm_is_list (tmscm obj) {
  if (tm_list_pred != 0)
    return Sboolean_value (Scall1 (tm_list_pred, obj));
  /* fallback before initialization: bounded walk */
  tmscm slow= obj, fast= obj;
  for (int i= 0; i < 1000000; i++) {
    if (Snullp (fast)) return true;
    if (!Spairp (fast)) return false;
    fast= Scdr (fast);
    if (Snullp (fast)) return true;
    if (!Spairp (fast)) return false;
    fast= Scdr (fast);
    slow= Scdr (slow);
    if (fast == slow) return false; /* cycle */
  }
  return false;
}

bool
tmscm_is_equal (tmscm o1, tmscm o2) {
  /* Blackboxes must be compared by the C++ value they wrap, not by the address
     token standing in for it: two conversions of the same value are distinct
     conses, so Chez's equal? would compare the addresses and report #f.

     This check MUST come first.  The tm_equal_pred branch below is always
     taken (the handle is fetched at init and never cleared), so a blackbox
     check placed after it would never run.

     This is the Chez counterpart of Guile's scm_set_smob_equalp handler
     (guile_tm.cpp cmp_blackbox), which does exactly this unwrap-and-compare.
     Chez has no per-type hook on equal?, so the decision has to be made here,
     on the C++ side, before delegating. */
  if (tmscm_is_blackbox (o1) && tmscm_is_blackbox (o2))
    return tmscm_to_blackbox (o1) == tmscm_to_blackbox (o2);
  /* Guard the delegation: Stop_level_value hands back 0x1e (the unbound
     marker) rather than 0 when a symbol is unbound, so "!= 0" alone would let
     an unbound handle through and detonate inside Scall2.  Sprocedurep asks
     the question we actually care about -- did we get a callable procedure? */
  if (tm_equal_pred != 0 && Sprocedurep (tm_equal_pred))
    return Sboolean_value (Scall2 (tm_equal_pred, o1, o2));
  return o1 == o2;
}

/* ------------------------------------------------------------------------
 * String and symbol conversions
 * ---------------------------------------------------------------------- */

tmscm
string_to_tmscm (string s) {
  c_string _s (s);
  return Sstring_of_length (_s, (iptr) N (s));
}

string
tmscm_to_string (tmscm s) {
  iptr n= Sstring_length (s);
  STACK_NEW_ARRAY (buf, char, n + 1);
  for (iptr i= 0; i < n; i++) buf[i]= (char) Sstring_ref (s, i);
  buf[n]= '\0';
  string r (buf, (int) n);
  STACK_DELETE_ARRAY (buf);
  return r;
}

tmscm
symbol_to_tmscm (string s) {
  c_string _s (s);
  return Sstring_to_symbol (_s);
}

string
tmscm_to_symbol (tmscm s) {
  tmscm str= Ssymbol_to_string (s);
  return tmscm_to_string (str);
}

/* ------------------------------------------------------------------------
 * Blackboxes
 * ---------------------------------------------------------------------- */

bool
tmscm_is_blackbox (tmscm t) {
  return Sboxp (t)
      && tmscm_is_int (Sunbox (t))
      && (Sinteger_value (Sunbox (t)) != 0);
}

tmscm
blackbox_to_tmscm (blackbox b) {
  blackbox* ptr= tm_new<blackbox> (b);
  return Sbox (Sinteger ((iptr) ptr));
}

blackbox
tmscm_to_blackbox (tmscm t) {
  void* p= (void*) Sinteger_value (Sunbox (t));
  if (!p) return blackbox ();
  return *((blackbox*) p);
}

extern "C" void
tmscm_delete_blackbox (void* p) {
  if (p) tm_delete ((blackbox*) p);
}

extern "C" ptr
tmscm_blackbox_equal (ptr b1, ptr b2) {
  if (!Sboxp (b1) || !Sboxp (b2)) return Sboolean (0);
  void* p1= (void*) Sinteger_value (Sunbox (b1));
  void* p2= (void*) Sinteger_value (Sunbox (b2));
  if (p1 == p2) return Sboolean (1);
  if (!p1 || !p2) return Sboolean (0);
  return Sboolean (*((blackbox*) p1) == *((blackbox*) p2));
}

extern "C" iptr
tmscm_blackbox_hash (ptr b) {
  if (!Sboxp (b)) return 0;
  void* p= (void*) Sinteger_value (Sunbox (b));
  if (!p) return 0;
  blackbox* bb= (blackbox*) p;
  if (type_box (*bb) == type_helper<tree>::id) {
    return (iptr) hash (open_box<tree> (*bb));
  }
  return (iptr) type_box (*bb);
}

void
reap_blackboxes () {
  chez_lock lock;
  chez_activate activate;
  if (!tm_blackbox_guardian) {
    FAILED ("reap_blackboxes called but tm_blackbox_guardian is null");
  }
  while (true) {
    tmscm b= Scall0 (tm_blackbox_guardian);
    if (b == Sboolean (0)) break;
    if (Sboxp (b)) {
      void* p= (void*) Sinteger_value (Sunbox (b));
      if (p) {
        tm_delete ((blackbox*) p);
        Sset_box (b, Sinteger (0));
      }
    }
  }
}

/* ------------------------------------------------------------------------
 * Registry of C++ procedures callable from Scheme
 *
 * Scheme side: every procedure installed with tmscm_install_procedure is
 * defined as
 *     (define <name> (lambda args (tm-call-by-name "<name>" args)))
 * where tm-call-by-name is a foreign procedure into tm_call_by_name below.
 * The Chez FFI brackets the foreign call with Sactivate_thread /
 * Sdeactivate_thread automatically, which is required by the threaded
 * kernel.
 * ---------------------------------------------------------------------- */

struct tm_proc_entry {
  void* fn;
  int   arity;
};

static std::map<string, tm_proc_entry> tm_proc_registry;
const char* current_glue_proc = NULL;

extern "C" ptr
tm_call_by_name (const char* name, ptr args) {
  /* Threaded kernel: this callback may run on a thread whose activation
     was deactivated after the previous foreign return.  Allocating tmscm
     objects (tmg_* glue constructs lists/objects) without an active
     thread corrupts the heap / trips the write barrier (S_dirty_set). */
  bool activated= Sactivate_thread () == 1;
  chez_lock lock;
  current_glue_proc = name;
  std::map<string, tm_proc_entry>::iterator it= tm_proc_registry.find (name);
  if (it == tm_proc_registry.end ()) {
    if (activated) Sdeactivate_thread ();
    return Sboolean (0);
  }
  void* fn= it->second.fn;
  int   arity= it->second.arity;

  ptr a[10];
  int n= 0;
  while (Spairp (args) && n < 10) {
    a[n++]= Scar (args);
    args= Scdr (args);
  }
  if (n != arity) return Sboolean (0);

  union {
    void* from;
    tmscm (*to0) ();
    tmscm (*to1) (tmscm);
    tmscm (*to2) (tmscm, tmscm);
    tmscm (*to3) (tmscm, tmscm, tmscm);
    tmscm (*to4) (tmscm, tmscm, tmscm, tmscm);
    tmscm (*to5) (tmscm, tmscm, tmscm, tmscm, tmscm);
    tmscm (*to6) (tmscm, tmscm, tmscm, tmscm, tmscm, tmscm);
    tmscm (*to7) (tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm);
    tmscm (*to8) (tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm);
    tmscm (*to9) (tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm);
    tmscm (*to10)(tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm);
  } cast;
  cast.from= fn;

  /* C++ glue functions throw std::string on failure (e.g. "no current
     editor"); through the FFI such an exception would escape into the
     kernel and abort the process. Contain it and return the Guile-style
     error pair (tag . (msg)) that TeXmacs Scheme code already handles. */
  try {
    switch (arity) {
      case 0: return cast.to0 ();
      case 1: return cast.to1 (a[0]);
      case 2: return cast.to2 (a[0], a[1]);
      case 3: return cast.to3 (a[0], a[1], a[2]);
      case 4: return cast.to4 (a[0], a[1], a[2], a[3]);
      case 5: return cast.to5 (a[0], a[1], a[2], a[3], a[4]);
      case 6: return cast.to6 (a[0], a[1], a[2], a[3], a[4], a[5]);
      case 7: return cast.to7 (a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
      case 8: return cast.to8 (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
      case 9: return cast.to9 (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
      case 10: return cast.to10 (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]);
      default: return Sboolean (0);
    }
  }
  catch (const std::string& e) {
    if (activated) Sdeactivate_thread ();
    return Scons (Sboolean (1),
                  Scons (Sstring_of_length (e.c_str (), (iptr) e.size ()), tm_null));
  }
  catch (...) {
    if (activated) Sdeactivate_thread ();
    return Scons (Sboolean (1), Scons (Sstring_of_length ("<exception>", 11), tm_null));
  }
  /* normal path */
}

/* Evaluate a string of Scheme code in the top-level environment.
   Used for the initialization code and for installing procedures.
   NOTE: init_prg contains MANY top-level forms; read-eval must loop
   until eof -- a single read would silently define only the first one
   (and Stop_level_value later hands back 0x1e, the unbound marker,
   which detonates at the first call). */
static ptr
eval_string_raw (const char* s) {
  ptr open_proc= Stop_level_value (Sstring_to_symbol ("open-input-string"));
  ptr read_proc= Stop_level_value (Sstring_to_symbol ("read"));
  ptr eval_proc= Stop_level_value (Sstring_to_symbol ("eval"));
  ptr env_proc= Stop_level_value (Sstring_to_symbol ("interaction-environment"));
  ptr str= Sstring (s);
  Slock_object (str);
  ptr port= Scall1 (open_proc, str);
  Slock_object (port);
  ptr env= Scall0 (env_proc);
  ptr r= Svoid;
  while (true) {
    ptr form= Scall1 (read_proc, port);
    if (Seof_objectp (form)) break;
    r= Scall2 (eval_proc, form, env);
  }
  Sunlock_object (port);
  Sunlock_object (str);
  return r;
}

void
chez_install_procedure (const char* name, void* fn, int arity) {
  chez_lock lock;
  tm_proc_registry[name]= tm_proc_entry { fn, arity };
  /* define (name . args) as a call into the registry */
  string def= "(define " * string (name) *
              " (lambda args (tm-register-guardian! (tm-call-by-name \"" * string (name) * "\" args))))";
  c_string _def (def);
  ptr ok= Scall1 (tm_install_guarded, Sstring (_def));
  if (ok == Sfalse) {
    fprintf (stderr, "CHEZDBG: INSTALL FAILED: %s\n", name);
    fflush (stderr);
  }
}

/* ------------------------------------------------------------------------
 * Evaluation and calls
 * ---------------------------------------------------------------------- */

tmscm
eval_scheme_file (string file) {
  chez_lock lock;
  chez_activate activate;
  c_string _file (file);
  fprintf (stderr, "CHEZDBG: eval_scheme_file %s\n", (const char*) _file);
  fflush (stderr);
  ptr r= Scall1 (tm_load_file_proc, Sstring_of_length (_file, (iptr) N (file)));
  fprintf (stderr, "CHEZDBG: eval_scheme_file done\n");
  fflush (stderr);
  return r;
}

tmscm
eval_scheme (string s) {
  chez_lock lock;
  chez_activate activate;
  c_string _s (s);
  return Scall1 (tm_eval_string_proc, Sstring_of_length (_s, (iptr) N (s)));
}

tmscm
call_scheme (tmscm fun) {
  chez_lock lock;
  chez_activate activate;
  return Scall2 (tm_apply_proc, fun, tmscm_null ());
}

tmscm
call_scheme (tmscm fun, tmscm a1) {
  chez_lock lock;
  chez_activate activate;
  return Scall2 (tm_apply_proc, fun, Scons (a1, tmscm_null ()));
}

tmscm
call_scheme (tmscm fun, tmscm a1, tmscm a2) {
  chez_lock lock;
  chez_activate activate;
  return Scall2 (tm_apply_proc, fun, Scons (a1, Scons (a2, tmscm_null ())));
}

tmscm
call_scheme (tmscm fun, tmscm a1, tmscm a2, tmscm a3) {
  chez_lock lock;
  chez_activate activate;
  return Scall2 (tm_apply_proc, fun,
                 Scons (a1, Scons (a2, Scons (a3, tmscm_null ()))));
}

tmscm
call_scheme (tmscm fun, tmscm a1, tmscm a2, tmscm a3, tmscm a4) {
  chez_lock lock;
  chez_activate activate;
  return Scall2 (tm_apply_proc, fun,
                 Scons (a1, Scons (a2, Scons (a3, Scons (a4, tmscm_null ())))));
}

tmscm
call_scheme (tmscm fun, array<tmscm> a) {
  chez_lock lock;
  chez_activate activate;
  tmscm l= tmscm_null ();
  for (int i= N (a) - 1; i >= 0; i--) l= Scons (a[i], l);
  return Scall2 (tm_apply_proc, fun, l);
}

/* ------------------------------------------------------------------------
 * Dialect and initialization
 * ---------------------------------------------------------------------- */

string
scheme_dialect () {
  return "chez";
}

static void
custom_init (void) {
  /* called by Sbuild_heap before loading the boot files */
}

#ifndef CHEZ_BOOT_DIR
#define CHEZ_BOOT_DIR ""
#endif

static string
boot_dir () {
  const char* env= getenv ("SCHEMEHEAPDIRS");
  if (env != NULL && env[0] != '\0') return env;
  return CHEZ_BOOT_DIR;
}

static bool s_has_texmacs_boot = false;

bool
chez_has_boot () {
  return s_has_texmacs_boot;
}

void
start_scheme (int argc, char** argv, void (*call_back) (int, char**)) {
  Sscheme_init (NULL);
  string dir= boot_dir ();
  if (N (dir) > 0 && dir[N (dir) - 1] != '/') dir= dir * "/";
  Sregister_boot_file (c_string (dir * "petite.boot"));
  Sregister_boot_file (c_string (dir * "scheme.boot"));

  bool is_compile_modules = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp (argv[i], "-compile-modules") == 0 ||
        strcmp (argv[i], "-recompile-modules") == 0) {
      is_compile_modules = true;
      break;
    }
  }

  if (!is_compile_modules) {
    string texmacs_boot = "";
    const char* env_boot = getenv ("TEXMACS_BOOT_FILE");
    if (env_boot != NULL && env_boot[0] != '\0' && exists (url (env_boot))) {
      texmacs_boot = env_boot;
    }

    if (N (texmacs_boot) > 0) {
      char resolved[PATH_MAX];
      if (realpath (c_string (texmacs_boot), resolved) != NULL) {
        texmacs_boot = string (resolved);
      }
      Sregister_boot_file (c_string (texmacs_boot));
      s_has_texmacs_boot = true;
      fprintf (stderr, "Chez Scheme: booting from AOT image %s\n", (char*) c_string (texmacs_boot));
    }
  }

  Sbuild_heap (argv[0], custom_init);
  if (call_back != NULL) call_back (argc, argv);
}

static const char* init_prg=
  "(define tmscm-null '())\n"
  "(define tm-blackbox-guardian (make-guardian))\n"
  "(define (tm-register-guardian! x)\n"
  "  (cond ((box? x)\n"
  "         (if (and (top-level-bound? 'blackbox?) (blackbox? x))\n"
  "             (tm-blackbox-guardian x))\n"
  "         x)\n"
  "        ((pair? x)\n"
  "         (tm-register-guardian! (car x))\n"
  "         (tm-register-guardian! (cdr x))\n"
  "         x)\n"
  "        (else x)))\n"
  "(define tm-user-env (interaction-environment))\n"
  "\n"
  "(define (display-to-string obj)\n"
  "  (call-with-string-output-port\n"
  "    (lambda (port) (display obj port))))\n"
  "(define (object->string obj)\n"
  "  (call-with-string-output-port\n"
  "    (lambda (port) (write obj port))))\n"
  "(define (texmacs-version) \"" TEXMACS_VERSION "\")\n"
  "(define object-stack '(()))\n"
  "\n"
  /* Chez's own condition messages are format strings; capture the kernel
     format before the progs shims can rebind it so that messages are
     rendered with their irritants. */
  "(define tm-format format)\n"
  "(define (tm-safe-irritants e)\n"
  "  (guard (_ (else '()))\n"
  "    (cond ((syntax-violation? e)\n"
  "           (list (syntax-violation-form e) (syntax-violation-subform e)))\n"
  "          ((condition? e) (condition-irritants e))\n"
  "          (else '()))))\n"
  "(define (tm-error-message e)\n"
  "  (cond ((condition? e)\n"
  "         (let ((m (condition-message e)) (irr (tm-safe-irritants e)))\n"
  "           (if (pair? irr)\n"
  "               (guard (_ (else m)) (apply tm-format m irr))\n"
  "               m)))\n"
  "        (else (call-with-string-output-port\n"
  "                (lambda (p) (display e p))))))\n"
  "\n"
  "(define (tm-eval-string s)\n"
  "  (guard (e (else (begin"
  "    (display (list 'EVAL-ERROR s (tm-error-message e)"
  "                   (tm-safe-irritants e)))"
  "    (newline)"
  "    (cons #t (list (tm-error-message e))))))\n"
  "    (let ((x (read (open-input-string s))))\n"
  "      (if (eof-object? x) x (eval x tm-user-env)))))\n"
  "\n"
  "(define (tm-current-eval-env)\n"
  "  (if (top-level-bound? 'current-module-env)\n"
  "      (current-module-env)\n"
  "      tm-user-env))\n"
  "(define (tm-collect-keywords x acc)\n"
  "  (cond ((and (symbol? x)\n"
  "              (let ((s (symbol->string x)))\n"
  "                (and (> (string-length s) 0)\n"
  "                     (char=? (string-ref s 0) #\\:))))\n"
  "         (if (member x acc) acc (cons x acc)))\n"
  "        ((pair? x) (tm-collect-keywords (car x)\n"
  "                     (tm-collect-keywords (cdr x) acc)))\n"
  "        (else acc)))\n"
  "(define (tm-bind-keywords x)\n"
  "  (let ((env (tm-current-eval-env))\n"
  "        (ienv (interaction-environment)))\n"
  "    (for-each\n"
  "      (lambda (k)\n"
  "        (if (not (top-level-bound? k env))\n"
  "            (define-top-level-value k k env))\n"
  "        (if (not (top-level-bound? k ienv))\n"
  "            (define-top-level-value k k ienv)))\n"
  "      (tm-collect-keywords x '()))))\n"
  "(define (tm-form-diagnose f i x e)\n"
  "    ;; verbose one-screen post-mortem for a persistently failing form\n"
  "  (display (list 'FORM-STILL-FAILS f i\n"
  "                 (tm-error-message e)\n"
  "                 (if (pair? x) (car x) 'atom)\n"
  "                 (if (who-condition? e) (condition-who e) 'no-who)\n"
  "                 (tm-safe-irritants e)))\n"
  "  (newline)\n"
  "  (guard (e2 (else (begin (display (list 'expand-failed)) (newline))))\n"
  "    (let ((expansion (expand x)))\n"
  "      (if (pair? expansion)\n"
  "          (let ((str (object->string expansion)))\n"
  "            (display (substring str 0 (min 200 (string-length str)))))\n"
  "          (display expansion)))\n"
  "    (newline)))\n"
  "(define (tm-read-all-forms port)\n"
  "  (let loop ((acc '()))\n"
  "    (let ((x (read port)))\n"
  "      (if (eof-object? x)\n"
  "          (reverse acc)\n"
  "          (loop (cons x acc))))))\n"
  "(define (tm-compile-eval expr env)\n"
  "  (let ((res (compile expr env)))\n"
  "    (if (procedure? res) (res) res)))\n"
  "(define (tm-load-forms-itemized f forms)\n"
  "  (let loop ((pending-forms forms) (i 0) (retry '()))\n"
  "    (if (null? pending-forms)\n"
  "        (let nloop ((pending (reverse retry)) (still 0))\n"
  "          (if (null? pending)\n"
  "              (if (> still 0)\n"
  "                  (begin\n"
  "                    (display (list 'LOAD-SUMMARY f i still))\n"
  "                    (newline)))\n"
  "              (let* ((ix (car pending))\n"
  "                     (i2 (car ix))\n"
  "                     (x2 (cdr ix))\n"
  "                     (ok2 (guard (e2 (else (tm-form-diagnose f i2 x2 e2) #f))\n"
  "                            (begin\n"
  "                              (tm-bind-keywords x2)\n"
  "                              (tm-compile-eval x2 (tm-current-eval-env))\n"
  "                              #t))))\n"
  "                (nloop (cdr pending)\n"
  "                       (if ok2 still (+ still 1))))))\n"
  "        (let* ((x (car pending-forms))\n"
  "               (ok (guard (e (else #f))\n"
  "                     (begin\n"
  "                       (tm-bind-keywords x)\n"
  "                       (tm-compile-eval x (tm-current-eval-env))\n"
  "                       #t))))\n"
  "          (loop (cdr pending-forms)\n"
  "                (+ i 1)\n"
  "                (if ok retry (cons (cons i x) retry)))))))\n"
  "(define (tm-so-candidates f)\n"
  "  (let* ((len (string-length f))\n"
  "         (is-so? (and (>= len 3) (string=? (substring f (- len 3) len) \".so\")))\n"
  "         (is-scm? (and (>= len 4) (string=? (substring f (- len 4) len) \".scm\"))))\n"
  "    (cond (is-so? (list f))\n"
  "          (is-scm?\n"
  "           (let* ((local-so (string-append (substring f 0 (- len 4)) \".so\"))\n"
  "                  (progs-idx\n"
  "                   (let loop ((i (- len 7)))\n"
  "                     (cond ((< i 0) #f)\n"
  "                           ((string=? (substring f i (+ i 7)) \"/progs/\") (+ i 7))\n"
  "                           (else (loop (- i 1))))))\n"
  "                  (rel-so (if progs-idx\n"
  "                              (string-append (substring f progs-idx (- len 4)) \".so\")\n"
  "                              #f))\n"
  "                  (cache-dirs (list\n"
  "                                (getenv \"TEXMACS_CACHE_PATH\")\n"
  "                                \"build-texmacos/boot\"\n"
  "                                \"../build-texmacos/boot\"\n"
  "                                \"build-texmacos/boot-cache\"\n"
  "                                \"../build-texmacos/boot-cache\"\n"
  "                                (let ((bd (getenv \"TEXMACS_BUILD_DIR\")))\n"
  "                                  (if bd (string-append bd \"/boot\") #f))\n"
  "                                (let ((bd (getenv \"TEXMACS_BUILD_DIR\")))\n"
  "                                  (if bd (string-append bd \"/boot-cache\") #f)))))\n"
  "             (cons local-so\n"
  "                   (if rel-so\n"
  "                       (let loop ((dirs cache-dirs) (acc '()))\n"
  "                         (if (null? dirs)\n"
  "                             (reverse acc)\n"
  "                             (let ((d (car dirs)))\n"
  "                               (loop (cdr dirs)\n"
  "                                     (if d (cons (string-append d \"/\" rel-so) acc) acc)))))\n"
  "                       '()))))\n"
  "          (else '()))))\n"
  "(define (tm-find-so-file f)\n"
  "  (let loop ((cands (tm-so-candidates f)))\n"
  "    (if (null? cands)\n"
  "        #f\n"
  "        (let ((cand (car cands)))\n"
  "          (if (and (file-exists? cand)\n"
  "                   (or (not (file-exists? f))\n"
  "                       (time>=? (file-modification-time cand)\n"
  "                                (file-modification-time f))))\n"
  "              cand\n"
  "              (loop (cdr cands)))))))\n"
  "(define (tm-load-from-source f)\n"
  "  (display (list 'LOAD-START f))\n"
  "  (newline)\n"
  "  (let* ((port (open-input-file f))\n"
  "         (forms (dynamic-wind\n"
  "                  (lambda () #f)\n"
  "                  (lambda () (tm-read-all-forms port))\n"
  "                  (lambda () (close-port port)))))\n"
  "    (if (null? forms)\n"
  "        #t\n"
  "        (let ((has-header? (and (pair? (car forms))\n"
  "                                (eq? (caar forms) 'texmacs-module))))\n"
  "          (if has-header?\n"
  "              (guard (e2 (else\n"
  "                          (display (list 'LOAD-BATCH-FALLBACK f (tm-error-message e2)))\n"
  "                          (newline)\n"
  "                          (tm-load-forms-itemized f forms)))\n"
  "                (let ((hdr (car forms)))\n"
  "                  (tm-bind-keywords hdr)\n"
  "                  (tm-compile-eval hdr (tm-current-eval-env)))\n"
  "                (let ((body (cdr forms)))\n"
  "                  (if (null? body)\n"
  "                      #t\n"
  "                      (let ((env (tm-current-eval-env)))\n"
  "                        (tm-bind-keywords (cons 'begin body))\n"
  "                        (tm-compile-eval (cons 'begin body) env)))))\n"
  "              (tm-load-forms-itemized f forms))))))\n"
  "(define (tm-load-probe f) (noop))\n"
  "(define (tm-load-file f)\n"
  "  (guard (e (else (begin\n"
  "             (display-condition e)\n"
  "             (newline)\n"
  "             (tm-backtrace e)\n"
  "             (display (list 'LOAD-ERROR f (tm-error-message e)\n"
  "                            (tm-safe-irritants e)))\n"
  "             (newline)\n"
  "             (cons #t (list (tm-error-message e))))))\n"
  "    (load f)))\n"
  "\n"
  "(define (tm-backtrace c)\n"
  "  (guard (e (else (display (list 'BT-ERR (tm-error-message e))) (newline)))\n"
  "    (if (continuation-condition? c)\n"
  "        (let* ((k (condition-continuation c))\n"
  "               (ko (inspect/object k)))\n"
  "          (let loop ((i 0))\n"
  "            (guard (e (else #f))\n"
  "              (let* ((link (ko 'link* i))\n"
  "                     (co (guard (e (else #f)) (link 'code)))\n"
  "                     (name (and co (guard (e (else #f)) (co 'name))))\n"
  "                     (so (guard (e (else #f)) (link 'source)))\n"
  "                     (sval (and so (guard (e (else #f)) (so 'value))))\n"
  "                     (sp (guard (e (else #f))\n"
  "                           (call-with-values (lambda () (link 'source-path))\n"
  "                             (lambda v v)))))\n"
  "                (display (list 'FRAME i 'CODE name 'SRC sval 'LOC sp))\n"
  "                (newline)\n"
  "                (when (< i 25) (loop (+ i 1)))))))\n"
  "        (display \"no continuation in condition\\n\"))))\n"
  "\n"
  "(define (tm-apply fun args)\n"
  "  (guard (e (else (begin (display (list 'TM-APPLY-ERROR (tm-error-message e) 'FUN: fun 'ARGS: args)) (newline) (display-condition e) (newline) (tm-backtrace e) (cons #t (list (tm-error-message e))))))\n"
  "    (let ((proc (if (symbol? fun)\n"
  "                    (let* ((env (tm-current-eval-env))\n"
  "                           (user-env (and (top-level-bound? 'texmacs-user)\n"
  "                                          (tm-module-env texmacs-user))))\n"
  "                      (cond ((top-level-bound? fun env)\n"
  "                             (top-level-value fun env))\n"
  "                            ((and user-env (top-level-bound? fun user-env))\n"
  "                             (top-level-value fun user-env))\n"
  "                            (else\n"
  "                             (top-level-value fun))))\n"
  "                    fun)))\n"
  "      (apply proc args))))\n"
  "\n"
  "(define tm-call-by-name\n"
  "  (foreign-procedure \"tm-call-by-name\" (string scheme-object) scheme-object))\n";

void
initialize_scheme () {
  chez_lock lock;
  fprintf (stderr, "CHEZDBG: Sforeign_symbol\n"); fflush (stderr);
  Sforeign_symbol ("tm-call-by-name", (void*) tm_call_by_name);
  Sforeign_symbol ("tmscm_delete_blackbox", (void*) tmscm_delete_blackbox);
  Sforeign_symbol ("tmscm_blackbox_equal", (void*) tmscm_blackbox_equal);
  Sforeign_symbol ("tmscm_blackbox_hash", (void*) tmscm_blackbox_hash);
  fprintf (stderr, "CHEZDBG: eval init_prg\n"); fflush (stderr);
  eval_string_raw (init_prg);
  if (compile_modules_mode) {
    eval_string_raw ("(define-top-level-value 'texmacs-chez-compiling? #t)");
  }
  fprintf (stderr, "CHEZDBG: init_prg done, lookups\n"); fflush (stderr);
  /* Cache frequently-used procedures.  These ptrs live in STATIC storage,
     which Chez's collector does not scan: newly allocated objects start in
     the copying nursery and move on collection, so an unpinned handle goes
     stale as soon as enough allocation happens to trigger a minor GC.
     Slock_object pins them (they are process-lifetime, never unlocked). */
  tm_null= Stop_level_value (Sstring_to_symbol ("tmscm-null"));
  Slock_object (tm_null);
  tm_blackbox_guardian= Stop_level_value (Sstring_to_symbol ("tm-blackbox-guardian"));
  Slock_object (tm_blackbox_guardian);
  tm_eval_string_proc= Stop_level_value (Sstring_to_symbol ("tm-eval-string"));
  Slock_object (tm_eval_string_proc);
  tm_load_file_proc= Stop_level_value (Sstring_to_symbol ("tm-load-file"));
  Slock_object (tm_load_file_proc);
  tm_apply_proc= Stop_level_value (Sstring_to_symbol ("tm-apply"));
  Slock_object (tm_apply_proc);
  tm_list_pred= Stop_level_value (Sstring_to_symbol ("list?"));
  Slock_object (tm_list_pred);
  tm_equal_pred= Stop_level_value (Sstring_to_symbol ("equal?"));
  Slock_object (tm_equal_pred);
  object_stack= Stop_level_value (Sstring_to_symbol ("object-stack"));
  Slock_object (object_stack);

  fprintf (stderr, "CHEZDBG: initialize_glue\n"); fflush (stderr);
  /* Debug aid: report exactly which installed definition fails and why */
  eval_string_raw (
    "(define (tm-install-guarded def)"
    "  (guard (e (else (begin"
    "    (display (list 'install-failed (tm-error-message e)))"
    "    (newline) #f)))"
    "    (eval (read (open-input-string def)) (interaction-environment))"
    "    #t))");
  tm_install_guarded= Stop_level_value (Sstring_to_symbol ("tm-install-guarded"));
  Slock_object (tm_install_guarded);
  initialize_glue ();
  fprintf (stderr, "CHEZDBG: initialize_glue done\n"); fflush (stderr);
}
