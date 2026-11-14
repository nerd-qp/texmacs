;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : init-texmacs-aot.scm
;; DESCRIPTION : TeXmacs Chez Scheme AOT bootstrap (loads texmacs.so)
;; COPYRIGHT   : (C) 2026
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(when (top-level-bound? '*init-texmacs-aot-loaded*)
  (display "WARNING: init-texmacs-aot.scm loaded more than once!\n"))
(define *init-texmacs-aot-loaded* #t)

(define load (lambda (f . ignore-env) (tm-load-file f)))

(unless (top-level-bound? 'notify-preferences-booted)
  (define-top-level-value 'notify-preferences-booted (lambda () (noop))))

;; 1. Load and import chez-compat.so first to provide macro-expansion helpers (ca*r, etc.)
(let* ((boot-env (getenv "TEXMACS_BOOT_PATH"))
       (tm-path (getenv "TEXMACS_PATH"))
       (candidates (list (if boot-env (string-append boot-env "/kernel/boot/chez-compat.so") #f)
                         (if tm-path (string-append tm-path "/boot/kernel/boot/chez-compat.so") #f)
                         "build-texmacos/boot/kernel/boot/chez-compat.so"
                         "boot/kernel/boot/chez-compat.so")))
  (let loop ((c candidates))
    (cond ((null? c) (error 'init-texmacs-aot "Cannot locate chez-compat.so"))
          ((and (car c) (file-exists? (car c)))
           (primitive-load (car c)))
          (else (loop (cdr c))))))

(eval '(import kernel:boot:chez-compat) (interaction-environment))

;; 2. Load the consolidated AOT object file (contains remaining 452 modules)
(let* ((boot-env (getenv "TEXMACS_BOOT_PATH"))
       (tm-path (getenv "TEXMACS_PATH"))
       (candidates (list (if (getenv "TEXMACS_SO_FILE") (getenv "TEXMACS_SO_FILE") #f)
                         (if (getenv "TEXMACS_BOOT_FILE") (getenv "TEXMACS_BOOT_FILE") #f)
                         (if boot-env (string-append boot-env "/texmacs.so") #f)
                         (if tm-path (string-append tm-path "/boot/texmacs.so") #f)
                         "build-texmacos/boot/texmacs.so"
                         "boot/texmacs.so")))
  (let loop ((c candidates))
    (cond ((null? c) (error 'init-texmacs-aot "Cannot locate texmacs.so"))
          ((and (car c) (file-exists? (car c)))
           (primitive-load (car c)))
          (else (loop (cdr c))))))

;; Import all resident AOT modules into the interaction environment
(eval '(import
  kernel:boot:chez-compat
  kernel:boot:compat
  kernel:boot:abbrevs
  kernel:boot:debug
  kernel:boot:srfi
  kernel:boot:ahash-table
  kernel:boot:prologue
  kernel:library:base
  kernel:library:list
  kernel:library:tree
  kernel:library:content
  kernel:library:patch
  kernel:regexp:regexp-match
  kernel:regexp:regexp-select
  kernel:logic:logic-bind
  kernel:logic:logic-unify
  kernel:logic:logic-rules
  kernel:logic:logic-query
  kernel:logic:logic-data
  kernel:texmacs:tm-define
  kernel:texmacs:tm-preferences
  kernel:texmacs:tm-dialogue
  kernel:texmacs:tm-plugins
  kernel:texmacs:tm-modes
  kernel:texmacs:tm-secure
  kernel:texmacs:tm-convert
  kernel:texmacs:tm-language
  kernel:texmacs:tm-file-system
  kernel:texmacs:tm-states
  kernel:gui:gui-markup
  kernel:gui:menu-define
  kernel:gui:kbd-define
  kernel:gui:menu-widget
  kernel:gui:speech-define
  kernel:gui:kbd-handlers
  kernel:gui:menu-test
  kernel:old-gui:old-gui-widget
  kernel:old-gui:old-gui-factory
  kernel:old-gui:old-gui-form
  kernel:old-gui:old-gui-test
  utils:library:cpp-wrap
  utils:library:tree
  utils:library:smart-table
  convert:rewrite:tmtm-brackets
  utils:plugins:plugin-convert
  utils:misc:markup-funcs
  utils:misc:artwork
  utils:misc:tooltip
  utils:handwriting:handwriting
  bibtex:bib-utils
  utils:base:environment
  texmacs:texmacs:tm-tools
  utils:library:length
  utils:library:cursor
  utils:edit:variants
  utils:library:ptrees
  bibtex:bib-complete
  source:macro-search
  generic:generic-edit
  generic:document-style
  generic:document-edit
  texmacs:texmacs:tm-server
  texmacs:texmacs:tm-view
  texmacs:texmacs:tm-print
  texmacs:texmacs:tm-files
  texmacs:keyboard:config-kbd
  texmacs:menus:main-menu
  tools:ai:ai-batch
  fonts:fonts-ec
  fonts:fonts-adobe
  fonts:fonts-x
  fonts:fonts-math
  fonts:fonts-foreign
  fonts:fonts-misc
  fonts:fonts-composite
  fonts:fonts-truetype
  utils:automate:auto-edit
  utils:automate:auto-build
  utils:automate:auto-tmfs
  utils:automate:auto-kbd
  utils:edit:selections
  texmacs:keyboard:prefix-kbd
  utils:edit:auto-close
  generic:format-edit
  text:text-drd
  text:text-edit
  texmacs:keyboard:latex-kbd
  generic:embedded-edit
  generic:format-drd
  generic:format-geometry-edit
  source:source-drd
  source:source-edit
  doc:help-funcs
  generic:generic-kbd
  generic:generic-speech
  generic:generic-speech-en
  generic:generic-speech-fr
  text:text-kbd
  math:math-drd
  convert:tools:tmconcat
  math:math-edit
  table:table-edit
  math:math-kbd
  math:math-stats
  math:math-speech
  text:text-speech
  math:math-speech-en
  text:text-speech-en
  math:math-speech-fr
  text:text-speech-fr
  text:chinese:chinese
  math:math-sem-edit
  math:math-adjust-en
  math:math-adjust-fr
  convert:rewrite:init-rewrite
  doc:apidoc-collect
  doc:apidoc-funcs
  doc:apidoc-widgets
  prog:scheme-tools
  prog:prog-edit
  prog:glue-symbols
  prog:scheme-autocomplete
  utils:misc:tm-keywords
  prog:scheme-edit
  prog:dot-edit
  prog:java-edit
  prog:scala-edit
  prog:cpp-edit
  prog:python-edit
  prog:fortran-edit
  prog:prog-kbd
  source:source-kbd
  table:table-kbd
  graphics:graphics-drd
  graphics:graphics-utils
  graphics:graphics-env
  graphics:graphics-main
  graphics:graphics-object
  graphics:graphics-single
  dynamic:dynamic-drd
  dynamic:animate-edit
  graphics:graphics-group
  graphics:graphics-animate
  graphics:graphics-edit
  graphics:graphics-kbd
  dynamic:fold-edit
  education:edu-drd
  education:edu-edit
  education:edu-kbd
  dynamic:fold-kbd
  utils:plugins:plugin-eval
  utils:plugins:plugin-cmd
  dynamic:scripts-drd
  dynamic:scripts-edit
  dynamic:scripts-kbd
  text:text-structure
  link:locus-edit
  version:version-drd
  version:version-edit
  dynamic:session-drd
  dynamic:session-edit
  dynamic:calc-drd
  dynamic:calc-edit
  dynamic:calc-table
  dynamic:calc-kbd
  doc:tmdoc-kbd
  doc:apidoc-kbd
  database:db-base
  database:db-format
  database:db-users
  database:db-version
  database:db-edit
  database:db-convert
  database:db-tmfs
  database:db-widgets
  texmacs:menus:print-widgets
  texmacs:menus:file-menu
  generic:generic-menu
  generic:document-menu
  database:db-menu
  convert:bibtex:init-bibtex
  convert:tools:output
  convert:latex:latex-command-drd
  convert:latex:latex-symbol-drd
  convert:latex:latex-texmacs-drd
  convert:latex:latex-define
  convert:latex:latex-overload
  convert:latex:latex-drd
  convert:latex:latex-tools
  convert:latex:texout
  convert:bibtex:bibtexout
  database:bib-db
  database:bib-manage
  database:bib-menu
  database:bib-kbd
  link:link-edit
  link:link-extern
  link:link-navigate
  link:link-extract
  link:link-kbd
  version:version-compare
  version:version-kbd
  utils:library:process
  tools:spell:spell-edit
  tools:spell:spell-lantool
  tools:spell:spell-kbd
  convert:images:init-images
  convert:html:init-html
  convert:latex:init-latex
  convert:tmml:init-tmml
  prog:prog-format
  kernel:gui:menu-convert
  language:std-symbols
  language:std-math
  utils:cas:cas-rewrite
  utils:cas:cas-out
  doc:tmdoc
  utils:test:test-convert
  utils:misc:gui-utils
  utils:misc:gui-keyboard
  bibtex:bib-widgets
  texmacs:menus:edit-menu
  texmacs:menus:view-widgets
  texmacs:menus:view-menu
  texmacs:menus:tools-menu
  language:natural
  texmacs:menus:preferences-menu
  texmacs:menus:preferences-widgets
  texmacs:menus:preferences-tools
  generic:embedded-menu
  generic:format-menu
  generic:document-part
  generic:insert-menu
  generic:generic-doc
  generic:search-widgets
  generic:spell-widgets
  generic:format-widgets
  generic:pattern-selector
  generic:document-widgets
  generic:format-tools
  generic:document-tools
  generic:pattern-tools
  text:text-menu
  math:math-menu
  prog:prog-menu
  source:macro-edit
  source:macro-widgets
  source:source-menu
  source:macro-menu
  source:shortcut-edit
  source:shortcut-widgets
  table:table-menu
  table:table-widgets
  table:table-tools
  graphics:graphics-menu
  graphics:graphics-markup
  language:minimal
  education:edu-menu
  dynamic:fold-menu
  dynamic:program-drd
  dynamic:program-menu
  dynamic:program-edit
  dynamic:session-menu
  dynamic:scripts-menu
  dynamic:calc-menu
  dynamic:animate-menu
  dynamic:scripts-plot
  doc:tmdoc-drd
  doc:tmdoc-edit
  doc:apidoc-menu
  doc:tmdoc-menu
  doc:help-menu
  doc:docgrep
  doc:tmdoc-search
  doc:tmweb
  doc:apidoc-markup
  doc:apidoc
  convert:tmml:tmmlout
  convert:tmml:tmmltm
  convert:tmml:tmtmml
  convert:images:tmimage
  convert:tools:tmtable
  convert:mathml:mathml-drd
  convert:mathml:tmmath
  convert:tools:stm
  convert:tools:tmlength
  convert:tools:tmcolor
  convert:tools:old-tmtable
  convert:tools:sxml
  convert:tools:sxhtml
  convert:tools:css
  convert:html:htmlout
  convert:html:tmhtml
  convert:html:tmhtml-expand
  convert:tools:tmpre
  doc:tmdoc-markup
  convert:latex:tmtex
  convert:latex:tmtex-widgets
  part:part-shared
  part:part-tmfs
  part:part-menu
  database:bib-local
  security:gpg:gpg-base
  security:gpg:gpg-wallet
  security:wallet:wallet-base
  security:keychain:macos-security
  security:wallet:wallet-menu
  security:gpg:gpg-widgets
  security:gpg:gpg-edit
  security:gpg:gpg-menu
  client:client-authentication
  client:client-base
  client:client-remote-config
  client:client-db
  version:version-tmfs
  client:client-tmfs
  server:server-authentication
  security:password
  server:server-base
  server:server-widgets
  server:server-db
  server:server-cache
  server:server-tmfs
  server:server-db-sync
  server:server-sync
  server:server-notifications
  server:server-chat
  server:server-menu
  client:client-db-sync
  client:client-sync
  client:client-chat
  utils:relate:live-document
  utils:relate:live-connection
  utils:relate:live-view
  client:client-live
  client:client-notifications
  client:client-widgets
  client:client-menu
  notification:notification-base
  link:link-menu
  link:ref-edit
  link:ref-menu
  version:version-menu
  debug:debug-menu
  prog:scheme-menu
  texmacs:menus:developer-menu
  debug:debug-widgets
  tools:poster:poster-drd
  tools:poster:poster-edit
  tools:poster:poster-menu
  tools:theme:theme-edit
  tools:theme:theme-menu
  tools:ai:ai-translate
  fonts:font-old-menu
  fonts:font-sample
  fonts:font-new-widgets
  convert:tools:environment
  convert:tools:xmltm
  convert:mathml:mathtm
  convert:html:htmltm
  convert:html:htmltm-test
  convert:html:tmhtml-test
  convert:tools:xmltm-test
  convert:tools:tmlength-test
  convert:tools:environment-test
  convert:mathml:mathtm-test
  convert:tmml:tmmltm-test
  prog:prog-format-test
  server:server-cache-test
  server:server-backup
  server:server-fixtures
  server:server-backup-test
  server:server-notifications-test
  server:server-tmfs-test
  utils:cite:cite-sort
  utils:cite:cite-sort-test
  check:check-master
  database:title-transform
  database:title-markup
  math:math-markup
  table:table-doc
  text:text-natbib
  texmacs:menus:view-tools
  generic:document-doc
  convert:latex:tmtex-ams
  convert:latex:tmtex-acm
  convert:latex:tmtex-beamer
  convert:latex:tmtex-elsevier
  convert:latex:tmtex-ieee
  convert:latex:tmtex-revtex
  convert:latex:tmtex-springer
  convert:bibtex:bibtextm
  convert:bibtex:tmbibtex
  convert:coq:scmcoqml
  convert:coq:coqmlscm
  convert:coq:coqmlout
  convert:coq:vernacout
  convert:coq:gallinatm
  convert:coq:tmvernac
  convert:coq:init-coqml
  dynamic:calc-markup
  dynamic:fold-markup
  dynamic:session-doc
  dynamic:program-doc
  bibtex:plain
  bibtex:abbrv
  bibtex:abstract
  bibtex:acm
  bibtex:alpha
  bibtex:elsart-num
  bibtex:ieeetr
  bibtex:siam
  bibtex:unsrt
  client:client-markup
  convert:coq:coqmltest
  convert:html:htmltest
  convert:latex:test-tmtex
  convert:latex:textest
  database:db-markup
  education:edu-markup
  kernel:library:iterator
  kernel:logic:logic-test
  kernel:regexp:regexp-test
  kernel:texmacs:tm-convert-test
  link:ref-markup
  prog:default-lang
  security:keychain:win-security
  server:server-live
  text:cyrillic:cp1251-kbd
  text:cyrillic:jcuken-kbd
  text:cyrillic:koi8-kbd
  text:cyrillic:translit-kbd
  text:cyrillic:yawerty-kbd
  text:vietnamese:vietnamese
  tools:comment:comment-drd
  tools:comment:comment-edit
  tools:comment:comment-widgets
  tools:comment:comment-menu
  utils:automate:auto-menu
  utils:email:email-tmfs
  utils:literate:lp-edit
  utils:literate:lp-build
  utils:literate:lp-menu
  utils:misc:doxygen
  utils:misc:extern-demo
  utils:misc:tiles
  utils:misc:translation-list
  utils:misc:updater
  utils:relate:live-menu
  utils:relate:relate-menu
  utils:test:test-latex-export
  version:version-git
  version:version-svn
) (interaction-environment))

;; Runtime definitions for export-bearing syntax
(define-syntax define-public
  (syntax-rules ()
    ((_ (name . args) body ...)
     (define (name . args) body ...))
    ((_ name val)
     (define name val))))

(define-syntax indirect-export
  (syntax-rules ()
    ((_ id ...) (noop))))

(define-syntax define-public-macro
  (syntax-rules ()
    ((_ (nm . formals) body ...)
     (define-macro (nm . formals) body ...))
    ((_ nm val)
     (define-macro nm val))))

(define supports-email? (url-exists-in-path? "mmail"))
(if supports-email? (eval '(import utils:email:email-tmfs) (interaction-environment)))

(tm-define (notify-set-attachment name key val) (noop))

;; Fix Chez Scheme symbol?/keyword? conflation in tree-ref:
;; In Guile, keywords (:up, :next, :previous, etc.) are distinct from symbols,
;; so (symbol? :up) => #f, falling through to (select t l).
;; In Chez Scheme, keywords are symbols, causing (symbol? :up) => #t which erroneously
;; looks for a child node named :up and returns #f.
(tm-define (tree-ref t . l)
  (cond ((not (tree? t)) #f)
        ((null? l) t)
        ((integer? (car l))
         (with i (car l)
           (and (tree-compound? t) (>= i 0) (< i (tree-arity t))
                (apply tree-ref (cons (tree-child-ref t i) (cdr l))))))
        ((== (car l) :first)
         (apply tree-ref (cons t (cons 0 (cdr l)))))
        ((== (car l) :last)
         (and (tree-compound? t)
              (apply tree-ref (cons t (cons (- (tree-arity t) 1) (cdr l))))))
        ((and (symbol? (car l)) (not (keyword? (car l))))
         (and (tree-compound? t)
              (with i (list-find-index (tree-children t)
                                       (cut tree-is? <> (car l)))
                (apply tree-ref (cons t (cons i (cdr l)))))))
        (else (with r (select t l)
                (and (nnull? r) (car r))))))

(tm-property (open-search) (:interactive #t))
(tm-property (open-replace) (:interactive #t))
(tm-property (open-paragraph-format) (:interactive #t))
(tm-property (open-page-format) (:interactive #t)
                                (:applicable (not (selection-active?))))
(tm-property (open-source-tree-preferences) (:interactive #t))
(tm-property (open-document-paragraph-format) (:interactive #t))
(tm-property (open-document-page-format) (:interactive #t))
(tm-property (open-document-metadata) (:interactive #t))
(tm-property (open-document-colors) (:interactive #t))
(tm-property (open-pattern-selector cmd w) (:interactive #t))
(tm-property (open-gradient-selector cmd) (:interactive #t))
(tm-property (open-background-picture-selector cmd) (:interactive #t))

(tm-property (open-macro-editor l mode) (:interactive #t))
(tm-property (create-table-macro l mode) (:interactive #t))
(tm-property (open-macros-editor mode) (:interactive #t))
(tm-property (edit-focus-macro) (:interactive #t))
(tm-property (open-shortcuts-editor . opt) (:interactive #t))
(when (url-exists? "$TEXMACS_HOME_PATH/system/shortcuts.scm")
  (delayed (:idle 100) (init-user-shortcuts)))

(tm-property (open-cell-properties) (:interactive #t))
(tm-property (open-table-properties) (:interactive #t))

(define-secure-symbols arrow-with-text arrow-with-text*)
(define-secure-symbols tmdoc-include youtube-select)
(tm-property (open-website-builder) (:interactive #t))
(define-secure-symbols ext-tmhtml-eqnarray*)
(tm-property (open-biblio) (:interactive #t))
(define-secure-symbols preview-reference)

(for-each lazy-plugin-initialize (plugin-list))

(tm-property (open-font-selector) (:interactive #t))
(tm-property (open-document-font-selector) (:interactive #t))

(when (updater-supported?)
  (delayed (:idle 2000) (updater-initialize)))

(delayed (:idle 10000) (autosave-delayed))
(texmacs-banner)
