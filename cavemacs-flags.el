;;; cavemacs-flags.el --- Per-shell mode/model/thinking transient  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Transient menu (`C-c C-o' in cavemacs-shell-mode) for mid-session
;; model / thinking-level switching, plus session-restart-required flags
;; (provider, plan/goal mode, autopilot, caveman-mode).
;;
;;; Code:

(require 'cavemacs-shell)
(require 'cavemacs-rpc)
(require 'cavemacs-tools)
(require 'cavemacs-commands)

;; See cavemacs-cavekit.el for the rationale behind lazy transient
;; definition; same load-order defense applies here.

(defvar cavemacs-flags--defined nil)
(declare-function cavemacs-flags--prefix "cavemacs-flags" ())

(defun cavemacs-flags--require-conn ()
  (unless (and (boundp 'cavemacs-shell--conn)
               (cavemacs-rpc-live-p cavemacs-shell--conn))
    (user-error "Not in a live cavemacs buffer")))

(defun cavemacs-flags-cycle-model ()
  "Cycle to the next scoped model (mirrors caveman's Ctrl-P)."
  (interactive)
  (cavemacs-flags--require-conn)
  (let ((resp (cavemacs-rpc-request-sync
               cavemacs-shell--conn "cycle_model" nil 10)))
    (let ((data (alist-get 'data resp)))
      (if (null data)
          (message "cavemacs: no scoped models configured (start caveman with --models)")
        (let ((m (alist-get 'model data)))
          (message "cavemacs: %s/%s"
                   (alist-get 'provider m) (alist-get 'id m)))))))

(defun cavemacs-flags-cycle-thinking ()
  "Cycle the thinking level."
  (interactive)
  (cavemacs-flags--require-conn)
  (let ((resp (cavemacs-rpc-request-sync
               cavemacs-shell--conn "cycle_thinking_level" nil 5)))
    (let ((data (alist-get 'data resp)))
      (if (null data)
          (message "cavemacs: model has no scoped thinking levels")
        (message "cavemacs: thinking = %s" (alist-get 'level data))))))

(defun cavemacs-flags-set-thinking (level)
  "Set thinking level to LEVEL."
  (interactive
   (list (completing-read "Thinking level: "
                          '("off" "minimal" "low" "medium" "high" "xhigh")
                          nil t)))
  (cavemacs-flags--require-conn)
  (cavemacs-rpc-send cavemacs-shell--conn "set_thinking_level" :level level)
  (message "cavemacs: thinking -> %s" level))

(defun cavemacs-flags-pick-model ()
  "Pick a model from `get_available_models' and switch to it."
  (interactive)
  (cavemacs-flags--require-conn)
  (let* ((resp (cavemacs-rpc-request-sync
                cavemacs-shell--conn "get_available_models" nil 30))
         (models (alist-get 'models (alist-get 'data resp)))
         (table (mapcar
                 (lambda (m)
                   (cons (format "%s/%s — %s"
                                 (alist-get 'provider m)
                                 (alist-get 'id m)
                                 (or (alist-get 'name m) ""))
                         m))
                 models))
         (choice (and table (completing-read "Model: " table nil t))))
    (when choice
      (let* ((m (cdr (assoc choice table))))
        (cavemacs-rpc-request
         cavemacs-shell--conn "set_model"
         (lambda (r)
           (if (eq (alist-get 'success r) t)
               (message "cavemacs: model -> %s/%s"
                        (alist-get 'provider m) (alist-get 'id m))
             (message "cavemacs: set_model failed: %s"
                      (alist-get 'error r))))
         :provider (alist-get 'provider m)
         :modelId  (alist-get 'id m))))))

(defun cavemacs-flags-toggle-autopilot ()
  "Toggle local autopilot (auto-approve confirms in this buffer)."
  (interactive)
  (setq-local cavemacs-tools-autopilot (not cavemacs-tools-autopilot))
  (message "cavemacs autopilot: %s"
           (if cavemacs-tools-autopilot "ON" "off")))

(defun cavemacs-flags-toggle-auto-compaction ()
  "Toggle auto-compaction for this session."
  (interactive)
  (cavemacs-flags--require-conn)
  (let* ((state (cavemacs-rpc-request-sync
                 cavemacs-shell--conn "get_state" nil 5))
         (cur (and (alist-get 'success state)
                   (eq (alist-get 'autoCompactionEnabled
                                   (alist-get 'data state)) t))))
    (cavemacs-rpc-send cavemacs-shell--conn
                       "set_auto_compaction"
                       :enabled (if cur :json-false t))
    (message "cavemacs: auto-compaction -> %s" (if cur "off" "on"))))

(defun cavemacs-flags-compact ()
  "Force a context compaction."
  (interactive)
  (cavemacs-flags--require-conn)
  (cavemacs-rpc-send cavemacs-shell--conn "compact")
  (message "cavemacs: compacting…"))

(defun cavemacs-flags--ensure-defined ()
  "Define the flags transient prefix on first use."
  (unless cavemacs-flags--defined
    (require 'transient)
    (eval
     '(transient-define-prefix cavemacs-flags--prefix ()
        "Per-session model, thinking, and behaviour flags."
        ["Model"
         ("m" "Pick model"          cavemacs-flags-pick-model)
         ("M" "Cycle model"         cavemacs-flags-cycle-model)]
        ["Thinking"
         ("t" "Set level"           cavemacs-flags-set-thinking)
         ("T" "Cycle level"         cavemacs-flags-cycle-thinking)]
        ["Behaviour"
         ("a" "Toggle autopilot"    cavemacs-flags-toggle-autopilot)
         ("c" "Toggle auto-compact" cavemacs-flags-toggle-auto-compaction)
         ("C" "Compact now"         cavemacs-flags-compact)])
     t)
    (setq cavemacs-flags--defined t)))

;;;###autoload
(defun cavemacs-flags ()
  "Open the cavemacs flags transient menu."
  (interactive)
  (cavemacs-flags--ensure-defined)
  (call-interactively #'cavemacs-flags--prefix))

;; Bind into the shell map at load time.
(with-eval-after-load 'cavemacs-shell
  (define-key cavemacs-shell-mode-map (kbd "C-c C-o") #'cavemacs-flags)
  (define-key cavemacs-shell-mode-map (kbd "C-c C-p") #'cavemacs-commands-pick))

(provide 'cavemacs-flags)
;;; cavemacs-flags.el ends here
