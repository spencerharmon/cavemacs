;;; spike-prompt.el --- M0 streaming-prompt spike -*- lexical-binding: t; -*-
;;
;; Builds on spike.el: sends an actual `prompt` and captures the streamed
;; AgentSessionEvent sequence until turn_end + agent_end. Uses GitHub Copilot
;; (already authed in ~/.cave/agent/auth.json).
;;
;; Run:
;;   emacs --batch -l spike/spike.el -l spike/spike-prompt.el \
;;         -f cavemacs-spike-prompt-run

(require 'cl-lib)

(defvar cavemacs-spike-prompt--done nil)
(defvar cavemacs-spike-prompt--assistant-text "")
(defvar cavemacs-spike-prompt--update-count 0)
(defvar cavemacs-spike-prompt--event-types nil) ; alist type -> count

;; Override the event handler to tally types and watch for agent_end.
;; We keep the response/extension-ui paths from spike.el untouched by wrapping.
(defun cavemacs-spike-prompt--on-event (obj)
  (let ((type (cdr (assq 'type obj))))
    (cl-incf (alist-get type cavemacs-spike-prompt--event-types 0 nil #'equal))
    (cond
     ((equal type "message_update")
      (cl-incf cavemacs-spike-prompt--update-count)
      ;; Extract latest assistant text length, if shape matches expectation.
      (let* ((msg (cdr (assq 'message obj)))
             (content (cdr (assq 'content msg)))
             ;; content is a list of parts; concat any text parts
             (txt (mapconcat
                   (lambda (part)
                     (or (cdr (assq 'text part)) ""))
                   (and (listp content) content)
                   "")))
        (when (stringp txt)
          (setq cavemacs-spike-prompt--assistant-text txt))))
     ((equal type "tool_execution_start")
      (message "[spike] tool_execution_start: %s"
               (cdr (assq 'toolName obj))))
     ((equal type "agent_end")
      (setq cavemacs-spike-prompt--done t)))))

(defun cavemacs-spike-prompt-run ()
  "Run a real prompt against caveman and tally streamed events."
  (let ((caveman (or (executable-find "caveman")
                     (expand-file-name "~/.nvm/versions/node/v22.22.3/bin/caveman"))))
    (setq cavemacs-spike--buffer ""
          cavemacs-spike--pending (make-hash-table :test 'equal)
          cavemacs-spike--event-count 0
          cavemacs-spike--log nil
          cavemacs-spike-prompt--done nil
          cavemacs-spike-prompt--assistant-text ""
          cavemacs-spike-prompt--update-count 0
          cavemacs-spike-prompt--event-types nil)

    ;; Monkey-patch the dispatch to also route events to our tally.
    (advice-add 'cavemacs-spike--dispatch :after
                (lambda (obj)
                  (let ((type (cdr (assq 'type obj))))
                    (unless (or (equal type "response")
                                (equal type "extension_ui_request"))
                      (cavemacs-spike-prompt--on-event obj)))))

    (setq cavemacs-spike--proc
          (make-process
           :name "cavemacs-spike-prompt"
           :command (list caveman "--mode" "rpc" "--no-session"
                          "--provider" "github-copilot")
           :coding 'utf-8
           :connection-type 'pipe
           :noquery t
           :filter #'cavemacs-spike--on-output
           :stderr (make-pipe-process
                    :name "cavemacs-spike-prompt-stderr"
                    :buffer " *cavemacs-spike-prompt-stderr*"
                    :noquery t
                    :filter #'cavemacs-spike--on-stderr)))

    ;; Brief settle.
    (cavemacs-spike--await
     (lambda () (not (process-live-p cavemacs-spike--proc))) 1.0)

    (when (process-live-p cavemacs-spike--proc)
      (message "--- get_state to confirm model resolved ---")
      (let ((id (cavemacs-spike--request "get_state")))
        (cavemacs-spike--await
         (lambda () (not (gethash id cavemacs-spike--pending))) 10))

      (message "--- sending prompt: 'Reply with the single word: pong' ---")
      (cavemacs-spike--request
       "prompt"
       (cons 'message "Reply with the single word: pong"))

      ;; Wait up to 60s for agent_end.
      (cavemacs-spike--await (lambda () cavemacs-spike-prompt--done) 60)

      (message "--- shutting down ---")
      (process-send-eof cavemacs-spike--proc)
      (cavemacs-spike--await
       (lambda () (not (process-live-p cavemacs-spike--proc))) 5))

    (message "===== PROMPT SPIKE SUMMARY =====")
    (message "Process exit: %s (%s)"
             (process-status cavemacs-spike--proc)
             (process-exit-status cavemacs-spike--proc))
    (message "agent_end seen:       %s" cavemacs-spike-prompt--done)
    (message "message_update count: %d" cavemacs-spike-prompt--update-count)
    (message "Final assistant text: %S"
             (string-trim cavemacs-spike-prompt--assistant-text))
    (message "Event-type tally:")
    (dolist (entry (sort cavemacs-spike-prompt--event-types
                         (lambda (a b) (string< (car a) (car b)))))
      (message "  %-28s %d" (car entry) (cdr entry)))))

;;; spike-prompt.el ends here
