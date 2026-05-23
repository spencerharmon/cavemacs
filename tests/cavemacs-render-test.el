;;; cavemacs-render-test.el --- Renderer tests against captured events  -*- lexical-binding: t; -*-
;;; Commentary:
;; Drives the renderer with a hand-built event sequence (mirroring the
;; one captured live in spike/spike-prompt.el) and asserts on the
;; resulting buffer contents.  No subprocess required.
;;; Code:

(require 'ert)
(require 'cavemacs-render)
(require 'cavemacs-shell)

(defun cavemacs-render-test--fresh-buffer ()
  "Return a fresh cavemacs shell buffer suitable for rendering tests."
  (let ((buf (generate-new-buffer "*cavemacs-render-test*")))
    (with-current-buffer buf
      (cavemacs-shell-mode)
      (cavemacs-render-init-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer))
      ;; Install a prompt marker at end-of-buffer so the renderer
      ;; inserts above it.
      (goto-char (point-max))
      (insert "\n--- input ---\n")
      (setq cavemacs-shell--prompt-marker (copy-marker (point) nil))
      (set-marker-insertion-type cavemacs-shell--prompt-marker nil))
    buf))

(defconst cavemacs-render-test--ping-sequence
  '(((type . "agent_start"))
    ((type . "turn_start"))
    ((type . "message_start")
     (message . ((role . "user")
                 (content . (((text . "say pong")))))))
    ((type . "message_end")
     (message . ((role . "user")
                 (content . (((text . "say pong")))))))
    ((type . "message_start")
     (message . ((role . "assistant")
                 (content . nil)
                 (provider . "github-copilot")
                 (model . "gpt-4o"))))
    ((type . "message_update")
     (assistantMessageEvent . ((type . "text_start") (contentIndex . 0))))
    ((type . "message_update")
     (assistantMessageEvent . ((type . "text_delta") (contentIndex . 0)
                               (delta . "pong")))
     (message . ((role . "assistant")
                 (usage . ((input . 1000) (output . 1)
                           (totalTokens . 1001)
                           (cost . ((total . 0.001))))))))
    ((type . "message_update")
     (assistantMessageEvent . ((type . "text_end") (contentIndex . 0)
                               (content . "pong"))))
    ((type . "message_end")
     (message . ((role . "assistant")
                 (content . (((text . "pong"))))
                 (provider . "github-copilot")
                 (model . "gpt-4o")
                 (usage . ((input . 1000) (output . 1)
                           (totalTokens . 1001)
                           (cost . ((total . 0.001))))))))
    ((type . "turn_end"))
    ((type . "agent_end")
     (messages . nil)))
  "Synthetic event sequence equivalent to a real one-word reply.")

(ert-deftest cavemacs-render/streams-assistant-text ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (dolist (ev cavemacs-render-test--ping-sequence)
            (cavemacs-render-event ev))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "You" text))
            (should (string-match-p "say pong" text))
            (should (string-match-p "Assistant" text))
            (should (string-match-p "pong" text))
            ;; Token footer:
            (should (string-match-p "1000 in / 1 out / 1001 total" text))
            (should (string-match-p "\\$0\\.001" text))))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/tool-block ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-event
           '((type . "tool_execution_start")
             (toolCallId . "tc-1")
             (toolName . "bash")
             (args . ((command . "ls")))))
          (cavemacs-render-event
           '((type . "tool_execution_end")
             (toolCallId . "tc-1")
             (toolName . "bash")
             (isError . :json-false)
             (result . ((output . "file1\nfile2"))))) ; nested alist
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "⚙ bash" text))
            (should (string-match-p "command=ls" text))
            (should (string-match-p "file1" text))
            (should (string-match-p "file2" text))))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/handles-unknown-event-types ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Should not raise.
          (cavemacs-render-event '((type . "future_event_we_dont_know")
                                   (whatever . "data"))))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/surfaces-upstream-error ()
  "When message_end has stopReason=error + errorMessage, that error
must be rendered visibly under the assistant block.  Caveman emits
these for provider rejections (rate-limit, content filter, model-
specific param mismatches, etc.); silent empty assistant blocks
are a UX regression."
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          ;; Start an assistant message.
          (cavemacs-render-event
           '((type . "message_start")
             (message . ((role . "assistant")
                         (content . nil)
                         (provider . "github-copilot")
                         (model . "claude-opus-4.7")))))
          ;; End it with an upstream error and no content.
          (cavemacs-render-event
           '((type . "message_end")
             (message . ((role . "assistant")
                         (content . nil)
                         (provider . "github-copilot")
                         (model . "claude-opus-4.7")
                         (stopReason . "error")
                         (errorMessage . "400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"\\\"thinking.type.enabled\\\" is not supported for this model.\"}}")))))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            ;; Status code surfaced.
            (should (string-match-p "400" text))
            ;; Human-readable error message extracted.
            (should (string-match-p "thinking.type.enabled" text))
            ;; Warning sigil present.
            (should (string-match-p "⚠" text))))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/error-fallback-when-unparseable ()
  "If the errorMessage doesn't match the JSON shape we expect,
fall back to showing it raw with the sigil."
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-event
           '((type . "message_start")
             (message . ((role . "assistant") (content . nil)))))
          (cavemacs-render-event
           '((type . "message_end")
             (message . ((role . "assistant")
                         (content . nil)
                         (stopReason . "error")
                         (errorMessage . "Connection refused")))))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "⚠ Connection refused" text))))
      (kill-buffer buf))))

(provide 'cavemacs-render-test)
;;; cavemacs-render-test.el ends here
