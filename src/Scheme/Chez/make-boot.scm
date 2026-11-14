;;; make-boot.scm -- Assemble ahead-of-time (AOT) Chez Scheme images (texmacs.so & texmacs.boot)
;;;
;;; Usage (CLI):
;;;   scheme --script src/Scheme/Chez/make-boot.scm [boot-dir] [out-so-file] [out-boot-file]
;;; Usage (Scheme):
;;;   (load "src/Scheme/Chez/make-boot.scm")
;;;   (assemble-aot-images!)

(import (chezscheme))

(define (make-boot:string-suffix? suf s)
  (let ((suflen (string-length suf))
        (slen (string-length s)))
    (and (>= slen suflen)
         (string=? (substring s (- slen suflen) slen) suf))))

(define (make-boot:concatenate-files out-path input-files)
  (when (file-exists? out-path) (delete-file out-path))
  (let ((out (open-file-output-port out-path (file-options replace) (buffer-mode block))))
    (for-each
      (lambda (in-path)
        (let* ((in (open-file-input-port in-path (file-options) (buffer-mode block)))
               (buf (make-bytevector 65536)))
          (let loop ()
            (let ((n (get-bytevector-n! in buf 0 65536)))
              (unless (eof-object? n)
                (put-bytevector out buf 0 n)
                (loop))))
          (close-port in)))
      input-files)
    (close-port out)))

(define (assemble-aot-images! . args)
  (let* ((boot-dir
          (cond ((>= (length args) 1) (car args))
                ((getenv "TEXMACS_BOOT_PATH") (getenv "TEXMACS_BOOT_PATH"))
                ((file-exists? "build-texmacos/boot") "build-texmacos/boot/")
                ((file-exists? "boot") "boot/")
                (else "build-texmacos/boot/")))
         (boot-dir (if (and (> (string-length boot-dir) 0)
                            (not (char=? (string-ref boot-dir (- (string-length boot-dir) 1)) #\/)))
                       (string-append boot-dir "/")
                       boot-dir))
         (order-file (string-append boot-dir "boot-order-full.scm"))
         (out-so
          (cond ((>= (length args) 2) (cadr args))
                ((getenv "TEXMACS_SO_FILE") (getenv "TEXMACS_SO_FILE"))
                (else (string-append boot-dir "texmacs.so"))))
         (out-boot
          (cond ((>= (length args) 3) (caddr args))
                ((getenv "TEXMACS_BOOT_FILE") (getenv "TEXMACS_BOOT_FILE"))
                (else (string-append boot-dir "texmacs.boot")))))

    (unless (file-exists? order-file)
      (error 'make-boot "Boot order manifest not found" order-file))

    (let* ((boot-order (read (open-input-file order-file)))
           (raw-so-paths (map (lambda (rel) (string-append boot-dir rel)) boot-order))
           ;; boot-chez.so is loaded by initialize_scheme(); chez-compat.so is loaded
           ;; by init-texmacs-aot.scm to provide early Guile macros before texmacs.so.
           (so-paths (remp (lambda (p)
                             (or (make-boot:string-suffix? "/boot-chez.so" p)
                                 (string=? p "boot-chez.so")
                                 (make-boot:string-suffix? "/chez-compat.so" p)
                                 (string=? p "chez-compat.so")))
                           raw-so-paths)))

      (printf "Assembling ~a input modules into AOT binary images...\n" (length so-paths))

      (for-each
        (lambda (f)
          (unless (file-exists? f)
            (error 'make-boot "Missing compiled module .so file" f)))
        so-paths)

      ;; 1. Generate Approach 1 image: texmacs.so (CSUG 2.8 concatenated object file)
      (printf "Generating ~a (Approach 1: concatenated object file)...\n" out-so)
      (make-boot:concatenate-files out-so so-paths)
      (let ((sz (file-length (open-file-input-port out-so))))
        (printf "SUCCESS: Created AOT consolidated object file ~a (~,2f MB, ~a bytes)\n"
                out-so (/ sz 1048576.0) sz))

      ;; 2. Generate Approach 2 image: texmacs.boot (CSUG 12.1 native boot file)
      (printf "Generating ~a (Approach 2: native boot file)...\n" out-boot)
      (when (file-exists? out-boot) (delete-file out-boot))
      (apply make-boot-file out-boot '("petite" "scheme") so-paths)
      (let ((sz (file-length (open-file-input-port out-boot))))
        (printf "SUCCESS: Created AOT boot image ~a (~,2f MB, ~a bytes)\n"
                out-boot (/ sz 1048576.0) sz)))))

;; If executed directly via scheme --script, run immediately
(when (top-level-bound? 'command-line-arguments)
  (let ((args (command-line-arguments)))
    (when (or (null? args)
              (and (pair? args)
                   (not (string=? (car args) "-compile-modules"))))
      (apply assemble-aot-images! args))))
