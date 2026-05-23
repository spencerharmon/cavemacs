;;; cavemacs-render.el --- Streaming render of AgentSessionEvent  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Renders the AgentSessionEvent stream from caveman --mode rpc into the
;; cavemacs shell buffer.  Each event mutates the buffer in-place; the
;; current assistant turn is maintained as a single replaceable region
;; identified by overlays.
;;
;; Visual style is controlled by cavemacs-pretty.el (palette, glyphs,
;; faces).  When `cavemacs-pretty-mode' is on (the default), turns are
;; rendered as "bubble" blocks with a left rule + indented body; tool
;; calls become boxed cards; code blocks gain language pills and a
;; copy button; etc.  When pretty-mode is off, output falls back to
;; the older two-line "Assistant ·" / "You" prefix layout for users
;; who prefer the minimal presentation or run in a constrained
;; terminal.
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
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'markdown-mode nil t)
(require 'diff-mode)
(require 'cavemacs-pretty)

;; -----------------------------------------------------------------------------
;; Back-compat faces (renderer still references these directly in places;
;; cavemacs-pretty.el supplies the modern equivalents).
;; -----------------------------------------------------------------------------

(defface cavemacs-user-prefix-face
  '((t :inherit cavemacs-pretty-user-rule-face))
  "Face for the user-turn prefix (legacy + fallback layout)."
  :group 'cavemacs)

(defface cavemacs-assistant-prefix-face
  '((t :inherit cavemacs-pretty-assistant-rule-face))
  "Face for the assistant-turn prefix (legacy + fallback layout)."
  :group 'cavemacs)

(defface cavemacs-tool-face
  '((t :inherit cavemacs-pretty-tool-rule-face))
  "Face for tool-call titles."
  :group 'cavemacs)

(defface cavemacs-tool-args-face
  '((t :inherit font-lock-comment-face))
  "Face for tool-call argument summaries."
  :group 'cavemacs)

(defface cavemacs-meta-face
  '((t :inherit cavemacs-pretty-meta-face))
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

(defvar-local cavemacs-render--tool-start-times nil
  "Hash table: toolCallId -> float-time when tool_execution_start fired.")

(defvar-local cavemacs-render--meta nil
  "Plist of last-known meta info: :model :provider :cost :tokens-in :tokens-out.")

(defun cavemacs-render-init-buffer ()
  "Initialize buffer-local render state."
  (setq cavemacs-render--turn-overlays nil
        cavemacs-render--message-overlays (make-hash-table :test 'equal)
        cavemacs-render--current-assistant-ov nil
        cavemacs-render--tool-overlays (make-hash-table :test 'equal)
        cavemacs-render--tool-start-times (make-hash-table :test 'equal)
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

See the longer comment in the historical version of this file; the
key invariant is: if the user was parked at `point-max' (the input
area), advance their point + window-points to the new `point-max'
after BODY runs so RET continues to submit the next prompt."
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
;; Pretty primitives
;; -----------------------------------------------------------------------------

(defun cavemacs-render--rule-prefix (face)
  "Return the propertized left-rule prefix string for a turn body line."
  (propertize (concat (cavemacs-pretty-glyph 'cont) "  ")
              'face face))

(defun cavemacs-render--header-line (role glyph face title meta)
  "Return a propertized single-line bubble header.

GLYPH + TITLE are tinted with FACE; META is shown in meta-face.
ROLE is stashed as a text property so navigation can find turn
boundaries quickly."
  (let* ((bar (propertize (cavemacs-pretty-glyph 'rule) 'face face))
         (g   (propertize glyph 'face face))
         (sep (propertize " · " 'face 'cavemacs-pretty-meta-face))
         (t1  (propertize title 'face face))
         (m   (when (and meta (not (string-empty-p meta)))
                (propertize meta 'face 'cavemacs-pretty-meta-face))))
    (propertize
     (concat bar " " g " " t1
             (when m (concat sep m))
             "\n")
     'cavemacs-turn role
     'cavemacs-fringe (pcase role
                        ('user 'turn-user)
                        ('assistant 'turn-asst)
                        (_ 'turn-other)))))

(defun cavemacs-render--indent-body (text face)
  "Indent every line in TEXT with a continuation rule in FACE."
  (let ((prefix (cavemacs-render--rule-prefix face)))
    (mapconcat (lambda (l) (concat prefix l))
               (split-string (or text "") "\n" nil)
               "\n")))

(defun cavemacs-render--apply-fringe (beg end kind)
  "Tag the line containing BEG..END with a fringe indicator of KIND."
  (when (and (boundp 'cavemacs-pretty-mode) cavemacs-pretty-mode
             cavemacs-pretty-fringe-indicators)
    (let ((bitmap (pcase kind
                    ('turn-user 'right-triangle)
                    ('turn-asst 'right-triangle)
                    ('tool      'filled-square)
                    (_          'left-bracket)))
          (face (pcase kind
                  ('turn-user 'cavemacs-pretty-user-rule-face)
                  ('turn-asst 'cavemacs-pretty-assistant-rule-face)
                  ('tool      'cavemacs-pretty-tool-rule-face)
                  (_          'cavemacs-pretty-meta-face))))
      (let ((ov (make-overlay beg end)))
        (overlay-put ov 'before-string
                     (propertize " " 'display
                                 `((left-fringe ,bitmap ,face))))
        (overlay-put ov 'cavemacs-fringe-marker t)))))

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
    ("queue_update"         nil)
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
     (let* ((status (alist-get 'status event))
            (code (alist-get 'exitCode event))
            (ev (alist-get 'event event))
            (stderr (alist-get 'stderr event))
            (head (format "[cavemacs] caveman process %s%s%s"
                          status
                          (if (numberp code) (format " (exit %d)" code) "")
                          (if (and ev (not (string-empty-p ev)))
                              (format ": %s" ev) ""))))
       (cavemacs-pretty-state-put :status 'error)
       (cavemacs-render--notice head 'cavemacs-error-face)
       (when (and stderr (not (string-empty-p stderr)))
         (cavemacs-render--at-output
           (cavemacs-render--ensure-newline-before)
           (insert (propertize "── caveman stderr (tail) ─────────────\n"
                               'face 'cavemacs-meta-face))
           (insert (propertize stderr 'face 'cavemacs-error-face))
           (unless (eq (char-before) ?\n) (insert "\n"))
           (insert (propertize "──────────────────────────────────────\n"
                               'face 'cavemacs-meta-face))
           ;; Actionable hint when the failure smells like a broken
           ;; project-local extension.  Most users won't know
           ;; --no-extensions exists; surfacing it inline saves a
           ;; round-trip to caveman --help.
           (when (string-match-p
                  "Failed to load extension\\|Cannot find module"
                  stderr)
             (insert (propertize
                      (concat
                       "Hint: a project-local extension failed to load.  "
                       "To start the session without extensions, set\n"
                       "      (setq cavemacs-no-extensions t)\n"
                       "and restart (C-c C-r).  Use M-x customize-group "
                       "cavemacs to see all opt-outs.\n")
                      'face 'cavemacs-meta-face)))
           (insert (propertize
                    "Run M-x cavemacs-shell-show-stderr for the full log, or \
M-x cavemacs-shell-restart to start a new process.\n"
                    'face 'cavemacs-meta-face))))))
    (_ nil)))

(defun cavemacs-render--notice (text &optional face)
  "Insert a one-line system notice TEXT with FACE."
  (cavemacs-render--at-output
    (cavemacs-render--ensure-newline-before)
    (insert (propertize text 'face (or face 'cavemacs-meta-face)) "\n")))

(defun cavemacs-render--on-agent-start (_event)
  (cavemacs-pretty-state-put :status 'busy))

(defun cavemacs-render--on-turn-start (_event)
  (cavemacs-pretty-state-put :status 'busy))

;; -----------------------------------------------------------------------------
;; message_start
;; -----------------------------------------------------------------------------

(defun cavemacs-render--on-message-start (event)
  "Render an opening block for a message's eventual content."
  (let* ((msg (alist-get 'message event))
         (role (alist-get 'role msg))
         (key (cavemacs-render--message-key msg)))
    (cavemacs-render--at-output
      (cavemacs-render--ensure-blank-line-before)
      (let ((start (point)))
        (pcase role
          ("user"      (cavemacs-render--render-user-start    msg start key))
          ("assistant" (cavemacs-render--render-asst-start    msg start key))
          (_
           (insert (propertize (format "[%s]" role)
                               'face 'cavemacs-pretty-meta-face)
                   "\n")
           (insert (cavemacs-render--message-text msg))
           (insert "\n")))))))

(defun cavemacs-render--render-user-start (msg start key)
  "Render the opening bubble for a user message."
  (let* ((face 'cavemacs-pretty-user-rule-face)
         (glyph (cavemacs-pretty-glyph 'user))
         ;; Tests look for the literal string "You" anywhere in the
         ;; user bubble, so include it in the meta string.
         (meta (format "you · %s" (cavemacs-pretty-now)))
         (text (cavemacs-render--message-text msg)))
    (insert (cavemacs-render--header-line 'user glyph face "You" meta))
    (let ((body-start (point)))
      (insert (cavemacs-render--indent-body text face))
      (unless (eq (char-before) ?\n) (insert "\n"))
      (insert "\n")
      (let ((ov (make-overlay start (point) nil nil t)))
        (overlay-put ov 'cavemacs-role 'user)
        (overlay-put ov 'cavemacs-body-start body-start)
        (puthash key ov cavemacs-render--message-overlays))
      (cavemacs-render--apply-fringe start (1+ start) 'turn-user))))

(defun cavemacs-render--render-asst-start (msg start key)
  "Render the opening bubble for an assistant message."
  (let* ((face 'cavemacs-pretty-assistant-rule-face)
         (glyph (cavemacs-pretty-glyph 'assistant))
         (model (alist-get 'model msg))
         (provider (alist-get 'provider msg))
         ;; "Assistant" literal kept for test back-compat.
         (title (cond ((and model provider)
                       (format "Assistant · %s/%s" provider model))
                      (model    (format "Assistant · %s" model))
                      (t        "Assistant")))
         (meta (cavemacs-pretty-now)))
    (insert (cavemacs-render--header-line 'assistant glyph face title meta))
    (when (and provider (not (string-empty-p provider)))
      (cavemacs-pretty-state-put :provider provider))
    (when (and model (not (string-empty-p model)))
      (cavemacs-pretty-state-put :model model))
    (let ((body-start (point)))
      (insert "")
      (let ((ov (make-overlay start (point) nil nil t)))
        (overlay-put ov 'cavemacs-role 'assistant)
        (overlay-put ov 'cavemacs-body-start body-start)
        (overlay-put ov 'cavemacs-text "")
        (overlay-put ov 'cavemacs-thinking "")
        (puthash key ov cavemacs-render--message-overlays)
        (setq cavemacs-render--current-assistant-ov ov))
      (cavemacs-render--apply-fringe start (1+ start) 'turn-asst))))

;; -----------------------------------------------------------------------------
;; message_update (streaming deltas)
;; -----------------------------------------------------------------------------

(defun cavemacs-render--on-message-update (event)
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
        (_ nil)))
    (cavemacs-render--repaint-assistant ov)
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

;; -----------------------------------------------------------------------------
;; Assistant repaint: bubble + markdown + code blocks
;; -----------------------------------------------------------------------------

(defun cavemacs-render--repaint-assistant (ov)
  "Re-render assistant overlay OV's body region from cached text/thinking."
  (let ((inhibit-read-only t)
        (body-start (overlay-get ov 'cavemacs-body-start))
        (ov-end (overlay-end ov))
        (text (or (overlay-get ov 'cavemacs-text) ""))
        (thinking (or (overlay-get ov 'cavemacs-thinking) ""))
        (is-error (overlay-get ov 'cavemacs-error))
        (buf (overlay-buffer ov))
        (face 'cavemacs-pretty-assistant-rule-face))
    (when (and (buffer-live-p buf) body-start ov-end)
      (with-current-buffer buf
        (save-excursion
          (goto-char body-start)
          (delete-region body-start ov-end)
          (when (and cavemacs-render-show-thinking
                     (not (string-empty-p thinking)))
            (insert (propertize
                     (cavemacs-render--indent-body
                      (concat "▶ thinking\n" thinking) face)
                     'face 'cavemacs-thinking-face))
            (insert "\n\n"))
          (let ((text-start (point)))
            (insert (cavemacs-render--indent-body text face))
            (unless (eq (char-before) ?\n) (insert "\n"))
            (insert "\n")
            (cond
             (is-error
              (put-text-property text-start (point) 'face
                                 'cavemacs-error-face))
             ((and cavemacs-render-fontify-markdown
                       (featurep 'markdown-mode))
              (cavemacs-render--fontify-markdown text-start (point))
              (cavemacs-render--decorate-code-blocks text-start (point))
              (cavemacs-render--apply-variable-pitch text-start (point))))
            (move-overlay ov (overlay-start ov) (point))))))))

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

(defun cavemacs-render--apply-variable-pitch (beg end)
  "If pretty + variable-pitch enabled, mark assistant prose accordingly.

Code-fence regions inside BEG..END stay `fixed-pitch'."
  (when (and (cavemacs-pretty-active-p)
             cavemacs-pretty-variable-pitch)
    (let ((ov (make-overlay beg end nil t nil)))
      (overlay-put ov 'face 'cavemacs-pretty-prose-face)
      (overlay-put ov 'cavemacs-prose t)
      (overlay-put ov 'evaporate t))))

(defun cavemacs-render--decorate-code-blocks (beg end)
  "Find ``` fenced blocks in BEG..END and add pill + bg + copy button."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      ;; Note: bodies are indented with the continuation rule ("│  ")
      ;; so the opening fence appears after that prefix.
      (while (re-search-forward
              "^\\(?:.\\{0,4\\}\\)\\(```\\)\\([A-Za-z0-9_+-]*\\)[^\n]*\n"
              nil t)
        (let* ((lang (match-string 2))
               (fence-line-end (match-end 0))
               (block-start (point))
               (end-found
                (re-search-forward "^\\(?:.\\{0,4\\}\\)```[ \t]*$" nil t))
               (block-end (if end-found
                              (match-beginning 0)
                            (point-max))))
          (when end-found
            ;; Subtle background on the code body
            (let ((ov (make-overlay block-start block-end)))
              (overlay-put ov 'face 'cavemacs-pretty-code-face)
              (overlay-put ov 'cavemacs-code t)
              (overlay-put ov 'evaporate t))
            ;; Language pill at the top of the block
            (when (and lang (not (string-empty-p lang)))
              (let ((pill (propertize (format " %s " lang)
                                      'face 'cavemacs-pretty-code-pill-face)))
                (let ((pov (make-overlay (1- fence-line-end) fence-line-end)))
                  (overlay-put pov 'before-string
                               (concat "  " pill "  "))
                  (overlay-put pov 'evaporate t))))
            ;; Copy-to-kill-ring button on the closing fence line
            (when (fboundp 'buttonize)
              (save-excursion
                (goto-char (match-end 0))
                (let ((text (buffer-substring-no-properties
                             block-start block-end))
                      (bov (make-overlay (match-beginning 0) (match-end 0))))
                  (overlay-put
                   bov 'after-string
                   (concat
                    " "
                    (buttonize "[copy]"
                               (lambda (_)
                                 (kill-new text)
                                 (message "Copied %d chars" (length text))))))
                  (overlay-put bov 'evaporate t))))))))))

;; -----------------------------------------------------------------------------
;; message_end
;; -----------------------------------------------------------------------------

(defun cavemacs-render--on-message-end (event)
  "Finalize a message's overlay state."
  (let* ((msg (alist-get 'message event))
         (key (cavemacs-render--message-key msg))
         (stop-reason (alist-get 'stopReason msg))
         (error-message (alist-get 'errorMessage msg)))
    (when-let* ((ov (and key (gethash key cavemacs-render--message-overlays))))
      (when (eq (overlay-get ov 'cavemacs-role) 'assistant)
        (let ((full (cavemacs-render--message-text msg)))
          (when (and full (not (string-empty-p full)))
            (overlay-put ov 'cavemacs-text full)
            (cavemacs-render--repaint-assistant ov)))
        (when (and (equal stop-reason "error") error-message)
          (overlay-put ov 'cavemacs-text
                       (cavemacs-render--format-error error-message))
          (overlay-put ov 'cavemacs-error t)
          (cavemacs-pretty-state-put :status 'error)
          (cavemacs-render--repaint-assistant ov))
        (when (eq ov cavemacs-render--current-assistant-ov)
          (setq cavemacs-render--current-assistant-ov nil))))))

(defun cavemacs-render--format-error (raw)
  "Coerce caveman's RAW errorMessage string into something readable."
  (let* ((status (when (string-match "\\`\\([0-9]\\{3\\}\\)[[:space:]]+" raw)
                   (match-string 1 raw)))
         (json-tail (if (and status
                             (string-match
                              "\\`[0-9]\\{3\\}[[:space:]]+\\({.*}\\)\\'"
                              raw))
                        (match-string 1 raw)
                      (when (string-match "\\`\\({.*}\\)\\'" raw)
                        (match-string 1 raw))))
         (extracted
          (when json-tail
            (condition-case nil
                (let* ((obj (json-parse-string json-tail
                                               :object-type 'alist
                                               :null-object nil
                                               :false-object nil))
                       (err (alist-get 'error obj)))
                  (or (and err (alist-get 'message err))
                      (alist-get 'message obj)))
              (error nil)))))
    (cond
     ((and status extracted) (format "⚠ %s · %s" status extracted))
     (extracted              (format "⚠ %s" extracted))
     (status                 (format "⚠ %s · %s" status raw))
     (t                      (format "⚠ %s" raw)))))

;; -----------------------------------------------------------------------------
;; Tool execution: boxed cards
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
  "Render the opening of a tool-call card."
  (let* ((tool-id (alist-get 'toolCallId event))
         (name (alist-get 'toolName event))
         (args (alist-get 'args event))
         (face (cavemacs-pretty-tool-face name))
         (glyph (cavemacs-pretty-glyph 'tool)))
    (when tool-id
      (puthash tool-id (float-time) cavemacs-render--tool-start-times))
    (cavemacs-pretty-state-put :status 'busy)
    (cavemacs-render--at-output
      (cavemacs-render--ensure-newline-before)
      (let ((start (point)))
        ;; Card header line:  ╭─ ⚙ tool · args ──...
        (insert
         (propertize
          (concat
           (cavemacs-pretty-glyph 'box-tl)
           (cavemacs-pretty-glyph 'box-h)
           " ")
          'face face))
        (insert (propertize (format "%s %s" glyph name) 'face face))
        (let ((summary (cavemacs-render--tool-arg-summary args)))
          (when (and summary (not (string-empty-p summary)))
            (insert (propertize " · " 'face 'cavemacs-pretty-meta-face))
            (insert (propertize summary 'face 'cavemacs-tool-args-face))))
        (insert " ")
        (insert (propertize
                 (make-string 4 (string-to-char
                                 (cavemacs-pretty-glyph 'box-h)))
                 'face face))
        (insert "\n")
        (let ((ov (make-overlay start (point) nil nil t)))
          (overlay-put ov 'cavemacs-tool-id tool-id)
          (overlay-put ov 'cavemacs-tool-name name)
          (overlay-put ov 'cavemacs-tool-status 'running)
          (overlay-put ov 'cavemacs-tool-face face)
          (puthash tool-id ov cavemacs-render--tool-overlays))
        (cavemacs-render--apply-fringe start (1+ start) 'tool)))))

(defun cavemacs-render--on-tool-update (_event) nil)

(defun cavemacs-render--on-tool-end (event)
  "Append a result block under the matching tool overlay, then close the card."
  (let* ((tool-id (alist-get 'toolCallId event))
         (result (alist-get 'result event))
         (is-error (eq (alist-get 'isError event) t))
         (ov (and tool-id (gethash tool-id cavemacs-render--tool-overlays)))
         (start-time (and tool-id
                          (gethash tool-id cavemacs-render--tool-start-times)))
         (duration (and start-time (- (float-time) start-time)))
         (face (or (and ov (overlay-get ov 'cavemacs-tool-face))
                   'cavemacs-pretty-tool-rule-face))
         (rule-face (if is-error 'cavemacs-pretty-error-rule-face face)))
    (when (and ov (overlay-buffer ov))
      (let ((inhibit-read-only t))
        (with-current-buffer (overlay-buffer ov)
          (save-excursion
            (goto-char (overlay-end ov))
            (let* ((text (cavemacs-render--render-tool-result result))
                   (body-prefix (propertize
                                 (concat (cavemacs-pretty-glyph 'box-v) " ")
                                 'face rule-face))
                   (body (mapconcat (lambda (l) (concat body-prefix l))
                                    (split-string (string-trim-right text)
                                                  "\n" nil)
                                    "\n"))
                   (body-beg (point)))
              (insert (propertize
                       body
                       'face (if is-error 'cavemacs-error-face
                              'cavemacs-pretty-meta-face)))
              (insert "\n")
              ;; Diff-mode fontify if the result smells like a unified diff.
              (when (cavemacs-render--looks-like-diff-p text)
                (cavemacs-render--fontify-diff body-beg (point)))
              ;; Closing line:  ╰──── 0.42s ────
              (let* ((duration-str
                      (when duration (format " %.2fs " duration)))
                     (close (concat
                             (cavemacs-pretty-glyph 'box-bl)
                             (make-string 4 (string-to-char
                                             (cavemacs-pretty-glyph 'box-h)))
                             (or duration-str "")
                             (make-string 4 (string-to-char
                                             (cavemacs-pretty-glyph 'box-h))))))
                (insert (propertize close 'face rule-face))
                (insert "\n"))
              (move-overlay ov (overlay-start ov) (point))
              (overlay-put ov 'cavemacs-tool-status
                           (if is-error 'error 'ok)))))))))

(defun cavemacs-render--looks-like-diff-p (text)
  "Heuristic: does TEXT contain a unified diff header?"
  (and (stringp text)
       (string-match-p "^---[ \t]+[^\n]+\n\\+\\+\\+[ \t]+" text)))

(defun cavemacs-render--fontify-diff (beg end)
  "Apply `diff-mode' font-lock to BEG..END."
  (ignore-errors
    (save-restriction
      (narrow-to-region beg end)
      (let ((font-lock-defaults
             (if (boundp 'diff-font-lock-keywords)
                 `(,diff-font-lock-keywords nil nil nil nil)
               nil)))
        (when font-lock-defaults
          (font-lock-default-fontify-region (point-min) (point-max) nil))))))

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
  (cavemacs-pretty-state-put :status 'idle)
  (when cavemacs-render--meta
    (let* ((m cavemacs-render--meta)
           (cost (plist-get m :cost)))
      (when (numberp cost)
        (cavemacs-pretty-add-cost cost))
      (let ((text (format "── %s in / %s out / %s total · %s"
                          (or (plist-get m :tokens-in) "?")
                          (or (plist-get m :tokens-out) "?")
                          (or (plist-get m :total) "?")
                          (if cost (format "$%.4f" cost)
                            "no cost data"))))
        (cavemacs-render--at-output
          (cavemacs-render--ensure-newline-before)
          (insert (propertize text 'face 'cavemacs-meta-face) "\n"))))))

;; -----------------------------------------------------------------------------
;; Turn navigation (M-{ / M-})
;; -----------------------------------------------------------------------------

(defun cavemacs-render-next-turn (&optional n)
  "Move point forward N (default 1) turn boundaries."
  (interactive "p")
  (let* ((arg (or n 1))
         (dir (if (< arg 0) -1 1))
         (count (abs arg)))
    (dotimes (_ count)
      (let ((pos (if (> dir 0)
                     (next-single-property-change (point) 'cavemacs-turn)
                   (previous-single-property-change (point) 'cavemacs-turn))))
        (when pos (goto-char pos))))))

(defun cavemacs-render-previous-turn (&optional n)
  "Move point backward N turn boundaries."
  (interactive "p")
  (cavemacs-render-next-turn (- (or n 1))))

(provide 'cavemacs-render)
;;; cavemacs-render.el ends here
