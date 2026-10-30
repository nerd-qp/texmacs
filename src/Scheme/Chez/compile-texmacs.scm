;;; TODO: UNDER REVIEWED AI GENERATED CODE.
;;;
;;; compile-texmacs.scm -- Transpiles and compiles all TeXmacs modules into native Chez Scheme modules
;;;
;;; Usage:
;;;  ENV=??? TeXmacs --compile-modules

(define-top-level-value 'texmacs-chez-compiling? #t)
(define-top-level-value 'boot-kernel-loaded? #t)

(define tm-load-file (if (top-level-bound? 'tm-load-file) tm-load-file load))
(define texmacs-time (if (top-level-bound? 'texmacs-time) texmacs-time (lambda () 0)))
(define os-win32? (if (top-level-bound? 'os-win32?) os-win32? (lambda () #f)))
(define developer-mode? (if (top-level-bound? 'developer-mode?) developer-mode? #f))
(define native-load
  (lambda (path)
    (load path (lambda (x) (eval x (interaction-environment))))))

(define *progs-dir*
  (cond ((and (getenv "TEXMACS_PATH") (file-exists? (string-append (getenv "TEXMACS_PATH") "/progs")))
         (string-append (getenv "TEXMACS_PATH") "/progs"))
        ((file-exists? "TeXmacs/progs") "TeXmacs/progs")
        ((file-exists? "texmacs/TeXmacs/progs") "texmacs/TeXmacs/progs")
        (else "TeXmacs/progs")))

(define *boot-dir*
  (cond ((file-exists? "build-texmacos/boot") "build-texmacos/boot")
        ((file-exists? "texmacs/build-texmacos/boot") "texmacs/build-texmacos/boot")
        ((file-exists? "../build-texmacos/boot") "../build-texmacos/boot")
        (else "build-texmacos/boot")))

(unless (top-level-bound? 'boot-chez-loaded?)
  (load (string-append *progs-dir* "/kernel/boot/boot-chez.scm")))

(define *compiler-dir*
  (cond ((file-exists? "compiler-db.scm") ".")
        ((file-exists? "src/Scheme/Chez/compiler-db.scm") "src/Scheme/Chez")
        ((file-exists? "texmacs/src/Scheme/Chez/compiler-db.scm") "texmacs/src/Scheme/Chez")
        (else
         (error 'compile-texmacs "cannot find compiler-db.scm"))))

(primitive-load (string-append *compiler-dir* "/compiler-db.scm"))
(import (compiler-db))
(primitive-load (string-append *compiler-dir* "/compiler-scan.scm"))
(import (compiler-scan))

(unless (top-level-bound? 'compilation-environment)
  (define-top-level-value 'compilation-environment
    (make-parameter (interaction-environment))))

(define *kernel-files*
  '(
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
    "kernel/logic/logic-bind.scm"
    "kernel/logic/logic-unify.scm"
    "kernel/logic/logic-rules.scm"
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
    "kernel/gui/kbd-define.scm"
    "kernel/gui/menu-widget.scm"
    "kernel/gui/speech-define.scm"
    "kernel/gui/kbd-handlers.scm"
    "kernel/gui/menu-test.scm"
    "kernel/old-gui/old-gui-widget.scm"
    "kernel/old-gui/old-gui-factory.scm"
    "kernel/old-gui/old-gui-form.scm"
    "kernel/old-gui/old-gui-test.scm"
   ))

(define *tier2-files*
  '(
    "utils/library/cpp-wrap.scm"
    "utils/library/tree.scm"
    "utils/library/smart-table.scm"
    "utils/library/length.scm"
    "utils/library/cursor.scm"
    "utils/plugins/plugin-convert.scm"
    "convert/rewrite/tmtm-brackets.scm"
    "utils/misc/markup-funcs.scm"
    "utils/misc/artwork.scm"
    "utils/misc/tooltip.scm"
    "utils/handwriting/handwriting.scm"
    "utils/edit/variants.scm"
    "utils/base/environment.scm"
    "utils/library/ptrees.scm"
    "generic/document-edit.scm"
    "generic/generic-edit.scm"
    "generic/document-style.scm"
    "texmacs/texmacs/tm-server.scm"
    "texmacs/texmacs/tm-tools.scm"
    "texmacs/texmacs/tm-view.scm"
    "texmacs/texmacs/tm-files.scm"
    "texmacs/texmacs/tm-print.scm"
    "texmacs/keyboard/config-kbd.scm"
    "fonts/fonts-ec.scm"
    "fonts/fonts-adobe.scm"
    "fonts/fonts-x.scm"
    "fonts/fonts-math.scm"
    "fonts/fonts-foreign.scm"
    "fonts/fonts-misc.scm"
    "fonts/fonts-composite.scm"
    "fonts/fonts-truetype.scm"
    "bibtex/bib-utils.scm"
    "bibtex/bib-complete.scm"
    "database/title-transform.scm"
    "database/title-markup.scm"
    "source/macro-search.scm"
    "tools/ai/ai-batch.scm"
    "utils/misc/gui-utils.scm"
    "utils/misc/gui-keyboard.scm"
    "tools/spell/spell-lantool.scm"
    "debug/debug-widgets.scm"
    "language/natural.scm"
    "utils/library/process.scm"
    "utils/edit/selections.scm"
    "utils/edit/auto-close.scm"
    "utils/plugins/plugin-cmd.scm"
    "utils/plugins/plugin-eval.scm"
    "utils/cite/cite-sort.scm"
   ))

(define *tier3-files*
  '(
    ;; Math editing:
    "math/math-edit.scm"
    "math/math-kbd.scm"
    "math/math-menu.scm"

    ;; Table editing:
    "table/table-edit.scm"
    "table/table-kbd.scm"
    "table/table-menu.scm"

    ;; Text editing:
    "text/text-drd.scm"
    "text/text-edit.scm"
    "text/text-kbd.scm"
    "text/text-menu.scm"

    ;; Graphics canvas:
    "graphics/graphics-drd.scm"
    "graphics/graphics-utils.scm"
    "graphics/graphics-env.scm"
    "graphics/graphics-markup.scm"
    "graphics/graphics-group.scm"
    "graphics/graphics-object.scm"
    "graphics/graphics-main.scm"
    "graphics/graphics-edit.scm"
    "graphics/graphics-menu.scm"
    "graphics/graphics-kbd.scm"
    "graphics/graphics-single.scm"
    "graphics/graphics-animate.scm"
    "math/math-drd.scm"
    "math/math-markup.scm"
    "table/table-widgets.scm"
    "table/table-tools.scm"
    "table/table-doc.scm"
    "text/text-structure.scm"
    "text/text-natbib.scm"
   ))

(define *tier4-files*
  '(
    ;; Core desktop menus:
    "texmacs/menus/file-menu.scm"
    "texmacs/menus/edit-menu.scm"
    "texmacs/menus/view-menu.scm"
    "texmacs/menus/view-tools.scm"
    "texmacs/menus/view-widgets.scm"
    "texmacs/menus/tools-menu.scm"
    "texmacs/menus/preferences-menu.scm"
    "texmacs/menus/preferences-tools.scm"
    "texmacs/menus/preferences-widgets.scm"
    "texmacs/menus/print-widgets.scm"
    "texmacs/menus/developer-menu.scm"
    "texmacs/menus/main-menu.scm"

    ;; Generic interactive layer:
    "generic/generic-kbd.scm"
    "generic/format-drd.scm"
    "generic/format-edit.scm"
    "generic/format-geometry-edit.scm"
    "generic/format-menu.scm"
    "generic/format-tools.scm"
    "generic/format-widgets.scm"
    "generic/document-menu.scm"
    "generic/document-part.scm"
    "generic/document-tools.scm"
    "generic/document-widgets.scm"
    "generic/document-doc.scm"
    "generic/insert-menu.scm"
    "generic/generic-menu.scm"
    "generic/pattern-selector.scm"
    "generic/pattern-tools.scm"
    "generic/search-widgets.scm"
    "generic/spell-widgets.scm"
    "generic/generic-doc.scm"
    "generic/embedded-edit.scm"
    "generic/embedded-menu.scm"
    "generic/generic-speech.scm"
    "generic/generic-speech-en.scm"
    "generic/generic-speech-fr.scm"
    "source/source-drd.scm"
    "source/source-edit.scm"
    "source/source-kbd.scm"
    "source/source-menu.scm"
    "source/macro-edit.scm"
    "source/macro-menu.scm"
    "source/macro-widgets.scm"
   ))

(define *tier5-convert-files*
  '(
    ;; Core converter tools:
    "convert/tools/output.scm"
    "convert/tools/tmconcat.scm"
    "convert/tools/tmcolor.scm"
    "convert/tools/tmlength.scm"
    "convert/tools/tmtable.scm"
    "convert/tools/stm.scm"
    "convert/tools/environment.scm"
    "convert/tools/sxml.scm"
    "convert/tools/css.scm"
    "convert/tools/tmpre.scm"
    "convert/tools/xmltm.scm"
    "convert/tools/sxhtml.scm"

    ;; Core format rewrite:
    "convert/rewrite/init-rewrite.scm"

    ;; Image formats:
    "convert/images/tmimage.scm"
    "convert/images/init-images.scm"

    ;; LaTeX subsystem:
    "convert/latex/latex-define.scm"
    "convert/latex/latex-drd.scm"
    "convert/latex/latex-command-drd.scm"
    "convert/latex/latex-symbol-drd.scm"
    "convert/latex/latex-texmacs-drd.scm"
    "convert/latex/latex-tools.scm"
    "convert/latex/latex-overload.scm"
    "convert/latex/texout.scm"
    "convert/latex/tmtex.scm"
    "convert/latex/tmtex-widgets.scm"
    "convert/latex/init-latex.scm"
    "convert/latex/tmtex-ams.scm"
    "convert/latex/tmtex-acm.scm"
    "convert/latex/tmtex-beamer.scm"
    "convert/latex/tmtex-elsevier.scm"
    "convert/latex/tmtex-ieee.scm"
    "convert/latex/tmtex-revtex.scm"
    "convert/latex/tmtex-springer.scm"

    ;; HTML subsystem:
    "convert/html/htmlout.scm"
    "convert/html/tmhtml.scm"
    "convert/html/htmltm.scm"
    "convert/html/tmhtml-expand.scm"
    "convert/html/init-html.scm"

    ;; TMML subsystem:
    "convert/tmml/tmtmml.scm"
    "convert/tmml/tmmltm.scm"
    "convert/tmml/tmmlout.scm"
    "convert/tmml/init-tmml.scm"

    ;; MathML subsystem:
    "convert/mathml/mathml-drd.scm"
    "convert/mathml/tmmath.scm"
    "convert/mathml/mathtm.scm"

    ;; BibTeX subsystem:
    "convert/bibtex/bibtextm.scm"
    "convert/bibtex/tmbibtex.scm"
    "convert/bibtex/bibtexout.scm"
    "convert/bibtex/init-bibtex.scm"

    ;; Coq subsystem:
    "convert/coq/scmcoqml.scm"
    "convert/coq/coqmlscm.scm"
    "convert/coq/coqmlout.scm"
    "convert/coq/vernacout.scm"
    "convert/coq/gallinatm.scm"
    "convert/coq/tmvernac.scm"
    "convert/coq/init-coqml.scm"
   ))

(define *tier6-dynamic-files*
  '(
    "dynamic/dynamic-drd.scm"
    "dynamic/calc-drd.scm"
    "dynamic/calc-markup.scm"
    "dynamic/calc-edit.scm"
    "dynamic/calc-kbd.scm"
    "dynamic/calc-menu.scm"
    "dynamic/calc-table.scm"
    "dynamic/fold-markup.scm"
    "dynamic/fold-edit.scm"
    "dynamic/fold-kbd.scm"
    "dynamic/fold-menu.scm"
    "dynamic/session-drd.scm"
    "dynamic/session-edit.scm"
    "dynamic/session-menu.scm"
    "dynamic/session-doc.scm"
    "dynamic/program-drd.scm"
    "dynamic/program-edit.scm"
    "dynamic/program-menu.scm"
    "dynamic/program-doc.scm"
    "dynamic/animate-edit.scm"
    "dynamic/animate-menu.scm"
    "dynamic/scripts-drd.scm"
    "dynamic/scripts-edit.scm"
    "dynamic/scripts-kbd.scm"
    "dynamic/scripts-menu.scm"
    "dynamic/scripts-plot.scm"
   ))

(define *tier7-extended-files*
  '(
    "bibtex/plain.scm"
    "bibtex/abbrv.scm"
    "bibtex/abstract.scm"
    "bibtex/acm.scm"
    "bibtex/alpha.scm"
    "bibtex/bib-widgets.scm"
    "bibtex/elsart-num.scm"
    "bibtex/ieeetr.scm"
    "bibtex/siam.scm"
    "bibtex/unsrt.scm"
    "convert/tmml/tmmltm-test.scm"
    "database/db-base.scm"
    "database/db-format.scm"
    "database/db-users.scm"
    "database/db-version.scm"
    "server/server-authentication.scm"
    "security/password.scm"
    "server/server-base.scm"
    "server/server-cache.scm"
    "server/server-cache-test.scm"
    "convert/tools/xmltm-test.scm"
    "convert/tools/tmlength-test.scm"
    "server/server-tmfs.scm"
    "server/server-notifications.scm"
    "server/server-chat.scm"
    "server/server-fixtures.scm"
    "server/server-tmfs-test.scm"
    "server/server-backup.scm"
    "server/server-backup-test.scm"
    "convert/tools/environment-test.scm"
    "convert/mathml/mathtm-test.scm"
    "prog/prog-format-test.scm"
    "utils/cite/cite-sort-test.scm"
    "convert/html/tmhtml-test.scm"
    "server/server-notifications-test.scm"
    "convert/html/htmltm-test.scm"
    "check/check-master.scm"
    "client/client-authentication.scm"
    "client/client-base.scm"
    "version/version-tmfs.scm"
    "client/client-db.scm"
    "client/client-tmfs.scm"
    "client/client-chat.scm"
    "database/db-edit.scm"
    "database/db-convert.scm"
    "client/client-db-sync.scm"
    "utils/relate/live-document.scm"
    "utils/relate/live-connection.scm"
    "utils/relate/live-view.scm"
    "client/client-live.scm"
    "client/client-markup.scm"
    "client/client-remote-config.scm"
    "client/client-sync.scm"
    "client/client-notifications.scm"
    "client/client-widgets.scm"
    "client/client-menu.scm"
    "convert/coq/coqmltest.scm"
    "convert/html/htmltest.scm"
    "convert/latex/test-tmtex.scm"
    "convert/latex/textest.scm"
    "convert/tools/old-tmtable.scm"
    "database/bib-db.scm"
    "database/bib-manage.scm"
    "database/db-tmfs.scm"
    "database/db-widgets.scm"
    "database/db-menu.scm"
    "database/bib-menu.scm"
    "database/bib-kbd.scm"
    "database/bib-local.scm"
    "database/db-markup.scm"
    "debug/debug-menu.scm"
    "doc/apidoc-collect.scm"
    "doc/apidoc-funcs.scm"
    "doc/apidoc-widgets.scm"
    "doc/apidoc-kbd.scm"
    "doc/apidoc-markup.scm"
    "prog/scheme-tools.scm"
    "doc/apidoc-menu.scm"
    "doc/apidoc.scm"
    "doc/help-funcs.scm"
    "doc/docgrep.scm"
    "doc/help-menu.scm"
    "doc/tmdoc-drd.scm"
    "doc/tmdoc-edit.scm"
    "doc/tmdoc-kbd.scm"
    "doc/tmdoc-markup.scm"
    "doc/tmdoc-menu.scm"
    "doc/tmdoc-search.scm"
    "doc/tmdoc.scm"
    "doc/tmweb.scm"
    "education/edu-drd.scm"
    "education/edu-edit.scm"
    "education/edu-kbd.scm"
    "education/edu-markup.scm"
    "education/edu-menu.scm"
    "fonts/font-sample.scm"
    "fonts/font-new-widgets.scm"
    "fonts/font-old-menu.scm"
    "kernel/boot/boot.scm"
    "kernel/gui/menu-convert.scm"
    "kernel/library/iterator.scm"
    "kernel/logic/logic-test.scm"
    "kernel/regexp/regexp-test.scm"
    "kernel/texmacs/tm-convert-test.scm"
    "language/minimal.scm"
    "language/std-symbols.scm"
    "language/std-math.scm"
    "link/locus-edit.scm"
    "link/link-edit.scm"
    "link/link-extern.scm"
    "link/link-navigate.scm"
    "link/link-extract.scm"
    "link/link-kbd.scm"
    "link/link-menu.scm"
    "link/ref-edit.scm"
    "link/ref-markup.scm"
    "link/ref-menu.scm"
    "math/math-stats.scm"
    "math/math-speech.scm"
    "math/math-adjust-en.scm"
    "math/math-adjust-fr.scm"
    "math/math-sem-edit.scm"
    "math/math-speech-en.scm"
    "math/math-speech-fr.scm"
    "notification/notification-base.scm"
    "part/part-shared.scm"
    "part/part-tmfs.scm"
    "part/part-menu.scm"
    "prog/prog-edit.scm"
    "prog/cpp-edit.scm"
    "prog/default-lang.scm"
    "prog/dot-edit.scm"
    "prog/fortran-edit.scm"
    "prog/glue-symbols.scm"
    "prog/java-edit.scm"
    "prog/prog-format.scm"
    "prog/scheme-autocomplete.scm"
    "utils/misc/tm-keywords.scm"
    "prog/scheme-edit.scm"
    "prog/python-edit.scm"
    "prog/scala-edit.scm"
    "prog/prog-kbd.scm"
    "prog/prog-menu.scm"
    "prog/scheme-menu.scm"
    "security/gpg/gpg-base.scm"
    "security/gpg/gpg-wallet.scm"
    "security/wallet/wallet-base.scm"
    "security/wallet/wallet-menu.scm"
    "security/gpg/gpg-widgets.scm"
    "security/gpg/gpg-edit.scm"
    "security/gpg/gpg-menu.scm"
    "security/keychain/macos-security.scm"
    "security/keychain/win-security.scm"
    "server/server-db-sync.scm"
    "server/server-db.scm"
    "server/server-live.scm"
    "server/server-sync.scm"
    "server/server-widgets.scm"
    "server/server-menu.scm"
    "source/shortcut-edit.scm"
    "source/shortcut-widgets.scm"
    "texmacs/keyboard/latex-kbd.scm"
    "texmacs/keyboard/prefix-kbd.scm"
    "text/chinese/chinese.scm"
    "text/cyrillic/cp1251-kbd.scm"
    "text/cyrillic/jcuken-kbd.scm"
    "text/cyrillic/koi8-kbd.scm"
    "text/cyrillic/translit-kbd.scm"
    "text/cyrillic/yawerty-kbd.scm"
    "text/text-speech.scm"
    "text/text-speech-en.scm"
    "text/text-speech-fr.scm"
    "text/vietnamese/vietnamese.scm"
    "version/version-drd.scm"
    "version/version-edit.scm"
    "tools/ai/ai-translate.scm"
    "tools/comment/comment-drd.scm"
    "tools/comment/comment-edit.scm"
    "tools/comment/comment-widgets.scm"
    "tools/comment/comment-menu.scm"
    "tools/poster/poster-drd.scm"
    "tools/poster/poster-edit.scm"
    "tools/poster/poster-menu.scm"
    "tools/spell/spell-edit.scm"
    "tools/spell/spell-kbd.scm"
    "tools/theme/theme-edit.scm"
    "tools/theme/theme-menu.scm"
    "utils/automate/auto-edit.scm"
    "utils/automate/auto-build.scm"
    "utils/automate/auto-tmfs.scm"
    "utils/automate/auto-kbd.scm"
    "utils/automate/auto-menu.scm"
    "utils/cas/cas-rewrite.scm"
    "utils/cas/cas-out.scm"
    "utils/email/email-tmfs.scm"
    "utils/literate/lp-edit.scm"
    "utils/literate/lp-build.scm"
    "utils/literate/lp-menu.scm"
    "utils/misc/doxygen.scm"
    "utils/misc/extern-demo.scm"
    "utils/misc/tiles.scm"
    "utils/misc/translation-list.scm"
    "utils/misc/updater.scm"
    "utils/relate/live-menu.scm"
    "utils/relate/relate-menu.scm"
    "utils/test/test-convert.scm"
    "utils/test/test-latex-export.scm"
    "version/version-compare.scm"
    "version/version-git.scm"
    "version/version-kbd.scm"
    "version/version-menu.scm"
    "version/version-svn.scm"
   ))

(define *source-files*
  (append *kernel-files*
          *tier2-files*
          *tier3-files*
          *tier4-files*
          *tier5-convert-files*
          *tier6-dynamic-files*
          *tier7-extended-files*))

(define *compiler-db*
  (scan-source-files->db *progs-dir* *source-files*))

(define (spec->symbol spec)
  (let* ((parts (if (pair? spec)
                    (map symbol->string spec)
                    (list (symbol->string spec))))
         (joined (let loop ((p parts))
                   (if (null? (cdr p))
                       (car p)
                       (string-append (car p) ":" (loop (cdr p)))))))
    (string->symbol joined)))

(define (rel-path->spec rel-path)
  (let* ((without-ext (if (and (>= (string-length rel-path) 4)
                               (string=? (substring rel-path (- (string-length rel-path) 4) (string-length rel-path)) ".scm"))
                          (substring rel-path 0 (- (string-length rel-path) 4))
                          rel-path))
         (len (string-length without-ext)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
        ((= i len)
         (reverse (cons (string->symbol (substring without-ext start i)) acc)))
        ((char=? (string-ref without-ext i) #\/)
         (loop (+ i 1) (+ i 1) (cons (string->symbol (substring without-ext start i)) acc)))
        (else
         (loop (+ i 1) start acc))))))

;; ========================================================
;; Incremental & Selective Compilation Configuration
;; ========================================================

(define (file-newer? f1 f2)
  (and (file-exists? f1)
       (or (not (file-exists? f2))
           (time>? (file-modification-time f1)
                   (file-modification-time f2)))))

(define (tm-macroify-cp head)
  (if (pair? head)
      (cons (tm-macroify-cp (car head)) (cdr head))
      (string->symbol (string-append (symbol->string head) "$impl"))))

(define *recompile-all?*
  (or (and (top-level-bound? '*recompile-all*) *recompile-all?*)
      (let ((v (getenv "TEXMACS_RECOMPILE_ALL")))
        (and v (not (string=? v "")) (not (string=? v "0"))))))

(define (module-needs-recompile? rel-path trans-scm out-so)
  (cond
    (*recompile-all?* #t)
    ((not (file-exists? out-so)) #t)
    ((not (file-exists? trans-scm)) #t)
    (else
     (let ((src (string-append *progs-dir* "/" rel-path)))
       (or (file-newer? src out-so)
           (file-newer? trans-scm out-so))))))

(when *recompile-all?*
  (display "========================================================\n")
  (display "  MODE: RECOMPILE FROM SCRATCH (FALLBACK / CLEAN)\n")
  (display "========================================================\n"))

(define (hex-digit? c)
  (or (char<=? #\0 c #\9)
      (char<=? #\a c #\f)
      (char<=? #\A c #\F)))

(define (normalize-guile-string-escapes str)
  (let ((len (string-length str))
        (out (open-output-string)))
    (let loop ((i 0) (in-string? #f))
      (if (>= i len)
          (get-output-string out)
          (let ((c (string-ref str i)))
            (cond
              ;; Outside string
              ((not in-string?)
               (cond
                 ;; Character literal `#\"`
                 ((and (char=? c #\#)
                       (< (+ i 2) len)
                       (char=? (string-ref str (+ i 1)) #\\)
                       (char=? (string-ref str (+ i 2)) #\"))
                  (display "#\\\"" out)
                  (loop (+ i 3) #f))
                 ;; Start of string literal
                 ((char=? c #\")
                  (write-char c out)
                  (loop (+ i 1) #t))
                 ;; Line comment
                 ((char=? c #\;)
                  (let comment-loop ((j i))
                    (if (or (>= j len) (char=? (string-ref str j) #\newline))
                        (begin
                          (display (substring str i j) out)
                          (loop j #f))
                        (comment-loop (+ j 1)))))
                 (else
                  (write-char c out)
                  (loop (+ i 1) #f))))
              ;; Inside string
              (else
               (cond
                 ;; Escaped character inside string
                 ((char=? c #\\)
                  (if (>= (+ i 1) len)
                      (begin (write-char c out) (loop (+ i 1) #t))
                      (let ((next-c (string-ref str (+ i 1))))
                        (cond
                          ;; \\ or \"
                          ((or (char=? next-c #\\) (char=? next-c #\"))
                           (write-char c out)
                           (write-char next-c out)
                           (loop (+ i 2) #t))
                          ;; \x or \X hex escape
                          ((and (or (char=? next-c #\x) (char=? next-c #\X))
                                (< (+ i 3) len)
                                (hex-digit? (string-ref str (+ i 2)))
                                (hex-digit? (string-ref str (+ i 3))))
                           (let ((h1 (string-ref str (+ i 2)))
                                 (h2 (string-ref str (+ i 3))))
                             (if (and (< (+ i 4) len)
                                      (char=? (string-ref str (+ i 4)) #\;))
                                 ;; Already has semicolon \xNN;
                                 (begin
                                   (display (substring str i (+ i 5)) out)
                                   (loop (+ i 5) #t))
                                 ;; Missing semicolon \xNN -> \xNN;
                                 (begin
                                   (display (substring str i (+ i 4)) out)
                                   (write-char #\; out)
                                   (loop (+ i 4) #t)))))
                          (else
                           (write-char c out)
                           (write-char next-c out)
                           (loop (+ i 2) #t))))))
                 ;; End of string
                 ((char=? c #\")
                  (write-char c out)
                  (loop (+ i 1) #f))
                 (else
                  (write-char c out)
                  (loop (+ i 1) #t))))))))))

(define (read-all-forms file-path)
  (let* ((port (open-input-file file-path))
         (content (get-string-all port)))
    (close-port port)
    (let* ((str (if (eof-object? content) "" content))
           (normalized (normalize-guile-string-escapes str))
           (in-port (open-string-input-port normalized)))
      (let loop ((acc '()))
        (let ((x (read in-port)))
          (if (eof-object? x)
              (reverse acc)
              (loop (cons x acc))))))))

(define (ensure-dir path)
  (let loop ((i (- (string-length path) 1)))
    (when (>= i 0)
      (if (char=? (string-ref path i) #\/)
          (let ((dir (substring path 0 i)))
            (unless (file-exists? dir)
              (system (string-append "mkdir -p \"" dir "\""))))
          (loop (- i 1))))))

(define (def-form? x)
  (and (pair? x)
       (memq (car x) '(define define-syntax define-public define-public-macro define-public-macro-trace
                       define-macro-trace
                       define-module-macro
                       define-state
                       provide-public
                       define-macro
                       define-menu
                       define-widget
                       define-record-type
                       define-values
                       bib-define-style
                       texmacs-modes
                       import export indirect-export eval-when meta))))

(define (has-def? x)
  (cond
    ((def-form? x) #t)
    ((and (pair? x) (eq? (car x) 'begin))
     (let loop ((forms (cdr x)))
       (and (pair? forms)
            (or (has-def? (car forms))
                (loop (cdr forms))))))
    (else #f)))

(define (cond-def? x)
  (and (pair? x)
       (cond
         ((eq? (car x) 'if)
          (and (pair? (cdr x))
               (pair? (cddr x))
               (or (has-def? (caddr x))
                   (and (pair? (cdddr x))
                        (has-def? (cadddr x))))))
         ((memq (car x) '(when unless))
          (and (pair? (cdr x))
               (pair? (cddr x))
               (has-def? (cons 'begin (cddr x)))))
         (else #f))))

(define (ca*r x) (if (pair? x) (ca*r (car x)) x))

(define (unique-syms l)
  (let loop ((rest l) (seen '()) (acc '()))
    (if (null? rest) (reverse acc)
        (let ((x (car rest)))
          (if (or (not (symbol? x))
                  (keyword? x)
                  (memq x seen)
                  (let ((s (symbol->string x)))
                    (and (>= (string-length s) 8) (string=? (substring s 0 8) "_tm_def_"))))
              (loop (cdr rest) seen acc)
              (loop (cdr rest) (cons x seen) (cons x acc)))))))

(define module-public-vars '())
(define module-local-defs '())
(define current-used-symbols '())
(define module-exports-table (make-eq-hashtable))

(define (get-module-exports mod-sym)
  (or (hashtable-ref module-exports-table mod-sym #f)
      (let* ((str (symbol->string mod-sym))
             (len (string-length str))
             (out (open-output-string)))
        (let loop ((i 0))
          (when (< i len)
            (let ((c (string-ref str i)))
              (write-char (if (char=? c #\:) #\/ c) out)
              (loop (+ i 1)))))
        (let* ((rel (get-output-string out))
               (scm-path (string-append *boot-dir* "/" rel ".scm")))
          (if (not (file-exists? scm-path))
              '()
              (let* ((p (open-input-file scm-path))
                     (forms (let rloop ((acc '()))
                              (let ((x (read p)))
                                (if (eof-object? x) (reverse acc)
                                    (rloop (cons x acc)))))))
                (close-port p)
                (let loop ((rest forms) (exports '()))
                  (if (null? rest)
                      (begin
                        (hashtable-set! module-exports-table mod-sym (reverse exports))
                        (reverse exports))
                      (let ((f (car rest)))
                        (if (and (pair? f) (eq? (car f) 'module) (pair? (cddr f)))
                            (let body-loop ((b (cdddr f)) (acc exports))
                              (if (null? b)
                                  (loop (cdr rest) acc)
                                  (let ((stmt (car b)))
                                    (cond
                                      ((and (pair? stmt)
                                            (memq (car stmt) '(define-public provide-public))
                                            (pair? (cdr stmt)))
                                       (let* ((head (cadr stmt))
                                              (var (let vloop ((h head)) (if (pair? h) (vloop (car h)) h))))
                                         (if (and (symbol? var) (not (memq var acc)))
                                             (body-loop (cdr b) (cons var acc))
                                             (body-loop (cdr b) acc))))
                                      ((and (pair? stmt)
                                            (eq? (car stmt) 'export)
                                            (pair? (cdr stmt))
                                            (pair? (cadr stmt))
                                            (eq? (caadr stmt) 'import)
                                            (pair? (cdadr stmt)))
                                       (let* ((dep-mod (cadadr stmt))
                                              (dep-exports (get-module-exports dep-mod)))
                                         (body-loop (cdr b)
                                                    (append (filter (lambda (v) (not (memq v acc))) dep-exports)
                                                            acc))))
                                      (else (body-loop (cdr b) acc))))))
                            (loop (cdr rest) exports)))))))))))

(define-top-level-value 'module-exports-table module-exports-table)
(define-top-level-value 'module-exports-table module-exports-table (interaction-environment))
(define-top-level-value 'get-module-exports get-module-exports)
(define-top-level-value 'get-module-exports get-module-exports (interaction-environment))



(define (tm-collect-keywords x acc)
  (cond ((and (symbol? x)
              (let ((s (symbol->string x)))
                (and (> (string-length s) 0)
                     (char=? (string-ref s 0) #\:))))
         (if (member x acc) acc (cons x acc)))
        ((pair? x) (tm-collect-keywords (car x)
                     (tm-collect-keywords (cdr x) acc)))
        (else acc)))

(define (tm-bind-keywords x)
  (let ((env (compilation-environment)))
    (for-each
      (lambda (k)
        (unless (top-level-bound? k env)
          (define-top-level-value k k env))
        (unless (top-level-bound? k)
          (define-top-level-value k k)))
      (tm-collect-keywords x '()))))

(define (uncurry-def definer head body)
  (if (pair? (car head))
      (uncurry-def definer (car head) (list `(lambda ,(cdr head) ,@body)))
      `(,definer ,head ,@body)))

(define (tm-maybe-uncurry e)
  (if (and (pair? e) (memq (car e) '(define define-public provide-public))
           (pair? (cadr e)) (pair? (caadr e)))
      (uncurry-def (car e) (cadr e) (cddr e))
      e))

(define (tm-strip-docstring e)
  (if (and (pair? e) (memq (car e) '(define define-public provide-public)) (pair? (cadr e))
           (pair? (cddr e)) (string? (caddr e)) (pair? (cdddr e)))
      (cons (car e) (cons (cadr e) (cdddr e)))
      e))




(define (expand-macro-def x)
  (let* ((kind (car x))
         (decl (cadr x))
         (nm (if (pair? decl) (ca*r decl) decl))
         (formals (if (pair? decl)
                      (cdr decl)
                      (if (and (pair? (caddr x)) (eq? (caaddr x) 'lambda))
                          (cadr (caddr x))
                          'args)))
         (raw-body (if (pair? decl)
                       (cddr x)
                       (if (and (pair? (caddr x)) (eq? (caaddr x) 'lambda))
                           (cddr (caddr x))
                           (list (list (caddr x) 'args)))))
         (body (let strip ((b raw-body))
                 (if (and (pair? b) (pair? (car b)) (keyword? (caar b)))
                     (strip (cdr b))
                     b))))
    (cond
      ((eq? kind 'tm-define-macro)
       (let* ((macro-head (if (pair? decl)
                              (cons (string->symbol (string-append (symbol->string (ca*r decl)) "$impl"))
                                    (cdr decl))
                              (string->symbol (string-append (symbol->string decl) "$impl"))))
              (impl (if (pair? macro-head) (car macro-head) macro-head)))
         (values nm
                 `(lambda ,formals ,@body)
                 (list `(tm-define ,macro-head ,@raw-body)
                       `(putprop ',nm 'macro-transformer (lambda ,formals ,@body))
                       `(define-top-level-syntax ',nm
                          (lambda (stx)
                            (datum->syntax (car (syntax->list stx))
                              (apply (lambda ,formals ,@body) (cdr (syntax->datum stx)))))
                          (if (top-level-bound? 'compilation-environment)
                              (compilation-environment)
                              (interaction-environment)))))))
      ((eq? kind 'define-public-macro-trace)
       (values nm
               `(lambda ,formals ,@body)
               (list `(define-public-macro ,decl ,@body)
                     `(putprop ',nm 'macro-transformer (lambda ,formals ,@body)))))
      (else ;; define-macro-trace (private to module)
       (values nm
               `(lambda ,formals ,@body)
               (list `(define-macro ,decl ,@body)
                     `(putprop ',nm 'macro-transformer (lambda ,formals ,@body))))))))

;; Render any raised object as a printable string, without assuming it is a condition.
(define (condition-text e)
  (if (condition? e)
      (with-output-to-string (lambda () (display-condition e)))
      e))

;; Evaluate `thunk`, reporting any exception as one flat log line
;;   (MESSAGE irritant ... <condition text>)
;; and returning `default` instead of propagating it.  A `message` of #f keeps the call
;; silent.  Every eager evaluation in the transpiler goes through here, so a failure is
;; attributed to the form that caused it instead of aborting the module.
(define (guard-eval message irritants default thunk)
  (guard (e (else
	     (when message
	       (display (append (list message) irritants (list (condition-text e))))
	       (newline))
	     default))
    (thunk)))

(define (eval-in-compile x message)
  (guard-eval message (list x) #f
    (lambda ()
      (parameterize ((interaction-environment (compilation-environment)))
	(eval x (interaction-environment))))))

;; Publish a binding created in `(compilation-environment)` into the global environment.
;; The value is shared, not copied: its free variables keep resolving against the module's
;; own environment, which is exactly what keeps private definitions private.
(define (publish-value! name message)
  (guard-eval message (list name) #f
    (lambda ()
      (define-top-level-value name
			      (top-level-value name (compilation-environment))
			      (interaction-environment)))))

(define (publish-syntax! name message)
  (guard-eval message (list name) #f
    (lambda ()
      (define-top-level-syntax name
			      (top-level-syntax name (compilation-environment))
			      (interaction-environment)))))


;; The symbol a definition form introduces:
;;   (tm-define (foo x) ...)              -> foo
;;   (tm-define foo ...)                  -> foo
;;   (define-table foo ...)               -> foo
;;   (define-top-level-syntax 'foo proc)  -> foo   (the argument is a quoted symbol)
(define (defined-name x)
  (let ((head (cadr x)))
    (if (and (pair? head) (eq? (car head) 'quote))
	(cadr head)
	(ca*r head))))

;; These are global top-level values, supposed to be available to texmacs-user space.
;; Evaluate `x` where the module's definitions live, then publish the binding it produced.
(define (eval-install-value-env x message)
  (let ((name (defined-name x)))
    (eval-in-compile x message)
    (publish-value! name message)))

(define (eval-install-syntax-env x message)
  (let ((name (defined-name x)))
    (eval-in-compile x message)
    (publish-syntax! name message)))

(define (eval-install-tm-macro-env x message)
  (let* ((name (defined-name x))
	 (head (cadr x))
	 (impl-name (ca*r (tm-macroify-cp head))))
    (eval-in-compile x message)
    (publish-value! impl-name message)
    (publish-syntax! name message)))

(define (eval-install-group-env x message)
  (let* ((group (cadr x))
	 (list-name (symbol-append group '-list))
	 (pred-name (symbol-append group '?))
	 (inside-name (symbol-append 'inside- group '?)))
    (eval-in-compile x message)
    (publish-value! list-name message)
    (publish-value! pred-name message)
    (publish-value! inside-name message)))

(define (eval-and-auto-publish! x message)
  (let* ((c-env (compilation-environment))
         (before-syms (environment-symbols c-env)))
    ;; 1. Evaluate the form in compilation-environment
    (eval-in-compile x message)
    ;; 2. Publish any newly added bindings to interaction-environment
    (let ((after-syms (environment-symbols c-env)))
      (for-each
        (lambda (sym)
          (unless (memq sym before-syms)
            ;; NOTE: We use `top-level-bound?` to branch between values and syntax because in Chez Scheme
            ;; `top-level-syntax?` returns #t for all identifiers, including regular variables, whereas
            ;; `top-level-bound?` specifically checks for bound variable values.
            (if (top-level-bound? sym c-env)
                (publish-value! sym message)
                (publish-syntax! sym message))))
        after-syms))))

;; For forms that install something other than a value -- a syntax binding, a property --
;; publishing the value is not enough, so the form has to run again in the global
;; environment.
(define (eval-twice x message)
  (eval-in-compile x message)
  (guard-eval message (list x) #f
	      (lambda ()
		(eval x (interaction-environment)))))

(define (eval-eager-form! x)
  (let ((head (and (pair? x) (car x))))
    (cond
      ((memq head '(define define-public provide-public))
       (guard-eval #f '() #f
         (lambda ()
           (eval (cond ((and (pair? x) (eq? (car x) 'define-public))
                        (cons 'define (cdr x)))
                       ((and (pair? x) (eq? (car x) 'provide-public))
                        (cons 'define (cdr x)))
                       (else x))
                 (compilation-environment)))))

      ((memq head '(define-macro define-public-macro))
       (guard-eval #f '() #f
         (lambda ()
           (eval (cons 'define-macro (cdr x)) (compilation-environment)))))

      ((eq? head 'define-module-macro)
       (guard-eval #f '() #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((eq? head 'define-state)
       (guard-eval 'WARNING-DEFINE-STATE-EVAL-FAIL (list (cadr x)) #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((eq? head 'tm-define)
       (eval-install-value-env x 'WARNING-TM-DEFINE-EVAL-FAIL))

      ((eq? head 'tm-define-macro)
       (eval-install-tm-macro-env x 'WARNING-TM-DEFINE-MACRO-EVAL-FAIL))

      ((eq? head 'define-group)
       (eval-install-group-env x 'WARNING-DEFINE-GROUP-EVAL-FAIL))

      ((memq head '(define-table define-collection extend-table extend-collection smart-table))
       (eval-install-value-env x 'WARNING-TABLE-EVAL-FAIL))

      ((eq? head 'define-top-level-syntax)
       (eval-install-syntax-env x 'WARNING-TOP-LEVEL-SYNTAX-FAIL))

      ((eq? head 'putprop)
       (eval-twice x 'WARNING-PUTPROP-FAIL))

      ;; `tm-property` installs NOTHING: no value, no syntax binding. Its whole effect is
      ;; a side effect on `cur-props-table` via `property-set!`. Both `eval-and-auto-publish!`
      ;; (publishes newly introduced names -- the diff is empty by construction) and
      ;; `eval-twice` (installs twice at compile time) are the wrong shape, because they
      ;; run the side effect at COMPILE time. Values referenced by properties such as
      ;; (:check-mark *clipboard-test-import?) only exist at module LOAD time, so any
      ;; compile-time evaluation reports `variable ... is not bound`.
      ;;
      ;; So we do not evaluate it here at all: the form stays in the module body, Chez
      ;; expands it at compile time, and the emitted `(property-set! ...)` runs at load
      ;; time inside the module's own environment.
      ((eq? head 'tm-property) #f)

      ((memq head '(define-table-decls define-collection-decls))
       (guard-eval #f '() #f
         (lambda ()
           (eval x (compilation-environment)))))

      ((and (eq? head 'ahash-set!)
            (pair? (cdr x)) (eq? (cadr x) 'define-option-table))
       (guard-eval 'FAILED-EVAL-OPT-REG '() #f
         (lambda ()
           (eval x (compilation-environment))))))))

(define (prepare-forms forms)
  (let loop ((rest forms) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((x (car rest)))
          (cond
           ((not x) (loop (cdr rest) acc))
           ((and (pair? x) (eq? (car x) 'begin))
            (loop (append (cdr x) (cdr rest)) acc))
	   ((and (pair? x)
		 (memq (car x) '(tm-define
				 tm-define-macro
				 lazy-define
				 define-group
				 define-table
				 define-collection
				 extend-table
				 extend-collection
				 tm-property)))
	    (loop (cdr rest) (cons x acc)))
           ;; Macro definitions: capture define-public-macro-trace, define-macro-trace, tm-define-macro
           ;; BEFORE generic macro expansion so macro definitions are registered as transformers.
           ((and (pair? x) (memq (car x) '(define-public-macro-trace define-macro-trace tm-define-macro)))
            (let-values (((nm proc-expr expanded-forms) (expand-macro-def x)))
              (guard-eval 'WARNING-MACRO-EVAL-FAIL (list nm) #f
			  (lambda ()
			    (let ((proc (eval proc-expr (compilation-environment))))
			      (when proc (putprop nm 'macro-transformer proc)))))
              (loop (append expanded-forms (cdr rest)) acc)))
           ;; Stateful macro trace expansion:
           ;; Macros defined via define-public-macro-trace or tm-define-macro have their transformer procedure
           ;; attributed via `(putprop nm 'macro-transformer proc)`.
           ;; When `prepare-forms` encounters any macro with `'macro-transformer`, it invokes
           ;; the authentic Scheme transformer directly in `(compilation-environment)` in source order,
           ;; captures the emitted S-expression trace, and puts the expanded form back onto `rest`
           ;; (`(loop (cons expanded (cdr rest)) acc)`).
           ;; This expands nested macros ahead of Chez Scheme, ensuring that dynamic state mutations
           ;; (like `cur-conds`, `cur-props`, and option registrations) run cleanly before Chez Scheme
           ;; compiles the resulting definitions and expressions.
           ((and (pair? x)
                 (symbol? (car x))
                 (getprop (car x) 'macro-transformer))
            (let* ((nm (car x))
                   (xfrm (getprop (car x) 'macro-transformer))
                   (expanded (apply xfrm (cdr x))))
              (when (memq nm '(tm-define tm-define-overloaded menu-dynamic tm-define-macro))
                (display (list 'XFRM nm (if (pair? (cadr x)) (caar (cdr x)) (cadr x))))
                (newline))
              (loop (cons expanded (cdr rest)) acc)))
           ((and (pair? x) (memq (car x) '(define-top-level-syntax putprop)))
            (loop (cdr rest) (cons x acc)))
           ((and (pair? x)
                 (eq? (car x) 'define)
                 (symbol? (cadr x))
                 (pair? (cddr x))
                 (symbol? (caddr x))
                 (let* ((var-str (symbol->string (cadr x)))
                        (val-str (symbol->string (caddr x))))
                   (and (> (string-length var-str) 4)
                        (string=? (substring var-str 0 4) "cpp-")
                        (string=? (substring var-str 4 (string-length var-str)) val-str))))
            (let* ((var (cadr x))
                   (val (caddr x)))
              (loop (cdr rest) (cons `(define ,var (top-level-value ',val)) acc))))
           ((and (pair? x) (memq (car x) '(define define-public provide-public define-menu define-widget)))
            (let* ((x (tm-strip-docstring (tm-maybe-uncurry x)))
                   (head (cadr x))
                   (var (if (pair? head) (ca*r head) head)))
              (when (symbol? var)
                (unless (memq var module-local-defs)
                  (set! module-local-defs (cons var module-local-defs))))
              (when (and (symbol? var) (memq (car x) '(define-public provide-public)))
                (unless (memq var module-public-vars)
                  (set! module-public-vars (cons var module-public-vars))))
              (loop (cdr rest) (cons x acc))))
           ((and (pair? x) (memq (car x) '(define-macro define-public-macro define-module-macro)))
            (let* ((head (cadr x))
                   (nm (if (pair? head) (ca*r head) head)))
              (when (symbol? nm)
                (unless (memq nm module-local-defs)
                  (set! module-local-defs (cons nm module-local-defs))))
              (when (and (symbol? nm) (memq (car x) '(define-public-macro define-module-macro)))
                (unless (memq nm module-public-vars)
                  (set! module-public-vars (cons nm module-public-vars))))
              (loop (cdr rest) (cons x acc))))
           ((and (pair? x) (eq? (car x) 'define-syntax))
            (let ((var (cadr x)))
              (when (symbol? var)
                (unless (memq var module-local-defs)
                  (set! module-local-defs (cons var module-local-defs))))
              (loop (cdr rest) (cons x acc))))
           ((and (pair? x) (eq? (car x) 'bib-define-style))
            (let* ((s (cadr x))
                   (pred (string->symbol (string-append "bib-" s "?"))))
              (unless (memq pred module-local-defs)
                (set! module-local-defs (cons pred module-local-defs)))
              (unless (memq pred module-public-vars)
                (set! module-public-vars (cons pred module-public-vars)))
              (loop (cdr rest) (cons x acc))))
           ;; AST Decomposition:
           ;; In GNU Guile, module bodies allow arbitrary interleaving of definitions
           ;; and expressions. In Chez Scheme R6RS `(module M () defs ... exprs ...)`,
           ;; definitions cannot follow expressions.
           ;; We desugar compound definers here into separate definitions and initialization calls
           ;; so `partition-forms` can group definitions at the top and expressions at the bottom.
           ;; `define-export-macro` in `graphics/graphics-utils.scm`:
           ;; Upstream used a local macro helper to avoid historical Guile 1.8 macro caching bugs.
           ;; We convert it directly to `define-public-macro` so it is placed into `defs` rather than
           ;; `exprs`, avoiding "invalid context for definition" errors in Chez R6RS modules.
           ((and (pair? x) (eq? (car x) 'define-export-macro))
            (loop (cons (cons 'define-public-macro (cdr x)) (cdr rest)) acc))
           ;; In-body `(use-modules ...)` and `(inherit-modules ...)`:
           ;; R6RS forbids `import` inside expression contexts. We desugar in-body module declarations
           ;; to runtime `(module-provide 'mod)` calls, matching dynamic loading behavior without grammar errors.
           ((and (pair? x) (memq (car x) '(use-modules inherit-modules)))
            (loop (append (map (lambda (m) `(module-provide ',m)) (cdr x))
                          (cdr rest))
                  acc))
           ;; Dynamic `define-option-table` registrations (e.g. `:state` and `:state-slots` in `graphics-env.scm`):
           ;; These options are needed by `tm-define-sub` during macro expansion of subsequent definitions.
           ;; We evaluate the registration immediately into `(compilation-environment)` so intra-file and
           ;; downstream `tm-define` declarations recognize the new options at expand time.
           ((and (pair? x) (eq? (car x) 'ahash-set!)
                 (pair? (cdr x)) (eq? (cadr x) 'define-option-table))
            (loop (cdr rest) (cons x acc)))
           ((and (pair? x) (eq? (car x) 'define-preferences))
            (let* ((l (cdr x))
                   (pref-exprs (append (map define-preference l)
                                       (map define-preference-call-back l))))
              (loop (append pref-exprs (cdr rest)) acc)))
           ((cond-def? x)
            (let* ((kind (car x))
                   (raw-test (cadr x))
                   (test (if (eq? kind 'unless) `(not ,raw-test) raw-test))
                   (then-b (if (memq kind '(when unless))
                               (cons 'begin (cddr x))
                               (caddr x)))
                   (else-b (if (and (eq? kind 'if) (pair? (cdddr x))) (cadddr x) #f))
                   (eval-val (guard-eval #f '() 'eval-error
					 (lambda ()
					   (eval test (compilation-environment))))))
              (cond
               ((eq? eval-val 'eval-error)
                ;; Could not evaluate test at transpile time; retain as-is
                (loop (cdr rest) (cons x acc)))
               (eval-val
                ;; True branch active: unwrap and compile
                (let ((unwrapped (if (and (pair? then-b) (eq? (car then-b) 'begin))
                                     (cdr then-b)
                                     (list then-b))))
                  (loop (append unwrapped (cdr rest)) acc)))
               (else-b
                ;; False branch active: unwrap and compile
                (let ((unwrapped (if (and (pair? else-b) (eq? (car else-b) 'begin))
                                     (cdr else-b)
                                     (list else-b))))
                  (loop (append unwrapped (cdr rest)) acc)))
               (else
                ;; False and no else branch: strip dead code completely
                (loop (cdr rest) acc)))))
           (else
            (loop (cdr rest) (cons x acc))))))))

;; Linter: Detect potential mid-load mutation hazards where a top-level non-procedure definition
;; follows an expression that mutates state, risking R6RS hoisting anomalies.
(define (check-mid-load-hazards forms mod-name)
  (let loop ((rest forms) (seen-exprs '()) (mutated-vars '()))
    (when (pair? rest)
      (let ((x (car rest)))
        (cond
          ;; Detect direct mutations: (set! var val) or (ahash-set! tbl ...)
          ((and (pair? x) (eq? (car x) 'set!) (pair? (cdr x)) (symbol? (cadr x)))
           (loop (cdr rest) (cons x seen-exprs) (cons (cadr x) mutated-vars)))
          ((and (pair? x) (eq? (car x) 'ahash-set!) (pair? (cdr x)) (symbol? (cadr x)))
           (loop (cdr rest) (cons x seen-exprs) (cons (cadr x) mutated-vars)))
          ;; Check if a subsequent definition is a non-procedure definition reading mutated-vars:
          ((def-form? x)
           (when (and (pair? (cdr x)) (symbol? (cadr x)) (pair? (cddr x)))
             ;; It's (define var val) where val is evaluated at load time
             (let ((val (caddr x)))
               (when (not (and (pair? val) (eq? (car val) 'lambda)))
                 (let has-hazard? ((e val))
                   (cond
                     ((symbol? e)
                      (when (memq e mutated-vars)
                        (display (list 'WARNING-MID-LOAD-MUTATION-HAZARD mod-name 'def: (cadr x) 'reads-mutated: e))
                        (newline)))
                     ((pair? e)
                      (has-hazard? (car e))
                      (has-hazard? (cdr e))))))))
           (loop (cdr rest) seen-exprs mutated-vars))
          (else
           (loop (cdr rest) (cons x seen-exprs) mutated-vars)))))))

(define (partition-forms forms)
  (let loop ((rest forms) (defs '()) (exprs '()))
    (if (null? rest)
        (values (reverse defs) (reverse exprs))
        (let ((x (car rest)))
          (if (def-form? x)
              (loop (cdr rest) (cons x defs) exprs)
              (loop (cdr rest) defs (cons x exprs)))))))

(define compiled-modules '())
(define compile-errors '())
(define *all-module-deps* (make-ahash-table))

(define (read-module-header file-path)
  (guard (e (else
             (display (string-append "ERROR: read-module-header failed for " file-path "\n"))
             (display-condition e)
             (newline)
             #f))
    (call-with-input-file file-path
      (lambda (p)
        (let loop ()
          (let ((x (read p)))
            (cond ((eof-object? x) #f)
                  ((and (pair? x) (eq? (car x) 'texmacs-module)) x)
                  (else (loop)))))))))

(define (header->deps header mod-spec)
  (let ((deps '()))
    (for-each
      (lambda (opt)
        (when (and (pair? opt) (memq (car opt) '(:use :inherit)))
          (for-each
            (lambda (s)
              (unless (or (equal? s mod-spec) (member s deps))
                (set! deps (cons s deps))))
            (cdr opt))))
      (cddr header))
    (reverse deps)))

(define (get-module-deps rel-path)
  (let ((spec (rel-path->spec rel-path)))
    (or (ahash-ref *all-module-deps* spec)
        (let* ((src (string-append *progs-dir* "/" rel-path))
               (hdr (and (file-exists? src) (read-module-header src)))
               (deps (if hdr (header->deps hdr spec) '())))
          (ahash-set! *all-module-deps* spec deps)
          deps))))

(define (transpile-module rel-path out-path)
  (display (list 'TRANSPILE-START rel-path)) (newline)
  (guard (e (else
              (display (list 'TRANSPILE-ERROR rel-path)) (newline)
              (display-condition e) (newline)
              (set! compile-errors (cons (cons rel-path e) compile-errors))
              #f))
    (let* ((src (string-append *progs-dir* "/" rel-path))
           (forms (read-all-forms src))
           (has-header? (and (pair? forms)
                             (pair? (car forms))
                             (eq? (caar forms) 'texmacs-module)))
           (hdr (if has-header? (car forms) #f))
           (body (if has-header? (cdr forms) forms)))
      (tm-bind-keywords forms)
      (ensure-dir out-path)
      (if (not has-header?)
          (begin
            (display (list 'SKIP rel-path "no texmacs-module header")) (newline)
            #f)
          (let* ((mod-spec (cadr hdr))
                 (mod-sym (spec->symbol mod-spec))
                 (options (cddr hdr))
                 (deps (header->deps hdr mod-spec)))
            (ahash-set! *all-module-deps* mod-spec deps)

            ;; Track declared dependencies for overload resolution
            (set! current-used-symbols (map spec->symbol deps))

            ;; Import declared dependencies into this file's isolated compilation environment
            (for-each
              (lambda (s)
                (let ((s-sym (spec->symbol s)))
                  (when (memq s-sym compiled-modules)
                    (guard-eval #f '() #f
                      (lambda ()
                        (eval `(import (for ,s-sym run expand)) (compilation-environment)))))))
              deps)

            (set! *current-module* (make-tm-module mod-sym (compilation-environment) '() '() (make-eq-hashtable)))
            (set! module-public-vars '())
            (set! module-local-defs '())
            (let* ((prepared (prepare-forms body)))
              (check-mid-load-hazards prepared rel-path)
              (let* ((public-vars (unique-syms (reverse module-public-vars)))
                     (all-local-defs (unique-syms (reverse module-local-defs)))
                     (seen-imported '())
                     (import-forms '())
                     (export-forms (if (pair? public-vars) (list `(export ,@public-vars)) '())))
                (hashtable-set! module-exports-table mod-sym public-vars)
                (for-each
                  (lambda (opt)
                    (when (pair? opt)
                      (let ((kind (car opt))
                            (specs (cdr opt)))
                        (cond
                          ((eq? kind ':use)
                           (for-each
                             (lambda (s)
                               (let ((s-sym (spec->symbol s)))
                                 (if (memq s-sym compiled-modules)
                                     (let* ((s-exports (get-module-exports s-sym))
                                            (conflicts (filter (lambda (v)
                                                                 (or (memq v all-local-defs)
                                                                     (memq v seen-imported)))
                                                               s-exports)))
                                       (if (null? conflicts)
                                           (begin
                                             (set! import-forms
                                               (cons `(import (for ,s-sym run expand)) import-forms))
                                             (set! seen-imported (append s-exports seen-imported)))
                                           (begin
                                             (set! import-forms
                                               (cons `(import (for (except ,s-sym ,@conflicts) run expand)) import-forms))
                                             (set! seen-imported
                                               (append (filter (lambda (v) (not (memq v conflicts))) s-exports)
                                                       seen-imported)))))
                                     (begin
                                       (display (list 'DEFER-CIRCULAR-IMPORT mod-sym '-> s-sym))
                                       (newline)))))
                             specs))
                          ((eq? kind ':inherit)
                           (for-each
                             (lambda (s)
                               (let ((s-sym (spec->symbol s)))
                                 (if (memq s-sym compiled-modules)
                                     (set! import-forms
                                       (cons `(import (for ,s-sym run expand)) import-forms))
                                     (begin
                                       (display (list 'DEFER-CIRCULAR-IMPORT mod-sym '-> s-sym))
                                       (newline)))
                                 (set! export-forms
                                   (cons `(export (import ,s-sym)) export-forms))))
                             specs))))))
                  options)
                (set! import-forms (reverse import-forms))
                (set! export-forms (reverse export-forms))
                ;; Evaluate eager forms sequentially in source order before partitioning:
                (parameterize ((compile-export-mode? #f))
                  (for-each eval-eager-form! prepared))
                (let-values (((defs exprs) (partition-forms prepared)))
                  (let* ((keywords (tm-collect-keywords forms '()))
                         (keyword-defs (map (lambda (k) `(define ,k ',k)) keywords))
                         (dep-provides (map (lambda (d) `(module-provide ',d)) deps)))
                    (let ((out-p (open-output-file out-path 'replace)))
                      (dynamic-wind
                        (lambda () #f)
                        (lambda ()
                          (display ";;; Auto-generated native Chez Scheme module from " out-p)
                          (display rel-path out-p) (newline out-p)
                          (write `(module ,mod-sym ()
                                    ,@import-forms
                                    ,@export-forms
                                    ,@keyword-defs
                                    ,@defs
                                    ,@dep-provides
                                    ,@exprs)
                                 out-p)
                          (newline out-p))
                        (lambda () (close-port out-p))))
                    mod-sym)))))))))

(define (transpile-and-compile-module rel-path trans-scm out-so)
  (parameterize ((compilation-environment (copy-environment (interaction-environment) #t)))
   (let ((mod-sym (transpile-module rel-path trans-scm)))
    (if mod-sym
        (begin
          (display (list 'COMPILE rel-path '-> out-so)) (newline)
          (call/cc
            (lambda (k)
              (with-exception-handler
                (lambda (e)
                  (if (serious-condition? e)
                      (begin
                        (display (list 'FAIL rel-path)) (newline)
                        (display-condition e) (newline)
                        (when (who-condition? e)
                          (display (list 'WHO: (condition-who e))) (newline))
                        (when (irritants-condition? e)
                          (display (list 'IRRITANTS: (condition-irritants e))) (newline))
                        (when (syntax-violation? e)
                          (display (list 'FORM: (syntax-violation-form e))) (newline)
                          (display (list 'SUBFORM: (syntax-violation-subform e))) (newline))
                        (set! compile-errors (cons (cons rel-path e) compile-errors))
                        (k #f))
                      (void)))
                (lambda ()
                  (parameterize ((compile-export-mode? #t))
                    (compile-file trans-scm out-so))
                  mod-sym)))))
        #f))))

(define compiled-count 0)
(define cached-count 0)
(define (save-module-deps-manifest!)
  (let ((manifest-file (string-append *boot-dir* "/module-deps.scm")))
    (display (list 'SAVING-MANIFEST manifest-file)) (newline)
    (let ((out-p (open-output-file manifest-file 'replace)))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (write (map (lambda (pair) (list (car pair) (cdr pair)))
                      (ahash-table->list *all-module-deps*))
                 out-p)
          (newline out-p))
        (lambda () (close-port out-p))))))

(define (register-module-loaded! rel-path out-so mod-sym is-cached?)
  (get-module-deps rel-path)
  (let* ((load-ok? #t)
         (spec (rel-path->spec rel-path)))
    (ahash-set! *texmacs-modules-loaded* spec #t)
    (guard (e (else
                (ahash-remove! *texmacs-modules-loaded* spec)
                (set! load-ok? #f)
                (display (list 'NATIVE-LOAD-FAIL rel-path (if (condition? e) (with-output-to-string (lambda () (display-condition e))) e)))
                (newline)
                (when (file-exists? out-so) (delete-file out-so))
                (set! compile-errors (cons (cons rel-path e) compile-errors))))
      (load out-so))
    (if load-ok?
      (begin
        (when (member rel-path *kernel-files*)
          (guard-eval 'IMPORT-FAIL (list mod-sym) #f
	          (lambda ()
		          (eval `(import ,mod-sym) (interaction-environment)))))
        (set! compiled-modules (cons mod-sym compiled-modules))
        (if is-cached?
          (begin
            (set! cached-count (+ cached-count 1))
            (display (list 'UP-TO-DATE rel-path)) (newline))
          (begin
            (set! compiled-count (+ compiled-count 1))
            (display (list 'OK rel-path)) (newline))))
      (begin
        (display (list 'SKIPPED rel-path))
        (newline)))))

(define (compile-module-list tier-title file-list)
  (display "========================================================\n")
  (display (string-append "  " tier-title "\n"))
  (display "========================================================\n")
  (for-each
    (lambda (rel-path)
      (let* ((trans-scm (string-append *boot-dir* "/" rel-path))
             (out-so (string-append (substring trans-scm 0 (- (string-length trans-scm) 4)) ".so"))
             (needs-build? (module-needs-recompile? rel-path trans-scm out-so))
             (mod-sym (if needs-build?
                          (transpile-and-compile-module rel-path trans-scm out-so)
                          (spec->symbol (rel-path->spec rel-path)))))
        (cond
          ((and (not needs-build?) (file-exists? out-so))
           (parameterize ((compile-export-mode? #t))
             (register-module-loaded! rel-path out-so mod-sym #t)))
          (mod-sym
           (parameterize ((compile-export-mode? #t))
             (register-module-loaded! rel-path out-so mod-sym #f)))
          (else
           (display (list 'SKIPPED rel-path))
           (newline)))))
    file-list))

(compile-module-list "Compiling TeXmacs Kernel Modules" *kernel-files*)

(newline)
(if (null? compile-errors)
    (begin
      (let* ((user-scm (string-append *boot-dir* "/texmacs-user.scm"))
             (user-so (string-append *boot-dir* "/texmacs-user.so"))
             (user-up-to-date? (and (file-exists? user-so)
                                    (not *recompile-all?*)
                                    (let loop ((l *kernel-files*))
                                      (if (null? l) #t
                                          (let* ((rel (car l))
                                                 (trans-scm (string-append *boot-dir* "/" rel))
                                                 (out-so (string-append (substring trans-scm 0 (- (string-length trans-scm) 4)) ".so"))
                                                 (src (string-append *progs-dir* "/" rel)))
                                            (if (or (file-newer? src user-so)
                                                    (file-newer? out-so user-so))
                                                #f
                                                (loop (cdr l)))))))))
        (if user-up-to-date?
            (begin
              (display (list 'UP-TO-DATE "texmacs-user.so (kernel snapshot)")) (newline)
              (load user-so))
            (begin
              (display "--------------------------------------------------------\n")
              (display "  Building aggregate texmacs-user environment\n")
              (display "--------------------------------------------------------\n")
              (let ((p (open-output-file user-scm 'replace)))
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (display ";;; Aggregate texmacs-user and texmacs-user-kernel\n" p)
                    (for-each
                      (lambda (rel)
                        (let* ((trans-scm (string-append *boot-dir* "/" rel))
                               (out-so (string-append (substring trans-scm 0 (- (string-length trans-scm) 4)) ".so")))
                          (write `(primitive-load ,out-so) p)
                          (newline p)))
                      *kernel-files*)
                    (let* ((all-mods (map (lambda (rel) (spec->symbol (rel-path->spec rel))) *kernel-files*))
                           (imports (map (lambda (m) `(import (for ,m run expand))) all-mods))
                           (exports (map (lambda (m) `(export (import ,m))) all-mods)))
                      (write `(module texmacs-user ()
                                ,@imports
                                ,@exports)
                             p)
                      (newline p)
                      (write `(module texmacs-user-kernel ()
                                (export (import texmacs-user)))
                             p)
                      (newline p)
                      (write `(import texmacs-user-kernel) p)
                      (newline p)
                      (for-each
                        (lambda (m)
                          (write `(import ,m) p)
                          (newline p))
                        all-mods))
                    (write `(unless (top-level-bound? 'texmacs-user)
                              (define-top-level-value 'texmacs-user (interaction-environment)))
                           p)
                    (newline p)
                    (write `(unless (top-level-bound? 'texmacs-user-kernel)
                              (define-top-level-value 'texmacs-user-kernel (interaction-environment)))
                           p)
                    (newline p))
                  (lambda () (close-port p))))
              (display (list 'COMPILE user-scm '-> user-so)) (newline)
              (compile-file user-scm user-so)
              (load user-so)
              (display "--------------------------------------------------------\n")
              (display "  SUCCESS: ALL KERNEL MODULES COMPILED & SNAPSHOTTED!\n")
              (display "--------------------------------------------------------\n"))))
      (compile-module-list "Compiling Tier 2 (Application Core) Modules" *tier2-files*)
      (compile-module-list "Compiling Tier 3 (Core Editing) Modules" *tier3-files*)
      (compile-module-list "Compiling Tier 4 (Desktop GUI & Menus) Modules" *tier4-files*)
      (compile-module-list "Compiling Tier 5 (Document Converters) Modules" *tier5-convert-files*)
      (compile-module-list "Compiling Tier 6 (Dynamic & Interactive Sessions) Modules" *tier6-dynamic-files*)
      (compile-module-list "Compiling Tier 7 (Extended Subsystems & Plugins) Modules" *tier7-extended-files*)
      (save-module-deps-manifest!)
      (write-compiler-db *compiler-db*
                         (string-append *boot-dir* "/compiler-db.fasl"))
      (newline)
      (display "========================================================\n")
      (display "  COMPILATION SUMMARY:\n")
      (display (list "  - Recompiled:" compiled-count "modules")) (newline)
      (display (list "  - Up-to-date (cached):" cached-count "modules")) (newline)
      (display (list "  - Failures:" (length compile-errors))) (newline)
      (when (pair? compile-errors)
        (for-each
          (lambda (err)
            (display (list "    * FAIL:" (car err))) (newline))
          (reverse compile-errors)))
      (display "========================================================\n"))
    (begin
      (display "--------------------------------------------------------\n")
      (display (list "FAILED KERNEL MODULES COUNT:" (length compile-errors))) (newline)
      (for-each
        (lambda (err)
          (display (list "  - " (car err))) (newline))
        compile-errors)
      (display "--------------------------------------------------------\n")))

(when (and (top-level-bound? 'quit-TeXmacs)
           (not (top-level-bound? '*dont-quit*)))
  (quit-TeXmacs))
