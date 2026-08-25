/******************************************************************************
 * MODULE     : chez_tm.hpp
 * DESCRIPTION: Interface to the Chez Scheme kernel (C API)
 * COPYRIGHT  : (C) 2026
 *******************************************************************************
 * This software falls under the GNU general public license version 3 or later.
 * It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
 * in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
 ******************************************************************************/

#ifndef CHEZ_TM_H
#define CHEZ_TM_H

#include "tm_configure.hpp"
#include "blackbox.hpp"
#include "array.hpp"

/* The Chez Scheme kernel API header ("scheme.h").  The include directory
   must be supplied by the build system (e.g. -I/usr/lib/csv<version>/<mach>).
   "scheme.h" defines the kernel types (ptr, iptr, uptr), the accessor
   macros (Scar, Scdr, Sstring_ref, ...) and the exported functions
   (Sscheme_init, Sregister_boot_file, Sbuild_heap, Scall0..Scall3, ...).
   See examples/crepl.c in the Chez Scheme distribution for the standard
   embedding pattern that we follow here. */
#include "scheme.h"

/* ------------------------------------------------------------------------
 * The engine-specific type: a Chez Scheme object is a kernel "ptr".
 * Everything which depends on the Scheme engine should be in this file
 * and in chez_tm.cpp, mirroring the structure of guile_tm.hpp/cpp.
 * ---------------------------------------------------------------------- */

typedef ptr tmscm;

/* -- global engine state (defined in chez_tm.cpp) ------------------------ */

extern tmscm tm_null;              /* the value of '()                        */
extern tmscm tm_blackbox_tag;      /* the symbol 'tmscm-blackbox              */
extern tmscm tm_eval_string_proc;  /* (tm-eval-string s)                      */
extern tmscm tm_load_file_proc;    /* (tm-load-file file)                     */
extern tmscm tm_apply_proc;        /* (tm-apply fun args-list)                */
extern tmscm tm_list_pred;         /* list?                                    */
extern tmscm tm_equal_pred;        /* equal?                                   */

/* -- basic predicates and constructors (all inline, kernel macros) -------- */

inline tmscm tmscm_null () { return tm_null; }
inline tmscm tmscm_true () { return Sboolean (1); }
inline tmscm tmscm_false () { return Sboolean (0); }

inline bool tmscm_is_null (tmscm obj) { return Snullp (obj); }
inline bool tmscm_is_pair (tmscm obj) { return Spairp (obj); }
inline bool tmscm_is_bool (tmscm obj) { return Sbooleanp (obj); }
inline bool tmscm_is_int (tmscm obj)   { return Sfixnump (obj) || Sbignump (obj); }
inline bool tmscm_is_double (tmscm obj) { return Sflonump (obj); }
inline bool tmscm_is_string (tmscm obj) { return Sstringp (obj); }
inline bool tmscm_is_symbol (tmscm obj) { return Ssymbolp (obj); }
bool tmscm_is_list (tmscm obj);   /* needs a call to list?; defined in cpp  */
bool tmscm_is_equal (tmscm o1, tmscm o2); /* needs equal?; defined in cpp   */

inline tmscm tmscm_cons (tmscm obj1, tmscm obj2) { return Scons (obj1, obj2); }
inline tmscm tmscm_car (tmscm obj) { return Scar (obj); }
inline tmscm tmscm_cdr (tmscm obj) { return Scdr (obj); }
inline tmscm tmscm_caar (tmscm obj) { return Scar (Scar (obj)); }
inline tmscm tmscm_cadr (tmscm obj) { return Scar (Scdr (obj)); }
inline tmscm tmscm_cdar (tmscm obj) { return Scdr (Scar (obj)); }
inline tmscm tmscm_cddr (tmscm obj) { return Scdr (Scdr (obj)); }
inline tmscm tmscm_caddr (tmscm obj) { return Scar (Scdr (Scdr (obj))); }
inline tmscm tmscm_cadddr (tmscm obj) { return Scar (Scdr (Scdr (Scdr (obj)))); }

