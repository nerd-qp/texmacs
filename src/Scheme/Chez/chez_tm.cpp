
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
#include "converter.hpp"
#include "../Scheme/glue.hpp"

#include <map>
#include <mutex>
#include <string.h>
#include <cstdio>
#include <cstdlib>  /* getenv, _fullpath/_MAX_PATH on Windows */

extern bool compile_modules_mode;

/* ------------------------------------------------------------------------
 * Global engine state
 * ---------------------------------------------------------------------- */

tmscm tm_null= 0;
tmscm tm_blackbox_guardian= 0;
static ptr tm_install_proc= 0;      /* (tm-install-procedure! name)           */
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
  /* Fast C-level cycle-detecting walk using Spairp/Scdr.
     Do NOT call Scheme (Scall1 tm_list_pred) here: C++ traversal functions
     like tmscm_to_scheme_tree call tmscm_is_list while holding unpinned tmscm
     pointers on the C++ stack; entering Scheme can trigger a copying GC which
     relocates the tree and causes a crash. */
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
  if (tm_equal_pred != 0 && Sprocedurep (tm_equal_pred))
    return Sboolean_value (Scall2 (tm_equal_pred, o1, o2));
  return o1 == o2;
}

/* ------------------------------------------------------------------------
 * String and symbol conversions
 *
 * NOTE [String Encoding Duality & Raw Byte Invariant]:
 * TeXmacs C++ assumes the Scheme <-> C++ string bridge operates on raw 8-bit
 * bytes (1 Scheme character = 1 C++ byte), preserving exact byte fidelity for
 * binary assets (e.g. PNG images loaded via string-load / tmfs-load) as well
 * as Cork and raw UTF-8 byte streams.
 *
 * Do NOT use decode_from_utf8 / encode_as_utf8 here: treating raw binary bytes
 * >= 128 as UTF-8 expands them into multi-byte sequences (e.g. PNG magic 0x89
 * -> 0xC2 0x89), inflating and corrupting image data (see TODO_CHEZ.md).
 *
 * KNOWN CONSEQUENCE, deliberately kept: a Scheme character above 0xFF cannot
 * cross this bridge.  tmscm_to_string truncates it to its low byte, so
 * U+03BC mu reaches C++ as 0xBC and regtest-xmltm reports one mismatch in the
 * Bx row of latin1-chart.  Fixing that by encoding UTF-8 here breaks binary
 * round-trips through string-load / tmfs-load, so the fix has to distinguish
 * text from byte buffers at the boundary that knows which one it is holding --
 * not inside these two functions.
 * ---------------------------------------------------------------------- */

tmscm
string_to_tmscm (string s) {
  iptr n= (iptr) N (s);
  tmscm res= Smake_bytevector (n, 0);
  memcpy (Sbytevector_data (res), &s[0], n);
  return res;
}

string
tmscm_to_string (tmscm s) {
  if (Sbytevectorp (s)) {
    iptr n= Sbytevector_length (s);
    string r ((int) n);
    memcpy (&r[0], Sbytevector_data (s), n);
    return r;
  }
  FAILED ("bytevector expected in tmscm_to_string");
  return "";
}

tmscm
symbol_to_tmscm (string s) {
  c_string _s (s);
  return Sstring_to_symbol (_s);
}

