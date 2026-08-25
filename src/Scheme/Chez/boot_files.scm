;;; boot_files.scm -- Topological load order of core TeXmacs modules
;;;
;;; NOTE ON ORDERING & DEPENDENCY TOPOLOGY:
;;; ---------------------------------------------------------------------------
;;; The files in this manifest must be strictly topologically sorted (DFS post-order):
;;; every module/file must appear AFTER all of its dependencies and submodules,
;;; and BEFORE any caller file that requires it during initialization.
;;;
;;; PITFALL TO AVOID:
;;; Capturing the file list by logging load entry (e.g. `LOAD-START`) produces
;;; DFS pre-order, which mistakenly places caller/orchestrator files (such as
;;; `init-texmacs.scm`) at the top before the kernel, library, and GUI modules
;;; they depend on. When compiled into an AOT boot file or sequentially loaded,
;;; this causes unbound variable errors or circular load loops.
;;;
;;; In contrast, `init-texmacs.scm` must be placed near the end (after all kernel,
;;; GUI, font, and tool modules have been loaded), right before `init-buffer.scm`.
;;;
;;; AUTOMATION GOAL:
;;; Ideally, this manifest should be automatically generated rather than manually
;;; maintained. Automated generation can be achieved by:
;;; 1. Logging `LOAD-FINISH` (post-order exit) during a verified headless boot, or
;;; 2. Statically analyzing `(texmacs-module ... (:use ...))` declarations and
;;;    `(load ...)` calls to construct a dependency DAG and running topological
;;;    sorting (`tsort`).
;;; ---------------------------------------------------------------------------

(define *texmacs-boot-files*
  '(
    "init-texmacs-chez.scm"
    ;; "kernel/boot/boot-chez.scm"
    "kernel/boot/compat.scm"
    "kernel/boot/abbrevs.scm"
    "kernel/boot/debug.scm"
    "kernel/boot/srfi.scm"
    "kernel/boot/ahash-table.scm"
    "kernel/boot/prologue.scm"
    "kernel/library/base.scm"
    "kernel/library/list.scm"
    "kernel/library/tree.scm"
    "kernel/library/content.scm"
    "kernel/library/patch.scm"
    "kernel/regexp/regexp-match.scm"
    "kernel/regexp/regexp-select.scm"
    "kernel/logic/logic-rules.scm"
    "kernel/logic/logic-bind.scm"
    "kernel/logic/logic-unify.scm"
    "kernel/logic/logic-query.scm"
    "kernel/logic/logic-data.scm"
    "kernel/texmacs/tm-define.scm"
    "kernel/texmacs/tm-preferences.scm"
    "kernel/texmacs/tm-modes.scm"
    "kernel/texmacs/tm-plugins.scm"
    "kernel/texmacs/tm-secure.scm"
    "kernel/texmacs/tm-convert.scm"
    "kernel/texmacs/tm-dialogue.scm"
    "kernel/texmacs/tm-language.scm"
    "kernel/texmacs/tm-file-system.scm"
    "kernel/texmacs/tm-states.scm"
    "kernel/gui/gui-markup.scm"
    "kernel/gui/menu-define.scm"
    "kernel/gui/menu-widget.scm"
    "kernel/gui/kbd-define.scm"
    "kernel/gui/speech-define.scm"
    "kernel/gui/kbd-handlers.scm"
    "kernel/gui/menu-test.scm"
    "kernel/old-gui/old-gui-widget.scm"
    "kernel/old-gui/old-gui-factory.scm"
    "kernel/old-gui/old-gui-form.scm"
    "kernel/old-gui/old-gui-test.scm"
    "utils/library/cpp-wrap.scm"
    "utils/library/tree.scm"
    "utils/library/smart-table.scm"
    "utils/plugins/plugin-convert.scm"
    "convert/rewrite/tmtm-brackets.scm"
    "utils/misc/markup-funcs.scm"
    "utils/misc/artwork.scm"
    "utils/misc/tooltip.scm"
    "utils/handwriting/handwriting.scm"
    "bibtex/bib-utils.scm"
    "texmacs/texmacs/tm-server.scm"
    "generic/document-edit.scm"
    "utils/base/environment.scm"
    "texmacs/texmacs/tm-tools.scm"
    "utils/library/length.scm"
    "utils/library/cursor.scm"
    "generic/generic-edit.scm"
    "utils/edit/variants.scm"
    "bibtex/bib-complete.scm"
    "utils/library/ptrees.scm"
    "source/macro-search.scm"
    "generic/document-style.scm"
    "texmacs/texmacs/tm-view.scm"
    "texmacs/texmacs/tm-files.scm"
    "texmacs/texmacs/tm-print.scm"
    "texmacs/keyboard/config-kbd.scm"
    "texmacs/menus/main-menu.scm"
    "tools/ai/ai-batch.scm"
    "fonts/fonts-ec.scm"
    "fonts/fonts-adobe.scm"
    "fonts/fonts-x.scm"
    "fonts/fonts-math.scm"
    "fonts/fonts-foreign.scm"
    "fonts/fonts-misc.scm"
    "fonts/fonts-composite.scm"
    "fonts/fonts-truetype.scm"
    "database/title-transform.scm"
    "database/title-markup.scm"
   ))
