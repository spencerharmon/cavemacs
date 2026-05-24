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

(ert-deftest cavemacs-render/tool-block-copy-strips-rule-glyphs ()
  "Kill/yank on tool-card body must not pull `│ ' or the box rules."
  (require 'cavemacs-shell)
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-event
           '((type . "tool_execution_start")
             (toolCallId . "tc-9")
             (toolName . "bash")
             (args . ((command . "ls")))))
          (cavemacs-render-event
           '((type . "tool_execution_end")
             (toolCallId . "tc-9")
             (toolName . "bash")
             (isError . :json-false)
             (result . ((output . "file1\nfile2")))))
          (let* ((copied (filter-buffer-substring (point-min) (point-max))))
            (should-not (string-match-p "│" copied))
            (should-not (string-match-p "╭" copied))
            (should-not (string-match-p "╰" copied))
            (should (string-match-p "file1" copied))
            (should (string-match-p "file2" copied))))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/prose-copy-strips-rule-glyphs ()
  "Kill/yank on assistant prose body must not pull `│ ' line prefixes."
  (require 'cavemacs-shell)
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-event
           '((type . "message_start")
             (message . ((role . "assistant")
                         (content . nil)))))
          (cavemacs-render-event
           '((type . "message_update")
             (assistantMessageEvent
              . ((type . "text_start") (contentIndex . 0)))))
          (cavemacs-render-event
           '((type . "message_update")
             (assistantMessageEvent
              . ((type . "text_delta") (contentIndex . 0)
                 (delta . "line one\nline two\nline three")))))
          (cavemacs-render-event
           '((type . "message_end")
             (message . ((role . "assistant")
                         (content . (((text . "line one\nline two\nline three"))))))))
          (let* ((copied (filter-buffer-substring (point-min) (point-max))))
            (should-not (string-match-p "│" copied))
            (should (string-match-p "line one" copied))
            (should (string-match-p "line two" copied))
            (should (string-match-p "line three" copied))))
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

;; -----------------------------------------------------------------------------
;; M11: collapsibility
;; -----------------------------------------------------------------------------

(defun cavemacs-render-test--push-tool-pair (id name result)
  "Push a tool start + end event pair into the current buffer."
  (cavemacs-render-event
   `((type . "tool_execution_start")
     (toolCallId . ,id)
     (toolName . ,name)
     (args . ((x . 1)))))
  (cavemacs-render-event
   `((type . "tool_execution_end")
     (toolCallId . ,id)
     (toolName . ,name)
     (isError . :json-false)
     (result . ((output . ,result))))))

(ert-deftest cavemacs-render/collapse-block-stores-state ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-test--push-tool-pair "tc-collapse" "bash" "line1\nline2\nline3")
          (cavemacs-render--set-collapsed "tool:tc-collapse" t)
          (should (cavemacs-render--collapsed-p "tool:tc-collapse"))
          (cavemacs-render--set-collapsed "tool:tc-collapse" nil)
          (should-not (cavemacs-render--collapsed-p "tool:tc-collapse")))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/tool-block-registers-collapse-overlay ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-test--push-tool-pair "tc-ov" "bash" "a\nb")
          (should (gethash "tool:tc-ov" cavemacs-render--collapse-overlays))
          ;; Header line should carry the collapse id text property.
          (let ((found nil))
            (save-excursion
              (goto-char (point-min))
              (while (let ((next (next-single-property-change
                                  (point) 'cavemacs-collapse-id)))
                       (and next (progn (goto-char next) t)))
                (when (equal (get-text-property (point) 'cavemacs-collapse-id)
                             "tool:tc-ov")
                  (setq found t))))
            (should found)))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/toggle-all-flips-everything ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-test--push-tool-pair "tc-a" "bash" "x")
          (cavemacs-render-test--push-tool-pair "tc-b" "bash" "y")
          (cavemacs-render--set-collapsed "tool:tc-a" nil)
          (cavemacs-render--set-collapsed "tool:tc-b" nil)
          (cavemacs-render-toggle-all)
          (should (cavemacs-render--collapsed-p "tool:tc-a"))
          (should (cavemacs-render--collapsed-p "tool:tc-b"))
          (cavemacs-render-toggle-all)
          (should-not (cavemacs-render--collapsed-p "tool:tc-a"))
          (should-not (cavemacs-render--collapsed-p "tool:tc-b")))
      (kill-buffer buf))))

(ert-deftest cavemacs-render/expand-all-then-collapse-all ()
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-test--push-tool-pair "tc-c" "bash" "z")
          (cavemacs-render-expand-all)
          (should-not (cavemacs-render--collapsed-p "tool:tc-c"))
          (cavemacs-render-collapse-all)
          (should (cavemacs-render--collapsed-p "tool:tc-c")))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------------
;; File-path linkification (M9 stretch)
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-render/linkify-diff-header ()
  "+++ b/<existing-file> in a tool result gets a clickable button."
  (let* ((tmp (make-temp-file "cavemacs-link-" nil ".el"))
         (buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((default-directory (file-name-directory tmp))
                (cavemacs-shell--project-root (file-name-directory tmp)))
            (cavemacs-render-test--push-tool-pair
             "tc-link"
             "edit"
             (format "--- a/%s\n+++ b/%s\n@@\n-x\n+y"
                     (file-name-nondirectory tmp)
                     (file-name-nondirectory tmp))))
          ;; Walk overlays looking for a cavemacs-file-path equal to tmp.
          (let (found)
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (equal (overlay-get ov 'cavemacs-file-path)
                           (expand-file-name tmp))
                (setq found t)))
            (should found)))
      (kill-buffer buf)
      (delete-file tmp))))

(ert-deftest cavemacs-render/linkify-path-colon-line ()
  "path:42 in tool output becomes a button with :line 42."
  (let* ((tmp (make-temp-file "cavemacs-link2-" nil ".el"))
         (buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((default-directory (file-name-directory tmp))
                (cavemacs-shell--project-root (file-name-directory tmp)))
            (cavemacs-render-test--push-tool-pair
             "tc-link2" "grep"
             (format "%s:42:5: match here" (file-name-nondirectory tmp))))
          (let (found-line)
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (and (equal (overlay-get ov 'cavemacs-file-path)
                                (expand-file-name tmp))
                         (equal (overlay-get ov 'cavemacs-file-line) 42))
                (setq found-line t)))
            (should found-line)))
      (kill-buffer buf)
      (delete-file tmp))))

(ert-deftest cavemacs-render/linkify-ignores-nonexistent-paths ()
  "Paths that don't resolve to a real file are not linkified."
  (let ((buf (cavemacs-render-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cavemacs-render-test--push-tool-pair
           "tc-nope" "bash" "/this/path/should/never/exist.xyz:1:1")
          (let (found)
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (overlay-get ov 'cavemacs-file-path)
                (setq found t)))
            (should-not found)))
      (kill-buffer buf))))

(provide 'cavemacs-render-test)
;;; cavemacs-render-test.el ends here
