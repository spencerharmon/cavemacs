;;; cavemacs-render.el --- Streaming render of AgentSessionEvent  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Renders the AgentSessionEvent stream from caveman --mode rpc into the
;; cavemacs shell buffer.  Each event mutates the buffer in-place; the
;; current assistant turn is maintained as a single replaceable region
;; identified by overlays.
;;
;; Event ordering (validated empirically in spike/spike-prompt.el):
;;
;;   agent_start
;;   turn_start
;;     message_start  (role=user)
;;     message_end    (role=user)
;;     message_start  (role=assistant)
;;       message_update (assistantMessageEvent.type ∈
;;                         text_start | text_delta | text_end |
;;                         thinking_start | thinking_delta | thinking_end |
;;                         tool_call_start | tool_call_delta | tool_call_end)
;;       tool_execution_start
;;       tool_execution_update*
;;       tool_execution_end
;;     message_end    (role=assistant)
;;   turn_end
;;   agent_end
;;
;; A run may contain multiple turns (tool-use loop).  We render each
;; user/assistant message as its own block bounded by an overlay so we
;; can update it without re-walking the buffer.
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'markdown-mode nil t)

(defface cavemacs-user-prefix-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the \"You:\" prefix in chat buffers."
  :group 'cavemacs)

(defface cavemacs-assistant-prefix-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant role prefix."
  :group 'cavemacs)

(defface cavemacs-tool-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool-call titles."
  :group 'cavemacs)

(defface cavemacs-tool-args-face
  '((t :inherit font-lock-comment-face))
  "Face for tool-call argument summaries."
  :group 'cavemacs)

(defface cavemacs-meta-face
  '((t :inherit shadow))
  "Face for low-attention metadata (tokens, cost, timings)."
  :group 'cavemacs)

(defface cavemacs-error-face
  '((t :inherit error))
  "Face for error notes inside chat buffers."
  :group 'cavemacs)

(defface cavemacs-thinking-face
  '((t :inherit font-lock-doc-face :slant italic))
  "Face for assistant thinking content."
  :group 'cavemacs)

(defcustom cavemacs-render-fontify-markdown t
  "When non-nil, fontify assistant-message regions with `markdown-mode' keywords."
  :type 'boolean
  :group 'cavemacs)

(defcustom cavemacs-render-show-thinking t
  "When non-nil, render the assistant's thinking blocks; otherwise hide them."
  :type 'boolean
  :group 'cavemacs)

;; -----------------------------------------------------------------------------
;; Buffer-local render state
;; -----------------------------------------------------------------------------

(defvar-local cavemacs-render--turn-overlays nil
  "List of overlays representing in-progress assistant turns.")

(defvar-local cavemacs-render--message-overlays nil
  "Hash table: messageId/timestamp -> overlay covering that message's region.")

(defvar-local cavemacs-render--current-assistant-ov nil
  "Overlay over the currently-streaming assistant message block, or nil.")

(defvar-local cavemacs-render--tool-overlays nil
  "Hash table: toolCallId -> overlay covering that tool block.")

(defvar-local cavemacs-render--meta nil
  "Plist of last-known meta info: :model :provider :cost :tokens-in :tokens-out.")

(defun cavemacs-render-init-buffer ()
  "Initialize buffer-local render state."
  (setq cavemacs-render--turn-overlays nil
        cavemacs-render--message-overlays (make-hash-table :test 'equal)
        cavemacs-render--current-assistant-ov nil
        cavemacs-render--tool-overlays (make-hash-table :test 'equal)
        cavemacs-render--meta nil))

;; -----------------------------------------------------------------------------
;; Insertion helpers
;; -----------------------------------------------------------------------------

(defun cavemacs-render--insertion-point ()
  "Return the buffer position where new render content should go.
This is the position immediately before the input prompt marker."
  (if (and (boundp 'cavemacs-shell--prompt-marker)
           (markerp cavemacs-shell--prompt-marker)
           (marker-position cavemacs-shell--prompt-marker))
      (marker-position cavemacs-shell--prompt-marker)
    (point-max)))

(defmacro cavemacs-render--at-output (&rest body)
  "Run BODY at the rendering insertion point, with inhibit-read-only.

After BODY, if point in the cavemacs buffer was at `point-max'
before this macro fired (i.e., the user was parked in the input
area), and the live windows showing this buffer also had their
window-point at the buffer's old `point-max', then advance their
window-points to the new `point-max'.  This is the chat/comint
convention: the input prompt stays pinned to the bottom of the
window and the user keeps typing where they were.

Without this, `save-excursion' would put point back at its
original *numeric* buffer position, which after a render insert
is now in the middle of the rendered text, *before* the input
area.  `(eobp)' would be false and `RET' would insert a newline
instead of submitting the next prompt."
  (declare (indent 0) (debug t))
  `(let* ((inhibit-read-only t)
          (orig-point (point))
          (was-at-end (= orig-point (point-max)))
          (orig-window-points
           (when was-at-end
             (mapcar (lambda (w) (cons w (window-point w)))
                     (get-buffer-window-list (current-buffer) nil t)))))
     (save-excursion
       (goto-char (cavemacs-render--insertion-point))
       ,@body)
     (when was-at-end
       (goto-char (point-max))
       (dolist (entry orig-window-points)
         (let ((w (car entry)) (wp (cdr entry)))
           (when (and (window-live-p w) (= wp orig-point))
             (set-window-point w (point-max))))))))

(defun cavemacs-render--ensure-newline-before ()
  "Insert a newline before point unless we're at BOB or after a LF."
  (unless (or (bobp) (eq (char-before) ?\n))
    (insert "\n")))

(defun cavemacs-render--ensure-blank-line-before ()
  "Insert blank line separator before point if needed."
  (cavemacs-render--ensure-newline-before)
  (unless (or (bobp)
              (save-excursion
                (forward-char -1)
                (and (not (bobp)) (eq (char-before) ?\n))))
    (insert "\n")))

;; -----------------------------------------------------------------------------
;; Message helpers
;; -----------------------------------------------------------------------------

(defun cavemacs-render--message-text (message)
  "Extract concatenated text from a MESSAGE alist's content parts."
  (let ((content (alist-get 'content message)))
    (if (stringp content)
        content
      (mapconcat
       (lambda (part)
         (cond
          ((stringp part) part)
          ((alist-get 'text part) (alist-get 'text part))
          (t "")))
       (and (listp content) content)
       ""))))

(defun cavemacs-render--message-key (message)
  "Return a stable key for MESSAGE: id, or timestamp, or random."
  (or (alist-get 'id message)
      (alist-get 'timestamp message)
      (alist-get 'role message)))

;; -----------------------------------------------------------------------------
;; Per-event handlers
;; -----------------------------------------------------------------------------

(defun cavemacs-render-event (event)
  "Dispatch a single AgentSessionEvent EVENT to a render handler."
  (pcase (alist-get 'type event)
    ("agent_start"          (cavemacs-render--on-agent-start event))
    ("turn_start"           (cavemacs-render--on-turn-start event))
    ("message_start"        (cavemacs-render--on-message-start event))
    ("message_update"       (cavemacs-render--on-message-update event))
    ("message_end"          (cavemacs-render--on-message-end event))
    ("tool_execution_start" (cavemacs-render--on-tool-start event))
    ("tool_execution_update"(cavemacs-render--on-tool-update event))
    ("tool_execution_end"   (cavemacs-render--on-tool-end event))
    ("turn_end"             (cavemacs-render--on-turn-end event))
    ("agent_end"            (cavemacs-render--on-agent-end event))
    ("queue_update"         nil) ; reflect in modeline only (M6)
    ("compaction_start"     (cavemacs-render--notice "Compacting context..."))
    ("compaction_end"       (cavemacs-render--notice "Compaction complete."))
    ("auto_retry_start"
     (cavemacs-render--notice
      (format "Retry attempt %s/%s in %sms: %s"
              (alist-get 'attempt event)
              (alist-get 'maxAttempts event)
              (alist-get 'delayMs event)
              (alist-get 'errorMessage event))
      'cavemacs-meta-face))
    ("auto_retry_end"       nil)
    ("checkpoint_taken"
     (cavemacs-render--notice
      (format "Checkpoint %s (%s, %s files)"
              (substring (or (alist-get 'checkpointId event) "?") 0 8)
              (alist-get 'toolName event)
              (alist-get 'fileCount event))
      'cavemacs-meta-face))
    ("subagent_progress"
     (cavemacs-render--notice
      (format "[subagent %s] %s%s"
              (alist-get 'subagentName event)
              (alist-get 'phase event)
              (if-let ((d (alist-get 'detail event))) (concat ": " d) ""))
      'cavemacs-meta-face))
    ("extension_error"
     (cavemacs-render--notice
      (format "Extension error in %s: %s"
              (alist-get 'extensionPath event)
              (alist-get 'error event))
      'cavemacs-error-face))
    ("cavemacs_process_exited"
     (cavemacs-render--notice
      (format "[cavemacs] caveman process %s%s"
              (alist-get 'status event)
              (if-let ((e (alist-get 'event event)))
                  (format ": %s" e) ""))
      'cavemacs-error-face))
    (_ nil)))                            ; unknown events: silently ignore

(defun cavemacs-render--notice (text &optional face)
  "Insert a one-line system notice TEXT with FACE."
  (cavemacs-render--at-output
    (cavemacs-render--ensure-newline-before)
    (insert (propertize text 'face (or face 'cavemacs-meta-face)) "\n")))

(defun cavemacs-render--on-agent-start (_event) nil)
(defun cavemacs-render--on-turn-start (_event) nil)

(defun cavemacs-render--on-message-start (event)
  "Render an opening block for a message's eventual content."
  (let* ((msg (alist-get 'message event))
         (role (alist-get 'role msg))
         (key (cavemacs-render--message-key msg)))
    (cavemacs-render--at-output
      (cavemacs-render--ensure-blank-line-before)
      (let ((start (point)))
        (pcase role
          ("user"
           (insert (propertize "You" 'face 'cavemacs-user-prefix-face) "\n")
           (let ((body-start (point)))
             (insert (cavemacs-render--message-text msg))
             (insert "\n")
             (let ((ov (make-overlay start (point) nil nil t)))
               (overlay-put ov 'cavemacs-role 'user)
               (overlay-put ov 'cavemacs-body-start body-start)
               (puthash key ov cavemacs-render--message-overlays))))
          ("assistant"
           (let* ((model (alist-get 'model msg))
                  (provider (alist-get 'provider msg))
                  (title (cond
                          ((and model provider)
                           (format "Assistant · %s/%s" provider model))
                          (model (format "Assistant · %s" model))
                          (t "Assistant"))))
             (insert (propertize title 'face 'cavemacs-assistant-prefix-face)
                     "\n"))
           (let ((body-start (point)))
             ;; Placeholder so the overlay covers something even before deltas.
             (insert "")
             (let ((ov (make-overlay start (point) nil nil t)))
               (overlay-put ov 'cavemacs-role 'assistant)
               (overlay-put ov 'cavemacs-body-start body-start)
               (overlay-put ov 'cavemacs-text "")
               (overlay-put ov 'cavemacs-thinking "")
               (puthash key ov cavemacs-render--message-overlays)
               (setq cavemacs-render--current-assistant-ov ov))))
          (_
           (insert (format "[%s]\n" role))
           (insert (cavemacs-render--message-text msg))
           (insert "\n")))))))

(defun cavemacs-render--on-message-update (event)
  "Apply an assistantMessageEvent delta to the current assistant overlay."
  (when-let* ((ov cavemacs-render--current-assistant-ov)
              ((overlay-buffer ov))
              (ame (alist-get 'assistantMessageEvent event)))
    (let ((kind (alist-get 'type ame)))
      (pcase kind
        ("text_start"
         (overlay-put ov 'cavemacs-text ""))
        ("text_delta"
         (let* ((delta (or (alist-get 'delta ame) ""))
                (cur (or (overlay-get ov 'cavemacs-text) "")))
           (overlay-put ov 'cavemacs-text (concat cur delta))))
        ("text_end"
         (let ((final (or (alist-get 'content ame)
                          (overlay-get ov 'cavemacs-text)
                          "")))
           (overlay-put ov 'cavemacs-text final)))
        ("thinking_start"
         (overlay-put ov 'cavemacs-thinking ""))
        ("thinking_delta"
         (let* ((delta (or (alist-get 'delta ame) ""))
                (cur (or (overlay-get ov 'cavemacs-thinking) "")))
           (overlay-put ov 'cavemacs-thinking (concat cur delta))))
        ("thinking_end" nil)
        ;; Tool-call streaming inside an assistant message: tracked
        ;; separately via tool_execution_* events; ignore here.
        (_ nil)))
    (cavemacs-render--repaint-assistant ov)
    ;; Update meta info from the message's usage block.
    (when-let* ((msg (alist-get 'message event))
                (usage (alist-get 'usage msg)))
      (setq cavemacs-render--meta
            (list :model (alist-get 'model msg)
                  :provider (alist-get 'provider msg)
                  :tokens-in (alist-get 'input usage)
                  :tokens-out (alist-get 'output usage)
                  :total (alist-get 'totalTokens usage)
                  :cost (let ((c (alist-get 'cost usage)))
                          (and c (alist-get 'total c))))))))

(defun cavemacs-render--repaint-assistant (ov)
  "Re-render assistant overlay OV's body region from cached text/thinking."
  (let ((inhibit-read-only t)
        (body-start (overlay-get ov 'cavemacs-body-start))
        (ov-end (overlay-end ov))
        (text (or (overlay-get ov 'cavemacs-text) ""))
        (thinking (or (overlay-get ov 'cavemacs-thinking) ""))
        (buf (overlay-buffer ov)))
    (when (and (buffer-live-p buf) body-start ov-end)
      (with-current-buffer buf
        (save-excursion
          (goto-char body-start)
          (delete-region body-start ov-end)
          (when (and cavemacs-render-show-thinking
                     (not (string-empty-p thinking)))
            (insert (propertize
                     (concat
                      (propertize "▶ thinking\n" 'face 'cavemacs-meta-face)
                      (mapconcat (lambda (l) (concat "  " l))
                                 (split-string thinking "\n" nil) "\n")
                      "\n\n")
                     'face 'cavemacs-thinking-face)))
          (let ((text-start (point)))
            (insert text)
            (unless (eq (char-before) ?\n) (insert "\n"))
            (when (and cavemacs-render-fontify-markdown
                       (featurep 'markdown-mode))
              (cavemacs-render--fontify-markdown text-start (point))))
          (move-overlay ov (overlay-start ov) (point)))))))

(defun cavemacs-render--fontify-markdown (beg end)
  "Apply markdown font-lock keywords to the region BEG..END."
  (save-restriction
    (narrow-to-region beg end)
    (let ((font-lock-defaults (when (boundp 'markdown-mode-font-lock-keywords-basic)
                                `(,markdown-mode-font-lock-keywords-basic
                                  nil nil nil nil))))
      (when font-lock-defaults
        (ignore-errors
          (font-lock-default-fontify-region (point-min) (point-max) nil))))))

(defun cavemacs-render--on-message-end (event)
  "Finalize a message's overlay state."
  (let* ((msg (alist-get 'message event))
         (key (cavemacs-render--message-key msg)))
    (when-let* ((ov (and key (gethash key cavemacs-render--message-overlays))))
      (when (eq (overlay-get ov 'cavemacs-role) 'assistant)
        ;; Ensure final text is flushed (use the full message content as
        ;; source of truth in case a delta was dropped).
        (let ((full (cavemacs-render--message-text msg)))
          (when (and full (not (string-empty-p full)))
            (overlay-put ov 'cavemacs-text full)
            (cavemacs-render--repaint-assistant ov)))
        (when (eq ov cavemacs-render--current-assistant-ov)
          (setq cavemacs-render--current-assistant-ov nil))))))

;; -----------------------------------------------------------------------------
;; Tool execution
;; -----------------------------------------------------------------------------

(defun cavemacs-render--tool-arg-summary (args)
  "Return a short, single-line summary of tool ARGS for inline display."
  (cond
   ((null args) "")
   ((stringp args) (truncate-string-to-width args 80 nil nil "…"))
   ((listp args)
    (let* ((parts (cl-loop for (k . v) in args
                           collect (format "%s=%s" k
                                           (cond
                                            ((stringp v)
                                             (truncate-string-to-width v 40 nil nil "…"))
                                            (t (prin1-to-string v))))))
           (joined (string-join parts " ")))
      (truncate-string-to-width joined 120 nil nil "…")))
   (t (truncate-string-to-width (format "%S" args) 80 nil nil "…"))))

(defun cavemacs-render--on-tool-start (event)
  "Render a new tool-call block."
  (let* ((tool-id (alist-get 'toolCallId event))
         (name (alist-get 'toolName event))
         (args (alist-get 'args event)))
    (cavemacs-render--at-output
      (cavemacs-render--ensure-newline-before)
      (let ((start (point)))
        (insert (propertize (format "⚙ %s" name)
                            'face 'cavemacs-tool-face))
        (insert " ")
        (insert (propertize (cavemacs-render--tool-arg-summary args)
                            'face 'cavemacs-tool-args-face))
        (insert "\n")
        (let ((ov (make-overlay start (point) nil nil t)))
          (overlay-put ov 'cavemacs-tool-id tool-id)
          (overlay-put ov 'cavemacs-tool-name name)
          (overlay-put ov 'cavemacs-tool-status 'running)
          (puthash tool-id ov cavemacs-render--tool-overlays))))))

(defun cavemacs-render--on-tool-update (_event)
  ;; partialResult could be streamed; v1 just shows the final result.
  nil)

(defun cavemacs-render--on-tool-end (event)
  "Append a result block under the matching tool overlay."
  (let* ((tool-id (alist-get 'toolCallId event))
         (result (alist-get 'result event))
         (is-error (eq (alist-get 'isError event) t))
         (ov (and tool-id (gethash tool-id cavemacs-render--tool-overlays))))
    (when (and ov (overlay-buffer ov))
      (let ((inhibit-read-only t))
        (with-current-buffer (overlay-buffer ov)
          (save-excursion
            (goto-char (overlay-end ov))
            (let ((text (cavemacs-render--render-tool-result result)))
              (insert
               (propertize
                (mapconcat (lambda (l) (concat "  " l))
                           (split-string (string-trim-right text) "\n" nil)
                           "\n")
                'face (if is-error 'cavemacs-error-face 'cavemacs-meta-face)))
              (insert "\n")
              (move-overlay ov (overlay-start ov) (point))
              (overlay-put ov 'cavemacs-tool-status
                           (if is-error 'error 'ok)))))))))

(defun cavemacs-render--render-tool-result (result)
  "Coerce RESULT (any JSON shape) into displayable text."
  (cond
   ((null result) "(no result)")
   ((stringp result) result)
   ((listp result)
    (or (alist-get 'output result)
        (alist-get 'stdout result)
        (alist-get 'text result)
        (alist-get 'content result)
        (let ((print-escape-newlines nil)
              (print-length 64) (print-level 4))
          (prin1-to-string result))))
   (t (format "%S" result))))

;; -----------------------------------------------------------------------------
;; Turn / agent end (footer)
;; -----------------------------------------------------------------------------

(defun cavemacs-render--on-turn-end (_event) nil)

(defun cavemacs-render--on-agent-end (_event)
  "Insert a per-run footer with token / cost stats."
  (when cavemacs-render--meta
    (let* ((m cavemacs-render--meta)
           (text (format "── %s in / %s out / %s total · %s"
                         (or (plist-get m :tokens-in) "?")
                         (or (plist-get m :tokens-out) "?")
                         (or (plist-get m :total) "?")
                         (if-let ((c (plist-get m :cost)))
                             (format "$%.4f" c)
                           "no cost data"))))
      (cavemacs-render--at-output
        (cavemacs-render--ensure-newline-before)
        (insert (propertize text 'face 'cavemacs-meta-face) "\n")))))

(provide 'cavemacs-render)
;;; cavemacs-render.el ends here
