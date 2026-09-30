;;; agent-shell-anthropic.el --- Test stand-in -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:
(defun agent-shell-anthropic-make-claude-code-config ()
  "Stub config."
  (list (cons :identifier 'claude-code) (cons :buffer-name "Claude")
        (cons :mcp-servers nil)))
(provide 'agent-shell-anthropic)
;;; agent-shell-anthropic.el ends here
