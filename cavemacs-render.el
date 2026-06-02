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

(declare-function markdown-mode "markdown-mode" ())

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

(defcustom cavemacs-render-thinking-default-collapsed t
  "When non-nil, thinking blocks render collapsed by default.

Collapsed blocks show only a summary line (`▶ thinking (N lines)')
that the user can expand with TAB/RET/mouse-1."
  :type 'boolean
  :group 'cavemacs)

(defcustom cavemacs-render-tool-default-collapsed t
  "When non-nil, tool-call body regions render collapsed by default.

Collapsed bodies are replaced with a single summary line; the
card header and footer remain visible.  Toggle with TAB/RET/
mouse-1 on the card header."
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

(defvar-local cavemacs-render--collapsed nil
  "Hash table: block-id -> non-nil iff that block is collapsed.

Block ids are arbitrary strings chosen by the renderer.  For
thinking blocks the id is the assistant message key prefixed with
\"thinking:\"; for tool cards it is \"tool:<tool-call-id>\".

State lives buffer-local and is not persisted across restarts;
each new session starts at the defaults from
`cavemacs-render-thinking-default-collapsed' /
`cavemacs-render-tool-default-collapsed'.")

(defvar-local cavemacs-render--collapse-overlays nil
  "Hash table: block-id -> overlay covering the collapsible body region.

Used by `cavemacs-render-toggle-block' so the toggle keymap on the
header can find its body without walking the buffer.")

;; --- Streaming-repaint coalescing & GC tuning -------------------------------

(defcustom cavemacs-render-repaint-idle 0.03
  "Idle-time seconds to coalesce streaming assistant repaints.

During a streaming assistant message, `text_delta' events arrive
many times per second.  Repainting the full message body for each
is O(N) per delta and dominates CPU on long messages.  Instead we
update the overlay's cached text immediately and schedule a
single repaint on this idle timer.  `message_end' (and other
finalizers) flush synchronously."
  :type 'number
  :group 'cavemacs)

(defcustom cavemacs-render-streaming-gc-threshold (* 64 1024 1024)
  "Value bound to `gc-cons-threshold' while a turn is streaming.

String churn from delta concatenation triggers GC mid-stream and
shows up as visible stutter.  Restored to the prior value on
`turn_end' / `agent_end'."
  :type 'integer
  :group 'cavemacs)

(defvar-local cavemacs-render--pending-repaint nil
  "If non-nil, the overlay scheduled for a coalesced repaint.")

(defvar-local cavemacs-render--repaint-timer nil
  "Idle timer that flushes the pending streaming repaint.")

(defvar-local cavemacs-render--saved-gc-threshold nil
  "Previous `gc-cons-threshold' to restore at end of turn.")

(defmacro cavemacs-render--with-fast-insert (&rest body)
  "Run BODY with foreign modification hooks disabled and undo off.

Keeps `after-change-functions' (hl-line, whitespace-mode, lsp,
etc.) and undo-list growth from dominating render time on big
streams.  Buffer text changes are still visible to redisplay."
  (declare (indent 0) (debug t))
  `(let ((inhibit-modification-hooks t)
         (buffer-undo-list t))
     ,@body))

(defun cavemacs-render--bump-gc ()
  "Raise `gc-cons-threshold' for a streaming turn if not already raised."
  (unless cavemacs-render--saved-gc-threshold
    (setq cavemacs-render--saved-gc-threshold gc-cons-threshold
          gc-cons-threshold (max gc-cons-threshold
                                 cavemacs-render-streaming-gc-threshold))))

(defun cavemacs-render--restore-gc ()
  "Restore `gc-cons-threshold' saved by `cavemacs-render--bump-gc'."
  (when cavemacs-render--saved-gc-threshold
    (setq gc-cons-threshold cavemacs-render--saved-gc-threshold
          cavemacs-render--saved-gc-threshold nil)))

(defun cavemacs-render--cancel-repaint-timer ()
  (when (timerp cavemacs-render--repaint-timer)
    (cancel-timer cavemacs-render--repaint-timer)
    (setq cavemacs-render--repaint-timer nil)))

(defun cavemacs-render--flush-pending-repaint (buf)
  "Run the deferred streaming repaint for BUF, if any."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (cavemacs-render--cancel-repaint-timer)
      (let ((ov cavemacs-render--pending-repaint))
        (setq cavemacs-render--pending-repaint nil)
        (when (and ov (overlay-buffer ov)
                   (not (overlay-get ov 'cavemacs-finalized)))
          (cavemacs-render--repaint-assistant ov t))))))

(defun cavemacs-render--schedule-repaint (ov)
  "Schedule a coalesced repaint of assistant overlay OV."
  (setq cavemacs-render--pending-repaint ov)
  (unless (timerp cavemacs-render--repaint-timer)
    (let ((buf (current-buffer)))
      (setq cavemacs-render--repaint-timer
            (run-with-idle-timer
             cavemacs-render-repaint-idle nil
             #'cavemacs-render--flush-pending-repaint buf)))))

(defun cavemacs-render-init-buffer ()
  "Initialize buffer-local render state."
  (cavemacs-render--cancel-repaint-timer)
  (cavemacs-render--restore-gc)
  (setq cavemacs-render--pending-repaint nil
        cavemacs-render--turn-overlays nil
        cavemacs-render--message-overlays (make-hash-table :test 'equal)
        cavemacs-render--current-assistant-ov nil
        cavemacs-render--tool-overlays (make-hash-table :test 'equal)
        cavemacs-render--tool-start-times (make-hash-table :test 'equal)
        cavemacs-render--meta nil
        cavemacs-render--collapsed (make-hash-table :test 'equal)
        cavemacs-render--collapse-overlays (make-hash-table :test 'equal))
  (add-to-invisibility-spec 'cavemacs-collapse))

;; -----------------------------------------------------------------------------
;; Collapsibility (M11)
;; -----------------------------------------------------------------------------
;;
;; Generic toggle: each collapsible block is keyed by an arbitrary
;; string id.  Collapse state lives in `cavemacs-render--collapsed';
;; the body-region overlay is tracked in
;; `cavemacs-render--collapse-overlays' so the header's toggle handler
;; can find it cheaply.
;;
;; Thinking blocks use ids of the form "thinking:<message-key>"; tool
;; cards use "tool:<tool-call-id>".  Header overlays carry a
;; `cavemacs-collapse-id' property the toggle reads.

(defvar cavemacs-render-toggle-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "TAB")         #'cavemacs-render-toggle-at-point)
    (define-key m (kbd "<tab>")       #'cavemacs-render-toggle-at-point)
    (define-key m (kbd "RET")         #'cavemacs-render-toggle-at-point)
    (define-key m (kbd "<return>")    #'cavemacs-render-toggle-at-point)
    (define-key m (kbd "<mouse-1>")   #'cavemacs-render-toggle-at-mouse)
    m)
  "Keymap installed on collapsible block headers.")

(defun cavemacs-render--block-id-at (pos)
  "Return the cavemacs-collapse-id text-property at POS, if any."
  (get-text-property pos 'cavemacs-collapse-id))

(defun cavemacs-render--collapse-default (kind)
  "Return the default collapsed state for KIND (\"thinking\" or \"tool\")."
  (pcase kind
    ("thinking" cavemacs-render-thinking-default-collapsed)
    ("tool"     cavemacs-render-tool-default-collapsed)
    (_          nil)))

(defun cavemacs-render--collapsed-p (id)
  "Return non-nil iff block ID is currently collapsed.

If ID has no recorded state, fall back to the default for its
kind (the prefix of ID up to the first colon)."
  (cond
   ((and cavemacs-render--collapsed
         (let ((v (gethash id cavemacs-render--collapsed 'unset)))
           (if (eq v 'unset) nil v)))
    t)
   ((and cavemacs-render--collapsed
         (eq (gethash id cavemacs-render--collapsed 'unset) 'unset))
    (cavemacs-render--collapse-default
     (car (split-string id ":"))))
   (t nil)))

(defun cavemacs-render--set-collapsed (id value)
  "Set collapse state for ID to VALUE (non-nil = collapsed)."
  (unless cavemacs-render--collapsed
    (setq cavemacs-render--collapsed (make-hash-table :test 'equal)))
  (puthash id (and value t) cavemacs-render--collapsed))

(defun cavemacs-render--apply-collapse (id)
  "Apply the recorded collapse state of ID to its body overlay."
  (when-let* ((ov (and cavemacs-render--collapse-overlays
                       (gethash id cavemacs-render--collapse-overlays)))
              ((overlay-buffer ov)))
    (if (cavemacs-render--collapsed-p id)
        (progn
          (overlay-put ov 'invisible 'cavemacs-collapse)
          (overlay-put ov 'before-string
                       (overlay-get ov 'cavemacs-summary)))
      (overlay-put ov 'invisible nil)
      (overlay-put ov 'before-string nil))))

(defun cavemacs-render-toggle-block (id)
  "Toggle collapse state for block ID."
  (interactive (list (cavemacs-render--block-id-at (point))))
  (unless id
    (user-error "No collapsible block at point"))
  (cavemacs-render--set-collapsed
   id (not (cavemacs-render--collapsed-p id)))
  (cavemacs-render--apply-collapse id))

(defun cavemacs-render-toggle-at-point ()
  "Toggle the collapsible block whose header is at point."
  (interactive)
  (if-let* ((id (or (cavemacs-render--block-id-at (point))
                    (cavemacs-render--block-id-at (line-beginning-position)))))
      (cavemacs-render-toggle-block id)
    ;; Fall through to the previous binding so RET still submits
    ;; when called outside a header (e.g. in the input area).
    (call-interactively (key-binding (this-single-command-keys)))))

(defun cavemacs-render-toggle-at-mouse (event)
  "Toggle the collapsible block clicked by EVENT."
  (interactive "e")
  (let* ((pos (posn-point (event-start event))))
    (when-let* ((id (and pos (cavemacs-render--block-id-at pos))))
      (cavemacs-render-toggle-block id))))

(defun cavemacs-render--register-block (id header-beg header-end
                                            body-beg body-end summary)
  "Wire up a collapsible block.

ID is the stable key.  Header line spans HEADER-BEG..HEADER-END;
the body region spans BODY-BEG..BODY-END.  SUMMARY is a propertized
string shown as `before-string' on the body overlay when collapsed
(typically a one-liner like \"  ▶ collapsed (42 lines)\\n\").

The header gets the `cavemacs-collapse-id' text property + the
toggle keymap.  Idempotent: re-registering an ID replaces its
previous body overlay (handy for thinking blocks, whose body is
regenerated every delta)."
  (let ((inhibit-read-only t))
    ;; Tag the header line so navigation and the toggle handler can
    ;; find this block from point.
    (add-text-properties
     header-beg header-end
     `(cavemacs-collapse-id ,id
       keymap ,cavemacs-render-toggle-map
       mouse-face highlight
       help-echo "TAB / RET / mouse-1: toggle"))
    ;; Drop any prior body overlay for this id (thinking blocks
    ;; regenerate on every delta).
    (when-let* ((old (and cavemacs-render--collapse-overlays
                          (gethash id cavemacs-render--collapse-overlays))))
      (delete-overlay old))
    (let ((ov (make-overlay body-beg body-end nil nil nil)))
      (overlay-put ov 'cavemacs-block-id id)
      (overlay-put ov 'cavemacs-summary summary)
      (overlay-put ov 'evaporate t)
      (unless cavemacs-render--collapse-overlays
        (setq cavemacs-render--collapse-overlays
              (make-hash-table :test 'equal)))
      (puthash id ov cavemacs-render--collapse-overlays)
      (cavemacs-render--apply-collapse id))))

;;;###autoload
(defun cavemacs-render-collapse-all ()
  "Collapse every collapsible block in this buffer."
  (interactive)
  (when cavemacs-render--collapse-overlays
    (maphash (lambda (id _ov)
               (cavemacs-render--set-collapsed id t)
               (cavemacs-render--apply-collapse id))
             cavemacs-render--collapse-overlays)))

;;;###autoload
(defun cavemacs-render-expand-all ()
  "Expand every collapsible block in this buffer."
  (interactive)
  (when cavemacs-render--collapse-overlays
    (maphash (lambda (id _ov)
               (cavemacs-render--set-collapsed id nil)
               (cavemacs-render--apply-collapse id))
             cavemacs-render--collapse-overlays)))

;;;###autoload
(defun cavemacs-render-toggle-all ()
  "Toggle every collapsible block in this buffer.
If any are expanded, collapse all; otherwise expand all."
  (interactive)
  (let ((any-expanded nil))
    (when cavemacs-render--collapse-overlays
      (maphash (lambda (id _ov)
                 (unless (cavemacs-render--collapsed-p id)
                   (setq any-expanded t)))
               cavemacs-render--collapse-overlays))
    (if any-expanded
        (cavemacs-render-collapse-all)
      (cavemacs-render-expand-all))))

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
          (inhibit-modification-hooks t)
          (buffer-undo-list t)
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
             (set-window-point w (point-max))))))
     ;; Insertion above the prompt-marker pushes the input area
     ;; (and any point parked in or near it) toward `point-max'.
     ;; Emacs's auto-scroll only fires for the selected window's
     ;; buffer point; other windows showing this buffer, or a
     ;; redisplay deferred until after this filter returns, can
     ;; leave the input area scrolled below `window-end' --
     ;; visually "behind" the mode-line.  Force every live window
     ;; showing this buffer to scroll its window-point back on
     ;; screen.
     (dolist (w (get-buffer-window-list (current-buffer) nil t))
       (let ((wp (window-point w)))
         (when (= wp (point-max))
           (with-selected-window w
             (save-excursion
               (goto-char wp)
               (recenter -1))))))))

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
  "Return the propertized left-rule prefix string for a turn body line.
Tagged with `cavemacs-rule' so kill/yank strips it (see
`cavemacs-shell--filter-buffer-substring')."
  (propertize (concat (cavemacs-pretty-glyph 'cont) "  ")
              'face face
              'cavemacs-rule t))

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
;; History replay (session resume)
;; -----------------------------------------------------------------------------

(defun cavemacs-render-replay-messages (messages)
  "Render prior session MESSAGES (a list of AgentMessage alists) into the
buffer by synthesizing the AgentSessionEvents the live agent would have
emitted. Tool calls in assistant messages are paired with subsequent
toolResult messages by `toolCallId'."
  (dolist (msg messages)
    (let ((role (alist-get 'role msg)))
      (pcase role
        ("user"
         (cavemacs-render-event `((type . "message_start") (message . ,msg)))
         (cavemacs-render-event `((type . "message_end")   (message . ,msg))))
        ("assistant"
         (cavemacs-render-event `((type . "message_start") (message . ,msg)))
         (let ((content (alist-get 'content msg)))
           (when (listp content)
             (dolist (part content)
               (when (and (listp part)
                          (equal (alist-get 'type part) "toolCall"))
                 (cavemacs-render-event
                  `((type . "tool_execution_start")
                    (toolCallId . ,(alist-get 'id part))
                    (toolName   . ,(alist-get 'name part))
                    (args       . ,(alist-get 'arguments part))))))))
         (cavemacs-render-event `((type . "message_end") (message . ,msg))))
        ((or "toolResult" "tool_result" "tool")
         (cavemacs-render-event
          `((type . "tool_execution_end")
            (toolCallId . ,(alist-get 'toolCallId msg))
            (toolName   . ,(alist-get 'toolName msg))
            (result     . ((content . ,(alist-get 'content msg))
                           (details . ,(alist-get 'details msg))))
            (isError    . ,(alist-get 'isError msg)))))
        (_ nil))))
  (cavemacs-pretty-state-put :status 'idle))

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
  (cavemacs-render--bump-gc)
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
          ;; Tool-result messages are already displayed inside the
          ;; tool card; skip the redundant raw message rendering.
          ((or "tool" "toolResult" "tool_result") nil)
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
      (let ((ov (make-overlay start (point) nil nil nil)))
        (overlay-put ov 'cavemacs-role 'user)
        (overlay-put ov 'cavemacs-body-start body-start)
        (puthash key ov cavemacs-render--message-overlays))
      (cavemacs-render--apply-fringe start (1+ start) 'turn-user))))

(defun cavemacs-render--render-asst-start (msg start key)
  "Open an assistant message overlay WITHOUT yet emitting a header line.

Header is deferred and emitted by `cavemacs-render--maybe-emit-header'
on the first prose / thinking insertion.  Tool-only assistant
messages render with no header at all."
  (let* ((face 'cavemacs-pretty-assistant-rule-face)
         (glyph (cavemacs-pretty-glyph 'assistant))
         (model (alist-get 'model msg))
         (provider (alist-get 'provider msg))
         (title (cond ((and model provider)
                       (format "Caveman \u00b7 %s/%s" provider model))
                      (model    (format "Caveman \u00b7 %s" model))
                      (t        "Caveman")))
         (meta (cavemacs-pretty-now))
         (header (cavemacs-render--header-line
                  'assistant glyph face title meta)))
    (when (and provider (not (string-empty-p provider)))
      (cavemacs-pretty-state-put :provider provider))
    (when (and model (not (string-empty-p model)))
      (cavemacs-pretty-state-put :model model))
    (let ((body-start (point)))
      (let ((ov (make-overlay start (point) nil nil nil)))
        (overlay-put ov 'cavemacs-role 'assistant)
        (overlay-put ov 'cavemacs-body-start body-start)
        (overlay-put ov 'cavemacs-msg-key key)
        (overlay-put ov 'cavemacs-text "")
        (overlay-put ov 'cavemacs-thinking "")
        (overlay-put ov 'cavemacs-header-text header)
        (puthash key ov cavemacs-render--message-overlays)
        (setq cavemacs-render--current-assistant-ov ov)))))

(defun cavemacs-render--maybe-emit-header (ov)
  "If OV has a deferred header and any prose/thinking is present, emit it."
  (let ((header (overlay-get ov 'cavemacs-header-text))
        (text (or (overlay-get ov 'cavemacs-text) "")))
    (when (and header (not (string-empty-p text)))
      (let* ((body-start (overlay-get ov 'cavemacs-body-start))
             (inhibit-read-only t))
        (save-excursion
          (goto-char body-start)
          (let ((hbeg (point)))
            (insert header)
            (let ((new-body-start (point)))
              (overlay-put ov 'cavemacs-body-start new-body-start)
              (move-overlay ov (overlay-start ov)
                            (max (overlay-end ov) new-body-start))
              (overlay-put ov 'cavemacs-header-text nil)
              (cavemacs-render--apply-fringe hbeg (1+ hbeg) 'turn-asst))))))))

;; -----------------------------------------------------------------------------
;; message_update (streaming deltas)
;; -----------------------------------------------------------------------------

(defun cavemacs-render--on-message-update (event)
  (when-let* ((ov cavemacs-render--current-assistant-ov)
              ((overlay-buffer ov))
              (ame (alist-get 'assistantMessageEvent event)))
    (let ((kind (alist-get 'type ame))
          (immediate nil))
      (pcase kind
        ("text_start"
         (overlay-put ov 'cavemacs-text "")
         (setq immediate t))
        ("text_delta"
         (let* ((delta (or (alist-get 'delta ame) ""))
                (cur (or (overlay-get ov 'cavemacs-text) "")))
           (overlay-put ov 'cavemacs-text (concat cur delta))))
        ("text_end"
         (let ((final (or (alist-get 'content ame)
                          (overlay-get ov 'cavemacs-text)
                          "")))
           (overlay-put ov 'cavemacs-text final))
         (setq immediate t))
        ("thinking_start"
         (overlay-put ov 'cavemacs-thinking "")
         (setq immediate t))
        ("thinking_delta"
         (let* ((delta (or (alist-get 'delta ame) ""))
                (cur (or (overlay-get ov 'cavemacs-thinking) "")))
           (overlay-put ov 'cavemacs-thinking (concat cur delta))))
        ("thinking_end" (setq immediate t))
        (_ nil))
      (if immediate
          (progn
            (cavemacs-render--cancel-repaint-timer)
            (setq cavemacs-render--pending-repaint nil)
            (cavemacs-render--repaint-assistant ov))
        (cavemacs-render--schedule-repaint ov)))
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

(defun cavemacs-render--repaint-assistant (&optional ov streaming)
  "Re-render assistant overlay OV's body region from cached text/thinking.

When STREAMING is non-nil, skip markdown fontification and code-block
decoration — those are O(N) per call and dominate CPU on long
messages.  A final non-streaming repaint runs on `text_end' /
`message_end' to apply them once."
  (let ((inhibit-read-only t)
        (body-start (overlay-get ov 'cavemacs-body-start))
        (ov-end (overlay-end ov))
        (text (or (overlay-get ov 'cavemacs-text) ""))
        (thinking (or (overlay-get ov 'cavemacs-thinking) ""))
        (msg-key (overlay-get ov 'cavemacs-msg-key))
        (is-error (overlay-get ov 'cavemacs-error))
        (buf (overlay-buffer ov))
        (face 'cavemacs-pretty-assistant-rule-face))
    (when (and (buffer-live-p buf) body-start ov-end)
      (with-current-buffer buf
        (cavemacs-render--with-fast-insert
        ;; Emit deferred header on first prose/thinking content.
        (cavemacs-render--maybe-emit-header ov)
        (setq body-start (overlay-get ov 'cavemacs-body-start)
              ov-end (overlay-end ov))
        (save-excursion
          (goto-char body-start)
          (delete-region body-start ov-end)
          (when (and cavemacs-render-show-thinking
                     (not (string-empty-p thinking)))
            (let* ((nlines (length (split-string thinking "\n")))
                   (rule-prefix (cavemacs-render--rule-prefix face))
                   ;; Header line: rule + arrow + label.  We intentionally
                   ;; include the indent prefix here so the body region
                   ;; visually aligns.  The arrow stays as part of the
                   ;; header text and flips via property when expanded.
                   (header (concat
                            rule-prefix
                            (propertize "▶ thinking" 'face 'cavemacs-meta-face)
                            (propertize (format " (%d line%s)"
                                                nlines
                                                (if (= nlines 1) "" "s"))
                                        'face 'cavemacs-meta-face)
                            "\n"))
                   (header-beg (point))
                   (_ (insert header))
                   (header-end (point))
                   (body-beg (point))
                   (body-content
                    (cavemacs-render--indent-body thinking face)))
              (insert (propertize body-content
                                  'face 'cavemacs-thinking-face))
              (insert "\n")
              (let ((body-end (point)))
                ;; Hook this region into the collapse system if we have
                ;; a stable message key (we always do in practice).
                (when msg-key
                  (cavemacs-render--register-block
                   (format "thinking:%s" msg-key)
                   header-beg header-end body-beg body-end nil)))))
          (let ((text-start (point)))
            (unless (string-empty-p text)
              (let ((rendered
                     (if (and (not is-error)
                              (not streaming)
                              cavemacs-render-fontify-markdown
                              (or (featurep 'markdown-mode)
                                  (require 'markdown-mode nil t)))
                         (cavemacs-render--fontify-markdown-string text)
                       text)))
                (insert (cavemacs-render--indent-body rendered face)))
              (unless (eq (char-before) ?\n) (insert "\n"))
              (insert "\n"))
            (cond
             (is-error
              (put-text-property text-start (point) 'face
                                 'cavemacs-error-face))
             ((and (not streaming)
                   cavemacs-render-fontify-markdown
                   (or (featurep 'markdown-mode)
                       (require 'markdown-mode nil t)))
              (cavemacs-render--decorate-code-blocks text-start (point))
              (cavemacs-render--apply-variable-pitch text-start (point))))
            (move-overlay ov (overlay-start ov) (point)))))))))

(defun cavemacs-render--fontify-markdown-string (text)
  "Return TEXT with markdown-mode font-lock faces applied as text properties."
  (condition-case _
      (with-temp-buffer
        (insert text)
        (delay-mode-hooks (markdown-mode))
        (font-lock-ensure (point-min) (point-max))
        (buffer-string))
    (error text)))

(defun cavemacs-render--fontify-markdown (beg end)
  "Apply markdown font-lock to the region BEG..END (in-place)."
  (let ((text (buffer-substring-no-properties beg end)))
    (save-excursion
      (goto-char beg)
      (delete-region beg end)
      (insert (cavemacs-render--fontify-markdown-string text)))))

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
        ;; Flush any deferred streaming repaint for this overlay before
        ;; we run the final fontified repaint.
        (when (eq ov cavemacs-render--pending-repaint)
          (cavemacs-render--cancel-repaint-timer)
          (setq cavemacs-render--pending-repaint nil))
        (let ((full (cavemacs-render--message-text msg)))
          (when (and full (not (string-empty-p full)))
            (overlay-put ov 'cavemacs-text full)))
        (cavemacs-render--repaint-assistant ov)
        (when (and (equal stop-reason "error") error-message)
          (overlay-put ov 'cavemacs-text
                       (cavemacs-render--format-error error-message))
          (overlay-put ov 'cavemacs-error t)
          (cavemacs-pretty-state-put :status 'error)
          (cavemacs-render--repaint-assistant ov))
        ;; Freeze: later events must not re-render this overlay.
        (overlay-put ov 'cavemacs-finalized t)
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
          'face face 'cavemacs-rule t))
        (insert (propertize (format "%s %s" glyph name) 'face face))
        (let ((summary (cavemacs-render--tool-arg-summary args)))
          (when (and summary (not (string-empty-p summary)))
            (insert (propertize " · " 'face 'cavemacs-pretty-meta-face))
            (insert (propertize summary 'face 'cavemacs-tool-args-face))))
        (insert (propertize " " 'cavemacs-rule t))
        (insert (propertize
                 (make-string 4 (string-to-char
                                 (cavemacs-pretty-glyph 'box-h)))
                 'face face 'cavemacs-rule t))
        (insert (propertize "\n" 'cavemacs-rule t))
        (let ((header-end (point))
              (ov (make-overlay start (point) nil nil t)))
          (overlay-put ov 'cavemacs-tool-id tool-id)
          (overlay-put ov 'cavemacs-tool-name name)
          (overlay-put ov 'cavemacs-tool-args args)
          (overlay-put ov 'cavemacs-tool-status 'running)
          (overlay-put ov 'cavemacs-tool-face face)
          (overlay-put ov 'cavemacs-header-beg (copy-marker start nil))
          (overlay-put ov 'cavemacs-header-end (copy-marker header-end nil))
          (puthash tool-id ov cavemacs-render--tool-overlays)
          ;; Register a placeholder collapsible block now (empty body)
          ;; so the header is toggle-able while the tool is still
          ;; running.  --on-tool-end re-registers with the real body;
          ;; the user's collapse choice persists via the id hash.
          (when tool-id
            (cavemacs-render--register-block
             (format "tool:%s" tool-id)
             start header-end
             header-end header-end nil)))
        (cavemacs-render--apply-fringe start (1+ start) 'tool)))))

(defun cavemacs-render--on-tool-update (_event) nil)

(defun cavemacs-render--format-tool-args-full (args)
  "Return a multi-line pretty-printed string of tool ARGS (alist).

Each top-level key appears on its own line as `key:'; string values
that span multiple lines are indented under the key.  Returns the
empty string when ARGS has no displayable content."
  (cond
   ((null args) "")
   ((stringp args) args)
   ((listp args)
    (string-join
     (cl-loop for (k . v) in args
              for key = (format "%s" k)
              for val-str = (cond
                             ((stringp v) v)
                             (t (let ((print-length 64) (print-level 4))
                                  (prin1-to-string v))))
              collect
              (if (string-match-p "\n" val-str)
                  (concat key ":\n"
                          (mapconcat (lambda (l) (concat "  " l))
                                     (split-string val-str "\n" nil)
                                     "\n"))
                (format "%s: %s" key val-str)))
     "\n"))
   (t (format "%S" args))))

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
                   (args (and ov (overlay-get ov 'cavemacs-tool-args)))
                   (args-str (cavemacs-render--format-tool-args-full args))
                   (body-prefix (propertize
                                 (concat (cavemacs-pretty-glyph 'box-v) " ")
                                 'face rule-face
                                 'cavemacs-rule t))
                   (body (mapconcat (lambda (l) (concat body-prefix l))
                                    (split-string (string-trim-right text)
                                                  "\n" nil)
                                    "\n"))
                   (body-beg (point)))
              ;; Full input block (visible when expanded), then a
              ;; separator rule, then the result body.
              (when (and args-str (not (string-empty-p args-str)))
                (insert (mapconcat (lambda (l) (concat body-prefix l))
                                   (split-string args-str "\n" nil)
                                   "\n"))
                (insert "\n")
                (let* ((sep-char (string-to-char
                                  (cavemacs-pretty-glyph 'box-h)))
                       (sep (concat (cavemacs-pretty-glyph 'box-v) " "
                                    (make-string 8 sep-char))))
                  (insert (propertize sep 'face rule-face
                                      'cavemacs-rule t))
                  (insert (propertize "\n" 'cavemacs-rule t))))
              (insert (propertize
                       body
                       'face (if is-error 'cavemacs-error-face
                              'cavemacs-pretty-meta-face)))
              (insert "\n")
              (let ((body-end (point)))
                ;; Diff-mode fontify if the result smells like a unified diff.
                (when (cavemacs-render--looks-like-diff-p text)
                  (cavemacs-render--fontify-diff body-beg body-end))
                ;; Detect file paths inside the body and turn them into
                ;; clickable buttons (eldoc/xref glue, M9 stretch).
                (cavemacs-render--linkify-file-paths body-beg body-end)
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
                  (insert (propertize close 'face rule-face
                                      'cavemacs-rule t))
                  (insert (propertize "\n" 'cavemacs-rule t)))
                ;; Register the body region (body-beg .. body-end) as
                ;; the collapsible region.  Header is the line we wrote
                ;; in --on-tool-start.
                  (when (and tool-id
                             (overlay-get ov 'cavemacs-header-beg)
                             (overlay-get ov 'cavemacs-header-end))
                    (cavemacs-render--register-block
                     (format "tool:%s" tool-id)
                     (marker-position (overlay-get ov 'cavemacs-header-beg))
                     (marker-position (overlay-get ov 'cavemacs-header-end))
                     body-beg body-end nil))
                (move-overlay ov (overlay-start ov) (point))
                (overlay-put ov 'cavemacs-tool-status
                             (if is-error 'error 'ok))))))))))

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

;; -----------------------------------------------------------------------------
;; File-path linkification (M9 stretch: eldoc/xref glue)
;; -----------------------------------------------------------------------------

(defcustom cavemacs-render-linkify-file-paths t
  "When non-nil, recognize file paths in tool-call output and make them clickable.

Recognized patterns:
  - Unified-diff hunk headers (`+++ b/path' / `--- a/path')
  - `path:line' and `path:line:col' (compilation-style)
  - Bare relative paths that resolve to an existing file under the
    project root.

Clicking (or RET on) a recognized path opens the file via
`find-file-other-window' at the indicated line, if any."
  :type 'boolean
  :group 'cavemacs)

(defvar cavemacs-render--file-button-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")       #'cavemacs-render-visit-file-at-point)
    (define-key m (kbd "<return>")  #'cavemacs-render-visit-file-at-point)
    (define-key m (kbd "<mouse-2>") #'cavemacs-render-visit-file-at-mouse)
    (define-key m (kbd "<mouse-1>") #'cavemacs-render-visit-file-at-mouse)
    m)
  "Keymap installed on linkified file paths inside tool output.")

(defun cavemacs-render--project-root-for-link ()
  "Return the project root used as the base for resolving relative paths.

Prefers `cavemacs-shell--project-root' (the buffer's session root)
and falls back to `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (and (boundp 'cavemacs-shell--project-root)
             cavemacs-shell--project-root)
        default-directory))))

(defun cavemacs-render--resolve-path (path)
  "Return an absolute existing path for PATH, or nil.

Strips leading `a/' or `b/' (the diff convention) before testing.
Tries PATH as-is (absolute or relative to `default-directory'),
then under the project root."
  (let* ((p (replace-regexp-in-string "\\`[ab]/" "" path))
         (candidates
          (list p
                (expand-file-name p)
                (expand-file-name
                 p (cavemacs-render--project-root-for-link)))))
    (cl-loop for c in candidates
             when (and c (file-exists-p c) (not (file-directory-p c)))
             return (expand-file-name c))))

(defun cavemacs-render--linkify-file-paths (beg end)
  "Find file paths in BEG..END and overlay them as clickable links."
  (when cavemacs-render-linkify-file-paths
    (save-excursion
      (save-restriction
        (narrow-to-region beg end)
        ;; Pattern 1: diff hunk file headers.
        ;;   `--- a/foo.el'   `+++ b/foo.el'   `--- foo.el'
        ;; Tool-card bodies are prefixed with a `│ ' rule, so we
        ;; tolerate any non-LF prefix before the diff sigils.
        (goto-char (point-min))
        (while (re-search-forward
                "^[^\n]*?\\(?:---\\|\\+\\+\\+\\)[ \t]+\\([^ \t\n]+\\)"
                nil t)
          (let* ((path-beg (match-beginning 1))
                 (path-end (match-end 1))
                 (raw (match-string 1)))
            (when-let* ((abs (cavemacs-render--resolve-path raw)))
              (cavemacs-render--make-file-button
               path-beg path-end abs nil))))
        ;; Pattern 2: `path:line[:col]' anywhere in the body.
        (goto-char (point-min))
        (while (re-search-forward
                "\\([./[:alnum:]_+@~-]+\\.[A-Za-z0-9_+]+\\):\\([0-9]+\\)\\(?::[0-9]+\\)?\\>"
                nil t)
          (let* ((path-beg (match-beginning 1))
                 (path-end (match-end 0))
                 (raw (match-string 1))
                 (line (string-to-number (match-string 2))))
            (when-let* ((abs (cavemacs-render--resolve-path raw)))
              (cavemacs-render--make-file-button
               path-beg path-end abs line))))))))

(defun cavemacs-render--make-file-button (beg end abs-path &optional line)
  "Overlay BEG..END as a clickable button visiting ABS-PATH (at LINE)."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'cavemacs-file-path abs-path)
    (overlay-put ov 'cavemacs-file-line line)
    (overlay-put ov 'keymap cavemacs-render--file-button-map)
    (overlay-put ov 'mouse-face 'highlight)
    (overlay-put ov 'help-echo
                 (format "RET / mouse-1: visit %s%s"
                         abs-path
                         (if line (format ":%d" line) "")))
    (overlay-put ov 'face 'link)
    (overlay-put ov 'evaporate t)
    ov))

(defun cavemacs-render--file-button-at (pos)
  "Return (ABS-PATH . LINE) for the file-link overlay at POS, or nil."
  (cl-loop for ov in (overlays-at pos)
           for path = (overlay-get ov 'cavemacs-file-path)
           when path
           return (cons path (overlay-get ov 'cavemacs-file-line))))

(defun cavemacs-render-visit-file-at-point ()
  "Visit the file linked at point in another window."
  (interactive)
  (if-let* ((cell (cavemacs-render--file-button-at (point))))
      (cavemacs-render--visit (car cell) (cdr cell))
    (user-error "No linked file at point")))

(defun cavemacs-render-visit-file-at-mouse (event)
  "Visit the file linked at the mouse EVENT position."
  (interactive "e")
  (let* ((pos (posn-point (event-start event))))
    (if-let* ((cell (and pos (cavemacs-render--file-button-at pos))))
        (cavemacs-render--visit (car cell) (cdr cell))
      (user-error "No linked file at click position"))))

(defun cavemacs-render--visit (abs-path &optional line)
  "Open ABS-PATH in another window; if LINE is non-nil, jump to it."
  (let ((buf (find-file-noselect abs-path)))
    (pop-to-buffer buf)
    (when (integerp line)
      (goto-char (point-min))
      (forward-line (1- line))
      (back-to-indentation))))

(defun cavemacs-render--render-tool-result (result)
  "Coerce RESULT (any JSON shape) into displayable text."
  (cond
   ((null result) "(no result)")
   ((stringp result) result)
   ((vectorp result)
    (cavemacs-render--render-tool-result (append result nil)))
   ;; List of content parts: [((type . "text") (text . "...")) ...]
   ((and (listp result)
         (consp (car result))
         (consp (cdar result))
         (or (assoc 'type (car result)) (assoc 'text (car result))))
    (mapconcat (lambda (part)
                 (or (alist-get 'text part)
                     (alist-get 'output part)
                     (alist-get 'content part)
                     ""))
               result "\n"))
   ((listp result)
    (or (alist-get 'output result)
        (alist-get 'stdout result)
        (alist-get 'text result)
        (let ((c (alist-get 'content result)))
          (and c (cavemacs-render--render-tool-result c)))
        (let ((print-escape-newlines nil)
              (print-length 64) (print-level 4))
          (prin1-to-string result))))
   (t (format "%S" result))))

;; -----------------------------------------------------------------------------
;; Turn / agent end (footer)
;; -----------------------------------------------------------------------------

(defun cavemacs-render--on-turn-end (_event)
  (cavemacs-render--flush-pending-repaint (current-buffer))
  (cavemacs-render--restore-gc)
  (cavemacs-pretty-state-put :status 'idle))

(defun cavemacs-render--on-agent-end (_event)
  "Insert a per-run footer with token / cost stats."
  (cavemacs-render--flush-pending-repaint (current-buffer))
  (cavemacs-render--restore-gc)
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
