;;; agent-shell-crew-queue.el --- The crew work queue, stored in Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson

;; Author: Scott Whitson <scott@scottwhitson.com>
;; URL: https://github.com/scott-whitson/agent-shell-crew
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of agent-shell-crew.

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

;; One Org file per project holds the crew's work queue.  Each item is a
;; top-level heading whose TODO keyword is its state, whose properties say
;; who owns it, and whose "Log" child grows by one line per transition.
;; Only Emacs writes these files; agents reach them through
;; `agent-shell-crew-rpc'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)

(defgroup agent-shell-crew nil
  "A crew of agent-shell sessions sharing a work queue."
  :group 'tools
  :prefix "agent-shell-crew-")

(defcustom agent-shell-crew-directory (locate-user-emacs-file "agent-shell-crew/")
  "Directory holding one crew queue file per project."
  :type 'directory)

(defvar agent-shell-crew-changed-hook nil
  "Hook run after every queue change.
Each function is called with three arguments: the project root, the
item id, and the verb, a symbol such as `create' or `handoff'.")

(define-error 'agent-shell-crew-error "agent-shell-crew")

(defconst agent-shell-crew--todo-line
  "#+TODO: PENDING ACTIVE PARKED | DONE HANDED CANCELED"
  "The TODO keyword line every queue file starts with.")

(defun agent-shell-crew--fail (format-string &rest args)
  "Signal `agent-shell-crew-error' with FORMAT-STRING and ARGS."
  (signal 'agent-shell-crew-error (list (apply #'format format-string args))))

(defun agent-shell-crew-project-name (root)
  "Return the project name for ROOT, a directory."
  (file-name-nondirectory (directory-file-name (expand-file-name root))))

