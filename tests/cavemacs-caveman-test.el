;;; cavemacs-caveman-test.el --- Tests for cavemacs-caveman  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Unit tests for the caveman skill integration: detection,
;; activation triggers, level cycling, header-line plumbing, and
;; companion-command registration.
;;
;;; Code:

(require 'ert)
(require 'cavemacs-caveman)
(require 'cavemacs-commands)
(require 'cavemacs-pretty)

;; -----------------------------------------------------------------------------
;; Test helpers
;; -----------------------------------------------------------------------------

(defmacro cavemacs-caveman-test--with-fake-root (root &rest body)
  "Bind `cavemacs-caveman-skill-paths' to scopes rooted at ROOT for BODY."
  (declare (indent 1))
  `(let ((cavemacs-caveman-skill-paths
          (list (cons "project" ".cave/skills/caveman/SKILL.md")
                (cons "global"
                      (expand-file-name "global-skill/SKILL.md" ,root)))))
     ,@body))

(defmacro cavemacs-caveman-test--with-fake-conn (&rest body)
  "Run BODY in a temp buffer with a fake live RPC connection.
Outbound `cavemacs-rpc-send' calls land in `sent' (a buffer-local
list of (TYPE . PLIST) pairs).  Returns the (reversed) list, so
tests that care about envelopes can bind the macro to a variable."
  `(with-temp-buffer
     (setq-local cavemacs-shell--conn 'fake)
     (setq-local cavemacs-shell--project-root default-directory)
     (let ((sent '()))
       (cl-letf (((symbol-function 'cavemacs-rpc-live-p)
                  (lambda (_c) t))
                 ((symbol-function 'cavemacs-rpc-send)
                  (lambda (_conn type &rest fields)
                    (push (cons type fields) sent)
                    "fake-id"))
                 ((symbol-function 'cavemacs-render--notice)
                  (lambda (&rest _args) nil)))
         (prog1 (progn ,@body)
           ;; Side effect: reverse `sent' so the visible-from-outside
           ;; list is in send order.  Tests that ignore the return
           ;; value also don't care about this ordering.
           (setq sent (nreverse sent)))
         sent))))

;; -----------------------------------------------------------------------------
;; Detection
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-caveman/detects-project-install ()
  (let* ((root (make-temp-file "cavemacs-caveman-root-" t)))
    (unwind-protect
        (let ((skill (expand-file-name ".cave/skills/caveman/SKILL.md" root)))
          (make-directory (file-name-directory skill) t)
          (write-region "fake skill" nil skill)
          (should (equal "project" (cavemacs-caveman-installed-p root)))
          (should (equal skill (cavemacs-caveman-skill-path root))))
      (delete-directory root t))))

(ert-deftest cavemacs-caveman/detects-global-install ()
  (let* ((root (make-temp-file "cavemacs-caveman-root-" t))
         (fake-global (expand-file-name "fakehome" root))
         (skill (expand-file-name "global-skill/SKILL.md" fake-global)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory skill) t)
          (write-region "fake skill" nil skill)
          (cavemacs-caveman-test--with-fake-root fake-global
            (should (equal "global"
                           (cavemacs-caveman-installed-p root)))))
      (delete-directory root t))))