string
tmscm_to_symbol (tmscm s) {
  tmscm str= Ssymbol_to_string (s);
  iptr n= Sstring_length (str);
  string r;
  for (iptr i= 0; i < n; i++)
    r << encode_as_utf8 (Sstring_ref (str, i));
  return r;
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
  blackbox* p= tm_new<blackbox> (b);
  tmscm box= Sbox (Sinteger ((iptr) p));
  if (tm_blackbox_guardian) {
    Scall1 (tm_blackbox_guardian, box);
  }
  return box;
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
 * Scheme side: boot-chez.scm defines
 *     (define (tm-install-procedure! name)
 *       (define-top-level-value (string->symbol name)
 *         (lambda args (tm-call-by-name name args)) ...))
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

struct tm_fast_proc_entry {
  const char* name;
  void*       fn;
  int         arity;
};

static tm_fast_proc_entry tm_fast_table[2048];
static int tm_fast_proc_count = 0;

#define TM_FAST_CALL_BODY(call_expr) \
  if (__builtin_expect (id < 0 || id >= tm_fast_proc_count, 0)) return Sboolean (0); \
  chez_lock lock; \
  current_glue_proc = tm_fast_table[id].name; \
  try { \
    return (call_expr); \
  } catch (const std::string& e) { \
    return Scons (Sboolean (1), \
                  Scons (Sstring_of_length (e.c_str (), (iptr) e.size ()), tm_null)); \
  } catch (...) { \
    return Scons (Sboolean (1), \
                  Scons (Sstring_of_length ("<exception>", 11), tm_null)); \
  }

extern "C" ptr tm_fast_call_0 (int id) {
  TM_FAST_CALL_BODY (((tmscm (*)()) tm_fast_table[id].fn) ())
}
extern "C" ptr tm_fast_call_1 (int id, ptr a1) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm)) tm_fast_table[id].fn) (a1))
}
extern "C" ptr tm_fast_call_2 (int id, ptr a1, ptr a2) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2))
}
extern "C" ptr tm_fast_call_3 (int id, ptr a1, ptr a2, ptr a3) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3))
}
extern "C" ptr tm_fast_call_4 (int id, ptr a1, ptr a2, ptr a3, ptr a4) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4))
}
extern "C" ptr tm_fast_call_5 (int id, ptr a1, ptr a2, ptr a3, ptr a4, ptr a5) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4, a5))
}
extern "C" ptr tm_fast_call_6 (int id, ptr a1, ptr a2, ptr a3, ptr a4, ptr a5, ptr a6) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4, a5, a6))
}
extern "C" ptr tm_fast_call_7 (int id, ptr a1, ptr a2, ptr a3, ptr a4, ptr a5, ptr a6, ptr a7) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4, a5, a6, a7))
}
extern "C" ptr tm_fast_call_8 (int id, ptr a1, ptr a2, ptr a3, ptr a4, ptr a5, ptr a6, ptr a7, ptr a8) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4, a5, a6, a7, a8))
}
extern "C" ptr tm_fast_call_9 (int id, ptr a1, ptr a2, ptr a3, ptr a4, ptr a5, ptr a6, ptr a7, ptr a8, ptr a9) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4, a5, a6, a7, a8, a9))
}
extern "C" ptr tm_fast_call_10 (int id, ptr a1, ptr a2, ptr a3, ptr a4, ptr a5, ptr a6, ptr a7, ptr a8, ptr a9, ptr a10) {
  TM_FAST_CALL_BODY (((tmscm (*)(tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm, tmscm)) tm_fast_table[id].fn) (a1, a2, a3, a4, a5, a6, a7, a8, a9, a10))
}

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

/* ------------------------------------------------------------------------
 * Scheme bootstrap
 *
 * No Scheme source lives in this file.  Everything the kernel needs on the
 * Scheme side -- tm-apply, tm-load-file, tm-eval-string, the blackbox
 * guardian, the glue installer, texmacs-version -- is defined in
 * TeXmacs/progs/kernel/boot/boot-chez.scm, which initialize_scheme() loads
 * with Chez's primitive `load' before initialize_glue() runs.
 *
 * The only Scheme knowledge retained here is the *names* of the bindings the
 * kernel caches, because Stop_level_value() has to look them up by symbol.
 * ---------------------------------------------------------------------- */

/* FAILED() takes a C string; the messages here are assembled at run time. */
static void
boot_failed (string msg) {
  c_string _msg (msg);
  fprintf (stderr, "ERROR: %s\n", (const char*) _msg);
  fflush (stderr);
  tm_throw ((const char*) _msg);
}

/* Path of the Scheme bootstrap.  init_texmacs() has already exported
   TEXMACS_PATH by the time the kernel starts, and a packaged .app sets it
   relative to the executable, so getenv is authoritative; the url() fallback
   covers a tree booted without the variable, where the path system still
   knows where the data directory is. */
static string
boot_scheme_path () {
  const char* env= getenv ("TEXMACS_PATH");
  if (env != NULL && env[0] != '\0')
    return string (env) * "/progs/kernel/boot/boot-chez.scm";
  return as_string (url ("$TEXMACS_PATH/progs/kernel/boot/boot-chez.scm"));
}

/* Evaluate a file in the interaction environment.  Chez's `load' is what we
   need here: the engine's guarded per-form loader (tm-load-file) is itself
   defined by the file being loaded. */
static void
load_scheme_file (string file) {
  ptr load_proc= Stop_level_value (Sstring_to_symbol ("load"));
  if (!Sprocedurep (load_proc))
    boot_failed ("Chez Scheme: 'load' is not bound, cannot load " * file);
  c_string _file (file);
  ptr str= Sstring_of_length (_file, (iptr) N (file));
  Slock_object (str);
  Scall1 (load_proc, str);
  Sunlock_object (str);
}

/* Look up a procedure the bootstrap defined and call it with one argument. */
static void
call_boot_proc (const char* name, ptr arg) {
  ptr proc= Stop_level_value (Sstring_to_symbol (name));
  if (!Sprocedurep (proc))
    boot_failed ("Chez Scheme: boot-chez.scm did not define " * string (name));
  Scall1 (proc, arg);
}

/* TODO: Sstring_of_length converts 'name' into a Chez Scheme Sstring by
 * treating raw 8-bit bytes as Unicode scalar values (Latin-1 mapping). If a
 * procedure name ever contained non-ASCII UTF-8 characters, this would corrupt
 * the symbol name (Sstring_utf8 or interning via Sstring_to_symbol would be needed).
 * In addition, passing an Sstring across this boundary deviates from the rule
 * that TeXmacs strings over FFI are pure bytevectors (Sbytevectorp). It is currently
 * safe only because 'name' is an internal ASCII identifier passed once to
 * (tm-install-procedure! name) to be interned with string->symbol during glue setup. */
