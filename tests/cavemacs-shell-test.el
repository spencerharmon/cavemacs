;;; cavemacs-shell-test.el --- Tests for cavemacs-shell-mode  -*- lexical-binding: t; -*-
;;; Commentary:
;; Unit tests for cavemacs-shell behaviours that don't need a live
;; caveman subprocess.
;;; Code:

(require 'ert)
(require 'cavemacs-shell)

(defun cavemacs-shell-test--fresh-buffer ()
  "Return a buffer with a fake prompt layout matching the live mode."
  (let ((buf (generate-new-buffer "*cavemacs-shell-test*")))
    (with-current-buffer buf
      (cavemacs-shell-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "rendered output line 1\n")
        (insert "rendered output line 2\n")
        ;; Simulate the prompt layout: marker, separator, prefix,
        ;; input-start marker.
        (setq cavemacs-shell--prompt-marker (copy-marker (point) t))
        (insert (propertize "----\n"
                            'read-only t
                            'front-sticky '(read-only)
                            'rear-nonsticky '(read-only)))
        (insert (propertize "> "
                            'read-only t
                            'front-sticky '(read-only)
                            'rear-nonsticky '(read-only)))
        (setq cavemacs-shell--input-start-marker (copy-marker (point) nil))))
    buf))

;; -----------------------------------------------------------------------------
;; C-a / <home>: beginning-of-line inside the input area
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-shell/beginning-of-line-input-area ()
  "C-a inside the input area must land at the editable column,
not at column 0 (inside the read-only `> ' prefix)."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hello world")
          (cavemacs-shell-beginning-of-line)
          (should (= (point)
                     (marker-position cavemacs-shell--input-start-marker))))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/beginning-of-line-multiline-continuation ()
  "C-a on a continuation line of a multi-line prompt must go to
column 0 of that line, not back to the prompt-prefix line."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "line one\nline two")
          (cavemacs-shell-beginning-of-line)
          (should (= (point) (line-beginning-position)))
          (should (not (= (point)
                          (marker-position
                           cavemacs-shell--input-start-marker)))))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/beginning-of-line-output-region ()
  "C-a above the input area must behave as ordinary
`move-beginning-of-line' (lands at column 0 of the current line)."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Move to middle of "rendered output line 1".
          (goto-char (point-min))
          (forward-char 5)
          (cavemacs-shell-beginning-of-line)
          (should (= (point) (point-min))))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/beginning-of-line-on-prompt-prefix ()
  "C-a from a position before input-start (e.g. on the `>' prefix
itself) should fall through to ordinary line-beginning behaviour;
it must not land at input-start (that would be a forward jump,
unexpected and confusing)."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (marker-position cavemacs-shell--input-start-marker))
          ;; Step one char back into the read-only `>' prefix region.
          (forward-char -1)
          (cavemacs-shell-beginning-of-line)
          ;; Standard line-beginning should land at column 0 of the
          ;; "> " line.  Read-only prevents subsequent insertion, but
          ;; navigation itself is allowed.
          (should (< (point) (marker-position
                              cavemacs-shell--input-start-marker))))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/c-c-c-idle-abandons-line ()
  "C-c C-c when idle: leaves typed text in buffer, drops a fresh
prompt below, moves point to new input-start, sends nothing."
  (let ((buf (cavemacs-shell-test--fresh-buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-pretty-state-put :status 'idle)
          (goto-char (point-max))
          (insert "half-written prompt")
          (let ((old-input-start (marker-position
                                  cavemacs-shell--input-start-marker)))
            (cl-letf (((symbol-function 'cavemacs-rpc-send)
                       (lambda (&rest args) (push args sent)))
                      ((symbol-function 'cavemacs-rpc-live-p)
                       (lambda (&rest _) t)))
              (cavemacs-shell-abort))
            (should (string-match-p
                     "half-written prompt"
                     (buffer-substring-no-properties (point-min) (point-max))))
            (should-not sent)
            (should (= (point) (point-max)))
            (should (= (point)
                       (marker-position cavemacs-shell--input-start-marker)))
            (should (> (marker-position cavemacs-shell--input-start-marker)
                       old-input-start))))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/c-c-c-busy-aborts-on-confirm ()
  "C-c C-c when busy + user confirms: sends abort RPC."
  (let ((buf (cavemacs-shell-test--fresh-buffer))
        (sent nil)
        (native-comp-deferred-compilation nil)
        (inhibit-automatic-native-compilation t))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-pretty-state-put :status 'busy)
          (cl-letf (((symbol-function 'cavemacs-rpc-send)
                     (lambda (_conn verb &rest _) (push verb sent)))
                    ((symbol-function 'cavemacs-rpc-live-p)
                     (lambda (&rest _) t))
                    ((symbol-function 'cavemacs-shell--confirm-abort)
                     (lambda (&rest _) t)))
            (cavemacs-shell-abort))
          (should (member "abort" sent)))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/c-c-c-busy-declined-noop ()
  "C-c C-c when busy + user declines: no RPC, input untouched."
  (let ((buf (cavemacs-shell-test--fresh-buffer))
        (sent nil)
        (native-comp-deferred-compilation nil)
        (inhibit-automatic-native-compilation t))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-pretty-state-put :status 'busy)
          (goto-char (point-max))
          (insert "keep me")
          (let ((before (buffer-string)))
            (cl-letf (((symbol-function 'cavemacs-rpc-send)
                       (lambda (&rest args) (push args sent)))
                      ((symbol-function 'cavemacs-rpc-live-p)
                       (lambda (&rest _) t))
                      ((symbol-function 'cavemacs-shell--confirm-abort)
                       (lambda (&rest _) nil)))
              (cavemacs-shell-abort))
            (should-not sent)
            (should (equal before (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/busy-clears-on-turn-end ()
  "After turn_end, header status must flip back to idle.
Regression: previously only agent_end cleared it."
  (require 'cavemacs-render)
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-pretty-state-put :status 'idle)
          (cavemacs-render-event '((type . "turn_start")))
          (should (eq (cavemacs-pretty-state-get :status) 'busy))
          (cavemacs-render-event '((type . "turn_end")))
          (should (eq (cavemacs-pretty-state-get :status) 'idle)))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/history-prev-and-next ()
  "M-p / M-n cycle through previously-sent prompts and restore live input."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-shell--history-push "first")
          (cavemacs-shell--history-push "second")
          (cavemacs-shell--history-push "third")
          (goto-char (point-max))
          (insert "draft")
          (cavemacs-shell-previous-input)
          (should (equal "third" (cavemacs-shell--input-text)))
          (cavemacs-shell-previous-input)
          (should (equal "second" (cavemacs-shell--input-text)))
          (cavemacs-shell-previous-input)
          (should (equal "first" (cavemacs-shell--input-text)))
          (should-error (cavemacs-shell-previous-input))
          (cavemacs-shell-next-input)
          (should (equal "second" (cavemacs-shell--input-text)))
          (cavemacs-shell-next-input)
          (should (equal "third" (cavemacs-shell--input-text)))
          (cavemacs-shell-next-input)
          (should (equal "draft" (cavemacs-shell--input-text)))
          (should-not cavemacs-shell--history-index))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/history-dedup-adjacent ()
  "Repeated identical pushes collapse to a single history entry."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-shell--history-push "same")
          (cavemacs-shell--history-push "same")
          (cavemacs-shell--history-push "same")
          (should (equal '("same") cavemacs-shell--input-history)))
      (kill-buffer buf))))

(ert-deftest cavemacs-shell/c-p-on-non-first-line-moves-line ()
  "In multi-line input, <up> on a non-first line acts like `previous-line'."
  (let ((buf (cavemacs-shell-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-shell--history-push "old prompt")
          (goto-char (point-max))
          (insert "line one\nline two")
          (cavemacs-shell-previous-line-or-input)
          (should (string-match-p "line one\nline two"
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))
      (kill-buffer buf))))

(provide 'cavemacs-shell-test)
;;; cavemacs-shell-test.el ends here
