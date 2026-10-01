;;; agent-shell-crew-board.el --- Where each piece of crew work stands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson

;; Author: Scott Whitson <scott@scottwhitson.com>

;; This file is not part of GNU Emacs.

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

;; `agent-shell-crew-board' shows one row per piece of work -- every item
;; sharing a ref is one piece, an item without one is its own -- with its
;; current state, whether its branch has reached the crew's trunk, and the
;; one sentence its owner last wrote on where it stands.  The crew list shows
;; who is doing what now; the board shows what got done.  See docs/design.md,
;; "The board".

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'agent-shell-crew)

(defcustom agent-shell-crew-trunk "main"
  "The branch a crew's work is merged into, unless its profile sets `:trunk'."
  :type 'string
  :group 'agent-shell-crew)

(defun agent-shell-crew-board--trunk (root)
  "Return the trunk branch for ROOT's crew."
  (or (seq-some (lambda (profile) (plist-get (cdr profile) :trunk))
                (agent-shell-crew--profiles-for-root root))
      agent-shell-crew-trunk))

(defun agent-shell-crew-board--first-sentence (text)
  "The first sentence of TEXT: up to the first full stop followed by a space.
A member's reason runs to a paragraph; a board row has room for one."
  (if (string-match "\\`\\(.+?[.!?]\\)\\(?: \\|\\'\\)" text)
      (match-string 1 text)
    text))

(defun agent-shell-crew-board--event-text (item)
  "The first sentence of ITEM's latest log line, without its time and author."
  (when-let* ((line (car (last (plist-get item :log)))))
    (agent-shell-crew-board--first-sentence
     (string-trim
      (replace-regexp-in-string "\\`\\[[^]]*\\] \\(?:[^:]*: \\)?" "" line)))))

