;;; cavemacs-config.el --- Shared customs + process invocation  -*- lexical-binding: t; -*-
;;; Commentary:
;; Customs, binary resolution, and CLI argument construction.  Lives
;; below cavemacs-shell.el in the dep graph so cavemacs.el can be the
;; thin top-level façade without introducing a require cycle.
;;; Code:

(require 'subr-x)

(defgroup cavemacs nil
  "Emacs front-end for the caveman-code agent."
  :group 'tools
  :prefix "cavemacs-")

(defcustom cavemacs-binary "caveman"
  "Path to the caveman executable, or a name to resolve via `executable-find'."
  :type 'string
  :group 'cavemacs)

(defcustom cavemacs-extra-args nil
  "Additional CLI arguments passed to `caveman --mode rpc'."
  :type '(repeat string)
  :group 'cavemacs)

(defcustom cavemacs-environment nil
  "Extra environment variables (NAME=VALUE strings) for the subprocess."
  :type '(repeat string)
  :group 'cavemacs)

(defcustom cavemacs-default-provider nil
  "Default provider passed as `--provider' when starting a session."
  :type '(choice (const :tag "caveman default" nil) string)
  :group 'cavemacs)

(defcustom cavemacs-default-model nil
  "Default model passed as `--model' when starting a session."
  :type '(choice (const :tag "caveman default" nil) string)
  :group 'cavemacs)

(defcustom cavemacs-thinking-level nil
  "Default `--thinking' level."
  :type '(choice (const :tag "caveman default" nil)
                 (const "off") (const "minimal") (const "low")
                 (const "medium") (const "high") (const "xhigh"))
  :group 'cavemacs)

(defcustom cavemacs-ephemeral-default nil
  "When non-nil, start sessions with `--no-session' by default."
  :type 'boolean
  :group 'cavemacs)

(defcustom cavemacs-no-extensions nil
  "When non-nil, pass `--no-extensions' to caveman.

Caveman discovers project-local extensions in `.cave/extensions/'
relative to its working directory.  Some extensions in third-party
repos `require' caveman's own internal package paths and fail to
load when the installed `caveman' binary on $PATH does not expose
that resolution -- killing the session at startup.

Enable this when you want to open a session in a repo whose
project-local extensions are broken in your install, or when you
do not want any extensions to load.  Explicit
`cavemacs-extra-args' entries like \"-e\" \"/path/to/ext.ts\"
still work alongside this flag."
  :type 'boolean
  :group 'cavemacs)

(defcustom cavemacs-no-skills nil
  "When non-nil, pass `--no-skills' to caveman to skip skill discovery."
  :type 'boolean
  :group 'cavemacs)

(defcustom cavemacs-no-prompt-templates nil
  "When non-nil, pass `--no-prompt-templates' to caveman."
  :type 'boolean
  :group 'cavemacs)

(defcustom cavemacs-no-themes nil
  "When non-nil, pass `--no-themes' to caveman."
  :type 'boolean
  :group 'cavemacs)

(defun cavemacs--binary ()
  "Resolve the caveman executable, honouring `cavemacs-binary'."
  (or (and cavemacs-binary
           (or (and (file-name-absolute-p cavemacs-binary)
                    (file-executable-p cavemacs-binary)
                    cavemacs-binary)
               (executable-find cavemacs-binary)))
      (user-error
       "Cannot find caveman.  Install it or customize `cavemacs-binary'")))

(defun cavemacs--default-process-args ()
  "Compose the default CLI argument list for a new session."
  (let ((args (list "--mode" "rpc")))
    (when cavemacs-ephemeral-default
      (setq args (append args (list "--no-session"))))
    (when cavemacs-default-provider
      (setq args (append args (list "--provider" cavemacs-default-provider))))
    (when cavemacs-default-model
      (setq args (append args (list "--model" cavemacs-default-model))))
    (when cavemacs-thinking-level
      (setq args (append args (list "--thinking" cavemacs-thinking-level))))
    (when cavemacs-no-extensions
      (setq args (append args (list "--no-extensions"))))
    (when cavemacs-no-skills
      (setq args (append args (list "--no-skills"))))
    (when cavemacs-no-prompt-templates
      (setq args (append args (list "--no-prompt-templates"))))
    (when cavemacs-no-themes
      (setq args (append args (list "--no-themes"))))
    (append args cavemacs-extra-args)))

(provide 'cavemacs-config)
;;; cavemacs-config.el ends here
