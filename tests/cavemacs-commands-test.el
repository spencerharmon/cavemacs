;;; cavemacs-commands-test.el --- Tests for slash command dispatch + CAPF  -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'cavemacs-commands)
(require 'cavemacs-shell)

;; --- Parser ---

(ert-deftest cavemacs-commands/parse-bare ()
  (should (equal (cavemacs-commands--parse "/help")
                 '("help" . ""))))

(ert-deftest cavemacs-commands/parse-with-args ()
  (should (equal (cavemacs-commands--parse "/name my session")
                 '("name" . "my session"))))

(ert-deftest cavemacs-commands/parse-leading-trailing-space ()
  (should (equal (cavemacs-commands--parse "  /compact  ")
                 '("compact" . ""))))

(ert-deftest cavemacs-commands/parse-with-colon-in-name ()
  (should (equal (cavemacs-commands--parse "/ck:spec extra")
                 '("ck:spec" . "extra"))))

(ert-deftest cavemacs-commands/parse-non-slash-returns-nil ()
  (should (null (cavemacs-commands--parse "hello world")))
  (should (null (cavemacs-commands--parse "")))
  (should (null (cavemacs-commands--parse "/"))))

;; --- Dispatch decision ---

(ert-deftest cavemacs-commands/dispatch-builtin-runs-handler ()
  "Built-in /new should be intercepted; no rpc-send for `prompt'."
  (let ((sent nil)
        (notices nil))
    (cl-letf (((symbol-function 'cavemacs-rpc-send)
               (lambda (_c verb &rest rest)
                 (push (cons verb rest) sent)))
              ((symbol-function 'cavemacs-render--notice)
               (lambda (text &optional _face) (push text notices))))
      (let ((result (cavemacs-commands-dispatch "/new" 'fake-conn)))
        (should result)
        ;; Should have called new_session (no prompt verb).
        (should (assoc "new_session" sent))
        (should-not (assoc "prompt" sent))))))

(ert-deftest cavemacs-commands/dispatch-non-slash-returns-nil ()
  "Plain text input must fall through (dispatch returns nil)."
  (should (null (cavemacs-commands-dispatch "hello there" 'fake-conn))))

(ert-deftest cavemacs-commands/dispatch-unknown-slash-returns-nil ()
  "Unknown slash commands fall through (dispatch returns nil) so
caveman's own prompt handler can try to handle them as extension
commands."
  (should (null (cavemacs-commands-dispatch
                 "/some-extension-command arg" 'fake-conn))))

(ert-deftest cavemacs-commands/dispatch-handler-error-caught ()
  (cl-letf (((symbol-function 'cavemacs-commands--builtin-new)
             (lambda (_a _c) (error "boom")))
            ((symbol-function 'cavemacs-render--notice)
             (lambda (text &optional _face)
               (should (string-match-p "/new error: boom" text)))))
    ;; Recompose the registry with the patched handler.
    (let ((cavemacs-commands--builtins
           (cons '("new" "" cavemacs-commands--builtin-new)
                 (cl-remove "new" cavemacs-commands--builtins
                            :key #'car :test #'equal))))
      ;; The dispatch should still return t (it claimed the command).
      (should (cavemacs-commands-dispatch "/new" 'fake-conn)))))

;; --- CAPF ---

(defun cavemacs-commands-test--fresh-shell-buffer ()
  "Create a minimal cavemacs shell buffer for CAPF testing."
  (let ((buf (generate-new-buffer "*cavemacs-capf-test*")))
    (with-current-buffer buf
      (cavemacs-shell-mode)
      (let ((inhibit-read-only t))
        (insert "\n")
        (insert "──── separator ────\n")
        (insert "> ")
        (setq cavemacs-shell--input-start-marker
              (copy-marker (point) nil))
        (setq cavemacs-shell--prompt-marker
              (copy-marker (1- (point-max)) t))))
    buf))

(ert-deftest cavemacs-commands/capf-active-on-slash ()
  "CAPF returns a completion table when the input starts with `/`."
  (let ((buf (cavemacs-commands-test--fresh-shell-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "/mod")
          ;; Stub out the RPC fetch so we don't try to talk to anything.
          (cl-letf (((symbol-function 'cavemacs-commands--user-commands)
                     (lambda (&rest _) '())))
            (let ((result (cavemacs-commands-capf)))
              (should result)
              (let* ((cands (nth 2 result))
                     (names (if (functionp cands)
                                (funcall cands "" nil t)
                              cands)))
                (should (member "model" names))
                (should (member "compact" names))))))
      (kill-buffer buf))))

(ert-deftest cavemacs-commands/capf-inactive-without-slash ()
  "CAPF returns nil when the input area doesn't start with `/`."
  (let ((buf (cavemacs-commands-test--fresh-shell-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello")
          (should (null (cavemacs-commands-capf))))
      (kill-buffer buf))))

(ert-deftest cavemacs-commands/capf-inactive-above-input-area ()
  "CAPF returns nil when point is above the input start marker."
  (let ((buf (cavemacs-commands-test--fresh-shell-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (null (cavemacs-commands-capf))))
      (kill-buffer buf))))

(provide 'cavemacs-commands-test)
;;; cavemacs-commands-test.el ends here