(defun agent-shell-crew-board--git (root &rest args)
  "Run git ARGS in ROOT; return its exit status, or nil without git."
  (let ((default-directory root))
    (condition-case nil (apply #'process-file "git" nil nil nil args) (error nil))))

(defun agent-shell-crew-board--merged (root branch trunk)
  "Has BRANCH reached TRUNK in ROOT's repository?
Returns `yes', `no' or `unknown'.  A branch deleted after it merged is
found by the merge commit naming it, which is the common case: a merged
branch is the first thing anyone cleans up."
  (cond
   ((eql 0 (agent-shell-crew-board--git root "rev-parse" "--verify" "--quiet"
                                        (concat branch "^{commit}")))
    (if (eql 0 (agent-shell-crew-board--git root "merge-base" "--is-ancestor" branch trunk))
        'yes 'no))
   ((let ((default-directory root))
      (ignore-errors
        (with-temp-buffer
          (and (eql 0 (process-file "git" nil t nil "log" trunk "--merges" "--format=%s"
                                    "--fixed-strings" (format "--grep=Merge branch '%s'" branch)))
               (> (buffer-size) 0)))))
    'yes)
   (t 'unknown)))

(defun agent-shell-crew-board--rows (root &optional items)
  "Return ROOT's board rows as plists, most recently created piece first.
ITEMS, when given, is ROOT's queue as already read."
  (let ((groups nil) (order nil))
    (dolist (item (or items (agent-shell-crew-queue-list root)))
      (let ((key (or (plist-get item :ref) (plist-get item :id))))
        (unless (assoc key groups) (push key order))
        (setf (alist-get key groups nil nil #'equal)
              (append (alist-get key groups nil nil #'equal) (list item)))))
    (mapcar
     (lambda (key)
       (let* ((members (alist-get key groups nil nil #'equal))
              (latest (car (last members)))
              (status (seq-some (lambda (i) (plist-get i :status)) (reverse members))))
         (list :ref key
               :title (plist-get latest :title)
               :state (plist-get latest :state)
               :owner (plist-get latest :owner)
               :id (plist-get latest :id)
               :branch (seq-some (lambda (i) (plist-get i :branch)) (reverse members))
               :status status
               :fallback (and (not status) (agent-shell-crew-board--event-text latest)))))
     order)))

(defvar-local agent-shell-crew-board--root nil
  "The project root this board shows.")

(defun agent-shell-crew-board--entry (row trunk)
  "Return the `tabulated-list-entries' element for ROW, merged into TRUNK."
  (let* ((branch (plist-get row :branch))
         (merged (if branch (agent-shell-crew-board--merged agent-shell-crew-board--root branch trunk)
                   'none))
         (state (or (plist-get row :state) "")))
    (list row
          (vector (or (plist-get row :ref) "")
                  (propertize state 'face (pcase state
                                            ("PARKED" 'warning)
                                            ((or "DONE" "HANDED") 'success)
                                            ("CANCELED" 'shadow)
                                            (_ 'default)))
                  (pcase merged ('yes (propertize "✓" 'face 'success)) ('no "—") ('unknown "?") (_ ""))
                  (or (plist-get row :title) "")
                  (if (plist-get row :status)
                      (plist-get row :status)
                    (propertize (or (plist-get row :fallback) "") 'face 'shadow))))))

(defun agent-shell-crew-board--refresh ()
  "Recompute the current board's rows."
  (when agent-shell-crew-board--root
    (let ((trunk (agent-shell-crew-board--trunk agent-shell-crew-board--root)))
      (setq tabulated-list-entries
            (mapcar (lambda (row) (agent-shell-crew-board--entry row trunk))
                    (agent-shell-crew-board--rows agent-shell-crew-board--root)))
      (setq mode-line-process (format " trunk:%s" trunk)))))

(defun agent-shell-crew-board--row-at-point ()
  "Return the board row at point, or signal."
  (or (tabulated-list-get-id) (user-error "No piece of work here")))

(defun agent-shell-crew-board-show ()
  "Open the queue file at this row's latest item."
  (interactive)
  (let ((row (agent-shell-crew-board--row-at-point)))
    (find-file (agent-shell-crew-queue-file agent-shell-crew-board--root))
    (goto-char (or (org-find-property "CREW_ID" (plist-get row :id)) (point-min)))
    (org-fold-show-subtree)))

(defun agent-shell-crew-board-edit-status ()
  "Rewrite this row's one-sentence status."
  (interactive)
  (let* ((row (agent-shell-crew-board--row-at-point))
         (text (read-string "Status (one sentence): "
                            (or (plist-get row :status) (plist-get row :fallback)))))
    (agent-shell-crew-queue-set-status agent-shell-crew-board--root "human" (plist-get row :id) text)
    (revert-buffer)))

(defvar-keymap agent-shell-crew-board-mode-map
  :parent tabulated-list-mode-map
  "RET" #'agent-shell-crew-board-show
  "e" #'agent-shell-crew-board-edit-status)

(define-derived-mode agent-shell-crew-board-mode tabulated-list-mode "Crew board"
  "Major mode showing where each piece of a crew's work stands.
\\{agent-shell-crew-board-mode-map}"
  (setq tabulated-list-format
        [("Ref" 10 t) ("State" 9 t) ("Merged" 7 t) ("Title" 40 t) ("Status" 0 nil)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'agent-shell-crew-board--refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-shell-crew-board (root)
  "Show where each piece of the crew's work at ROOT stands.
Returns the board buffer."
  (interactive (list (agent-shell-crew--read-root "Crew: ")))
  (let* ((root (agent-shell-crew--normal-root root))
         (buffer (get-buffer-create
                  (format "*crew board: %s*" (agent-shell-crew-project-name root)))))
    (with-current-buffer buffer
      (agent-shell-crew-board-mode)
      (setq agent-shell-crew-board--root root)
      (agent-shell-crew-board--refresh)
      (tabulated-list-print))
    (pop-to-buffer buffer)
    buffer))

(defun agent-shell-crew-board--refresh-root (root &rest _)
  "Refresh every board showing ROOT."
  (let ((root (agent-shell-crew--normal-root root)))
    (dolist (buffer (buffer-list))
      (when (and (eq (buffer-local-value 'major-mode buffer) 'agent-shell-crew-board-mode)
                 (equal (buffer-local-value 'agent-shell-crew-board--root buffer) root))
        (with-current-buffer buffer
          (agent-shell-crew-board--refresh)
          (tabulated-list-print t))))))

(add-hook 'agent-shell-crew-changed-hook #'agent-shell-crew-board--refresh-root)

(provide 'agent-shell-crew-board)
;;; agent-shell-crew-board.el ends here
