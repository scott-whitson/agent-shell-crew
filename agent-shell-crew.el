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

(require 'cl-lib)
(require 'map)
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

(defcustom agent-shell-crew-profiles nil
  "Named crews whose members work in their own directories.
Each element is (NAME . PLIST).  PLIST has :root, the crew's project
root (it names the queue and the @PROJECT of every member), and
:members, a list of member plists: :role, and optionally :name
\(default: the role), :directory (default: the root) and :brief (a file
name or the brief text, overriding the role's)."
  :type '(alist :key-type string :value-type plist)
  :group 'agent-shell-crew)

(defun agent-shell-crew--profiles-for-root (root)
  "Return every profile (NAME . PLIST) whose root is ROOT."
  (let ((root (agent-shell-crew--normal-root root)))
    (seq-filter (lambda (profile)
                  (when-let* ((r (plist-get (cdr profile) :root)))
                    (equal (agent-shell-crew--normal-root r) root)))
                agent-shell-crew-profiles)))

(defun agent-shell-crew--spec-name (spec)
  "Return the member name of profile member SPEC, without @PROJECT."
  (or (plist-get spec :name) (plist-get spec :role)))

(defvar-local agent-shell-crew--member nil
  "The crew member name of this agent-shell buffer, or nil.")
(put 'agent-shell-crew--member 'permanent-local t)

(defvar-local agent-shell-crew--pending nil
  "Nudges waiting until this session is ready and its input is empty.")
(put 'agent-shell-crew--pending 'permanent-local t)

(defvar-local agent-shell-crew--root nil
  "The project root of this crew member's session, or nil.")
(put 'agent-shell-crew--root 'permanent-local t)

(defvar-local agent-shell-crew--ready t
  "Nil while a crew session is still starting up.
Nudges wait until it is ready, so none is lost and none arrives before
the member's brief.")
(put 'agent-shell-crew--ready 'permanent-local t)

(defvar agent-shell-crew-session-changed-hook nil
  "Hook run when a crew session's status may have changed.
Each function is called with the member's project root.  Runs when a
member submits input, finishes a turn, or asks for or gets permission.")

(defvar agent-shell-crew--starting nil
  "Non-nil while `agent-shell-crew-start' is creating a session.")

(defvar agent-shell-session-strategy)
(defvar agent-shell-buffer-name-format)

(defun agent-shell-crew-member-name (role root)
  "Return the member name for ROLE in the project at ROOT."
  (format "%s@%s" role (agent-shell-crew-project-name root)))

(defun agent-shell-crew--normal-root (root)
  "Return ROOT as an absolute directory name."
  (file-name-as-directory (expand-file-name root)))

(defun agent-shell-crew-members (root)
  "Return every name that may own items in ROOT's crew.
A profiled crew's members come from every profile with that root -- a
small profile is often a subset of a full one -- and any other crew's
from `agent-shell-crew-roles'."
  (cons "human"
        (if-let* ((profiles (agent-shell-crew--profiles-for-root root)))
            (delete-dups
             (mapcar (lambda (spec) (agent-shell-crew-member-name (agent-shell-crew--spec-name spec) root))
                     (mapcan (lambda (profile) (copy-sequence (plist-get (cdr profile) :members)))
                             profiles)))
          (mapcar (lambda (role) (agent-shell-crew-member-name (car role) root))
                  agent-shell-crew-roles))))

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
  "Return ROLE's plist from `agent-shell-crew-roles', or nil."
  (cdr (assoc role agent-shell-crew-roles)))

(defun agent-shell-crew--session-config (role root socket &optional name)
  "Return the agent-shell config for ROLE in ROOT, reaching SOCKET.
NAME, when non-nil, is the member's name instead of ROLE."
  (let* ((maker (or (plist-get (agent-shell-crew--role role) :config-maker)
                    #'agent-shell-anthropic-make-claude-code-config))
         (member (agent-shell-crew-member-name (or name role) root))
         (config (progn
                   (unless (fboundp maker) (require 'agent-shell-anthropic nil t))
                   (copy-alist (funcall maker)))))
    (setf (alist-get :buffer-name config) member)
    (setf (alist-get :mcp-servers config)
          (append (or (alist-get :mcp-servers config) agent-shell-mcp-servers)
                  (list (agent-shell-crew--mcp-server member root socket))))
    config))

(defun agent-shell-crew--brief (role &optional override)
  "Return the brief text for ROLE, or OVERRIDE when non-nil.
Either may be an absolute file name or the text itself; no brief at
all is the empty string."
  (let ((brief (or override (plist-get (agent-shell-crew--role role) :brief) "")))
    (let ((file (and (file-name-absolute-p brief) (expand-file-name brief))))
      (if (and file (file-readable-p file))
          (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string)))
        brief))))

(defun agent-shell-crew--intro (role member root &optional brief)
  "Return the first prompt for MEMBER, who has ROLE in ROOT's crew.
BRIEF overrides ROLE's brief."
  (let ((owned (seq-filter (lambda (item) (member (plist-get item :state) '("PENDING" "ACTIVE" "PARKED")))
                           (agent-shell-crew-queue-list root member))))
    (concat (format "You are %s, the %s in this project's crew.  Your crew identity is %s; the crew_* tools act as you.\n\n"
                    member role member)
            (agent-shell-crew--brief role brief)
            (if owned
                (format "\n\nYou already own: %s.  Start with crew_mine."
                        (mapconcat (lambda (item) (plist-get item :id)) owned ", "))
              ""))))

(defun agent-shell-crew--member-buffer (member &optional root)
  "Return the live buffer of crew MEMBER, of the project at ROOT if given.
Two projects in folders with the same name have members with the same
name; ROOT tells them apart."
  (let ((root (and root (agent-shell-crew--normal-root root))))
    (seq-find (lambda (buffer)
                (and (equal (buffer-local-value 'agent-shell-crew--member buffer) member)
                     (or (null root)
                         (equal (buffer-local-value 'agent-shell-crew--root buffer) root))))
              (buffer-list))))

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
  "Send TEXT to the session in BUFFER without disturbing it.
Held back while the session is starting up."
  (if (buffer-local-value 'agent-shell-crew--ready buffer)
      (agent-shell-crew--send buffer text)
    (with-current-buffer buffer
      (setq agent-shell-crew--pending (append agent-shell-crew--pending (list text))))))

(defun agent-shell-crew--send (buffer text)
  "Send TEXT to the ready session in BUFFER without disturbing it."
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

;;; Stuck members

(defcustom agent-shell-crew-stall-minutes 10
  "Minutes a member may read busy with no activity before it counts as stuck.
A turn whose end never reaches the buffer leaves it busy forever, and every
nudge sent to it waits behind that turn.  Seen 2026-09-30: a gate held two
of the human's decisions for an hour behind a turn that had ended."
  :type 'number
  :group 'agent-shell-crew)

(defun agent-shell-crew--member-stuck (buffer)
  "Why the member session in BUFFER is stuck, or nil when it is not.
Two ways: busy with no activity for `agent-shell-crew-stall-minutes', or
idle with prompts still queued -- agent-shell pauses its queue after an
interrupt, and nothing resumes it.  Never signals."
  (condition-case nil
      (with-current-buffer buffer
        (let* ((state (bound-and-true-p agent-shell--state))
               (last (map-elt state :last-activity-time))
               (quiet (and last (/ (float-time (time-subtract nil last)) 60.0)))
               (held (length (map-elt state :pending-prompts)))
               (waiting (if (> held 0)
                            (format " (%d message%s waiting)" held (if (= held 1) "" "s"))
                          "")))
          (cond
           ((and (shell-maker-busy) quiet (>= quiet agent-shell-crew-stall-minutes))
            (format "busy with no activity for %d min%s; interrupt it with C-c C-c"
                    (round quiet) waiting))
           ((and (not (shell-maker-busy)) (> held 0) quiet (>= quiet 1))
            (format "idle with %d queued message%s that are not being sent; \
M-x agent-shell-prompt-queue-resume in its buffer"
                    held (if (= held 1) "" "s"))))))
    (error nil)))

(defvar agent-shell-crew--watch-timer nil
  "The timer `agent-shell-crew-watch-mode' runs.")

(defvar agent-shell-crew--warned nil
  "Member buffers already warned about for their current stuck episode.")

(defun agent-shell-crew--watch ()
  "Warn once about each member that has become stuck."
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'agent-shell-crew--member buffer)
      (let ((why (agent-shell-crew--member-stuck buffer)))
        (cond
         ((and why (not (memq buffer agent-shell-crew--warned)))
          (push buffer agent-shell-crew--warned)
          (display-warning 'agent-shell-crew
                           (format "%s looks stuck: %s"
                                   (buffer-local-value 'agent-shell-crew--member buffer) why)
                           :warning))
         ((not why)
          (setq agent-shell-crew--warned (delq buffer agent-shell-crew--warned)))))))
  (setq agent-shell-crew--warned (seq-filter #'buffer-live-p agent-shell-crew--warned)))

;;;###autoload
(define-minor-mode agent-shell-crew-watch-mode
  "Check every crew member each minute, and warn once when one is stuck."
  :global t
  :group 'agent-shell-crew
  (when agent-shell-crew--watch-timer
    (cancel-timer agent-shell-crew--watch-timer)
    (setq agent-shell-crew--watch-timer nil))
  (when agent-shell-crew-watch-mode
    (setq agent-shell-crew--watch-timer
          (run-with-timer 60 60 #'agent-shell-crew--watch))))

(defun agent-shell-crew--notify (member root text)
  "Tell crew MEMBER of the project at ROOT TEXT if its session is running."
  (when-let* ((buffer (agent-shell-crew--member-buffer member root)))
    (agent-shell-crew--deliver buffer text)))

(defun agent-shell-crew--adopt (buffer member role root &optional brief)
  "Make BUFFER crew MEMBER in ROOT.
Once the session is ready, send ROLE's brief -- unless ROLE is nil, as
for a restarted session that already has its conversation -- then any
nudges that arrived meanwhile.  BRIEF overrides ROLE's brief."
  (with-current-buffer buffer
    ;; Never `rename-buffer' here: shell-maker finds the session's process
    ;; by the buffer's ORIGINAL name, so a renamed shell silently stops
    ;; submitting.  The name comes from `--start-new-session' instead.
    (setq agent-shell-crew--member member
          agent-shell-crew--root (agent-shell-crew--normal-root root)
          agent-shell-crew--ready nil))
  (let ((sent nil))
    (agent-shell-subscribe-to
     ;; Not `prompt-ready': agent-shell emits that BEFORE it sets the model,
     ;; session mode and config options, and a prompt submitted in between
     ;; is lost while the shell stays busy.  `init-finished' ends startup.
     :shell-buffer buffer :event 'init-finished
     :on-event (lambda (_event)
                 (unless sent
                   (setq sent t)
                   (with-current-buffer buffer (setq agent-shell-crew--ready t))
                   (when role
                     (agent-shell-crew--send buffer (agent-shell-crew--intro role member root brief)))
                   (agent-shell-crew--flush buffer))))
    (dolist (event '(input-submitted turn-complete))
      (agent-shell-subscribe-to
       :shell-buffer buffer :event event
       :on-event (lambda (_event) (agent-shell-crew--flush buffer))))
    (dolist (event '(input-submitted turn-complete permission-request permission-response))
      (agent-shell-subscribe-to
       :shell-buffer buffer :event event
       :on-event (lambda (_event)
                   (condition-case nil
                       (run-hook-with-args 'agent-shell-crew-session-changed-hook root)
                     (error nil)))))))

(defun agent-shell-crew--running-roots ()
  "Return the roots of every crew with a running member, most recent first."
  (delete-dups
   (delq nil (mapcar (lambda (buffer) (buffer-local-value 'agent-shell-crew--root buffer))
                     (seq-filter (lambda (buffer) (buffer-local-value 'agent-shell-crew--member buffer))
                                 (buffer-list))))))

(defun agent-shell-crew--read-root (prompt)
  "Return a crew root, asking with PROMPT only when it is not obvious.
Inside a member's session, its crew; with one crew running, that one;
with several, a choice among them; with none, a directory."
  (let ((roots (agent-shell-crew--running-roots)))
    (cond (agent-shell-crew--root agent-shell-crew--root)
          ((null roots) (read-directory-name prompt (agent-shell-crew--default-root)))
          ((null (cdr roots)) (car roots))
          (t (completing-read prompt roots nil t nil nil (car roots))))))

(defun agent-shell-crew--default-root ()
  "Return the current project root, or `default-directory'."
  (if-let* ((project (project-current))) (project-root project) default-directory))

(cl-defun agent-shell-crew--start-member (root role &key name directory brief socket)
  "Start crew member NAME (default ROLE) of ROOT's crew and return its buffer.
The session runs in DIRECTORY (default ROOT) but acts on ROOT's queue.
BRIEF overrides ROLE's brief.  SOCKET is the Emacs server to reach.
Returns nil when the member is already running."
  (let ((member (agent-shell-crew-member-name (or name role) root)))
    (if (agent-shell-crew--member-buffer member root)
        (progn (message "%s is already running" member) nil)
      (let ((buffer (agent-shell-crew--start-new-session
                     (agent-shell-crew--normal-root (or directory root))
                     (agent-shell-crew--session-config role root socket name))))
        (agent-shell-crew--adopt buffer member role root brief)
        buffer))))

;;;###autoload
(defun agent-shell-crew-start (root roles)
  "Start crew ROLES as agent-shell sessions in the directory ROOT.
Interactively, read ROOT and a comma-separated list of ROLES."
  (interactive
   (list (read-directory-name "Crew for directory: " (agent-shell-crew--default-root))
         (completing-read-multiple "Roles: " (mapcar #'car agent-shell-crew-roles)
                                   nil t nil nil "owner,check")))
  (let ((root (agent-shell-crew--normal-root root)))
    (dolist (role roles)
      (unless (agent-shell-crew--role role) (user-error "Unknown crew role: %s" role)))
    (let ((socket (agent-shell-crew--server-socket)))
      (delq nil (mapcar (lambda (role) (agent-shell-crew--start-member root role :socket socket))
                        roles)))))

;;;###autoload
(defun agent-shell-crew-start-profile (name)
  "Start every member of crew profile NAME that is not already running.
See `agent-shell-crew-profiles'.  The whole profile is checked first:
a missing directory, a missing or unreadable brief, or a member name
used twice starts nothing."
  (interactive
   (list (completing-read "Crew profile: " (mapcar #'car agent-shell-crew-profiles) nil t)))
  (let* ((profile (or (assoc name agent-shell-crew-profiles)
                      (user-error "No crew profile named %s" name)))
         (root (agent-shell-crew--normal-root
                (or (plist-get (cdr profile) :root)
                    (user-error "Crew profile %s has no :root" name))))
         (specs (plist-get (cdr profile) :members)))
    (let ((seen nil))
      (dolist (spec specs)
        (let ((member (agent-shell-crew--spec-name spec))
              (dir (plist-get spec :directory))
              (brief (or (plist-get spec :brief)
                         (plist-get (agent-shell-crew--role (plist-get spec :role)) :brief))))
          (when (member member seen)
            (user-error "Crew profile %s names %s twice; give each a :name" name member))
          (push member seen)
          (when (and dir (not (file-directory-p dir)))
            (user-error "Crew member %s: no directory %s" member dir))
          (unless brief
            (user-error "Crew member %s: role %s has no brief" member (plist-get spec :role)))
          ;; A brief that looks like a file name but cannot be read would
          ;; otherwise be sent as the brief text itself.
          (when (and (file-name-absolute-p brief) (not (file-readable-p brief)))
            (user-error "Crew member %s: cannot read brief file %s" member brief)))))
    (let ((socket (agent-shell-crew--server-socket)))
      (delq nil (mapcar (lambda (spec)
                          (agent-shell-crew--start-member
                           root (plist-get spec :role)
                           :name (plist-get spec :name)
                           :directory (plist-get spec :directory)
                           :brief (plist-get spec :brief)
                           :socket socket))
                        specs)))))

(defun agent-shell-crew--start-new-session (directory config)
  "Start a NEW agent-shell session with CONFIG in DIRECTORY; return its buffer.
Bound from a temporary buffer: a caller in an agent-shell buffer has its
own buffer-local `agent-shell-session-strategy', which a plain `let'
would bind instead, leaving the new session to ask which session to
resume.  The buffer is named after the member when it is created."
  (with-temp-buffer
    (let ((default-directory directory)
          (agent-shell-session-strategy 'new)
          (agent-shell-crew--starting t)
          ;; Name the buffer exactly after the member (the config's
          ;; :buffer-name) at creation; it must never be renamed later.
          (agent-shell-buffer-name-format (lambda (agent-name _project) agent-name)))
      (agent-shell-start :config config))))

(defun agent-shell-crew--config-identity ()
  "Return (MEMBER . ROOT) from this buffer's crew MCP server, or nil."
  (when-let* ((servers (map-nested-elt (bound-and-true-p agent-shell--state)
                                       '(:agent-config :mcp-servers)))
              (crew (seq-find (lambda (s) (equal (alist-get 'name s) "agent-shell-crew"))
                              (append servers nil)))
              (env (alist-get 'env crew))
              (value (lambda (name) (alist-get 'value (seq-find (lambda (e) (equal (alist-get 'name e) name))
                                                               (append env nil)))))
              (member (funcall value "CREW_AGENT"))
              (root (funcall value "CREW_PROJECT")))
    (cons member root)))

(defun agent-shell-crew--maybe-adopt ()
  "Track a session that carries a crew identity but was not started by crew.
agent-shell's restart and fork reuse a member's config.  A restart,
where nobody else holds the identity, is adopted again; a fork, made
while the member is still running, is left untracked, so there is
never a second owner."
  (unless (or agent-shell-crew--starting agent-shell-crew--member)
    (when-let* ((identity (agent-shell-crew--config-identity)))
      (let ((holder (agent-shell-crew--member-buffer (car identity) (cdr identity))))
        (if (and holder (not (eq holder (current-buffer))))
            (message "agent-shell-crew: %s is already running; this copy is not a crew member"
                     (car identity))
          (agent-shell-crew--adopt (current-buffer) (car identity) nil (cdr identity)))))))

(add-hook 'agent-shell-mode-hook #'agent-shell-crew--maybe-adopt)

(defun agent-shell-crew--owner-candidates (root)
  "Return the members of ROOT's crew who can own an item, running ones first.
The first is the default, so pressing RET never picks a member with no
session."
  (let* ((members (remove "human" (agent-shell-crew-members root)))
         (running (seq-filter (lambda (m) (agent-shell-crew--member-buffer m root)) members)))
    (append running (seq-difference members running))))

(defconst agent-shell-crew--type-own "Type my own decision…"
  "The choice that opens a free-text prompt in place of a listed option.
A completion UI such as vertico submits the highlighted candidate on RET,
so text that matches no option was never reachable without it.")

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
          (candidates (agent-shell-crew--owner-candidates root))
          (owner (completing-read (format "For (default %s): " (car candidates))
                                  candidates nil t nil nil (car candidates)))
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
Pick among every parked item in every project; see
`agent-shell-crew-decide-item'."
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
                   (cdar table))))
    (agent-shell-crew-decide-item (car choice) (plist-get (cdr choice) :id))))

(defun agent-shell-crew-decide-item (root id)
  "Answer crew item ID of the project at ROOT, which is parked on you.
Opens the item's evidence alongside, offers its numbered options, and
tells the owner."
  (let* ((item (agent-shell-crew-queue-get root id))
         (question (or (plist-get item :question) ""))
         (evidence (plist-get item :evidence)))
    (unless (equal (plist-get item :state) "PARKED")
      (user-error "%s is %s, not waiting on you" id (plist-get item :state)))
    (when evidence
      (let ((file (expand-file-name evidence root)))
        (when (file-readable-p file)
          (display-buffer (find-file-noselect file) '(nil (inhibit-same-window . t))))))
    (let* ((options (agent-shell-crew--options question))
           (picked (completing-read (format "%s\nDecision: " question)
                                    (if options
                                        (append options (list agent-shell-crew--type-own))
                                      options)))
           (decision (string-trim
                      (if (equal picked agent-shell-crew--type-own)
                          (read-string (format "%s\nYour decision: " question))
                        picked))))
      (when (string-empty-p decision) (user-error "No decision given; nothing recorded"))
      (let ((owner (agent-shell-crew-queue-decide root id decision)))
        (agent-shell-crew--notify
         owner root (format "Decision on crew item %s: %s.  Call crew_show with id %s." id decision id))
        (message "Decided %s" id)))))

;;;###autoload
(defun agent-shell-crew-open (root)
  "Open the crew queue file for the project at ROOT."
  (interactive (list (agent-shell-crew--read-root "Crew: ")))
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
