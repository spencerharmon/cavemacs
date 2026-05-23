;;; cavemacs-rpc.el --- JSONL RPC transport for caveman --mode rpc  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Production transport for the caveman RPC protocol, derived from the
;; M0 spike at spike/spike.el and validated end-to-end against
;; caveman-code 0.65.2.
;;
;; Protocol summary (NOT JSON-RPC; custom envelope):
;;
;;   Commands (stdin):
;;     {"id": <opt>, "type": <type>, ...}
;;
;;   Responses (stdout, in reply to a command):
;;     {"id": <echoed>, "type": "response", "command": <type>,
;;      "success": true | false, "data"?: <obj>, "error"?: <string>}
;;
;;   Events (stdout, streamed asynchronously):
;;     {"type": "agent_start" | "turn_start" | "message_start" |
;;              "message_update" | "message_end" | "turn_end" |
;;              "agent_end" | "tool_execution_start" |
;;              "tool_execution_update" | "tool_execution_end" |
;;              "queue_update" | "compaction_start" | "compaction_end" |
;;              "auto_retry_start" | "auto_retry_end" |
;;              "checkpoint_taken" | "subagent_progress" |
;;              "extension_error", ...}
;;
;;   Extension UI requests (stdout, require a reply):
;;     {"type": "extension_ui_request", "id": <uuid>, "method":
;;       "select" | "confirm" | "input" | "editor" | "notify" |
;;       "setStatus" | "setWidget" | "setTitle" | "set_editor_text",
;;      ...}
;;
;;   Extension UI replies (stdin):
;;     {"type": "extension_ui_response", "id": <echo>,
;;      "value"?: <string> | "confirmed"?: <bool> | "cancelled"?: true}
;;
;; Framing: strict LF-only JSONL. Payload strings may contain U+2028 /
;; U+2029, so do not use Emacs readline-style splitters that would
;; misinterpret them. We split on "\n" only and tolerate a trailing
;; "\r" before the LF.
;;
;; This module exposes:
;;
;;   `cavemacs-rpc-start'           -- spawn a caveman subprocess
;;   `cavemacs-rpc-stop'            -- graceful shutdown via EOF
;;   `cavemacs-rpc-send'            -- send a raw command alist, get id
;;   `cavemacs-rpc-request'         -- send & invoke callback on response
;;   `cavemacs-rpc-add-event-hook'  -- subscribe to streamed events
;;   `cavemacs-rpc-add-ui-handler'  -- handle extension_ui_request
;;   `cavemacs-rpc-reply-ui'        -- reply to an extension_ui_request

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'map)

;; -----------------------------------------------------------------------------
;; Per-process state
;; -----------------------------------------------------------------------------

(cl-defstruct (cavemacs-rpc-conn
               (:constructor cavemacs-rpc-conn--make)
               (:copier nil))
  "Live connection to a `caveman --mode rpc' subprocess."
  process            ; the process object
  stderr-buffer      ; buffer holding stderr output for debugging
  (read-buffer "")   ; accumulator for partial JSONL reads
  (pending (make-hash-table :test 'equal)) ; id -> callback (lambda (resp))
  (event-hooks nil)  ; list of (lambda (event-alist))
  (ui-handlers nil)  ; list of (lambda (request-alist)) -- first non-nil wins
  (next-id 0)        ; monotonic counter for request ids
  (owner-buffer nil)); buffer this conn belongs to, for advisory back-ref

;; -----------------------------------------------------------------------------
;; ID generation
;; -----------------------------------------------------------------------------

(defun cavemacs-rpc--next-id (conn)
  "Generate a new request id for CONN."
  (let ((n (cl-incf (cavemacs-rpc-conn-next-id conn))))
    (format "cm-%d" n)))

;; -----------------------------------------------------------------------------
;; JSON helpers
;; -----------------------------------------------------------------------------

(defconst cavemacs-rpc--json-config
  '((json-object-type . alist)
    (json-array-type  . list)
    (json-key-type    . symbol)
    (json-false       . :json-false)
    (json-null        . nil))
  "Read/write JSON config used throughout cavemacs-rpc.")

