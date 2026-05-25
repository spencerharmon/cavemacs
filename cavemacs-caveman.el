;;; cavemacs-caveman.el --- caveman skill integration  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Integration layer for the caveman skill
;; (https://github.com/JuliusBrussee/caveman).  caveman is a
;; caveman-code skill that compresses agent output by ~65% by
;; instructing it to speak in clipped, telegraphic prose ("brain
;; still big, mouth small").
;;
;; The skill itself lives on disk under one of caveman-code's
;; skill-discovery paths (project-local `.cave/skills/caveman/' or
;; the global `~/.cave/skills/caveman/').  caveman-code already
;; knows how to load and enforce it; cavemacs's job is therefore
;; thin plumbing:
;;
;;   - Detect whether the skill is installed (project / global / no).
;;   - Track per-buffer "is caveman on, and at what level?" state,
;;     and reflect it in the pretty header-line.
;;   - Provide commands to toggle activation and cycle level,
;;     dispatched via caveman-code's existing /caveman trigger.
;;   - Wire the companion slash commands (/caveman-commit,
;;     /caveman-review, /caveman-stats, /caveman-compress) into the
;;     local command registry so they appear in completion.
;;   - Offer a one-shot installer wrapper.
;;
;; Loaded last among the companion modules so it can see the
;; pretty header-line state and the cavemacs-commands registry.
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cavemacs-config)
(require 'cavemacs-rpc)
(require 'cavemacs-shell)
(require 'cavemacs-render)
(require 'cavemacs-pretty)
(require 'cavemacs-commands)

(declare-function cavemacs-project-root "cavemacs-project")

(defgroup cavemacs-caveman nil
  "caveman skill integration."
  :group 'cavemacs
  :prefix "cavemacs-caveman-")

;; -----------------------------------------------------------------------------
;; Customs
;; -----------------------------------------------------------------------------

(defconst cavemacs-caveman-levels '("lite" "full" "ultra" "wenyan")
  "Documented caveman levels in order of increasing terseness.")

(defcustom cavemacs-caveman-default-level "full"
  "Initial caveman level used by `cavemacs-caveman-enable'."
  :type `(choice ,@(mapcar (lambda (l) `(const ,l))
                           cavemacs-caveman-levels))
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-auto-enable t
  "When to auto-enable caveman at session start.

- nil: never auto-enable; user opts in.
- t (default): auto-enable whenever the skill is detected (project or
  global).  Failing silently when the skill isn't installed is fine --
  the user just sees uncompressed agent output and can install with
  M-x cavemacs-caveman-install when they want it.
- function: called with the project root, returns non-nil to enable.

When auto-enable triggers, `cavemacs-caveman-default-level' is used."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Always when installed" t)
                 (function :tag "Predicate"))
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-trigger-format "/caveman %s"
  "Prompt format used to activate caveman at a given level.

A format string with one %s slot for the level token (\"full\",
\"ultra\", ...).  Pinned as a custom so users can adapt if
upstream renames the trigger phrase without waiting for a
cavemacs release."
  :type 'string
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-disable-trigger "normal mode"
  "Phrase sent to caveman-code to disable caveman for the session."
  :type 'string
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-skill-paths
  '(("project" . ".cave/skills/caveman/SKILL.md")
    ("global"  . "~/.cave/agent/skills/caveman/SKILL.md"))
  "Where to look for caveman's SKILL.md, in priority order.

Project-relative entries are resolved against the current
cavemacs project root.  Defaults match caveman-code's skill
discovery paths:

  - project: <cwd>/.cave/skills/caveman/SKILL.md
  - global:  ~/.cave/agent/skills/caveman/SKILL.md

(See caveman-code's packages/coding-agent/src/core/skills.ts ->
`loadSkills' for the canonical lookup order.)"
  :type '(alist :key-type string :value-type string)
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-install-source
  "https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh"
  "URL or absolute path to caveman's install.sh.

Used by `cavemacs-caveman-install-via-installer'.  Set to nil to
disable the installer entirely.

Note: as of upstream caveman 1.8.2 the installer's --only flag
does *not* accept \"caveman-code\" as an agent target -- the
installer only knows about Claude Code, Codex, Gemini, Cursor,
etc.  Prefer `cavemacs-caveman-install' (the default
M-x entry point), which fetches just SKILL.md and drops it into
caveman-code's global skill discovery path."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-skill-source
  "https://raw.githubusercontent.com/JuliusBrussee/caveman/main/skills/caveman/SKILL.md"
  "URL or absolute path to caveman's SKILL.md.

Fetched by `cavemacs-caveman-install' and written into
`cavemacs-caveman-global-skill-dir'.  Set to nil to disable the
fetch-and-drop installer."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-global-skill-dir
  "~/.cave/agent/skills/caveman"
  "Directory where `cavemacs-caveman-install' drops SKILL.md.

Default matches caveman-code's user-skills discovery path
(~/.cave/agent/skills/<name>/SKILL.md per the caveConfig
configDir of \".cave\")."
  :type 'directory
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-install-scope "claude"
  "Value passed to caveman's installer --only flag.

Only used by `cavemacs-caveman-install-via-installer'.  Default
is \"claude\" because the upstream installer does not (yet)
support caveman-code as an --only target.  See
`cavemacs-caveman-install' for the caveman-code path."
  :type 'string
  :group 'cavemacs-caveman)

(defcustom cavemacs-caveman-bash-program "bash"
  "Shell used to run caveman's install.sh."
  :type 'string
  :group 'cavemacs-caveman)

;; -----------------------------------------------------------------------------
;; Buffer-local state
;; -----------------------------------------------------------------------------

(defvar-local cavemacs-caveman--level nil
  "Active caveman level in this buffer (one of the strings in
`cavemacs-caveman-levels', or nil when caveman is off).")

;; -----------------------------------------------------------------------------
;; Detection
;; -----------------------------------------------------------------------------

(defun cavemacs-caveman--resolve-skill-path (root rel-or-abs)
  "Resolve REL-OR-ABS against project ROOT, expanding ~.
Returns an absolute path."
  (let ((expanded (expand-file-name rel-or-abs)))
    (if (file-name-absolute-p rel-or-abs)
        expanded
      (expand-file-name rel-or-abs root))))

(defun cavemacs-caveman-installed-p (&optional root)
  "Return the scope keyword where caveman is installed, or nil.

Scope is the car of the first matching entry in
`cavemacs-caveman-skill-paths' (typically \"project\" or
\"global\").  ROOT defaults to the current project root."
  (let ((root (file-name-as-directory
               (expand-file-name (or root
                                     (ignore-errors (cavemacs-project-root))
                                     default-directory)))))
    (cl-loop for (scope . rel) in cavemacs-caveman-skill-paths
             for abs = (cavemacs-caveman--resolve-skill-path root rel)
             when (file-exists-p abs)
             return scope)))

(defun cavemacs-caveman-skill-path (&optional root)
  "Return the absolute path to the discovered SKILL.md, or nil."
  (let ((root (file-name-as-directory
               (expand-file-name (or root
                                     (ignore-errors (cavemacs-project-root))
                                     default-directory)))))
    (cl-loop for (_ . rel) in cavemacs-caveman-skill-paths
             for abs = (cavemacs-caveman--resolve-skill-path root rel)
             when (file-exists-p abs)
             return abs)))

;; -----------------------------------------------------------------------------
;; Activation
;; -----------------------------------------------------------------------------

(defun cavemacs-caveman--require-conn ()
  (unless (and (boundp 'cavemacs-shell--conn)
               (cavemacs-rpc-live-p cavemacs-shell--conn))
    (user-error "Not in a live cavemacs buffer")))

(defun cavemacs-caveman--validate-level (level)
  (unless (member level cavemacs-caveman-levels)
    (user-error "cavemacs-caveman: bad level %S (want one of %s)"
                level (string-join cavemacs-caveman-levels ", ")))
  level)

(defun cavemacs-caveman--update-header ()
  "Mirror the buffer's caveman level into the pretty header-line."
  (when (fboundp 'cavemacs-pretty-state-put)
    (cavemacs-pretty-state-put :caveman-level cavemacs-caveman--level)))

(defun cavemacs-caveman--send-trigger (level)
  "Send the activation trigger for LEVEL (or disable string)."
  (let ((conn cavemacs-shell--conn))
    (cond
     (level
      (cavemacs-caveman--validate-level level)
      (cavemacs-rpc-send conn "prompt"
                         :message (format cavemacs-caveman-trigger-format
                                          level)))
     (t
      (cavemacs-rpc-send conn "prompt"
                         :message cavemacs-caveman-disable-trigger)))))

;;;###autoload
(defun cavemacs-caveman-enable (&optional level)
  "Turn caveman on for this session at LEVEL.

LEVEL defaults to `cavemacs-caveman-default-level'.  Sends
`cavemacs-caveman-trigger-format' (default \"/caveman <level>\")
through caveman-code's RPC `prompt' handler, which dispatches the
user-installed slash command."
  (interactive
   (list (completing-read
          (format "caveman level (default %s): "
                  cavemacs-caveman-default-level)
          cavemacs-caveman-levels nil t nil nil
          cavemacs-caveman-default-level)))
  (cavemacs-caveman--require-conn)
  (let ((level (cavemacs-caveman--validate-level
                (or level cavemacs-caveman-default-level))))
    (cavemacs-caveman--send-trigger level)
    (setq cavemacs-caveman--level level)
    (cavemacs-caveman--update-header)
    (cavemacs-render--notice
     (format "caveman: %s" level) 'cavemacs-meta-face)))

;;;###autoload
(defun cavemacs-caveman-disable ()
  "Turn caveman off for this session."
  (interactive)
  (cavemacs-caveman--require-conn)
  (cavemacs-caveman--send-trigger nil)
  (setq cavemacs-caveman--level nil)
  (cavemacs-caveman--update-header)
  (cavemacs-render--notice "caveman: off" 'cavemacs-meta-face))

;;;###autoload
(defun cavemacs-caveman-toggle ()
  "Toggle caveman on (at `cavemacs-caveman-default-level') or off."
  (interactive)
  (if cavemacs-caveman--level
      (cavemacs-caveman-disable)
    (cavemacs-caveman-enable cavemacs-caveman-default-level)))

;;;###autoload
(defun cavemacs-caveman-cycle-level (&optional reverse)
  "Cycle through `cavemacs-caveman-levels' (off -> lite -> ... -> off).
With prefix arg REVERSE, cycle the other direction."
  (interactive "P")
  (cavemacs-caveman--require-conn)
  (let* ((order (if reverse
                    (reverse (cons nil cavemacs-caveman-levels))
                  (append cavemacs-caveman-levels '(nil))))
         ;; Build a cycle by appending the head of the order back at
         ;; the end, so after the last element we wrap to the first.
         (ring (append order (list (car order))))
         (cur cavemacs-caveman--level)
         ;; `member' uses `equal'; nil-as-member is fine because it's
         ;; the "off" sentinel and appears at most once per ring.
         (tail (cdr (member cur ring)))
         ;; If `cur' isn't on the ring at all (defensive: someone
         ;; setq'd it to a custom string), fall through to the head.
         (next (if tail (car tail) (car order))))
    (if next
        (cavemacs-caveman-enable next)
      (cavemacs-caveman-disable))))

(defun cavemacs-caveman-maybe-auto-enable ()
  "Honour `cavemacs-caveman-auto-enable' for a freshly-spawned buffer."
  (when (and cavemacs-shell--conn
             (cavemacs-rpc-live-p cavemacs-shell--conn)
             (cavemacs-caveman-installed-p))
    (let ((decision
           (pcase cavemacs-caveman-auto-enable
             ('nil nil)
             ('t   t)
             ((pred functionp)
              (funcall cavemacs-caveman-auto-enable
                       (or cavemacs-shell--project-root default-directory))))))
      (when decision
        (cavemacs-caveman-enable cavemacs-caveman-default-level)))))

;; -----------------------------------------------------------------------------
;; Companion commands (registered in cavemacs-commands--builtins so they
;; appear in CAPF completion and dispatch correctly).
;; -----------------------------------------------------------------------------

(defun cavemacs-caveman--builtin-toggle (args _conn)
  "Handler for /caveman in the local registry.

If ARGS names a known level, activate that level.  If ARGS is
\"off\" / \"normal\", disable.  If ARGS is empty, toggle."
  (let ((a (and args (string-trim args))))
    (cond
     ((or (null a) (string-empty-p a))
      (cavemacs-caveman-toggle))
     ((member a '("off" "normal" "stop"))
      (cavemacs-caveman-disable))
     ((member a cavemacs-caveman-levels)
      (cavemacs-caveman-enable a))
     (t
      ;; Unknown arg: fall through to the upstream skill, which may
      ;; understand it.  Returning nil here would cause the dispatcher
      ;; to send the literal text as a prompt -- but we have to return
      ;; non-nil from a builtin handler.  So send the raw text
      ;; ourselves and report.
      (cavemacs-rpc-send cavemacs-shell--conn "prompt"
                         :message (format cavemacs-caveman-trigger-format a))
      (cavemacs-render--notice
       (format "caveman: %s (unrecognized level; passed to skill)" a)
       'cavemacs-meta-face))))
  t)

(defun cavemacs-caveman--builtin-stats (_args conn)
  "Send /caveman-stats and let the assistant reply render in place."
  (cavemacs-rpc-send conn "prompt" :message "/caveman-stats")
  t)

(defun cavemacs-caveman--builtin-commit (args conn)
  "Send /caveman-commit [args] to produce a Conventional Commit message."
  (cavemacs-rpc-send conn "prompt"
                     :message (if (and args (not (string-empty-p args)))
                                  (format "/caveman-commit %s" args)
                                "/caveman-commit"))
  t)

(defun cavemacs-caveman--builtin-review (args conn)
  "Send /caveman-review [args] for a terse PR review."
  (cavemacs-rpc-send conn "prompt"
                     :message (if (and args (not (string-empty-p args)))
                                  (format "/caveman-review %s" args)
                                "/caveman-review"))
  t)

(defun cavemacs-caveman--builtin-compress (args conn)
  "Send /caveman-compress <file>.

If ARGS is empty, prompt for a file path with `read-file-name'
rooted at the project root."
  (let ((path (if (and args (not (string-empty-p args)))
                  args
                (let ((default-directory
                       (or (ignore-errors (cavemacs-project-root))
                           default-directory)))
                  (read-file-name "Compress file: " nil nil t)))))
    (cavemacs-rpc-send conn "prompt"
                       :message (format "/caveman-compress %s" path)))
  t)

(defconst cavemacs-caveman--builtins
  '(("caveman"          "Toggle caveman / set level (lite|full|ultra|wenyan)"
     cavemacs-caveman--builtin-toggle)
    ("caveman-stats"    "Show caveman token-savings stats"
     cavemacs-caveman--builtin-stats)
    ("caveman-commit"   "Generate a Conventional Commit message"
     cavemacs-caveman--builtin-commit)
    ("caveman-review"   "One-line PR review comments"
     cavemacs-caveman--builtin-review)
    ("caveman-compress" "Rewrite a memory file in caveman-speak"
     cavemacs-caveman--builtin-compress))
  "caveman companion slash commands wired into the local registry.")

(defun cavemacs-caveman--register-builtins ()
  "Merge `cavemacs-caveman--builtins' into `cavemacs-commands--builtins'.

Idempotent: re-running does not duplicate entries.  Called at
file load time so the commands are available as soon as
cavemacs-caveman is required, without any user action."
  (dolist (entry cavemacs-caveman--builtins)
    (let ((name (car entry)))
      (unless (assoc name cavemacs-commands--builtins)
        ;; cavemacs-commands--builtins is defconst, so push via setq
        ;; on the symbol value.  Safe because the defconst is just
        ;; "the initial set"; we extend it intentionally here.
        (setq cavemacs-commands--builtins
              (append cavemacs-commands--builtins (list entry)))))))

(cavemacs-caveman--register-builtins)

;; -----------------------------------------------------------------------------
;; Installer
;; -----------------------------------------------------------------------------

;;;###autoload
(defun cavemacs-caveman-install ()
  "Install the caveman skill into caveman-code's global skills directory.

Fetches `cavemacs-caveman-skill-source' (default: SKILL.md from
upstream main) and writes it to
`cavemacs-caveman-global-skill-dir'/SKILL.md so caveman-code's
skill loader picks it up on next startup.

This is the right path for caveman-code today; the upstream
caveman installer's --only flag does not yet recognize
caveman-code as an agent target, so the curl|bash route does
not help.  Use `cavemacs-caveman-install-via-installer' if you
want to install for *other* agents (Claude Code, Codex, ...) on
the same machine.

Asks for confirmation before writing.  Restart caveman with
\\[cavemacs-shell-restart] afterwards."
  (interactive)
  (unless cavemacs-caveman-skill-source
    (user-error "cavemacs-caveman-skill-source is nil; installer disabled"))
  (let* ((dir (expand-file-name cavemacs-caveman-global-skill-dir))
         (dest (expand-file-name "SKILL.md" dir)))
    (when (or (not (file-exists-p dest))
              (yes-or-no-p (format "%s exists.  Overwrite? " dest)))
      (unless (yes-or-no-p
               (format "Fetch %s -> %s? "
                       cavemacs-caveman-skill-source dest))
        (user-error "Aborted"))
      (make-directory dir t)
      (cavemacs-caveman--fetch-skill cavemacs-caveman-skill-source dest)
      (message
       "cavemacs-caveman: wrote %s.  Restart caveman (C-c C-r) to load it."
       dest))))

(defun cavemacs-caveman--fetch-skill (src dest)
  "Fetch SRC into DEST.  SRC is a URL or a local file path."
  (cond
   ;; Local file: just copy.
   ((and (not (string-match-p "\\`[a-z]+://" src))
         (file-exists-p src))
    (copy-file src dest t))
   ;; Remote URL: url-retrieve-synchronously, strip HTTP headers.
   (t
    (require 'url)
    (let ((buf (url-retrieve-synchronously src t t 30)))
      (unless buf
        (user-error "cavemacs-caveman: failed to fetch %s" src))
      (with-current-buffer buf
        (goto-char (point-min))
        (unless (re-search-forward "\n\n" nil t)
          (user-error
           "cavemacs-caveman: malformed HTTP response from %s" src))
        (let ((coding-system-for-write 'utf-8))
          (write-region (point) (point-max) dest))
        (kill-buffer buf))))))

;;;###autoload
(defun cavemacs-caveman-install-via-installer (&optional non-interactive)
  "Run caveman's upstream install.sh as a subprocess.

Source is `cavemacs-caveman-install-source'; scope flag value is
`cavemacs-caveman-install-scope' (default \"claude\").

Note: as of caveman 1.8.2 the installer's --only flag does NOT
support \"caveman-code\".  For installing into caveman-code use
`cavemacs-caveman-install' instead, which writes SKILL.md
directly to caveman-code's global skills directory.

Output is shown in a `*cavemacs-caveman-install*' compilation
buffer so the user can audit the script's progress.

When called interactively, asks for confirmation first.  Pass
NON-INTERACTIVE non-nil to skip the prompt."
  (interactive)
  (unless cavemacs-caveman-install-source
    (user-error "cavemacs-caveman-install-source is nil; installer disabled"))
  (when (or non-interactive
            (yes-or-no-p
             (format "Run caveman installer (%s --only %s)? "
                     cavemacs-caveman-install-source
                     cavemacs-caveman-install-scope)))
    (let* ((src cavemacs-caveman-install-source)
           (local-path
            (cond
             ((and (not (string-match-p "\\`[a-z]+://" src))
                   (file-exists-p src))
              src)
             (t (cavemacs-caveman--fetch-installer-script src))))
           (default-directory (or (ignore-errors (cavemacs-project-root))
                                  default-directory))
           (buf (get-buffer-create "*cavemacs-caveman-install*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t)) (erase-buffer))
        (compilation-mode))
      (make-process
       :name "cavemacs-caveman-install"
       :buffer buf
       :command (list cavemacs-caveman-bash-program
                      local-path
                      "--only" cavemacs-caveman-install-scope)
       :sentinel (lambda (_p event)
                   (with-current-buffer buf
                     (goto-char (point-max))
                     (insert (format "\n-- installer %s --\n"
                                     (string-trim event))))))
      (pop-to-buffer buf)
      (message "cavemacs-caveman: installer running"))))

(defun cavemacs-caveman--fetch-installer-script (url)
  "Download URL into a temp .sh file and return the path."
  (require 'url)
  (let* ((tmp (make-temp-file "cavemacs-caveman-install-" nil ".sh"))
         (buf (url-retrieve-synchronously url t t 30)))
    (unless buf
      (user-error "cavemacs-caveman: failed to fetch %s" url))
    (with-current-buffer buf
      (goto-char (point-min))
      (unless (re-search-forward "\n\n" nil t)
        (user-error "cavemacs-caveman: malformed HTTP response from %s" url))
      (let ((coding-system-for-write 'utf-8))
        (write-region (point) (point-max) tmp))
      (kill-buffer buf))
    (set-file-modes tmp #o755)
    tmp))

;; -----------------------------------------------------------------------------
;; Pretty header-line: caveman pill
;; -----------------------------------------------------------------------------

(defface cavemacs-caveman-header-face
  '((t :inherit cavemacs-pretty-meta-face :weight bold))
  "Face for the caveman level pill in the pretty header-line."
  :group 'cavemacs-caveman)

(defun cavemacs-caveman--header-segment ()
  "Return the propertized caveman segment for the pretty header.
Always shows the current level (or \"off\") so users can see at a
glance whether caveman is active."
  (let* ((l (cavemacs-pretty-state-get :caveman-level))
         (label (or l "off")))
    (concat "  "
            (propertize (format "⛏ caveman:%s" label)
                        'face 'cavemacs-caveman-header-face
                        'mouse-face 'highlight
                        'help-echo "mouse-1: cycle caveman level"))))

;; Splice the caveman segment into the pretty header by advising the
;; formatter.  We add the segment between the model and the cost,
;; matching the placement the plan specifies.
(defun cavemacs-caveman--advise-header (orig &rest args)
  (let ((base (apply orig args))
        (seg (cavemacs-caveman--header-segment)))
    (if (and seg (not (string-empty-p seg)))
        (let ((idx (string-match "  \\$[0-9]" base)))
          (if idx
              (concat (substring base 0 idx) seg (substring base idx))
            (concat base seg)))
      base)))

(advice-add 'cavemacs-pretty--header-format :around
            #'cavemacs-caveman--advise-header)

;; -----------------------------------------------------------------------------
;; Interactive entry point
;; -----------------------------------------------------------------------------

;;;###autoload
(defun cavemacs-caveman ()
  "Top-level caveman menu: toggle / level / install."
  (interactive)
  (let* ((cur (or cavemacs-caveman--level "off"))
         (installed (cavemacs-caveman-installed-p))
         (actions
          (append
           (list (cons (format "Toggle (currently %s)" cur)
                       #'cavemacs-caveman-toggle)
                 (cons "Set level..." #'cavemacs-caveman-enable)
                 (cons "Cycle level" #'cavemacs-caveman-cycle-level)
                 (cons "Disable" #'cavemacs-caveman-disable)
                 (cons "Stats" (lambda () (interactive)
                                 (cavemacs-caveman--builtin-stats
                                  nil cavemacs-shell--conn))))
           (unless installed
             (list (cons "Install caveman skill..."
                         #'cavemacs-caveman-install)))))
         (choice (completing-read
                  (format "caveman [%s]: " (or installed "not installed"))
                  (mapcar #'car actions) nil t))
         (fn (cdr (assoc choice actions))))
    (when fn (call-interactively fn))))

;; Hook into the shell's startup so auto-enable fires.  The shell
;; sends `get_state' after `cavemacs-shell--start-process'; we piggy-back
;; on the same event router and fire once when the agent is idle.
(defun cavemacs-caveman--maybe-auto-enable-from-state (_resp)
  (cavemacs-caveman-maybe-auto-enable))

(add-hook 'cavemacs-shell-mode-hook
          (lambda ()
            ;; Defer until the connection is alive (the hook runs
            ;; before `cavemacs-shell--start-process' returns in some
            ;; init orders).
            (run-with-timer
             0.5 nil
             (lambda (buf)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (cavemacs-caveman-maybe-auto-enable))))
             (current-buffer))))

(provide 'cavemacs-caveman)
;;; cavemacs-caveman.el ends here
