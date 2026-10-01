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
    (stuck "◌" "stuck")
    (ready "●" "ready")
    (not-running "○" "not running"))
  "Icon and label for each member status.")

(defvar-local agent-shell-crew-list--root nil
  "The project root this list shows.")

(defun agent-shell-crew-list--member-status (member root)
  "Return MEMBER's status in ROOT's crew as a symbol."
  (let ((buffer (agent-shell-crew--member-buffer member root)))
    (cond
     ((not buffer) 'not-running)
     ((agent-shell-crew--member-stuck buffer) 'stuck)
     (t
      (pcase (condition-case nil (agent-shell-status :shell-buffer buffer) (error nil))
        ('busy 'working)
        ('blocked 'blocked)
        (_ 'ready))))))

(defun agent-shell-crew-list--open-p (item)
  "Non-nil when ITEM still needs someone."
  (member (plist-get item :state) '("PENDING" "ACTIVE" "PARKED")))

(defun agent-shell-crew-list--rows (root &optional all-items)
  "Return the rows for ROOT's crew as plists (:member :status :item).
One row per open item, and one for each member who owns none; the
human's items last.  Items owned by a name that is no longer a role are
kept, so nothing open is hidden.  ALL-ITEMS, when given, is ROOT's
queue as already read, so a caller on a timer need not reread it."
  (let* ((items (seq-filter #'agent-shell-crew-list--open-p
                            (or all-items (agent-shell-crew-queue-list root))))
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
  (interactive (list (agent-shell-crew--read-root "Crew: ")))
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

;;; Health: one dot for the whole crew

(defface agent-shell-crew-health-working '((t :foreground "#4caf50"))
  "Face of the health dot when the crew is working and nothing is stuck."
  :group 'agent-shell-crew)

(defface agent-shell-crew-health-attention '((t :inherit warning))
  "Face of the health dot when something waits on you."
  :group 'agent-shell-crew)

(defface agent-shell-crew-health-stalled '((t :inherit error))
  "Face of the health dot when open work is not moving."
  :group 'agent-shell-crew)

(defface agent-shell-crew-health-idle '((t :inherit shadow))
  "Face of the health dot when the crew is running and has nothing open."
  :group 'agent-shell-crew)

(defconst agent-shell-crew--health-rank '(stalled attention working idle)
  "Health states, worst first.")

(defvar agent-shell-crew-waiting-function nil
  "Function of ROOT returning the (REF . STAGE) pairs waiting on the human.
Set by `agent-shell-crew-board' when it loads; nil means no stages.")

(defun agent-shell-crew-health (root &optional all-items)
  "Return the health of ROOT's crew as (STATE . REASON).
STATE is, worst first:
  `stalled'   a member is stuck (see `agent-shell-crew--member-stuck'),
              an open item's owner is not running, or there is open
              work and no member is working;
  `attention' something waits on the human: a parked item, an item the
              human owns, a member blocked on a prompt, or -- when no
              member is working -- merged work at a stage the human owns;
  `working'   at least one member is working and nothing above holds;
  `idle'      members are running and nothing is open.
REASON is one line saying why.  ALL-ITEMS is as for
`agent-shell-crew-list--rows'."
  (let* ((rows (agent-shell-crew-list--rows root all-items))
         (stuck (seq-filter (lambda (r) (eq (plist-get r :status) 'stuck)) rows))
         (open (seq-filter (lambda (r) (plist-get r :item)) rows))
         (member-rows (seq-remove (lambda (r) (equal (plist-get r :member) "human")) rows))
         (status-of (lambda (name)
                      (plist-get (seq-find (lambda (r) (equal (plist-get r :member) name)) member-rows)
                                 :status)))
         (working (delete-dups (mapcar (lambda (r) (plist-get r :member))
                                       (seq-filter (lambda (r) (eq (plist-get r :status) 'working))
                                                   member-rows))))
         (blocked (delete-dups (mapcar (lambda (r) (plist-get r :member))
                                       (seq-filter (lambda (r) (eq (plist-get r :status) 'blocked))
                                                   member-rows))))
         (orphaned (seq-filter (lambda (r)
                                 (let ((owner (plist-get r :member)))
                                   (and (not (equal owner "human"))
                                        (memq (funcall status-of owner) '(not-running nil)))))
                               open))
         (yours (seq-filter (lambda (r)
                              (or (equal (plist-get (plist-get r :item) :state) "PARKED")
                                  (equal (plist-get r :member) "human")))
                            open))
         (crew-work (seq-remove (lambda (r) (equal (plist-get r :member) "human")) open))
         (title (lambda (r) (plist-get (plist-get r :item) :title)))
         (at-stage (and agent-shell-crew-waiting-function
                        (ignore-errors (funcall agent-shell-crew-waiting-function root)))))
    (cond
     (stuck
      (let* ((name (plist-get (car stuck) :member))
             (buffer (agent-shell-crew--member-buffer name root)))
        (cons 'stalled (format "%s %s" name (or (and buffer (agent-shell-crew--member-stuck buffer))
                                                 "is stuck")))))
     (orphaned
      (cons 'stalled (format "%s is owned by %s, which is not running"
                             (funcall title (car orphaned)) (plist-get (car orphaned) :member))))
     ((and crew-work (not working) (not blocked) (not yours))
      (cons 'stalled (format "%d open item%s and no member is working"
                             (length crew-work) (if (cdr crew-work) "s" ""))))
     ((or yours blocked)
      (cons 'attention
            (string-join
             (delq nil (list (and yours (format "%d waiting on you" (length yours)))
                             (and blocked (format "%s blocked" (string-join blocked ", ")))))
             "; ")))
     ((and at-stage (not working))
      (cons 'attention
            (format "%d waiting on you at a stage: %s"
                    (length at-stage)
                    (mapconcat (lambda (w) (format "%s %s" (car w) (cdr w))) at-stage ", "))))
     (working
      (cons 'working (format "%s working" (string-join working ", "))))
     (t (cons 'idle "running, nothing open")))))

(defvar agent-shell-crew--health-cache nil
  "Alist of (ROOT MTIME . ITEMS): each queue as last read, by file time.")

(defun agent-shell-crew--cached-items (root)
  "ROOT's queue items, reread only when its file has changed."
  (let* ((file (agent-shell-crew-queue-file root))
         (mtime (file-attribute-modification-time (file-attributes file)))
         (hit (assoc root agent-shell-crew--health-cache)))
    (if (and hit (equal (cadr hit) mtime))
        (cddr hit)
      (let ((items (and mtime (agent-shell-crew-queue-list root))))
        (setf (alist-get root agent-shell-crew--health-cache nil nil #'equal)
              (cons mtime items))
        items))))

(declare-function agent-shell-crew-board "agent-shell-crew-board")

(defun agent-shell-crew--open-board (root)
  "Open the board for ROOT's crew: the overview the dot stands for."
  (require 'agent-shell-crew-board)
  (agent-shell-crew-board root))

;;;###autoload
(defun agent-shell-crew-status-segment ()
  "A dot for every running crew's worst health, or nil when none runs.
For a status bar: the queue is reread only when its file changes, so
calling this every few seconds costs a stat per crew.  Hovering names
the reason; clicking opens the board.  Never signals."
  (condition-case nil
      (when-let* ((roots (agent-shell-crew--running-roots)))
        (let* ((healths (mapcar (lambda (root)
                                  (cons root (agent-shell-crew-health
                                              root (agent-shell-crew--cached-items root))))
                                roots))
               (worst (car (seq-sort-by (lambda (h) (seq-position agent-shell-crew--health-rank
                                                                   (cadr h)))
                                        #'< healths)))
               (state (cadr worst))
               (map (make-sparse-keymap)))
          (define-key map [tab-bar mouse-1]
                      (lambda () (interactive) (agent-shell-crew--open-board (car worst))))
          (define-key map [mode-line mouse-1]
                      (lambda () (interactive) (agent-shell-crew--open-board (car worst))))
          (propertize "●"
                      'face (intern (format "agent-shell-crew-health-%s" state))
                      'help-echo (mapconcat (lambda (h)
                                              (format "crew %s: %s"
                                                      (agent-shell-crew-project-name (car h))
                                                      (cddr h)))
                                            healths "\n")
                      'local-map map
                      'mouse-face 'highlight)))
    (error nil)))

(provide 'agent-shell-crew-list)
;;; agent-shell-crew-list.el ends here
