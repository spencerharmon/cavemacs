;;; cavemacs-pretty-test.el --- Tests for the pretty rendering layer  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Pure presentation tests for cavemacs-pretty + the renderer changes
;; introduced alongside it.  No subprocess required.
;;; Code:

(require 'ert)
(require 'cavemacs-pretty)
(require 'cavemacs-render)
(require 'cavemacs-shell)

(defun cavemacs-pretty-test--fresh-buffer ()
  (let ((buf (generate-new-buffer "*cavemacs-pretty-test*")))
    (with-current-buffer buf
      (cavemacs-shell-mode)
      (cavemacs-pretty-mode 1)
      (cavemacs-render-init-buffer)
      (let ((inhibit-read-only t)) (erase-buffer))
      (goto-char (point-max))
      (insert "\n--- input ---\n")
      (setq cavemacs-shell--prompt-marker (copy-marker (point) nil))
      (set-marker-insertion-type cavemacs-shell--prompt-marker nil))
    buf))

(ert-deftest cavemacs-pretty/palette-resolves ()
  "Auto palette returns a non-empty alist with the expected keys."
  (let ((p (cavemacs-pretty-resolve-palette)))
    (should (alist-get 'user-rule p))
    (should (alist-get 'asst-rule p))
    (should (alist-get 'tool-rule p))
    (should (alist-get 'meta-fg p))))

(ert-deftest cavemacs-pretty/glyph-lookup ()
  (should (stringp (cavemacs-pretty-glyph 'user)))
  (should (stringp (cavemacs-pretty-glyph 'assistant)))
  (should (stringp (cavemacs-pretty-glyph 'rule)))
  (should (equal "" (cavemacs-pretty-glyph 'totally-unknown))))

(ert-deftest cavemacs-pretty/header-line-includes-key-fields ()
  (with-temp-buffer
    (cavemacs-pretty-mode 1)
    (cavemacs-pretty-state-put :project "my-proj")
    (cavemacs-pretty-state-put :provider "github-copilot")
    (cavemacs-pretty-state-put :model "gpt-4o")
    (cavemacs-pretty-state-put :thinking "medium")
    (cavemacs-pretty-add-cost 0.01)
    (cavemacs-pretty-add-cost 0.02)
    (let ((line (substring-no-properties (cavemacs-pretty--header-format))))
      (should (string-match-p "cavemacs" line))
      (should (string-match-p "my-proj" line))
      (should (string-match-p "github-copilot/gpt-4o" line))
      (should (string-match-p "thinking: medium" line))
      (should (string-match-p "\\$0\\.0300" line)))))

(ert-deftest cavemacs-pretty/cost-tally-accumulates ()
  (with-temp-buffer
    (cavemacs-pretty-state-put :cost-cumulative nil)
    (cavemacs-pretty-add-cost 0.001)
    (cavemacs-pretty-add-cost 0.002)
    (cavemacs-pretty-add-cost nil)
    (should (< (abs (- 0.003 (cavemacs-pretty-state-get :cost-cumulative)))
               1e-9))))

(ert-deftest cavemacs-pretty/turn-property-marks-bubble-headers ()
  "Renderer tags each bubble header with a `cavemacs-turn' text property
so M-{ / M-} navigation can find turn boundaries."
  (let ((buf (cavemacs-pretty-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-event
           '((type . "message_start")
             (message . ((role . "user")
                         (content . (((text . "ping"))))))))
          (cavemacs-render-event
           '((type . "message_start")
             (message . ((role . "assistant")
                         (content . nil)
                         (provider . "p") (model . "m")))))
          ;; M13: assistant header is deferred until first prose/thinking.
          (cavemacs-render-event
           '((type . "message_update")
             (assistantMessageEvent
              . ((type . "text_start") (contentIndex . 0)))))
          (cavemacs-render-event
           '((type . "message_update")
             (assistantMessageEvent
              . ((type . "text_delta") (contentIndex . 0)
                 (delta . "hi")))))
          (let ((roles '()))
            (save-excursion
              (goto-char (point-min))
              (while (let ((next (next-single-property-change
                                  (point) 'cavemacs-turn)))
                       (and next (progn (goto-char next) t)))
                (when-let ((r (get-text-property (point) 'cavemacs-turn)))
                  (push r roles))))
            (should (memq 'user roles))
            (should (memq 'assistant roles))))
      (kill-buffer buf))))

(ert-deftest cavemacs-pretty/tool-card-has-box-borders ()
  (let ((buf (cavemacs-pretty-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-event
           '((type . "tool_execution_start")
             (toolCallId . "tc-x")
             (toolName . "bash")
             (args . ((command . "ls")))))
          (cavemacs-render-event
           '((type . "tool_execution_end")
             (toolCallId . "tc-x")
             (toolName . "bash")
             (isError . :json-false)
             (result . ((output . "a\nb")))))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            ;; Card head + closing line characters (from default glyph set).
            (should (string-match-p "╭" text))
            (should (string-match-p "╰" text))
            ;; Argument summary still rendered.
            (should (string-match-p "command=ls" text))
            ;; Result body preserved.
            (should (string-match-p "a" text))
            (should (string-match-p "b" text))))
      (kill-buffer buf))))

(ert-deftest cavemacs-pretty/looks-like-diff-detection ()
  (should (cavemacs-render--looks-like-diff-p
           "--- a/foo.el\n+++ b/foo.el\n@@\n-x\n+y"))
  (should-not (cavemacs-render--looks-like-diff-p
               "just regular output\nwith two lines"))
  (should-not (cavemacs-render--looks-like-diff-p nil)))

(ert-deftest cavemacs-pretty/mode-sets-header-line ()
  (with-temp-buffer
    (cavemacs-pretty-mode 1)
    (should header-line-format)
    (cavemacs-pretty-mode -1)
    (should (null header-line-format))))

(provide 'cavemacs-pretty-test)
;;; cavemacs-pretty-test.el ends here
