/******************************************************************************
 * MODULE     : scheme_engine.hpp
 * DESCRIPTION: Selection of the embedded Scheme engine implementation
 * COPYRIGHT  : (C) 2026
 *******************************************************************************
 * This software falls under the GNU general public license version 3 or later.
 * It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
 * in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
 ******************************************************************************/

#ifndef SCHEME_ENGINE_H
#define SCHEME_ENGINE_H

/* The build system selects the embedded Scheme engine with the
   TEXMACS_ENGINE_CHEZ define (see CMakeLists.txt, SCHEME_IMPL option).
   The default is Guile. */

#ifdef TEXMACS_ENGINE_CHEZ
#include "../Chez/chez_tm.hpp"
#else
#include "../Guile/guile_tm.hpp"
#endif

#endif /* defined SCHEME_ENGINE_H */