(defun cavemacs-rpc--parse-line (line)
  "Parse a single JSONL LINE into an alist, or signal `cavemacs-rpc-parse-error'."
  (condition-case err
      (let ((json-object-type 'alist)
            (json-array-type  'list)
            (json-key-type    'symbol)
            (json-false       :json-false)
            (json-null        nil))
        (json-read-from-string line))
    (error (signal 'cavemacs-rpc-parse-error
                   (list (error-message-string err) line)))))

(define-error 'cavemacs-rpc-parse-error "Failed to parse JSONL line")

(defun cavemacs-rpc--encode (obj)
  "Encode OBJ to a single JSONL line, including the terminating LF."
  (let ((json-encoding-pretty-print nil)
        (json-false :json-false)
        (json-null  nil))
    (concat (json-encode obj) "\n")))

;; -----------------------------------------------------------------------------
;; Process filter: split stdout into JSONL lines and dispatch
;; -----------------------------------------------------------------------------

(defun cavemacs-rpc--stdout-filter (proc chunk)
  "Process filter: split PROC stdout CHUNK on LF and dispatch each line."
  (let ((conn (process-get proc 'cavemacs-rpc-conn)))
    (unless conn
      (error "No cavemacs-rpc-conn attached to process %s" (process-name proc)))
    (setf (cavemacs-rpc-conn-read-buffer conn)
          (concat (cavemacs-rpc-conn-read-buffer conn) chunk))
    (let ((lines nil)
          (buf (cavemacs-rpc-conn-read-buffer conn))
          (start 0))
      ;; Walk the buffer extracting complete lines, never touching anything
      ;; past the last LF.
      (let ((idx (string-search "\n" buf start)))
        (while idx
          (let ((line (substring buf start idx)))
            ;; Trim a stray CR before LF for tolerance.
            (when (and (> (length line) 0)
                       (eq (aref line (1- (length line))) ?\r))
              (setq line (substring line 0 -1)))
            (push line lines))
          (setq start (1+ idx)
                idx (string-search "\n" buf start))))
      (setf (cavemacs-rpc-conn-read-buffer conn)
            (substring buf start))
      (dolist (line (nreverse lines))
        (when (> (length line) 0)
          (condition-case err
              (cavemacs-rpc--dispatch conn (cavemacs-rpc--parse-line line))
            (cavemacs-rpc-parse-error
             (message "cavemacs-rpc: parse error: %s | line=%S"
                      (cadr err) (substring (or (caddr err) "") 0 80)))
            (error
             (message "cavemacs-rpc: dispatch error: %s"
                      (error-message-string err)))))))))

(defun cavemacs-rpc--dispatch (conn obj)
  "Dispatch a single parsed OBJ on CONN."
  (let ((type (alist-get 'type obj)))
    (cond
     ;; ----- Command response -----
     ((equal type "response")
      (let* ((id (alist-get 'id obj))
             (cb (and id (gethash id (cavemacs-rpc-conn-pending conn)))))
        (when id (remhash id (cavemacs-rpc-conn-pending conn)))
        (when cb
          (condition-case err
              (funcall cb obj)
            (error
             (message "cavemacs-rpc: response callback error for %s: %s"
                      id (error-message-string err)))))))
     ;; ----- Extension UI request (needs reply) -----
     ((equal type "extension_ui_request")
      (cavemacs-rpc--dispatch-ui-request conn obj))
     ;; ----- Streamed event -----
     (t
      (dolist (hook (cavemacs-rpc-conn-event-hooks conn))
        (condition-case err
            (funcall hook obj)
          (error
           (message "cavemacs-rpc: event hook error (%s): %s"
                    type (error-message-string err)))))))))

(defun cavemacs-rpc--dispatch-ui-request (conn obj)
  "Offer extension UI request OBJ to the registered UI handlers on CONN.
Each handler in `cavemacs-rpc-conn-ui-handlers' is called in order; the
first to return non-nil claims the request.  If none claim it, we send a
cancelled reply so caveman does not hang forever."
  (let ((claimed nil))
    (cl-dolist (handler (cavemacs-rpc-conn-ui-handlers conn))
      (condition-case err
          (when (funcall handler obj)
            (setq claimed t)
            (cl-return))
        (error
         (message "cavemacs-rpc: ui handler error: %s"
                  (error-message-string err)))))
    (unless claimed
      (let ((id (alist-get 'id obj))
            (method (alist-get 'method obj)))
        ;; notify/setStatus/setWidget/setTitle/set_editor_text are
        ;; fire-and-forget; do not reply.
        (unless (member method '("notify" "setStatus" "setWidget"
                                 "setTitle" "set_editor_text"))
          (when id
            (cavemacs-rpc--write-raw
             conn `((type . "extension_ui_response")
                    (id . ,id)
                    (cancelled . t)))))))))

;; -----------------------------------------------------------------------------
;; Stderr filter: drain into a buffer for debugging
;; -----------------------------------------------------------------------------

(defun cavemacs-rpc--stderr-filter (proc chunk)
  "Append CHUNK from PROC stderr into its dedicated buffer."
  (let* ((stderr-proc proc)
         (buf (process-buffer stderr-proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (let ((inhibit-read-only t))
          (insert chunk))))))

;; -----------------------------------------------------------------------------
;; Sentinel
;; -----------------------------------------------------------------------------

(defun cavemacs-rpc--sentinel (proc event)
  "Process sentinel for the caveman RPC subprocess."
  (let ((conn (process-get proc 'cavemacs-rpc-conn)))
    (when (and conn (memq (process-status proc) '(exit signal closed failed)))
      ;; Reject any still-pending callbacks so callers don't hang.
      (maphash
       (lambda (id cb)
         (ignore id)
         (condition-case _
             (funcall cb `((type . "response")
                           (command . "<process-died>")
                           (success . :json-false)
                           (error . ,(format "process %s: %s"
                                             (process-status proc)
                                             (string-trim event)))))
           (error nil)))
       (cavemacs-rpc-conn-pending conn))
      (clrhash (cavemacs-rpc-conn-pending conn))
      ;; Notify owner buffer (if any) via a synthetic event.
      (dolist (hook (cavemacs-rpc-conn-event-hooks conn))
        (ignore-errors
          (funcall hook `((type . "cavemacs_process_exited")
                          (status . ,(symbol-name (process-status proc)))
                          (event . ,(string-trim event)))))))))

;; -----------------------------------------------------------------------------
;; Public API
;; -----------------------------------------------------------------------------

(cl-defun cavemacs-rpc-start
    (binary &key args environment owner-buffer)
  "Spawn a caveman --mode rpc subprocess and return a `cavemacs-rpc-conn'.

BINARY is the absolute path to the caveman executable.
ARGS is a list of additional command-line arguments (must include
\"--mode\" \"rpc\" or this function will refuse).
ENVIRONMENT is a list of \"NAME=VALUE\" strings prepended to
`process-environment'.
OWNER-BUFFER is the cavemacs shell buffer that owns the connection."
  (unless (and (member "--mode" args)
               (member "rpc" args))
    (error "cavemacs-rpc-start: args must include \"--mode\" \"rpc\""))
  (let* ((process-environment (append environment process-environment))
         (stderr-buf (generate-new-buffer
                      (format " *cavemacs-rpc-stderr<%s>*"
                              (if (buffer-live-p owner-buffer)
                                  (buffer-name owner-buffer)
                                "anon"))))
         (stderr-proc (make-pipe-process
                       :name "cavemacs-rpc-stderr"
                       :buffer stderr-buf
                       :noquery t
                       :filter #'cavemacs-rpc--stderr-filter))
         (proc (make-process
                :name "cavemacs-rpc"
                :command (cons binary args)
                :coding 'utf-8
                :connection-type 'pipe
                :noquery t
                :filter #'cavemacs-rpc--stdout-filter
                :sentinel #'cavemacs-rpc--sentinel
                :stderr stderr-proc))
         (conn (cavemacs-rpc-conn--make
                :process proc
                :stderr-buffer stderr-buf
                :owner-buffer owner-buffer)))
    (process-put proc 'cavemacs-rpc-conn conn)
    (process-put stderr-proc 'cavemacs-rpc-conn conn)
    conn))

(defun cavemacs-rpc-live-p (conn)
  "Return non-nil if CONN's subprocess is still running."
  (and conn (process-live-p (cavemacs-rpc-conn-process conn))))

(defun cavemacs-rpc-stop (conn)
  "Request graceful shutdown of CONN by closing its stdin.
Caveman's RPC loop calls `process.exit(0)' when stdin ends.  If the
process is still alive after a short grace period, it is killed."
  (when (cavemacs-rpc-live-p conn)
    (ignore-errors
      (process-send-eof (cavemacs-rpc-conn-process conn)))
    ;; Give it up to 2s, polling.
    (let ((deadline (+ (float-time) 2.0)))
      (while (and (cavemacs-rpc-live-p conn)
                  (< (float-time) deadline))
        (accept-process-output (cavemacs-rpc-conn-process conn) 0.1))
      (when (cavemacs-rpc-live-p conn)
        (kill-process (cavemacs-rpc-conn-process conn))))
    (when (buffer-live-p (cavemacs-rpc-conn-stderr-buffer conn))
      (kill-buffer (cavemacs-rpc-conn-stderr-buffer conn)))))

(defun cavemacs-rpc--write-raw (conn obj)
  "Send OBJ (already a complete envelope) to CONN's stdin."
  (unless (cavemacs-rpc-live-p conn)
    (error "cavemacs-rpc: connection not live"))
  (process-send-string (cavemacs-rpc-conn-process conn)
                       (cavemacs-rpc--encode obj)))

(cl-defun cavemacs-rpc-send (conn type &rest fields)
  "Send a command of TYPE with FIELDS (a plist) and return its id.

Returned id is suitable for matching against a later response object."
  (let* ((id (cavemacs-rpc--next-id conn))
         (envelope (append `((id . ,id) (type . ,type))
                           (cavemacs-rpc--plist-to-alist fields))))
    (cavemacs-rpc--write-raw conn envelope)
    id))

(defun cavemacs-rpc--plist-to-alist (plist)
  "Convert PLIST to alist, using bare keyword names as symbol keys.
\(:foo \"x\" :bar 1\) -> ((foo . \"x\") (bar . 1))."
  (let (out)
    (while plist
      (let ((k (car plist))
            (v (cadr plist)))
        (push (cons (intern (substring (symbol-name k) 1)) v) out))
      (setq plist (cddr plist)))
    (nreverse out)))

(cl-defun cavemacs-rpc-request (conn type callback &rest fields)
  "Send TYPE with FIELDS; invoke CALLBACK with the response alist.

CALLBACK is called exactly once, either on the response or on
process death (with a synthesized failure envelope).  Returns the
request id."
  (let* ((id (cavemacs-rpc--next-id conn))
         (envelope (append `((id . ,id) (type . ,type))
                           (cavemacs-rpc--plist-to-alist fields))))
    (puthash id callback (cavemacs-rpc-conn-pending conn))
    (cavemacs-rpc--write-raw conn envelope)
    id))

(defun cavemacs-rpc-request-sync (conn type fields &optional timeout)
  "Synchronously send TYPE with FIELDS plist and return response alist.
TIMEOUT defaults to 30 seconds.  Errors if the process dies or times out."
  (let ((done nil)
        (response nil)
        (deadline (+ (float-time) (or timeout 30))))
    (apply #'cavemacs-rpc-request conn type
           (lambda (resp) (setq response resp done t))
           fields)
    (while (and (not done) (< (float-time) deadline)
                (cavemacs-rpc-live-p conn))
      (accept-process-output (cavemacs-rpc-conn-process conn) 0.05))
    (unless done
      (error "cavemacs-rpc: timed out waiting for %s" type))
    response))

(defun cavemacs-rpc-add-event-hook (conn hook)
  "Add HOOK (a function of one argument, the event alist) to CONN.
Hooks are called in addition order; an error in one does not block others."
  (cl-pushnew hook (cavemacs-rpc-conn-event-hooks conn))
  hook)

(defun cavemacs-rpc-remove-event-hook (conn hook)
  "Remove HOOK from CONN."
  (setf (cavemacs-rpc-conn-event-hooks conn)
        (delq hook (cavemacs-rpc-conn-event-hooks conn))))

(defun cavemacs-rpc-add-ui-handler (conn handler)
  "Add HANDLER (function of the request alist) to CONN.
HANDLER must return non-nil to claim the request, and is responsible
for eventually calling `cavemacs-rpc-reply-ui'.  Handlers are tried
in addition order; the first to return non-nil wins."
  (cl-pushnew handler (cavemacs-rpc-conn-ui-handlers conn))
  handler)

(defun cavemacs-rpc-remove-ui-handler (conn handler)
  "Remove HANDLER from CONN."
  (setf (cavemacs-rpc-conn-ui-handlers conn)
        (delq handler (cavemacs-rpc-conn-ui-handlers conn))))

(defun cavemacs-rpc-reply-ui (conn request &rest fields)
  "Reply to extension UI REQUEST on CONN.  FIELDS is a plist.

Common reply shapes:
  (cavemacs-rpc-reply-ui conn req :value \"my input\")
  (cavemacs-rpc-reply-ui conn req :confirmed t)
  (cavemacs-rpc-reply-ui conn req :cancelled t)"
  (let ((id (alist-get 'id request)))
    (unless id
      (error "cavemacs-rpc-reply-ui: request has no id"))
    (cavemacs-rpc--write-raw
     conn (append `((type . "extension_ui_response") (id . ,id))
                  (cavemacs-rpc--plist-to-alist fields)))))

(provide 'cavemacs-rpc)
;;; cavemacs-rpc.el ends here
