;;; cavemacs-pretty.el --- Aesthetic layer for cavemacs chat buffers  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; This module implements the "pretty" rendering surface described in
;; pretty-plan.org.  It is intentionally self-contained:
;;
;;   - A small theme-aware palette (defcustom) with dark/light presets.
;;   - A face suite that everything else inherits from.
;;   - A glyph table (Unicode only -- NO Nerd Font / all-the-icons
;;     dependency, per the plan's non-goals).
;;   - Header-line formatter + cumulative session-cost tally.
;;   - Fringe-indicator helpers for turn / tool boundaries.
;;   - A `cavemacs-pretty-mode' buffer-local minor mode that toggles
;;     the whole presentation layer.  Users who want strict no-chrome
;;     output can `(setq cavemacs-pretty-default-enabled nil)' or
;;     toggle the mode per-buffer.
;;
;; The renderer in cavemacs-render.el is the consumer of this module.
;; It calls `cavemacs-pretty-glyph', `cavemacs-pretty-face', etc., so
;; the visual identity is defined in exactly one place.
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup cavemacs-pretty nil
  "Aesthetic layer for cavemacs chat buffers."
  :group 'cavemacs
  :prefix "cavemacs-pretty-")

;; -----------------------------------------------------------------------------
;; Palette
;; -----------------------------------------------------------------------------

(defconst cavemacs-pretty-palette-dark
  '((user-rule  . "#f6c177")
    (asst-rule  . "#9ccfd8")
    (tool-rule  . "#c4a7e7")
    (error-rule . "#eb6f92")
    (meta-fg    . "#908caa")
    (code-bg    . "#1f1d2e"))
  "Default palette for dark themes (Rose Pine-ish).")

(defconst cavemacs-pretty-palette-light
  '((user-rule  . "#b4651a")
    (asst-rule  . "#286983")
    (tool-rule  . "#7c4dff")
    (error-rule . "#b4347f")
    (meta-fg    . "#6e6a86")
    (code-bg    . "#f2efe6"))
  "Default palette for light themes.")

(defcustom cavemacs-pretty-palette nil
  "Palette used by cavemacs's pretty rendering.

When nil, `cavemacs-pretty-resolve-palette' auto-selects between
`cavemacs-pretty-palette-dark' and `cavemacs-pretty-palette-light'
based on the current frame's `background-mode'.

Set to an alist with keys `user-rule', `asst-rule', `tool-rule',
`error-rule', `meta-fg', `code-bg' to override."
  :type '(choice (const :tag "Auto (theme-aware)" nil)
                 (alist :key-type symbol :value-type string))
  :group 'cavemacs-pretty)

(defun cavemacs-pretty-resolve-palette ()
  "Return the effective palette alist for the current frame."
  (or cavemacs-pretty-palette
      (if (eq (frame-parameter nil 'background-mode) 'light)
          cavemacs-pretty-palette-light
        cavemacs-pretty-palette-dark)))

(defun cavemacs-pretty--color (key)
  "Look up KEY in the resolved palette."
  (alist-get key (cavemacs-pretty-resolve-palette)))

;; -----------------------------------------------------------------------------
;; Faces
;; -----------------------------------------------------------------------------
;;
;; All faces are defined with neutral defaults (no hard-coded color)
;; and then refreshed by `cavemacs-pretty-refresh-faces' from the
;; resolved palette.  That gives users two override paths: defcustom
;; palette, or `M-x customize-face' on the face itself.

(defface cavemacs-pretty-user-rule-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user-turn left rule (▌)."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-assistant-rule-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant-turn left rule (▌)."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-tool-rule-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool-call card borders."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-error-rule-face
  '((t :inherit error :weight bold))
  "Face for error-marked card borders."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-meta-face
  '((t :inherit shadow))
  "Face for low-attention metadata (timestamps, tokens, cost)."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-code-face
  '((t :inherit fixed-pitch :extend t))
  "Face applied as a subtle background to code blocks."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-code-pill-face
  '((t :inherit (cavemacs-pretty-meta-face) :weight bold
       :box (:line-width (1 . -1))))
  "Face for the small language-name pill at the head of a code block."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-prose-face
  '((t :inherit variable-pitch))
  "Face for assistant prose when pretty-mode is on."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-status-idle
  '((t :inherit success))
  "Header-line status dot when idle."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-status-busy
  '((t :inherit warning))
  "Header-line status dot when streaming / tool running."
  :group 'cavemacs-pretty)