inline void tmscm_set_car (tmscm a, tmscm b) { Sset_car (a, b); }
inline void tmscm_set_cdr (tmscm a, tmscm b) { Sset_cdr (a, b); }

/* -- conversions between C++ and Scheme values ---------------------------- */

inline tmscm bool_to_tmscm (bool b) { return Sboolean (b); }
inline tmscm int_to_tmscm (int i) { return Sinteger (i); }
inline tmscm long_to_tmscm (long l) { return Sinteger ((iptr) l); }
inline tmscm double_to_tmscm (double d) { return Sflonum (d); }

tmscm string_to_tmscm (string s);
tmscm symbol_to_tmscm (string s);
extern const char* current_glue_proc;
inline bool tmscm_to_bool (tmscm obj) { return Sboolean_value (obj); }
inline int  tmscm_to_int (tmscm obj)  {
  if (!Sfixnump (obj) && !Sbignump (obj)) {
    fprintf (stderr, "CHEZDBG: tmscm_to_int in %s: non-int!\n", current_glue_proc ? current_glue_proc : "unknown"); fflush (stderr);
  }
  return (int) Sinteger_value (obj);
}
inline unsigned int tmscm_to_uint (tmscm obj) { return (unsigned int) Sunsigned_value (obj); }
inline double tmscm_to_double (tmscm obj) { return Sflonum_value (obj); }
string tmscm_to_string (tmscm obj);
string tmscm_to_symbol (tmscm obj);

/* -- blackboxes (opaque C++ values kept inside Scheme objects) ------------ */
/* We represent a blackbox as (cons 'tmscm-blackbox <integer token>), where
   the token is the address of a heap allocated copy of the C++ blackbox.
   The copies are intentionally never freed (documented limitation): the
   Chez kernel C API exposes no finalizer hook, unlike Guile smobs or the
   s7 branch's c-objects.  Equality of two blackboxes is identity of the
   token, i.e. two independently converted copies of the same C++ value are
   NOT equal?.  This matches the needs of the current TeXmacs glue, where
   blackboxes are mostly used opaquely. */

bool tmscm_is_blackbox (tmscm obj);
tmscm blackbox_to_tmscm (blackbox b);
blackbox tmscm_to_blackbox (tmscm obj);

/* -- evaluation and calls -------------------------------------------------- */

tmscm eval_scheme_file (string name);
tmscm eval_scheme (string s);
tmscm call_scheme (tmscm fun);
tmscm call_scheme (tmscm fun, tmscm a1);
tmscm call_scheme (tmscm fun, tmscm a1, tmscm a2);
tmscm call_scheme (tmscm fun, tmscm a1, tmscm a2, tmscm a3);
tmscm call_scheme (tmscm fun, tmscm a1, tmscm a2, tmscm a3, tmscm a4);
tmscm call_scheme (tmscm fun, array<tmscm> a);

/* -- registering C++ procedures as Scheme procedures ---------------------- */

typedef tmscm (*FN)();

template<typename T> inline FN
tmscm_as_fn (T func) {
  union {
    T from;
    FN to;
  } cast = { func };
  return cast.to;
}

void chez_install_procedure (const char* name, void* fn, int arity);

#define tmscm_install_procedure(name, func, args, p0, p1) \
  chez_install_procedure (name, (void*) tmscm_as_fn (func), args)

#define TMSCM_ASSERT(_cond, _arg, _pos, _subr) (void) 0

#define TMSCM_ARG1 1
#define TMSCM_ARG2 2
#define TMSCM_ARG3 3
#define TMSCM_ARG4 4
#define TMSCM_ARG5 5
#define TMSCM_ARG6 6
#define TMSCM_ARG7 7
#define TMSCM_ARG8 8
#define TMSCM_ARG9 9
#define TMSCM_ARG10 10

#define TMSCM_UNSPECIFIED Svoid

string scheme_dialect ();
bool chez_has_boot ();

#endif /* defined CHEZ_TM_H */
