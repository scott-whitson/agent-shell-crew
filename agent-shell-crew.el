;;; agent-shell-crew.el --- A crew of agent-shell sessions sharing a work queue -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson

;; Author: Scott Whitson <scott@scottwhitson.com>
;; URL: https://github.com/scott-whitson/agent-shell-crew
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.81.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A small crew of agent-shell sessions -- a lead, a builder, a checker --
;; sharing a work queue.  Every item has one owner, hand-offs are recorded,
;; and anything that needs a human decision is parked, with its evidence,
;; for `agent-shell-crew-decide'.  See docs/design.md.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)
(require 'server)
(require 'agent-shell)
(require 'agent-shell-crew-queue)
(require 'agent-shell-crew-rpc)

(declare-function agent-shell-anthropic-make-claude-code-config "agent-shell-anthropic")

(defconst agent-shell-crew--package-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Where this package is installed.")

(defcustom agent-shell-crew-roles
  (mapcar (lambda (role)
            (list role
                  :brief (expand-file-name (format "briefs/%s.md" role) agent-shell-crew--package-dir)
                  :config-maker #'agent-shell-anthropic-make-claude-code-config))
          '("lead" "owner" "check"))
  "Crew roles.
Each element is (ROLE . PLIST).  PLIST has :brief, a file name or the
brief text itself, and :config-maker, a function returning an
agent-shell config (see `agent-shell-make-agent-config')."
  :type '(alist :key-type string :value-type plist)
  :group 'agent-shell-crew)

