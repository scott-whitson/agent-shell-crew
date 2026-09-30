;;; agent-shell.el --- Test stand-in for agent-shell -*- lexical-binding: t; -*-
;;; Commentary:
;; Only what agent-shell-crew calls.  Records calls in `agent-shell-test--calls'.
;;; Code:
(require 'cl-lib)
(defvar agent-shell-mcp-servers nil "Stub.")
(defvar agent-shell-test--calls nil "Recorded calls, newest first.")
(defvar agent-shell-test--busy nil "What `shell-maker-busy' returns.")
(defvar agent-shell-test--subscriptions nil "Recorded (BUFFER EVENT FN).")
(defun shell-maker-busy () "Stub." agent-shell-test--busy)
(cl-defun agent-shell-start (&key config session-id outgoing-request-decorator)
  "Stub: record CONFIG and return a new buffer."
  (ignore session-id outgoing-request-decorator)
  (push (list 'start config default-directory) agent-shell-test--calls)
  (generate-new-buffer "stub agent shell"))
(cl-defun agent-shell-insert (&key text submit no-focus shell-buffer)
  "Stub: record the insertion."
  (push (list 'insert text submit no-focus shell-buffer) agent-shell-test--calls))
(defun agent-shell-busy-submit-queue (prompt)
  "Stub: record PROMPT against the current buffer."
  (push (list 'queue prompt (current-buffer)) agent-shell-test--calls))
(cl-defun agent-shell-subscribe-to (&key shell-buffer event on-event)
  "Stub: record the subscription."
  (push (list shell-buffer event on-event) agent-shell-test--subscriptions))
(defun agent-shell-test--emit (buffer event)
  "Fire EVENT's subscribers for BUFFER."
  (dolist (s agent-shell-test--subscriptions)
    (when (and (eq (nth 0 s) buffer) (eq (nth 1 s) event))
      (funcall (nth 2 s) (list (cons :event event))))))
(defun agent-shell-buffers () "Stub." nil)
(provide 'agent-shell)
;;; agent-shell.el ends here
