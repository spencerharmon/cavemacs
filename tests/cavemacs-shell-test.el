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

(provide 'cavemacs-shell-test)
;;; cavemacs-shell-test.el ends here
