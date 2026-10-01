;;; agent-shell.el --- Test stand-in for agent-shell -*- lexical-binding: t; -*-
;;; Commentary:
;; Only what agent-shell-crew calls.  Records calls in `agent-shell-test--calls'.
;;; Code:
(require 'cl-lib)
(defvar agent-shell-mcp-servers nil "Stub.")
(defvar agent-shell-session-strategy 'prompt "Stub.")
(defvar agent-shell-buffer-name-format nil "Stub: a function or nil.")
(defvar-local agent-shell-test--created-name nil
  "The name the stub gave this buffer; shell-maker finds its process by it.")
(defvar-local agent-shell--state nil "Stub.")
(defvar agent-shell-mode-hook nil "Stub.")
(defvar agent-shell-test--calls nil "Recorded calls, newest first.")
(defvar agent-shell-test--busy nil "What `shell-maker-busy' returns.")
(defvar agent-shell-test--subscriptions nil "Recorded (BUFFER EVENT FN).")
(defun shell-maker-busy () "Stub." agent-shell-test--busy)
(cl-defun agent-shell-start (&key config session-id outgoing-request-decorator)
  "Stub: record CONFIG and return a new buffer."
  (ignore session-id outgoing-request-decorator)
  (push (list 'start config default-directory) agent-shell-test--calls)
  (let ((buffer (generate-new-buffer
                 (if (functionp agent-shell-buffer-name-format)
                     (funcall agent-shell-buffer-name-format (alist-get :buffer-name config) "proj")
                   "stub agent shell"))))
    (with-current-buffer buffer (setq agent-shell-test--created-name (buffer-name)))
    ;; Like the real one: the strategy is read INSIDE the new buffer.
    (push (list 'strategy (with-current-buffer buffer agent-shell-session-strategy))
          agent-shell-test--calls)
    buffer))
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
(defvar-local agent-shell-test--status nil "What `agent-shell-status' reports for this buffer.")
(cl-defun agent-shell-status (&key shell-buffer)
  "Stub: the buffer's `agent-shell-test--status', default `ready'."
  (or (buffer-local-value 'agent-shell-test--status (or shell-buffer (current-buffer))) 'ready))
(defun agent-shell-interrupt (&optional force)
  "Stub: record the interrupt."
  (push (list 'interrupt force (current-buffer)) agent-shell-test--calls))
(defun agent-shell-prompt-queue-resume ()
  "Stub: record the resume."
  (push (list 'resume (current-buffer)) agent-shell-test--calls))
(provide 'agent-shell)
;;; agent-shell.el ends here