(defface cavemacs-pretty-status-error
  '((t :inherit error))
  "Header-line status dot on error."
  :group 'cavemacs-pretty)

(defun cavemacs-pretty-refresh-faces (&rest _)
  "Re-apply palette colors to the cavemacs-pretty face suite.

Called on `enable-theme-functions' / `disable-theme-functions' so
palette colors track theme changes.  Safe to call any number of times."
  (let ((u  (cavemacs-pretty--color 'user-rule))
        (a  (cavemacs-pretty--color 'asst-rule))
        (tl (cavemacs-pretty--color 'tool-rule))
        (er (cavemacs-pretty--color 'error-rule))
        (m  (cavemacs-pretty--color 'meta-fg))
        (cb (cavemacs-pretty--color 'code-bg)))
    (when u  (set-face-foreground 'cavemacs-pretty-user-rule-face u))
    (when a  (set-face-foreground 'cavemacs-pretty-assistant-rule-face a))
    (when tl (set-face-foreground 'cavemacs-pretty-tool-rule-face tl))
    (when er (set-face-foreground 'cavemacs-pretty-error-rule-face er))
    (when m  (set-face-foreground 'cavemacs-pretty-meta-face m))
    (when cb (set-face-background 'cavemacs-pretty-code-face cb))))

(cavemacs-pretty-refresh-faces)

(when (boundp 'enable-theme-functions)
  (add-hook 'enable-theme-functions  #'cavemacs-pretty-refresh-faces))
(when (boundp 'disable-theme-functions)
  (add-hook 'disable-theme-functions #'cavemacs-pretty-refresh-faces))

;; -----------------------------------------------------------------------------
;; Glyphs
;; -----------------------------------------------------------------------------

(defcustom cavemacs-pretty-glyphs
  '((user      . "❯")
    (assistant . "✦")
    (tool      . "⚙")
    (system    . "●")
    (error     . "⚠")
    (rule      . "▌")
    (cont      . "│")
    (stream    . "▍")
    (box-tl    . "╭")
    (box-tr    . "╮")
    (box-bl    . "╰")
    (box-br    . "╯")
    (box-h     . "─")
    (box-v     . "│"))
  "Glyphs used by the pretty renderer.

All values are single-character strings; substitute ASCII fallbacks
here if your font does not cover the defaults."
  :type '(alist :key-type symbol :value-type string)
  :group 'cavemacs-pretty)

(defun cavemacs-pretty-glyph (key)
  "Return the glyph string registered under KEY (or empty string)."
  (or (alist-get key cavemacs-pretty-glyphs) ""))

(defun cavemacs-pretty-role-glyph (role)
  "Return (GLYPH . FACE) for a renderer role symbol."
  (pcase role
    ('user      (cons (cavemacs-pretty-glyph 'user)
                      'cavemacs-pretty-user-rule-face))
    ('assistant (cons (cavemacs-pretty-glyph 'assistant)
                      'cavemacs-pretty-assistant-rule-face))
    ('tool      (cons (cavemacs-pretty-glyph 'tool)
                      'cavemacs-pretty-tool-rule-face))
    ('error     (cons (cavemacs-pretty-glyph 'error)
                      'cavemacs-pretty-error-rule-face))
    (_          (cons (cavemacs-pretty-glyph 'system)
                      'cavemacs-pretty-meta-face))))

;; -----------------------------------------------------------------------------
;; Per-tool tint
;; -----------------------------------------------------------------------------

(defcustom cavemacs-pretty-tool-families
  '(("read"    . file)   ("edit"  . file)   ("write" . file)
    ("ls"      . search) ("grep"  . search) ("find"  . search)
    ("glob"    . search)
    ("bash"    . shell)  ("shell" . shell)  ("exec"  . shell))
  "Map of toolName -> family symbol.  Used for color identity in cards."
  :type '(alist :key-type string :value-type symbol)
  :group 'cavemacs-pretty)

(defun cavemacs-pretty-tool-family (name)
  "Return a family symbol for tool NAME (or `other')."
  (or (alist-get name cavemacs-pretty-tool-families nil nil #'string-equal)
      'other))

(defun cavemacs-pretty-tool-face (_name &optional is-error)
  "Return the rule face for tool NAME, or the error face if IS-ERROR."
  (cond
   (is-error 'cavemacs-pretty-error-rule-face)
   (t        'cavemacs-pretty-tool-rule-face)))

;; -----------------------------------------------------------------------------
;; Streaming cursor
;; -----------------------------------------------------------------------------

(defcustom cavemacs-pretty-streaming-cursor t
  "When non-nil, show a soft pulsing cursor at the streaming tail.

Set to nil to disable any animation (e.g. for accessibility or
battery)."
  :type 'boolean
  :group 'cavemacs-pretty)

;; -----------------------------------------------------------------------------
;; Mode + defaults
;; -----------------------------------------------------------------------------

(defcustom cavemacs-pretty-default-enabled t
  "Whether new cavemacs shell buffers turn on `cavemacs-pretty-mode'."
  :type 'boolean
  :group 'cavemacs-pretty)

(defcustom cavemacs-pretty-variable-pitch t
  "When non-nil, render assistant prose in `variable-pitch'.

Code blocks and the input area remain monospace regardless."
  :type 'boolean
  :group 'cavemacs-pretty)

(defcustom cavemacs-pretty-fringe-indicators t
  "When non-nil, mark turn boundaries and tool calls on the left fringe."
  :type 'boolean
  :group 'cavemacs-pretty)

(defcustom cavemacs-pretty-smooth-scroll t
  "When non-nil, enable pixel-precise scrolling in cavemacs shell buffers."
  :type 'boolean
  :group 'cavemacs-pretty)

(defvar-local cavemacs-pretty--header-state nil
  "Plist tracking header-line data: :model :provider :thinking
:cost-cumulative :status (idle|busy|error).")

(defun cavemacs-pretty-state-put (key value)
  "Set KEY -> VALUE in this buffer's pretty state plist."
  (setq cavemacs-pretty--header-state
        (plist-put (or cavemacs-pretty--header-state nil) key value))
  (force-mode-line-update))

(defun cavemacs-pretty-state-get (key)
  "Read KEY from this buffer's pretty state plist."
  (plist-get cavemacs-pretty--header-state key))

(defun cavemacs-pretty-add-cost (delta)
  "Add DELTA (number, possibly nil) to cumulative session cost."
  (when (numberp delta)
    (let ((cur (or (cavemacs-pretty-state-get :cost-cumulative) 0.0)))
      (cavemacs-pretty-state-put :cost-cumulative (+ cur delta)))))

(defun cavemacs-pretty--status-dot ()
  (let* ((s (or (cavemacs-pretty-state-get :status) 'idle))
         (face (pcase s
                 ('busy  'cavemacs-pretty-status-busy)
                 ('error 'cavemacs-pretty-status-error)
                 (_      'cavemacs-pretty-status-idle))))
    (propertize "●" 'face face)))

(defun cavemacs-pretty--header-format ()
  "Compute the cavemacs header-line string."
  (let* ((proj (or (cavemacs-pretty-state-get :project) ""))
         (prov (cavemacs-pretty-state-get :provider))
         (mod  (cavemacs-pretty-state-get :model))
         (think (cavemacs-pretty-state-get :thinking))
         (cost (cavemacs-pretty-state-get :cost-cumulative))
         (status (or (cavemacs-pretty-state-get :status) 'idle))
         (meta 'cavemacs-pretty-meta-face))
    (concat
     " "
     (propertize "cavemacs" 'face '(:weight bold))
     (when (and proj (not (string-empty-p proj)))
       (concat "  " (propertize proj 'face meta)))
     (when (or prov mod)
       (concat "  "
               (propertize (cond ((and prov mod) (format "%s/%s" prov mod))
                                 (mod mod)
                                 (t prov))
                           'face meta
                           'mouse-face 'highlight
                           'help-echo "mouse-1: pick model")))
     (when think
       (concat "  "
               (propertize (format "thinking: %s" think) 'face meta
                           'mouse-face 'highlight
                           'help-echo "mouse-1: cycle thinking level")))
     (when (numberp cost)
       (concat "  " (propertize (format "$%.4f" cost) 'face meta)))
     "  " (cavemacs-pretty--status-dot)
     " " (propertize (symbol-name status) 'face meta))))

;;;###autoload
(define-minor-mode cavemacs-pretty-mode
  "Enable the pretty rendering surface in a cavemacs shell buffer.

When enabled:
  - Header-line shows model, thinking level, cumulative cost,
    and a live status dot.
  - The renderer emits bubble-style headers with role glyphs.
  - Smooth scrolling and fringe indicators are turned on.
  - Assistant prose is shown in `variable-pitch' (with code-block
    regions pinned back to `fixed-pitch')."
  :init-value nil
  :lighter nil
  (cond
   (cavemacs-pretty-mode
    (setq-local header-line-format '(:eval (cavemacs-pretty--header-format)))
    (when cavemacs-pretty-smooth-scroll
      (when (fboundp 'pixel-scroll-precision-mode)
        (pixel-scroll-precision-mode 1)))
    (when cavemacs-pretty-fringe-indicators
      (setq-local left-fringe-width 12)
      (set-window-buffer (selected-window) (current-buffer)))
    (force-mode-line-update))
   (t
    (setq-local header-line-format nil)
    (force-mode-line-update))))

(defun cavemacs-pretty-maybe-enable ()
  "Turn on `cavemacs-pretty-mode' if `cavemacs-pretty-default-enabled'."
  (when cavemacs-pretty-default-enabled
    (cavemacs-pretty-mode 1)))

;; -----------------------------------------------------------------------------
;; Public helpers consumed by the renderer
;; -----------------------------------------------------------------------------

(defun cavemacs-pretty-active-p ()
  "Return non-nil iff the current buffer has pretty mode on."
  (and (boundp 'cavemacs-pretty-mode) cavemacs-pretty-mode))

(defun cavemacs-pretty-now ()
  "Return a short HH:MM timestamp string for header lines."
  (format-time-string "%H:%M"))

(defun cavemacs-pretty-indent-string (s prefix)
  "Indent every line in S with PREFIX (a propertized string)."
  (mapconcat (lambda (l) (concat prefix l))
             (split-string (or s "") "\n" nil)
             "\n"))

(provide 'cavemacs-pretty)
;;; cavemacs-pretty.el ends here
