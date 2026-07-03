;;; process-host.sld --- Portable host process-spawn shim for the native CLI
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Host/core boundary: this library owns the one host-specific capability the
;;; native CLI process boundary needs -- spawning a real child process and
;;; capturing its output -- behind a host-neutral interface.  R7RS-small has no
;;; portable process spawn, so each host branch imports its own process module.
;;;
;;; Every branch runs the child through `/bin/sh -c' with a trailing exit-status
;;; marker (`printf MARKER%s "$?"'), so the only host-specific capability each
;;; branch must provide is capturing a command's standard output.  Standard
;;; input redirection, standard error redirection, and the child exit status are
;;; carried by the shell, which keeps the per-host surface minimal and uniform.
;;; Hosts without a usable process module fall to the `else' branch, where
;;; `cli-host-available?' is #f and `cli-host-run' raises before any host work.

(define-library (cli process-host)
  (export cli-host-available? cli-host-run)
  (import (scheme base)
          (scheme file)
          (prefix (stdlib generator) gen:))

  ;; Host-specific process module and stdout capture.  Each branch defines
  ;; `cli-host-available?' and `cli-host--capture', the only host-dependent
  ;; pieces; everything below in the host-neutral `begin' builds on them.
  (cond-expand
   (gambit
    ;; Import only `shell-command'; `(gambit)' as a whole re-exports `guard' and
    ;; other identifiers that clash with `(scheme base)', and Gambit's keyword
    ;; argument syntax for `open-process' is disabled under `-:r7rs'.
    ;; `shell-command' with capture returns (STATUS . OUTPUT); the marker carries
    ;; the status, so the captured OUTPUT is all this branch needs.
    (import (only (gambit) shell-command))
    (begin
      (define (cli-host-available?) #t)
      (define (cli-host--capture shell-command-string)
        (cdr (shell-command shell-command-string #t)))))
   (chibi
    (import (chibi process))
    (begin
      (define (cli-host-available?) #t)
      (define (cli-host--capture shell-command)
        (process->string (list "/bin/sh" "-c" shell-command)))))
   (guile
    (import (ice-9 popen))
    (begin
      (define (cli-host-available?) #t)
      (define (cli-host--capture shell-command)
        ;; `"r"' is Guile's `OPEN_READ' mode, which is not bound under `--r7rs'.
        (let* ((port (open-pipe* "r" "/bin/sh" "-c" shell-command))
               (output (cli-host--drain port)))
          (close-pipe port)
          output))))
   (gauche
    (import (gauche process) (gauche base))
    (begin
      (define (cli-host-available?) #t)
      (define (cli-host--capture shell-command)
        (let* ((process (run-process (list "/bin/sh" "-c" shell-command)
                                     :output :pipe))
               (output (cli-host--drain (process-output process))))
          (process-wait process)
          output))))
   (racket
    (import (racket system))
    (begin
      (define (cli-host-available?) #t)
      (define (cli-host--capture shell-command)
        (let ((output (open-output-string)))
          (parameterize ((current-output-port output))
            (system shell-command))
          (get-output-string output)))))
   (else
    (begin
      (define (cli-host-available?) #f)
      (define (cli-host--capture shell-command)
        (error "cli-host: no process module available for this host"
               shell-command)))))

  (begin
    ;; Marker that separates captured child stdout from the shell exit status.
    ;; The command's own stdout precedes it; `printf' appends it last, so the
    ;; first occurrence delimits the boundary.
    (define cli-host--exit-marker "__CONSENT_CLI_EXIT__")

    (define (cli-host--port-character-generator port)
      "Return a generator that reads characters from PORT until EOF."
      (lambda ()
        (read-char port)))

    (define (cli-host--drain port)
      "Read every remaining character from PORT into a string.  Used by host"
      "branches whose process module yields an input port rather than a string."
      (gen:generator->string (cli-host--port-character-generator port)))

    (define (cli-host--escape string)
      "Return STRING with each single quote made shell-safe, for single-quoting."
      (let ((out (open-output-string)))
        (string-for-each
         (lambda (character)
           (if (char=? character #\')
               (write-string "'\\''" out)
               (write-char character out)))
         string)
        (get-output-string out)))

    (define (cli-host--quote string)
      "Return STRING wrapped as a single shell word."
      (string-append "'" (cli-host--escape string) "'"))

    (define (cli-host--join words)
      "Join shell-quoted WORDS with spaces."
      (cond
       ((null? words) "")
       ((null? (cdr words)) (car words))
       (else (string-append (car words) " " (cli-host--join (cdr words))))))

    (define (cli-host--index-of haystack needle)
      "Return the index of the first occurrence of NEEDLE in HAYSTACK, or #f."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((start 0))
          (cond
           ((> (+ start needle-length) haystack-length) #f)
           ((string=? (substring haystack start (+ start needle-length)) needle)
            start)
           (else (loop (+ start 1)))))))

    (define (cli-host--environment-prefix environment)
      "Render an environment-grant alist of (NAME . VALUE) string pairs as the"
      "`NAME='VALUE' ...' shell prefix that scopes those variables to the"
      "child."
      (if (null? environment)
          ""
          (string-append
           (car (car environment)) "=" (cli-host--quote (cdr (car environment)))
           " "
           (cli-host--environment-prefix (cdr environment)))))

    (define (cli-host--shell-program command arguments stdin-file stderr-file
                                     cwd environment)
      "Build the `/bin/sh -c' program: run COMMAND/ARGUMENTS as a group under"
      "the optional CWD and ENVIRONMENT grants with the optional stdin and"
      "stderr redirections, then print the exit marker and the shell `$?'."
      "Returning the status through stdout keeps exit-status capture"
      "host-neutral."
      (string-append
       "{ "
       (if cwd (string-append "cd " (cli-host--quote cwd) " && ") "")
       (cli-host--environment-prefix environment)
       (cli-host--quote command)
       (if (null? arguments) "" " ")
       (cli-host--join (map cli-host--quote arguments))
       " ; }"
       (if stdin-file (string-append " < " (cli-host--quote stdin-file)) "")
       (if stderr-file (string-append " 2> " (cli-host--quote stderr-file)) "")
       " ; printf '" cli-host--exit-marker "%s' \"$?\""))

    (define (cli-host--read-file file)
      "Read FILE's whole contents as a string, then delete it; return \"\" when"
      "FILE is absent.  The caller owns the path, so the captured stderr does"
      "not outlive the boundary call."
      (if (and file (file-exists? file))
          (let ((contents (call-with-input-file file cli-host--drain)))
            (delete-file file)
            contents)
          ""))

    (define (cli-host-run command arguments stdin-file stderr-file cwd
                          environment)
      "Spawn COMMAND with ARGUMENTS across a real process boundary and return"
      "a list (EXIT-STATUS STDOUT STDERR).  STDIN-FILE and STDERR-FILE, when"
      "non-#f, back the child's standard input and standard error.  CWD, when"
      "non-#f, is the child's granted working directory, and ENVIRONMENT is an"
      "alist of (NAME . VALUE) string pairs granted to the child.  Signals an"
      "error on a host without a process module, so a denied or unsupported"
      "request never reaches the shell."
      #((parameters
         (command (type string)
          (description "Executable name or path to spawn as the child."))
         (arguments (type (list-of string))
          (description ("List of string arguments passed to COMMAND as one group.")))
         (stdin-file (type (or string boolean))
          (description ("Path backing the child's standard input, or #f for none.")))
         (stderr-file (type (or string boolean))
          (description ("Path capturing the child's standard error, or #f for none.")))
         (cwd . ("Granted working directory for the child, or #f to inherit."))
         (environment (type list)
          (description ("Alist of (NAME . VALUE) string pairs granted to the child."))))
        (returns (type list)
         (description
          ("A list (EXIT-STATUS STDOUT STDERR): the child's exit"
            "status and its captured standard output and standard"
            "error.")))
        (effects host-eval error))
      (unless (cli-host-available?)
        (error "cli-host-run: process spawning is unavailable on this host"))
      (let* ((program (cli-host--shell-program command arguments
                                               stdin-file stderr-file
                                               cwd environment))
             (captured (cli-host--capture program))
             (marker (cli-host--index-of captured cli-host--exit-marker))
             (stdout (if marker (substring captured 0 marker) captured))
             (status (if marker
                         (or (string->number
                              (substring captured
                                         (+ marker (string-length
                                                    cli-host--exit-marker))
                                         (string-length captured)))
                             -1)
                         -1)))
        (list status stdout (cli-host--read-file stderr-file))))))
