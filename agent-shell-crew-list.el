;;; agent-shell-crew-list.el --- One view of a crew: members, status and work -*- lexical-binding: t; -*-

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

;; `agent-shell-crew-list' shows a project's crew in one buffer: every
;; member with its live session status (from `agent-shell-status', the
;; same source agent-shell uses) next to the items it owns and their
;; state, plus items waiting on the human.  RET goes to a member's
;; session, d answers a parked item, n creates one, o opens the queue
;; file, g refreshes.  It refreshes itself when the queue changes or a
;; member's status may have changed -- no timer.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'agent-shell-crew)

(defconst agent-shell-crew-list--status-labels
  '((working "◐" "working")
    (blocked "◉" "blocked")
    (ready "●" "ready")
    (not-running "○" "not running"))
  "Icon and label for each member status.")

(defvar-local agent-shell-crew-list--root nil
  "The project root this list shows.")

(defun agent-shell-crew-list--member-status (member root)
  "Return MEMBER's status in ROOT's crew as a symbol."
  (let ((buffer (agent-shell-crew--member-buffer member root)))
    (if (not buffer)
        'not-running
      (pcase (condition-case nil (agent-shell-status :shell-buffer buffer) (error nil))
        ('busy 'working)
        ('blocked 'blocked)
        (_ 'ready)))))

(defun agent-shell-crew-list--open-p (item)
  "Non-nil when ITEM still needs someone."
  (member (plist-get item :state) '("PENDING" "ACTIVE" "PARKED")))

(defun agent-shell-crew-list--rows (root)
  "Return the rows for ROOT's crew as plists (:member :status :item).
One row per open item, and one for each member who owns none; the
human's items last.  Items owned by a name that is no longer a role are
kept, so nothing open is hidden."
  (let* ((items (seq-filter #'agent-shell-crew-list--open-p (agent-shell-crew-queue-list root)))
         (members (append (remove "human" (agent-shell-crew-members root)) (list "human")))
         rows)
    (dolist (member members)
      (let ((status (unless (equal member "human")
                      (agent-shell-crew-list--member-status member root)))
            (owned (seq-filter (lambda (item) (equal (plist-get item :owner) member)) items)))
        (if owned
            (dolist (item owned) (push (list :member member :status status :item item) rows))
          (unless (equal member "human")
            (push (list :member member :status status :item nil) rows)))))
    (dolist (item items)
      (unless (member (plist-get item :owner) members)
        (push (list :member (plist-get item :owner) :status nil :item item) rows)))
    (nreverse rows)))

(defun agent-shell-crew-list--closed-count (root)
  "Return how many of ROOT's items are closed."
  (seq-count (lambda (item) (not (agent-shell-crew-list--open-p item)))
             (agent-shell-crew-queue-list root)))

(defun agent-shell-crew-list--entry (row)
  "Return the `tabulated-list-entries' element for ROW."
  (let* ((item (plist-get row :item))
         (state (plist-get item :state))
         (label (assq (plist-get row :status) agent-shell-crew-list--status-labels))
         (urgent (or (equal state "PARKED") (eq (plist-get row :status) 'blocked))))
    (list row
          (vector (or (nth 1 label) " ")
                  (plist-get row :member)
                  (let ((text (or (nth 2 label) "")))
                    (if (eq (plist-get row :status) 'blocked) (propertize text 'face 'warning) text))
                  (if state (propertize state 'face (if urgent 'warning 'default)) "—")
                  (concat (or (plist-get item :title) "")
                          (if (equal state "PARKED") (propertize "  ← decide" 'face 'warning) ""))
                  (or (plist-get item :id) "")))))

(defun agent-shell-crew-list--refresh ()
  "Recompute the current list's rows."
  (when agent-shell-crew-list--root
    (setq tabulated-list-entries
          (mapcar #'agent-shell-crew-list--entry (agent-shell-crew-list--rows agent-shell-crew-list--root)))
    (setq mode-line-process
          (format " %d closed" (agent-shell-crew-list--closed-count agent-shell-crew-list--root)))))

(defvar-keymap agent-shell-crew-list-mode-map
  :parent tabulated-list-mode-map
  "RET" #'agent-shell-crew-list-goto
  "d" #'agent-shell-crew-list-decide
  "n" #'agent-shell-crew-list-new
  "o" #'agent-shell-crew-list-open)

(define-derived-mode agent-shell-crew-list-mode tabulated-list-mode "Crew"
  "Major mode listing a crew's members, their status and their work.
\\{agent-shell-crew-list-mode-map}"
  (setq tabulated-list-format
        [("" 1 nil) ("Member" 26 t) ("Status" 12 t) ("State" 8 t) ("Item" 44 nil) ("Id" 20 nil)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'agent-shell-crew-list--refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-shell-crew-list (root)
  "Show the crew of the project at ROOT: members, status and work.
Returns the list buffer."
  (interactive (list (read-directory-name "Crew for directory: " (agent-shell-crew--default-root))))
  (let* ((root (agent-shell-crew--normal-root root))
         (buffer (get-buffer-create (format "*crew: %s*" (agent-shell-crew-project-name root)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-crew-list-mode) (agent-shell-crew-list-mode))
      (setq agent-shell-crew-list--root root)
      (agent-shell-crew-list--refresh)
      (tabulated-list-print t))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    buffer))

(defun agent-shell-crew-list--row-at-point ()
  "Return the row at point, or fail."
  (or (tabulated-list-get-id) (user-error "No crew row here")))

(defun agent-shell-crew-list-goto ()
  "Go to the session of the member on this row."
  (interactive)
  (let* ((row (agent-shell-crew-list--row-at-point))
         (member (plist-get row :member))
         (buffer (and (not (equal member "human"))
                      (agent-shell-crew--member-buffer member agent-shell-crew-list--root))))
    (if buffer
        (pop-to-buffer buffer)
      (user-error "%s has no running session; M-x agent-shell-crew-start" member))))

(defun agent-shell-crew-list-decide ()
  "Answer the parked item on this row."
  (interactive)
  (let ((item (plist-get (agent-shell-crew-list--row-at-point) :item)))
    (unless (equal (plist-get item :state) "PARKED")
      (user-error "Nothing on this row is waiting for a decision"))
    (agent-shell-crew-decide-item agent-shell-crew-list--root (plist-get item :id))))

(defun agent-shell-crew-list-new ()
  "Create an item for this list's crew."
  (interactive)
  (let ((default-directory agent-shell-crew-list--root))
    (call-interactively #'agent-shell-crew-new)))

(defun agent-shell-crew-list-open ()
  "Open this list's queue file."
  (interactive)
  (agent-shell-crew-open agent-shell-crew-list--root))

(defun agent-shell-crew-list--refresh-root (root &rest _)
  "Refresh every crew list showing ROOT."
  (let ((root (agent-shell-crew--normal-root root)))
    (dolist (buffer (buffer-list))
      (when (and (eq (buffer-local-value 'major-mode buffer) 'agent-shell-crew-list-mode)
                 (equal (buffer-local-value 'agent-shell-crew-list--root buffer) root))
        (with-current-buffer buffer
          (agent-shell-crew-list--refresh)
          (tabulated-list-print t))))))

(add-hook 'agent-shell-crew-changed-hook #'agent-shell-crew-list--refresh-root)
(add-hook 'agent-shell-crew-session-changed-hook #'agent-shell-crew-list--refresh-root)

(provide 'agent-shell-crew-list)
;;; agent-shell-crew-list.el ends here