void
chez_install_procedure (const char* name, void* fn, int arity) {
  chez_lock lock;
  int id = tm_fast_proc_count++;
  if (id >= 2048)
    FAILED ("Chez Scheme: tm_fast_table overflow");
  tm_fast_table[id]= tm_fast_proc_entry { name, fn, arity };
  tm_proc_registry[name]= tm_proc_entry { fn, arity };
  /* (tm-install-procedure! "name" id arity) defines the Scheme wrapper that forwards
     its arguments directly to tm_fast_call_N. */
  if (tm_install_proc == 0)
    FAILED ("Chez Scheme: tm-install-procedure! is not available");
  Scall3 (tm_install_proc,
          Sstring_of_length (name, (iptr) strlen (name)),
          Sinteger (id),
          Sinteger (arity));
}

/* ------------------------------------------------------------------------
 * Evaluation and calls
 * ---------------------------------------------------------------------- */

tmscm
eval_scheme_file (string file) {
  chez_lock lock;
  chez_activate activate;
  c_string _file (file);
  return Scall1 (tm_load_file_proc, Sstring_utf8 (_file, (iptr) N (file)));
}

tmscm
eval_scheme (string s) {
  chez_lock lock;
  chez_activate activate;
  c_string _s (s);
  return Scall1 (tm_eval_string_proc, Sstring_utf8 (_s, (iptr) N (s)));
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
#if defined(_WIN32)
      /* MinGW provides no realpath(); _fullpath() is the CRT equivalent and
         _MAX_PATH is the buffer size it expects. */
      char resolved[_MAX_PATH];
      if (_fullpath (resolved, c_string (texmacs_boot), _MAX_PATH) != NULL) {
        texmacs_boot = string (resolved);
      }
#else
      char resolved[PATH_MAX];
      if (realpath (c_string (texmacs_boot), resolved) != NULL) {
        texmacs_boot = string (resolved);
      }
#endif
      Sregister_boot_file (c_string (texmacs_boot));
      s_has_texmacs_boot = true;
      fprintf (stderr, "Chez Scheme: booting from AOT image %s\n", (char*) c_string (texmacs_boot));
    }
  }

  Sbuild_heap (argv[0], custom_init);
  if (call_back != NULL) call_back (argc, argv);
}

/* ------------------------------------------------------------------------
 * Initialization
 * ---------------------------------------------------------------------- */

void
initialize_scheme () {
  chez_lock lock;

  /* Foreign entry points first: boot-chez.scm binds each of them with
     foreign-procedure while it is being loaded, and Chez resolves the symbol
     at that point. */
  Sforeign_symbol ("tm-call-by-name", (void*) tm_call_by_name);
  Sforeign_symbol ("tm_fast_call_0", (void*) tm_fast_call_0);
  Sforeign_symbol ("tm_fast_call_1", (void*) tm_fast_call_1);
  Sforeign_symbol ("tm_fast_call_2", (void*) tm_fast_call_2);
  Sforeign_symbol ("tm_fast_call_3", (void*) tm_fast_call_3);
  Sforeign_symbol ("tm_fast_call_4", (void*) tm_fast_call_4);
  Sforeign_symbol ("tm_fast_call_5", (void*) tm_fast_call_5);
  Sforeign_symbol ("tm_fast_call_6", (void*) tm_fast_call_6);
  Sforeign_symbol ("tm_fast_call_7", (void*) tm_fast_call_7);
  Sforeign_symbol ("tm_fast_call_8", (void*) tm_fast_call_8);
  Sforeign_symbol ("tm_fast_call_9", (void*) tm_fast_call_9);
  Sforeign_symbol ("tm_fast_call_10", (void*) tm_fast_call_10);
  Sforeign_symbol ("tmscm_delete_blackbox", (void*) tmscm_delete_blackbox);
  Sforeign_symbol ("tmscm_blackbox_equal", (void*) tmscm_blackbox_equal);
  Sforeign_symbol ("tmscm_blackbox_hash", (void*) tmscm_blackbox_hash);

  string boot= boot_scheme_path ();
  if (!exists (url (boot)))
    boot_failed ("Chez Scheme: bootstrap file not found: " * boot);
  fprintf (stderr, "Chez Scheme: loading %s\n", (char*) c_string (boot));
  fflush (stderr);
  load_scheme_file (boot);
  call_boot_proc ("tm-set-compiling-mode!",
                  Sboolean (compile_modules_mode ? 1 : 0));

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
  tm_install_proc= Stop_level_value (Sstring_to_symbol ("tm-install-procedure!"));
  Slock_object (tm_install_proc);

  fprintf (stderr, "Chez Scheme: initialize_glue\n"); fflush (stderr);
  initialize_glue ();
}