(defun agent-shell-crew-queue-file (root)
  "Return the queue file for the project at ROOT.
Named after the project and a short hash of its full path, so two
projects in folders with the same name never share a queue."
  (let ((dir (file-name-as-directory (expand-file-name root))))
    (expand-file-name (format "%s-%s.org" (agent-shell-crew-project-name dir)
                              (substring (secure-hash 'sha1 dir) 0 6))
                      agent-shell-crew-directory)))

(defun agent-shell-crew--ensure-header (root)
  "Give the current, empty buffer the queue header for ROOT."
  (when (= (buffer-size) 0)
    (insert (format "#+TITLE: crew: %s\n#+CREW_ROOT: %s\n%s\n\n"
                    (agent-shell-crew-project-name root)
                    (file-name-as-directory (expand-file-name root))
                    agent-shell-crew--todo-line))
    (org-mode-restart)))

(defun agent-shell-crew--sync-with-disk ()
  "Make the current queue buffer match its file, or refuse."
  (when (and (buffer-file-name) (not (verify-visited-file-modtime)))
    (if (buffer-modified-p)
        (agent-shell-crew--fail "%s has unsaved edits and changed on disk; save or revert it first"
                                (buffer-file-name))
      (revert-buffer t t t))))

(defun agent-shell-crew--discard-changes ()
  "Throw away unsaved changes in the current queue buffer.
Called when a write fails part-way, so a half-written item is never
saved and never mistaken for a human's unsaved edit."
  (if (and (buffer-file-name) (file-exists-p (buffer-file-name)))
      (revert-buffer t t t)
    (erase-buffer)
    (set-buffer-modified-p nil)))

(defmacro agent-shell-crew--with-queue (root &rest body)
  "Run BODY in the queue buffer for ROOT, then save it.
Creates the file and its header when missing.  Refuses when the buffer
has unsaved edits, so a hand edit is never silently written over."
  (declare (indent 1) (debug t))
  `(let ((file (agent-shell-crew-queue-file ,root)))
     (make-directory (file-name-directory file) t)
     (with-current-buffer (let ((find-file-hook nil)) (find-file-noselect file t))
       (agent-shell-crew--sync-with-disk)
       (when (buffer-modified-p)
         (agent-shell-crew--fail "%s has unsaved edits; save or revert it first" file))
       (unless (derived-mode-p 'org-mode) (org-mode))
       (agent-shell-crew--ensure-header ,root)
       (prog1 (condition-case err
                  (save-excursion (save-restriction (widen) ,@body))
                (error (agent-shell-crew--discard-changes)
                       (signal (car err) (cdr err))))
         (when (buffer-modified-p)
           (let ((save-silently t)) (save-buffer)))))))

(defun agent-shell-crew--changed (root id verb)
  "Run `agent-shell-crew-changed-hook' for ROOT, ID and VERB.
The write is already saved, so a failing hook function is reported and
never turned into an error for the caller."
  (condition-case err
      (run-hook-with-args 'agent-shell-crew-changed-hook root id verb)
    (error (message "agent-shell-crew: changed-hook failed: %s" (error-message-string err)))))

(defun agent-shell-crew--new-id ()
  "Return a fresh item id."
  (format "c-%s-%04x" (format-time-string "%m%d-%H%M%S") (random 65536)))

(defun agent-shell-crew--now ()
  "Return an inactive Org timestamp for now."
  (format-time-string "[%Y-%m-%d %a %H:%M]"))

(defun agent-shell-crew--goto (id)
  "Move to the heading of item ID in the current buffer."
  (let ((pos (org-find-property "CREW_ID" id)))
    (unless pos (agent-shell-crew--fail "No crew item %s" id))
    (goto-char pos)
    (org-back-to-heading t)))

(defun agent-shell-crew--log (format-string &rest args)
  "Append a timestamped log line built from FORMAT-STRING and ARGS.
Point must be inside the item; the Log child is its last child.
Point does not move, so the item can still be read afterwards."
  (save-excursion
    (org-back-to-heading t)
    (org-end-of-subtree t t)
    (unless (bolp) (insert "\n"))
    (insert (format "- %s %s\n" (agent-shell-crew--now) (apply #'format format-string args)))))

(defun agent-shell-crew--clean-line (text)
  "Collapse TEXT onto one trimmed line."
  (string-trim (replace-regexp-in-string "[\n\r\t ]+" " " (or text ""))))

(defun agent-shell-crew--escape-body (text)
  "Keep TEXT inside an item: indent any line that starts with a star."
  (replace-regexp-in-string "^\\*" " *" (string-trim-right text)))

(defun agent-shell-crew--put-outcome (status branch)
  "Record STATUS and BRANCH on the item at point when they are non-blank.
STATUS is one sentence on where the work stands and whether it worked;
BRANCH is its git branch.  Blank values leave what was there."
  (unless (agent-shell-crew--blank-p status)
    (org-entry-put nil "STATUS" (agent-shell-crew--clean-line status)))
  (unless (agent-shell-crew--blank-p branch)
    (org-entry-put nil "BRANCH" (agent-shell-crew--clean-line branch))))

(defun agent-shell-crew--blank-p (value)
  "Non-nil when VALUE is nil or a blank string."
  (or (null value) (and (stringp value) (string-empty-p (string-trim value)))))

(cl-defun agent-shell-crew-queue-create (root actor &key title brief owner evidence ref parent
                                              status branch)
  "Create an item in ROOT's queue on behalf of ACTOR and return its id.
TITLE and OWNER are required.  BRIEF, EVIDENCE, REF, PARENT, STATUS and
BRANCH are optional strings."
  (when (agent-shell-crew--blank-p title) (agent-shell-crew--fail "An item needs a title"))
  (when (agent-shell-crew--blank-p owner) (agent-shell-crew--fail "An item needs an owner"))
  (let (id)
    (agent-shell-crew--with-queue root
      ;; The suffix is random, so a clash within one second is possible;
      ;; this buffer is the only writer, so checking here makes it unique.
      (setq id (agent-shell-crew--new-id))
      (while (org-find-property "CREW_ID" id)
        (setq id (agent-shell-crew--new-id)))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* PENDING %s :crew:\n" (agent-shell-crew--clean-line title)))
      (forward-line -1)
      (org-entry-put nil "CREW_ID" id)
      (org-entry-put nil "OWNER" owner)
      (org-entry-put nil "FROM" actor)
      (unless (agent-shell-crew--blank-p parent) (org-entry-put nil "PARENT" parent))
      (unless (agent-shell-crew--blank-p evidence)
        (org-entry-put nil "EVIDENCE" (agent-shell-crew--clean-line evidence)))
      (unless (agent-shell-crew--blank-p ref)
        (org-entry-put nil "REF" (agent-shell-crew--clean-line ref)))
      (agent-shell-crew--put-outcome status branch)
      (org-end-of-subtree t t)
      (unless (bolp) (insert "\n"))
      (unless (agent-shell-crew--blank-p brief)
        (insert (agent-shell-crew--escape-body brief) "\n"))
      (insert "** Log\n")
      (agent-shell-crew--goto id)
      (agent-shell-crew--log "created by %s for %s" actor owner))
    (agent-shell-crew--changed root id 'create)
    id))

(defun agent-shell-crew--read-item ()
  "Return the item at point as a plist."
  (org-back-to-heading t)
  (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
         (log-heading (save-excursion
                        (when (re-search-forward "^\\*\\* Log[ \t]*$" end t)
                          (line-beginning-position))))
         (body-start (save-excursion (org-end-of-meta-data t) (point)))
         (body-end (or log-heading end))
         (log (when log-heading
                (save-excursion
                  (goto-char log-heading)
                  (forward-line 1)
                  (let (lines)
                    (while (re-search-forward "^- \\(.*\\)$" end t)
                      (push (match-string-no-properties 1) lines))
                    (nreverse lines))))))
    (list :id (org-entry-get nil "CREW_ID")
          :title (org-get-heading t t t t)
          :state (org-get-todo-state)
          :owner (org-entry-get nil "OWNER")
          :from (org-entry-get nil "FROM")
          :parent (org-entry-get nil "PARENT")
          :evidence (org-entry-get nil "EVIDENCE")
          :ref (org-entry-get nil "REF")
          :status (org-entry-get nil "STATUS")
          :branch (org-entry-get nil "BRANCH")
          :question (org-entry-get nil "QUESTION")
          :decision (org-entry-get nil "DECISION")
          :brief (string-trim (buffer-substring-no-properties
                               (min body-start body-end) body-end))
          :log log)))

(defun agent-shell-crew-queue-get (root id)
  "Return item ID from ROOT's queue as a plist."
  (agent-shell-crew--with-queue root
    (agent-shell-crew--goto id)
    (agent-shell-crew--read-item)))

(defun agent-shell-crew-queue-list (root &optional owner)
  "Return ROOT's items in file order, only OWNER's when OWNER is non-nil."
  (let ((items (agent-shell-crew--with-queue root
                 (let (acc)
                   (org-map-entries
                    (lambda ()
                      (when (org-entry-get nil "CREW_ID")
                        (push (agent-shell-crew--read-item) acc)))
                    "LEVEL=1")
                   (nreverse acc)))))
    (if owner
        (seq-filter (lambda (item) (equal (plist-get item :owner) owner)) items)
      items)))

(defmacro agent-shell-crew--mutate (root id verb &rest body)
  "Run BODY at item ID in ROOT's queue, then run the hook with VERB."
  (declare (indent 3) (debug t))
  `(prog1 (agent-shell-crew--with-queue ,root
            (agent-shell-crew--goto ,id)
            ,@body)
     (agent-shell-crew--changed ,root ,id ,verb)))

(defun agent-shell-crew--require-owner (actor)
  "Fail unless ACTOR owns the item at point."
  (let ((owner (org-entry-get nil "OWNER")))
    (unless (equal owner actor)
      (agent-shell-crew--fail "%s does not own %s (owner: %s)"
                              actor (org-entry-get nil "CREW_ID") owner))))

(defun agent-shell-crew--require-state (&rest states)
  "Fail unless the item at point is in one of STATES."
  (let ((state (org-get-todo-state)))
    (unless (member state states)
      (agent-shell-crew--fail "%s is %s; this needs %s"
                              (org-entry-get nil "CREW_ID") state
                              (string-join states " or ")))))

(defun agent-shell-crew--set-state (state)
  "Set the item at point to STATE without the user's TODO side effects."
  (org-back-to-heading t)
  (let ((org-loop-over-headlines-in-active-region nil)
        (mark-active nil)
        (org-inhibit-logging t)
        (org-todo-log-states nil)
        (org-log-done nil)
        (org-after-todo-state-change-hook nil)
        (org-trigger-hook nil)
        (org-blocker-hook nil))
    (org-todo state)))

(defun agent-shell-crew-queue-claim (root actor id)
  "ACTOR claims item ID in ROOT's queue: PENDING to ACTIVE."
  (agent-shell-crew--mutate root id 'claim
    (agent-shell-crew--require-owner actor)
    (agent-shell-crew--require-state "PENDING")
    (agent-shell-crew--set-state "ACTIVE")
    (agent-shell-crew--log "claimed by %s" actor)))

(defun agent-shell-crew-queue-note (root actor id text)
  "Append TEXT to item ID's log in ROOT's queue on behalf of ACTOR.
Only the owner or the human may add notes."
  (when (agent-shell-crew--blank-p text) (agent-shell-crew--fail "A note needs text"))
  (agent-shell-crew--mutate root id 'note
    (unless (equal actor "human") (agent-shell-crew--require-owner actor))
    (agent-shell-crew--log "note by %s: %s" actor (agent-shell-crew--clean-line text))))

(defun agent-shell-crew-queue-set-status (root actor id status)
  "ACTOR rewrites the one-sentence STATUS of item ID in ROOT's queue.
Only the owner or the human may; the change is logged with the old text."
  (when (agent-shell-crew--blank-p status) (agent-shell-crew--fail "A status needs text"))
  (agent-shell-crew--mutate root id 'status
    (unless (equal actor "human") (agent-shell-crew--require-owner actor))
    (agent-shell-crew--log "status by %s: %s" actor (agent-shell-crew--clean-line status))
    (agent-shell-crew--put-outcome status nil)))

(defun agent-shell-crew-queue-stage (root actor id stage evidence &optional status)
  "ACTOR records that item ID in ROOT's queue has reached STAGE.
EVIDENCE says how it is known; STATUS is as for
`agent-shell-crew--put-outcome'.  Only the owner or the human may: a
member records what it did, the human records what they saw.  Works in
any state, since stages such as \"deployed\" come after an item closes."
  (when (agent-shell-crew--blank-p stage) (agent-shell-crew--fail "A stage needs a name"))
  (when (agent-shell-crew--blank-p evidence) (agent-shell-crew--fail "A stage needs evidence"))
  (agent-shell-crew--mutate root id 'stage
    (unless (equal actor "human") (agent-shell-crew--require-owner actor))
    (agent-shell-crew--log "stage %s by %s: %s" (agent-shell-crew--clean-line stage) actor
                           (agent-shell-crew--clean-line evidence))
    (agent-shell-crew--put-outcome status nil)))

(defun agent-shell-crew-queue-set-branch (root actor id branch)
  "ACTOR records BRANCH as the git branch of item ID in ROOT's queue.
Only the owner or the human may."
  (when (agent-shell-crew--blank-p branch) (agent-shell-crew--fail "A branch needs a name"))
  (agent-shell-crew--mutate root id 'branch
    (unless (equal actor "human") (agent-shell-crew--require-owner actor))
    (agent-shell-crew--log "branch by %s: %s" actor (agent-shell-crew--clean-line branch))
    (agent-shell-crew--put-outcome nil branch)))

(defun agent-shell-crew-queue-park (root actor id question &optional evidence status)
  "ACTOR parks item ID in ROOT's queue on the human with QUESTION.
EVIDENCE, when non-blank, replaces the item's evidence.  STATUS is as for
`agent-shell-crew--put-outcome'."
  (when (agent-shell-crew--blank-p question) (agent-shell-crew--fail "Parking needs a question"))
  (agent-shell-crew--mutate root id 'park
    (agent-shell-crew--require-owner actor)
    (agent-shell-crew--require-state "ACTIVE")
    (org-entry-put nil "QUESTION" (agent-shell-crew--clean-line question))
    (agent-shell-crew--put-outcome status nil)
    (unless (agent-shell-crew--blank-p evidence)
      (org-entry-put nil "EVIDENCE" (agent-shell-crew--clean-line evidence)))
    (agent-shell-crew--set-state "PARKED")
    (agent-shell-crew--log "parked on human by %s: %s" actor (agent-shell-crew--clean-line question))))

(defun agent-shell-crew-queue-decide (root id decision)
  "Record the human's DECISION on parked item ID in ROOT's queue.
Returns the item's owner, who should be told."
  (when (agent-shell-crew--blank-p decision) (agent-shell-crew--fail "A decision needs text"))
  (agent-shell-crew--mutate root id 'decide
    (agent-shell-crew--require-state "PARKED")
    (org-entry-put nil "DECISION" (agent-shell-crew--clean-line decision))
    (agent-shell-crew--set-state "ACTIVE")
    (agent-shell-crew--log "decided by human: %s" (agent-shell-crew--clean-line decision))
    (org-entry-get nil "OWNER")))

(defun agent-shell-crew-queue-done (root actor id reason &optional canceled status branch)
  "ACTOR closes item ID in ROOT's queue for REASON.
The item becomes CANCELED when CANCELED is non-nil, DONE otherwise.
STATUS and BRANCH are as for `agent-shell-crew--put-outcome'."
  (agent-shell-crew--mutate root id 'done
    (agent-shell-crew--require-owner actor)
    (agent-shell-crew--require-state "PENDING" "ACTIVE")
    (agent-shell-crew--set-state (if canceled "CANCELED" "DONE"))
    (agent-shell-crew--put-outcome status branch)
    (agent-shell-crew--log "%s by %s: %s" (if canceled "canceled" "done") actor
                           (if (agent-shell-crew--blank-p reason) "-"
                             (agent-shell-crew--clean-line reason)))))

(defun agent-shell-crew-queue-handoff (root actor id to summary &optional brief status branch)
  "ACTOR hands item ID in ROOT's queue to TO with SUMMARY and BRIEF.
Closes ID as HANDED and returns the id of the new item TO owns, which
inherits the ref, the branch and the status.  STATUS and BRANCH are as
for `agent-shell-crew--put-outcome'."
  (when (agent-shell-crew--blank-p to) (agent-shell-crew--fail "A hand-off needs a recipient"))
  (when (equal to actor) (agent-shell-crew--fail "%s cannot hand off to itself" actor))
  (when (agent-shell-crew--blank-p summary) (agent-shell-crew--fail "A hand-off needs a summary"))
  (let ((source (agent-shell-crew--mutate root id 'handoff
                  (agent-shell-crew--require-owner actor)
                  (agent-shell-crew--require-state "ACTIVE")
                  (agent-shell-crew--set-state "HANDED")
                  (agent-shell-crew--put-outcome status branch)
                  (agent-shell-crew--log "handed to %s: %s" to (agent-shell-crew--clean-line summary))
                  (agent-shell-crew--read-item))))
    (agent-shell-crew-queue-create
     root actor
     :title (plist-get source :title)
     :owner to
     :parent id
     :evidence (plist-get source :evidence)
     :ref (plist-get source :ref)
     :status (plist-get source :status)
     :branch (plist-get source :branch)
     :brief (concat "Handed off by " actor ": " summary
                    (if (agent-shell-crew--blank-p brief) "" (concat "\n\n" brief))))))

(defun agent-shell-crew--file-root (file)
  "Return the project root recorded in queue FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (when (re-search-forward "^#\\+CREW_ROOT: \\(.+\\)$" nil t)
      (match-string-no-properties 1))))

(defun agent-shell-crew--queue-file-root (file)
  "Return FILE's project root when FILE is that project's queue, else nil.
Lock files, sync-conflict copies and anything else in the directory
fail this test, so they are never counted as queues."
  (condition-case nil
      (when (and (file-regular-p file)
                 (not (string-prefix-p ".#" (file-name-nondirectory file))))
        (when-let* ((root (agent-shell-crew--file-root file))
                    ((equal (expand-file-name file) (agent-shell-crew-queue-file root))))
          root))
    (error nil)))

(defun agent-shell-crew--file-items (file)
  "Return the items in queue FILE, read from disk without visiting it."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((org-inhibit-startup t) (org-mode-hook nil)) (org-mode))
    (let (acc)
      (org-map-entries
       (lambda () (when (org-entry-get nil "CREW_ID") (push (agent-shell-crew--read-item) acc)))
       "LEVEL=1")
      (nreverse acc))))

(defun agent-shell-crew-parked ()
  "Return every PARKED item in every project as (ROOT . ITEM) pairs.
Reads the files on disk, so an unsaved hand edit in any queue buffer
never breaks it."
  (when (file-directory-p agent-shell-crew-directory)
    (apply #'append
           (mapcar
            (lambda (file)
              (when-let* ((root (agent-shell-crew--queue-file-root file)))
                (mapcar (lambda (item) (cons root item))
                        (seq-filter (lambda (item) (equal (plist-get item :state) "PARKED"))
                                    (agent-shell-crew--file-items file)))))
            (directory-files agent-shell-crew-directory t "\\.org\\'")))))

(provide 'agent-shell-crew-queue)
;;; agent-shell-crew-queue.el ends here
