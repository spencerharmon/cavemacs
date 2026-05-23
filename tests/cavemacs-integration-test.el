;;; cavemacs-integration-test.el --- End-to-end live caveman test  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Spawns a real `caveman --mode rpc' subprocess via the package's own
;; entry points, sends a small prompt, waits for `agent_end', and
;; asserts that the rendered buffer contains the response.
;;
;; Skipped if caveman is not on PATH or no provider is authenticated.
;;
;; Run:
;;   emacs --batch -L . -l tests/cavemacs-integration-test.el \
;;         -f ert-run-tests-batch-and-exit
;;; Code:

(require 'ert)
(require 'cavemacs)

(defvar cavemacs-integration-test--done nil)

(defun cavemacs-integration-test--wait-for (buffer pred &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 60))))
    (while (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (not (funcall pred)))
                (< (float-time) deadline))
      (sleep-for 0.1))))

(ert-deftest cavemacs-integration/smoke ()
  "Open a buffer, send a tiny prompt, see a response."
  (skip-unless (executable-find "caveman"))
  (let* ((cavemacs-ephemeral-default t)
         (cavemacs-default-provider "github-copilot")
         (buf (cavemacs-shell-new :project-root default-directory)))
    (unwind-protect
        (progn
          ;; Wait for the RPC to come up.
          (cavemacs-integration-test--wait-for
           buf (lambda () (and cavemacs-shell--conn
                               (cavemacs-rpc-live-p cavemacs-shell--conn)))
           5)
          (should (with-current-buffer buf
                    (cavemacs-rpc-live-p cavemacs-shell--conn)))
          ;; Send a prompt.
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "Reply with the single word: pong")
            (cavemacs-shell-send))
          ;; Wait for an assistant response to land.
          (cavemacs-integration-test--wait-for
           buf
           (lambda ()
             (save-excursion
               (goto-char (point-min))
               (search-forward "pong" nil t)))
           60)
          (should (with-current-buffer buf
                    (save-excursion
                      (goto-char (point-min))
                      (search-forward "pong" nil t))))
          ;; And that the modeline returned to idle.
          (cavemacs-integration-test--wait-for
           buf
           (lambda ()
             (string-match-p "idle" cavemacs-shell--mode-line-info))
           10)
          (should (with-current-buffer buf
                    (string-match-p "idle" cavemacs-shell--mode-line-info))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when cavemacs-shell--conn
            (ignore-errors (cavemacs-rpc-stop cavemacs-shell--conn))))
        (kill-buffer buf)))))

(provide 'cavemacs-integration-test)
;;; cavemacs-integration-test.el ends here