(defcustom agent-shell-crew-mcp-program
  (expand-file-name "bin/agent-shell-crew-mcp" agent-shell-crew--package-dir)
  "The crew MCP program each session starts."
  :type 'file
  :group 'agent-shell-crew)

(defcustom agent-shell-crew-python "python3"
  "Python interpreter that runs `agent-shell-crew-mcp-program'."
  :type 'string
  :group 'agent-shell-crew)

(defvar-local agent-shell-crew--member nil
  "The crew member name of this agent-shell buffer, or nil.")
(put 'agent-shell-crew--member 'permanent-local t)

(defvar-local agent-shell-crew--pending nil
  "Nudges waiting until this session's input is empty.")
(put 'agent-shell-crew--pending 'permanent-local t)

(defun agent-shell-crew-member-name (role root)
  "Return the member name for ROLE in the project at ROOT."
  (format "%s@%s" role (agent-shell-crew-project-name root)))

(defun agent-shell-crew-members (root)
  "Return every name that may own items in ROOT's crew."
  (cons "human" (mapcar (lambda (role) (agent-shell-crew-member-name (car role) root))
                        agent-shell-crew-roles)))

(defun agent-shell-crew--server-socket ()
  "Return the Emacs server socket, starting the server when needed."
  (unless (server-running-p) (server-start))
  (when server-use-tcp
    (user-error "Crew sessions need a local-socket Emacs server; `server-use-tcp' is set"))
  (expand-file-name server-name server-socket-dir))

(defun agent-shell-crew--mcp-server (member root socket)
  "Return the crew MCP server entry for MEMBER of ROOT, reaching SOCKET."
  `((name . "agent-shell-crew")
    (command . ,agent-shell-crew-python)
    (args . (,agent-shell-crew-mcp-program))
    (env . (((name . "CREW_AGENT") (value . ,member))
            ((name . "CREW_PROJECT") (value . ,(file-name-as-directory (expand-file-name root))))
            ((name . "CREW_EMACS_SOCKET") (value . ,socket))))))

(defun agent-shell-crew--role (role)
  "Return ROLE's plist, or fail."
  (or (cdr (assoc role agent-shell-crew-roles))
      (user-error "Unknown crew role: %s" role)))

(defun agent-shell-crew--session-config (role root socket)
  "Return the agent-shell config for ROLE in ROOT, reaching SOCKET."
  (let* ((spec (agent-shell-crew--role role))
         (maker (plist-get spec :config-maker))
         (member (agent-shell-crew-member-name role root))
         (config (progn
                   (unless (fboundp maker) (require 'agent-shell-anthropic nil t))
                   (copy-alist (funcall maker)))))
    (setf (alist-get :buffer-name config) member)
    (setf (alist-get :mcp-servers config)
          (append (or (alist-get :mcp-servers config) agent-shell-mcp-servers)
                  (list (agent-shell-crew--mcp-server member root socket))))
    config))

(defun agent-shell-crew--brief (role)
  "Return ROLE's brief text."
  (let ((brief (plist-get (agent-shell-crew--role role) :brief)))
    (cond ((and (stringp brief) (file-name-absolute-p brief) (file-readable-p brief))
           (with-temp-buffer (insert-file-contents brief) (string-trim (buffer-string))))
          ((stringp brief) brief)
          (t ""))))

(defun agent-shell-crew--intro (role member root)
  "Return the first prompt for MEMBER, who has ROLE in ROOT's crew."
  (let ((owned (seq-filter (lambda (item) (member (plist-get item :state) '("PENDING" "ACTIVE" "PARKED")))
                           (agent-shell-crew-queue-list root member))))
    (concat (format "You are %s, the %s in this project's crew.  Your crew identity is %s; the crew_* tools act as you.\n\n"
                    member role member)
            (agent-shell-crew--brief role)
            (if owned
                (format "\n\nYou already own: %s.  Start with crew_mine."
                        (mapconcat (lambda (item) (plist-get item :id)) owned ", "))
              ""))))

(defun agent-shell-crew--member-buffer (member)
  "Return the live buffer of crew MEMBER, or nil."
  (seq-find (lambda (buffer) (equal (buffer-local-value 'agent-shell-crew--member buffer) member))
            (buffer-list)))

(defun agent-shell-crew--input-empty-p (buffer)
  "Non-nil when BUFFER's shell input holds no text.
Anything uncertain counts as not empty, so a draft is never submitted."
  (with-current-buffer buffer
    (condition-case nil
        (string-empty-p
         (string-trim (buffer-substring-no-properties
                       (process-mark (get-buffer-process buffer)) (point-max))))
      (error nil))))

(defun agent-shell-crew--deliver (buffer text)
  "Send TEXT to the session in BUFFER without disturbing it."
  (with-current-buffer buffer
    (cond ((shell-maker-busy) (agent-shell-busy-submit-queue text))
          ((agent-shell-crew--input-empty-p buffer)
           (agent-shell-insert :text text :submit t :no-focus t :shell-buffer buffer))
          (t (setq agent-shell-crew--pending (append agent-shell-crew--pending (list text)))))))

(defun agent-shell-crew--flush (buffer)
  "Deliver the nudges BUFFER was holding."
  (when (buffer-live-p buffer)
    (let ((texts (buffer-local-value 'agent-shell-crew--pending buffer)))
      (when texts
        (with-current-buffer buffer (setq agent-shell-crew--pending nil))
        (dolist (text texts) (agent-shell-crew--deliver buffer text))))))

(defun agent-shell-crew--notify (member _root text)
  "Tell crew MEMBER TEXT if its session is running."
  (when-let* ((buffer (agent-shell-crew--member-buffer member)))
    (agent-shell-crew--deliver buffer text)))

(defun agent-shell-crew--adopt (buffer member role root)
  "Make BUFFER crew MEMBER with ROLE in ROOT and brief it once it is ready."
  (with-current-buffer buffer
    (rename-buffer member t)
    (setq agent-shell-crew--member member))
  (let ((intro (agent-shell-crew--intro role member root))
        (sent nil))
    (agent-shell-subscribe-to
     :shell-buffer buffer :event 'prompt-ready
     :on-event (lambda (_event)
                 (unless sent
                   (setq sent t)
                   (agent-shell-crew--deliver buffer intro))))
    (dolist (event '(input-submitted turn-complete))
      (agent-shell-subscribe-to
       :shell-buffer buffer :event event
       :on-event (lambda (_event) (agent-shell-crew--flush buffer))))))

(defun agent-shell-crew--default-root ()
  "Return the current project root, or `default-directory'."
  (if-let* ((project (project-current))) (project-root project) default-directory))

;;;###autoload
(defun agent-shell-crew-start (root roles)
  "Start crew ROLES as agent-shell sessions in the directory ROOT.
Interactively, read ROOT and a comma-separated list of ROLES."
  (interactive
   (list (read-directory-name "Crew for directory: " (agent-shell-crew--default-root))
         (completing-read-multiple "Roles: " (mapcar #'car agent-shell-crew-roles)
                                   nil t nil nil "owner,check")))
  (let ((root (file-name-as-directory (expand-file-name root)))
        (socket (agent-shell-crew--server-socket)))
    (dolist (role roles)
      (let ((member (agent-shell-crew-member-name role root)))
        (if (agent-shell-crew--member-buffer member)
            (message "%s is already running" member)
          (let* ((default-directory root)
                 (buffer (agent-shell-start :config (agent-shell-crew--session-config role root socket))))
            (agent-shell-crew--adopt buffer member role root)))))))

(defun agent-shell-crew--options (question)
  "Return the numbered options written inline in QUESTION.
Options look like \"(1) first; (2) second\"."
  (let ((start 0) options)
    (while (string-match
            "(\\([0-9]+\\))[ \t]*\\(.+?\\)[ \t]*\\(?:;\\|\\. \\|(\\([0-9]+\\))\\|\\.?\\'\\)"
            question start)
      (push (format "%s — %s" (match-string 1 question) (match-string 2 question)) options)
      (setq start (if (match-beginning 3) (1- (match-beginning 3)) (match-end 0))))
    (nreverse options)))

;;;###autoload
(defun agent-shell-crew-new (root owner title brief &optional evidence)
  "Create an item in ROOT's crew for OWNER with TITLE, BRIEF and EVIDENCE.
Returns the new item's id."
  (interactive
   (let* ((root (file-name-as-directory
                 (expand-file-name (read-directory-name "Project: " (agent-shell-crew--default-root)))))
          (owner (completing-read "For: " (remove "human" (agent-shell-crew-members root)) nil t))
          (title (read-string "Title: "))
          (brief (read-string "Brief: "))
          (evidence (read-string "Evidence file (optional): ")))
     (list root owner title brief (unless (string-empty-p evidence) evidence))))
  (let ((id (agent-shell-crew-queue-create root "human" :title title :brief brief
                                           :owner owner :evidence evidence)))
    (agent-shell-crew--notify owner root (agent-shell-crew--nudge-text id title))
    (message "Created %s for %s" id owner)
    id))

;;;###autoload
(defun agent-shell-crew-decide ()
  "Answer a crew item that is parked on you.
Opens the item's evidence alongside, offers its numbered options, and
tells the owner."
  (interactive)
  (let* ((parked (or (agent-shell-crew-parked) (user-error "Nothing is waiting on you")))
         (table (mapcar (lambda (pair)
                          (cons (format "[%s] %s (%s) — %s"
                                        (agent-shell-crew-project-name (car pair))
                                        (plist-get (cdr pair) :title) (plist-get (cdr pair) :id)
                                        (truncate-string-to-width
                                         (or (plist-get (cdr pair) :question) "") 80 nil nil "…"))
                                pair))
                        parked))
         (choice (if (cdr table)
                     (cdr (assoc (completing-read "Decide: " table nil t) table))
                   (cdar table)))
         (root (car choice))
         (item (cdr choice))
         (id (plist-get item :id))
         (question (or (plist-get item :question) ""))
         (evidence (plist-get item :evidence)))
    (when evidence
      (let ((file (expand-file-name evidence root)))
        (when (file-readable-p file)
          (display-buffer (find-file-noselect file) '(nil (inhibit-same-window . t))))))
    (let ((decision (string-trim (completing-read (format "%s\nDecision: " question)
                                                  (agent-shell-crew--options question)))))
      (when (string-empty-p decision) (user-error "No decision given; nothing recorded"))
      (let ((owner (agent-shell-crew-queue-decide root id decision)))
        (agent-shell-crew--notify
         owner root (format "Decision on crew item %s: %s.  Call crew_show with id %s." id decision id))
        (message "Decided %s" id)))))

;;;###autoload
(defun agent-shell-crew-open (root)
  "Open the crew queue file for the project at ROOT."
  (interactive (list (read-directory-name "Project: " (agent-shell-crew--default-root))))
  (find-file (agent-shell-crew-queue-file root)))

(defvar agent-shell-crew--parked-count 0
  "How many crew items wait on the human, as last counted.")

(defconst agent-shell-crew--mode-line
  '(:eval (when (> agent-shell-crew--parked-count 0)
            (format " crew:%d" agent-shell-crew--parked-count)))
  "The mode-line construct `agent-shell-crew-mode-line-mode' adds.")

(defun agent-shell-crew--refresh-count (&rest _)
  "Recount parked items and redraw mode lines."
  (setq agent-shell-crew--parked-count (length (agent-shell-crew-parked)))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode agent-shell-crew-mode-line-mode
  "Show in the mode line how many crew items wait on you."
  :global t
  :group 'agent-shell-crew
  (if agent-shell-crew-mode-line-mode
      (progn
        (unless (listp global-mode-string)
          (setq global-mode-string (list global-mode-string)))
        (add-to-list 'global-mode-string agent-shell-crew--mode-line t)
        (add-hook 'agent-shell-crew-changed-hook #'agent-shell-crew--refresh-count)
        (agent-shell-crew--refresh-count))
    (setq global-mode-string (delete agent-shell-crew--mode-line global-mode-string))
    (remove-hook 'agent-shell-crew-changed-hook #'agent-shell-crew--refresh-count)))

(setq agent-shell-crew-rpc-members-function #'agent-shell-crew-members
      agent-shell-crew-rpc-notify-function #'agent-shell-crew--notify)

(provide 'agent-shell-crew)
;;; agent-shell-crew.el ends here