(ert-deftest cavemacs-caveman/none-installed ()
  (let ((root (make-temp-file "cavemacs-caveman-empty-" t)))
    (unwind-protect
        (let ((cavemacs-caveman-skill-paths
               '(("project" . ".cave/skills/caveman/SKILL.md"))))
          (should-not (cavemacs-caveman-installed-p root))
          (should-not (cavemacs-caveman-skill-path root)))
      (delete-directory root t))))

;; -----------------------------------------------------------------------------
;; Activation
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-caveman/enable-sends-correct-prompt ()
  (let ((sent (cavemacs-caveman-test--with-fake-conn
               (cavemacs-caveman-enable "full"))))
    (should (= 1 (length sent)))
    (let* ((envelope (car sent))
           (type (car envelope))
           (msg  (plist-get (cdr envelope) :message)))
      (should (equal "prompt" type))
      (should (equal "/caveman full" msg)))))

(ert-deftest cavemacs-caveman/enable-respects-default-level ()
  (let ((cavemacs-caveman-default-level "ultra"))
    (let ((sent (cavemacs-caveman-test--with-fake-conn
                 (cavemacs-caveman-enable nil))))
      (should (equal "/caveman ultra"
                     (plist-get (cdr (car sent)) :message))))))

(ert-deftest cavemacs-caveman/enable-validates-level ()
  (cavemacs-caveman-test--with-fake-conn
    (should-error (cavemacs-caveman-enable "bogus")
                  :type 'user-error)))

(ert-deftest cavemacs-caveman/disable-sends-disable-trigger ()
  (let ((cavemacs-caveman-disable-trigger "normal mode"))
    (let ((sent (cavemacs-caveman-test--with-fake-conn
                 (setq cavemacs-caveman--level "full")
                 (cavemacs-caveman-disable))))
      (should (equal "normal mode"
                     (plist-get (cdr (car sent)) :message))))))

(ert-deftest cavemacs-caveman/toggle-flips-state ()
  (cavemacs-caveman-test--with-fake-conn
    (should-not cavemacs-caveman--level)
    (cavemacs-caveman-toggle)
    (should (equal cavemacs-caveman-default-level cavemacs-caveman--level))
    (cavemacs-caveman-toggle)
    (should-not cavemacs-caveman--level)))

(ert-deftest cavemacs-caveman/cycle-walks-all-levels-then-off ()
  (cavemacs-caveman-test--with-fake-conn
    (let ((order (append cavemacs-caveman-levels '(nil)))
          seen)
      (dotimes (_ (length order))
        (cavemacs-caveman-cycle-level)
        (push cavemacs-caveman--level seen))
      (should (equal order (nreverse seen))))))

;; -----------------------------------------------------------------------------
;; Header-line indicator
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-caveman/header-segment-shows-level-when-on ()
  (with-temp-buffer
    (cavemacs-pretty-mode 1)
    (cavemacs-pretty-state-put :caveman-level "full")
    (let ((seg (substring-no-properties
                (cavemacs-caveman--header-segment))))
      (should (string-match-p "caveman:full" seg)))))

(ert-deftest cavemacs-caveman/header-segment-shows-off-when-disabled ()
  (with-temp-buffer
    (cavemacs-pretty-mode 1)
    (cavemacs-pretty-state-put :caveman-level nil)
    (let ((seg (substring-no-properties
                (cavemacs-caveman--header-segment))))
      (should (string-match-p "caveman:off" seg)))))

(ert-deftest cavemacs-caveman/pretty-header-includes-caveman-pill ()
  (with-temp-buffer
    (cavemacs-pretty-mode 1)
    (cavemacs-pretty-state-put :caveman-level "ultra")
    (let ((line (substring-no-properties (cavemacs-pretty--header-format))))
      (should (string-match-p "caveman:ultra" line)))))

;; -----------------------------------------------------------------------------
;; Companion-command registration
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-caveman/companion-commands-registered ()
  (dolist (name '("caveman" "caveman-stats" "caveman-commit"
                  "caveman-review" "caveman-compress"))
    (should (assoc name cavemacs-commands--builtins))))

(ert-deftest cavemacs-caveman/builtin-stats-sends-slash-stats ()
  (let ((sent (cavemacs-caveman-test--with-fake-conn
               (cavemacs-caveman--builtin-stats nil 'fake))))
    (should (equal "/caveman-stats"
                   (plist-get (cdr (car sent)) :message)))))

(ert-deftest cavemacs-caveman/builtin-toggle-empty-args-toggles ()
  (cavemacs-caveman-test--with-fake-conn
    (should-not cavemacs-caveman--level)
    (cavemacs-caveman--builtin-toggle "" nil)
    (should cavemacs-caveman--level)))

(ert-deftest cavemacs-caveman/builtin-toggle-with-level-activates ()
  (cavemacs-caveman-test--with-fake-conn
    (cavemacs-caveman--builtin-toggle "wenyan" nil)
    (should (equal "wenyan" cavemacs-caveman--level))))

(ert-deftest cavemacs-caveman/builtin-toggle-off-disables ()
  (cavemacs-caveman-test--with-fake-conn
    (setq cavemacs-caveman--level "full")
    (cavemacs-caveman--builtin-toggle "off" nil)
    (should-not cavemacs-caveman--level)))

(provide 'cavemacs-caveman-test)
;;; cavemacs-caveman-test.el ends here
