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
  "Return the queue file for the project at ROOT."
  (expand-file-name (concat (agent-shell-crew-project-name root) ".org")
                    agent-shell-crew-directory))

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
       (prog1 (save-excursion (save-restriction (widen) ,@body))
         (when (buffer-modified-p)
           (let ((save-silently t)) (save-buffer)))))))

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
Point must be inside the item; the Log child is its last child."
  (org-back-to-heading t)
  (org-end-of-subtree t t)
  (unless (bolp) (insert "\n"))
  (insert (format "- %s %s\n" (agent-shell-crew--now) (apply #'format format-string args))))

(defun agent-shell-crew--clean-line (text)
  "Collapse TEXT onto one trimmed line."
  (string-trim (replace-regexp-in-string "[\n\r\t ]+" " " (or text ""))))

(defun agent-shell-crew--escape-body (text)
  "Keep TEXT inside an item: indent any line that starts with a star."
  (replace-regexp-in-string "^\\*" " *" (string-trim-right text)))

(defun agent-shell-crew--blank-p (value)
  "Non-nil when VALUE is nil or a blank string."
  (or (null value) (and (stringp value) (string-empty-p (string-trim value)))))

(cl-defun agent-shell-crew-queue-create (root actor &key title brief owner evidence ref parent)
  "Create an item in ROOT's queue on behalf of ACTOR and return its id.
TITLE and OWNER are required.  BRIEF, EVIDENCE, REF and PARENT are
optional strings."
  (when (agent-shell-crew--blank-p title) (agent-shell-crew--fail "An item needs a title"))
  (when (agent-shell-crew--blank-p owner) (agent-shell-crew--fail "An item needs an owner"))
  (let ((id (agent-shell-crew--new-id)))
    (agent-shell-crew--with-queue root
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* PENDING %s :crew:\n" (agent-shell-crew--clean-line title)))
      (forward-line -1)
      (org-entry-put nil "CREW_ID" id)
      (org-entry-put nil "OWNER" owner)
      (org-entry-put nil "FROM" actor)
      (unless (agent-shell-crew--blank-p parent) (org-entry-put nil "PARENT" parent))
      (unless (agent-shell-crew--blank-p evidence) (org-entry-put nil "EVIDENCE" evidence))
      (unless (agent-shell-crew--blank-p ref) (org-entry-put nil "REF" ref))
      (org-end-of-subtree t t)
      (unless (bolp) (insert "\n"))
      (unless (agent-shell-crew--blank-p brief)
        (insert (agent-shell-crew--escape-body brief) "\n"))
      (insert "** Log\n")
      (agent-shell-crew--goto id)
      (agent-shell-crew--log "created by %s for %s" actor owner))
    (run-hook-with-args 'agent-shell-crew-changed-hook root id 'create)
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

(provide 'agent-shell-crew-queue)
;;; agent-shell-crew-queue.el ends here
