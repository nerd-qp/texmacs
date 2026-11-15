/******************************************************************************
* MODULE     : glue_overrides.cpp
* DESCRIPTION: Early-boot safe glue implementations for Chez Scheme
* COPYRIGHT  : (C) 2026
*******************************************************************************
* This software falls under the GNU general public license version 3 or later.
* It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
* in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
******************************************************************************/

#include "chez_tm.hpp"
#include "Graphics/Fonts/font.hpp"
#include "Texmacs/server.hpp"
#include "Texmacs/tm_server.hpp"
#include "../Scheme/glue.hpp"

/* ---------------------------------------------------------------------------
 * Early-boot safe font rules
 *
 * During Sbuild_heap(), modules like fonts-composite.scm call set-font-rules at
 * top level. At that early point, the_server is NULL, but font_rule(l, r)
 * directly modifies the static global font table (src/Graphics/Fonts/find_font.cpp)
 * without needing server state.
 * ------------------------------------------------------------------------- */

tmscm
tmg_chez_set_font_rules (tmscm a1) {
  scheme_tree in1 = tmscm_to_scheme_tree (a1);
  int n = arity (in1);
  for (int i = 0; i < n; i++) {
    if (arity (in1[i]) == 2) {
      font_rule ((tree) in1[i][0], (tree) in1[i][1]);
    }
  }
  return TMSCM_UNSPECIFIED;
}

/* ---------------------------------------------------------------------------
 * Early-boot safe variant keys
 *
 * prefix-kbd.scm calls (set-variant-keys "tab" "S-tab") at top level. If the
 * server is not yet started, we buffer the keys and replay them once
 * initialize_scheme() runs with an active server.
 * ------------------------------------------------------------------------- */

static string s_pending_var   = "";
static string s_pending_unvar = "";
static bool   s_has_pending_variant_keys = false;

static string s_pending_printing_command = "";
static bool   s_has_pending_printing_command = false;

static string s_pending_paper_type = "";
static bool   s_has_pending_paper_type = false;

static string s_pending_printer_dpi = "";
static bool   s_has_pending_printer_dpi = false;

tmscm
tmg_chez_set_variant_keys (tmscm a1, tmscm a2) {
  string var   = tmscm_to_string (a1);
  string unvar = tmscm_to_string (a2);

  if (is_server_started ()) {
    get_server () -> set_variant_keys (var, unvar);
  } else {
    s_pending_var = var;
    s_pending_unvar = unvar;
    s_has_pending_variant_keys = true;
  }
  return TMSCM_UNSPECIFIED;
}

tmscm
tmg_chez_set_printing_command (tmscm a1) {
  string cmd = tmscm_to_string (a1);
  if (is_server_started ()) {
    get_server () -> set_printing_command (cmd);
  } else {
    s_pending_printing_command = cmd;
    s_has_pending_printing_command = true;
  }
  return TMSCM_UNSPECIFIED;
}

tmscm
tmg_chez_set_printer_paper_type (tmscm a1) {
  string paper = tmscm_to_string (a1);
  if (is_server_started ()) {
    get_server () -> set_printer_page_type (paper);
  } else {
    s_pending_paper_type = paper;
    s_has_pending_paper_type = true;
  }
  return TMSCM_UNSPECIFIED;
}

tmscm
tmg_chez_set_printer_dpi (tmscm a1) {
  string dpi = tmscm_to_string (a1);
  if (is_server_started ()) {
    get_server () -> set_printer_dpi (dpi);
  } else {
    s_pending_printer_dpi = dpi;
    s_has_pending_printer_dpi = true;
  }
  return TMSCM_UNSPECIFIED;
}

void
replay_early_variant_keys () {
  if (is_server_started ()) {
    if (s_has_pending_variant_keys) {
      get_server () -> set_variant_keys (s_pending_var, s_pending_unvar);
      s_has_pending_variant_keys = false;
    }
    if (s_has_pending_printing_command) {
      get_server () -> set_printing_command (s_pending_printing_command);
      s_has_pending_printing_command = false;
    }
    if (s_has_pending_paper_type) {
      get_server () -> set_printer_page_type (s_pending_paper_type);
      s_has_pending_paper_type = false;
    }
    if (s_has_pending_printer_dpi) {
      get_server () -> set_printer_dpi (s_pending_printer_dpi);
      s_has_pending_printer_dpi = false;
    }
  }
}
