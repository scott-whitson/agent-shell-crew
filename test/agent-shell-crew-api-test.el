;;; agent-shell-crew-api-test.el --- Guard the real agent-shell API -*- lexical-binding: t; -*-
;;; Commentary:
;; Run with `make api-check DEPS="-L <agent-shell> -L <acp> -L <shell-maker> ..."'.
;; Fails when agent-shell renames or drops anything crew relies on.
;;; Code:
(require 'ert)
(require 'agent-shell)
(require 'agent-shell-anthropic)
(require 'help-fns)
(require 'map)

(ert-deftest crew-api-functions-exist ()
  (dolist (fn '(agent-shell-start agent-shell-insert agent-shell-busy-submit-queue
                agent-shell-subscribe-to agent-shell-buffers shell-maker-busy
                agent-shell-anthropic-make-claude-code-config))
    (should (fboundp fn))))

(ert-deftest crew-api-events-documented ()
  (let ((doc (documentation 'agent-shell-subscribe-to)))
    (dolist (event '("init-finished" "input-submitted" "turn-complete"))
      (should (string-match-p event doc)))))

(ert-deftest crew-api-insert-keywords ()
  ;; A `cl-defun' compiles to (&rest rest); its keywords live in the
  ;; documented signature, "(agent-shell-insert &key TEXT SUBMIT ...)".
  (let ((usage (downcase (car (help-split-fundoc (documentation 'agent-shell-insert t)
                                                 'agent-shell-insert)))))
    (dolist (key '("text" "submit" "no-focus" "shell-buffer"))
      (should (string-match-p (concat "\\_<" key "\\_>") usage)))))

(ert-deftest crew-api-config-keys ()
  (let ((config (agent-shell-anthropic-make-claude-code-config)))
    (should (assq :buffer-name config))
    (should (assq :mcp-servers config))))

(ert-deftest crew-api-mcp-servers-variable ()
  (should (boundp 'agent-shell-mcp-servers)))

(ert-deftest crew-api-session-strategy-new ()
  "`agent-shell-crew-start' binds the strategy to `new' for every member."
  (should (boundp 'agent-shell-session-strategy))
  (should (string-match-p "\\_<new\\_>"
                          (format "%S" (get 'agent-shell-session-strategy 'custom-type)))))

(ert-deftest crew-api-restart-detection ()
  "Re-adoption reads the crew MCP server from the buffer's agent config.
`agent-shell--state' is internal, so this guards it explicitly."
  (should (boundp 'agent-shell-mode-hook))
  (should (local-variable-if-set-p 'agent-shell--state))
  (with-temp-buffer
    (setq-local agent-shell--state (list (cons :agent-config (list (cons :mcp-servers '(x))))))
    (should (equal (map-nested-elt agent-shell--state '(:agent-config :mcp-servers)) '(x)))))

(provide 'agent-shell-crew-api-test)
;;; agent-shell-crew-api-test.el ends here
