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

(defcustom agent-shell-crew-stages nil
  "Stages a crew's work passes after it merges, unless its profile sets `:stages'.
Each is a plist:
  :name   the stage, e.g. \"deployed\" or \"live-checked\";
  :owner  who moves work through it: a member name or \"human\" (default);
  :check  optional: a shell command, run in the crew root, that prints the
          commit the stage has reached -- or a function of ROOT returning
          one.  A piece of work has reached the stage when its commit is an
          ancestor of that one.  Checks run in the background and are cached
          for `agent-shell-crew-check-minutes'; nothing waits on them.
Without :check, a stage is reached when someone records it (`crew_stage',
or `s' on the board).  Stages show; they never act."
  :type '(repeat plist)
  :group 'agent-shell-crew)

(defcustom agent-shell-crew-check-minutes 5
  "How long a stage check's answer is trusted before it runs again."
  :type 'number
  :group 'agent-shell-crew)

(defun agent-shell-crew-board--stages (root)
  "Return the stages of ROOT's crew."
  (or (seq-some (lambda (profile) (plist-get (cdr profile) :stages))
                (agent-shell-crew--profiles-for-root root))
      agent-shell-crew-stages))

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
  "The first sentence of ITEM's latest log line, without its time and author.
Bookkeeping lines -- a branch or status being set -- say nothing about
the work, so the latest line that is not one of those."
  (when-let* ((line (seq-find (lambda (l) (not (string-match-p "\\] \\(?:branch\\|status\\) by " l)))
                              (reverse (plist-get item :log)))))
    (agent-shell-crew-board--first-sentence
     (string-trim
      (replace-regexp-in-string "\\`\\[[^]]*\\] \\(?:[^:]*: \\)?" "" line)))))

(defun agent-shell-crew-board--git (root &rest args)
  "Run git ARGS in ROOT; return its exit status, or nil without git."
  (let ((default-directory root))
    (condition-case nil (apply #'process-file "git" nil nil nil args) (error nil))))

(defun agent-shell-crew-board--git-out (root &rest args)
  "Run git ARGS in ROOT; return its trimmed output, or nil on failure."
  (let ((default-directory root))
    (ignore-errors
      (with-temp-buffer
        (when (eql 0 (apply #'process-file "git" nil t nil args))
          (let ((out (string-trim (buffer-string))))
            (unless (string-empty-p out) out)))))))

(defun agent-shell-crew-board--merged-commit (root branch trunk)
  "Where BRANCH stands against TRUNK in ROOT's repository, as (STATE . SHA).
STATE is `yes', `no' or `unknown'; SHA is the commit that carries the
work onto TRUNK when it is known.  A branch deleted after it merged is
found by the merge commit naming it, which is the common case: a merged
branch is the first thing anyone cleans up."
  (if-let* ((tip (agent-shell-crew-board--git-out root "rev-parse" "--verify" "--quiet"
                                                  (concat branch "^{commit}"))))
      (cons (if (eql 0 (agent-shell-crew-board--git root "merge-base" "--is-ancestor" tip trunk))
                'yes 'no)
            tip)
    (if-let* ((merge (agent-shell-crew-board--git-out
                      root "log" trunk "--merges" "-1" "--format=%H" "--fixed-strings"
                      (format "--grep=Merge branch '%s'" branch))))
        (cons 'yes merge)
      (cons 'unknown nil))))

(defun agent-shell-crew-board--merged (root branch trunk)
  "Has BRANCH reached TRUNK in ROOT's repository: `yes', `no' or `unknown'."
  (car (agent-shell-crew-board--merged-commit root branch trunk)))

;;; Stage checks, in the background

(defvar agent-shell-crew-board--checks nil
  "Alist of ((ROOT . STAGE) TIME . COMMIT): each check's last answer.")

(defvar agent-shell-crew-board--running nil
  "The (ROOT . STAGE) checks running now.")

(defun agent-shell-crew-board--store (key commit)
  "Remember COMMIT as the answer for check KEY, and refresh what shows it."
  (setf (alist-get key agent-shell-crew-board--checks nil nil #'equal) (cons (current-time) commit))
  (setq agent-shell-crew-board--running (delete key agent-shell-crew-board--running))
  (agent-shell-crew-board--recompute (car key))
  (agent-shell-crew-board--refresh-root (car key)))

(defun agent-shell-crew-board--check (root stage)
  "The commit STAGE of ROOT's crew has reached, as last known, or nil.
Starts the check in the background when its answer is missing or stale;
never waits for it."
  (let* ((key (cons root (plist-get stage :name)))
         (hit (alist-get key agent-shell-crew-board--checks nil nil #'equal))
         (check (plist-get stage :check)))
    (when (and check
               (not (member key agent-shell-crew-board--running))
               (or (not hit)
                   (> (float-time (time-subtract nil (car hit)))
                      (* 60 agent-shell-crew-check-minutes))))
      (push key agent-shell-crew-board--running)
      (if (functionp check)
          (run-with-idle-timer
           0 nil (lambda ()
                   (agent-shell-crew-board--store
                    key (condition-case nil (funcall check root) (error nil)))))
        (let ((default-directory root)
              (out (generate-new-buffer " *crew stage check*")))
          (condition-case nil
              (make-process
               :name "crew-stage-check" :buffer out :noquery t
               :command (list shell-file-name shell-command-switch check)
               :sentinel (lambda (proc _event)
                           (unless (process-live-p proc)
                             (let ((commit (and (eql 0 (process-exit-status proc))
                                                (with-current-buffer out
                                                  (car (split-string (buffer-string)))))))
                               (kill-buffer out)
                               (agent-shell-crew-board--store key commit)))))
            (error (kill-buffer out) (agent-shell-crew-board--store key nil))))))
    (cdr hit)))

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
              (status (seq-some (lambda (i) (plist-get i :status)) (reverse members)))
              (recorded (delete-dups
                         (mapcan (lambda (i)
                                   (delq nil (mapcar (lambda (line)
                                                       (and (string-match "\\] stage \\([^ ]+\\) by " line)
                                                            (match-string 1 line)))
                                                     (plist-get i :log))))
                                 members))))
         (list :ref key
               :title (plist-get latest :title)
               :state (plist-get latest :state)
               :owner (plist-get latest :owner)
               :id (plist-get latest :id)
               :branch (seq-some (lambda (i) (plist-get i :branch)) (reverse members))
               :status status
               :recorded recorded
               :fallback (and (not status) (agent-shell-crew-board--event-text latest)))))
     order)))

(defvar-local agent-shell-crew-board--root nil
  "The project root this board shows.")

(defun agent-shell-crew-board--progress (root row trunk stages)
  "ROW's progress in ROOT: (MERGED . STAGE-STATES), one symbol per stage.
MERGED is `yes', `no', `unknown' or `none' (no branch).  Each stage is
`yes', `no', `pending' (its check has not answered), `unknown', or
`none' when the piece records no branch and nothing was recorded."
  (let* ((branch (plist-get row :branch))
         (merged (if branch (agent-shell-crew-board--merged-commit root branch trunk) '(none)))
         (sha (cdr merged)))
    (cons (car merged)
          (mapcar
           (lambda (stage)
             (cond
              ((member (plist-get stage :name) (plist-get row :recorded)) 'yes)
              ((eq (car merged) 'none) 'none)
              ((not (plist-get stage :check)) 'no)
              ((not sha) 'unknown)
              (t (let ((commit (agent-shell-crew-board--check root stage)))
                   (cond ((not commit)
                          (if (member (cons root (plist-get stage :name))
                                      agent-shell-crew-board--running)
                              'pending 'unknown))
                         ((eql 0 (agent-shell-crew-board--git root "merge-base" "--is-ancestor"
                                                              sha commit))
                          'yes)
                         (t 'no))))))
           stages))))

(defun agent-shell-crew-board--mark (state)
  "The board's mark for progress STATE."
  (pcase state
    ('yes (propertize "✓" 'face 'success))
    ('no "—")
    ('pending "…")
    ('unknown "?")
    (_ "")))

(defun agent-shell-crew-board--entry (row progress)
  "Return the `tabulated-list-entries' element for ROW with its PROGRESS."
  (let ((state (or (plist-get row :state) "")))
    (list row
          (vconcat
           (vector (or (plist-get row :ref) "")
                   (propertize state 'face (pcase state
                                             ("PARKED" 'warning)
                                             ((or "DONE" "HANDED") 'success)
                                             ("CANCELED" 'shadow)
                                             (_ 'default)))
                   (agent-shell-crew-board--mark (car progress)))
           (mapcar #'agent-shell-crew-board--mark (cdr progress))
           (vector (or (plist-get row :title) "")
                   (if (plist-get row :status)
                       (plist-get row :status)
                     (propertize (or (plist-get row :fallback) "") 'face 'shadow)))))))

(defun agent-shell-crew-board--housekeeping-p (row)
  "Non-nil when ROW is closed and has no ref: a slate, a note, a one-off."
  (and (equal (plist-get row :ref) (plist-get row :id))
       (member (plist-get row :state) '("DONE" "CANCELED" "HANDED"))))

;;; What waits on the human

(defvar agent-shell-crew-board--waiting nil
  "Alist of (ROOT TIME . WAITING), WAITING a list of (REF . STAGE).")

(defun agent-shell-crew-board--waiting-in (root rows-progress stages)
  "The (REF . STAGE) pairs in ROWS-PROGRESS of ROOT waiting on the human.
A piece waits at the first stage it has not reached, once it has merged,
when the human owns that stage."
  (ignore root)
  (delq nil
        (mapcar (lambda (rp)
                  (let ((row (car rp)) (progress (cdr rp)))
                    (when (eq (car progress) 'yes)
                      (let ((i (seq-position (cdr progress) 'yes (lambda (a b) (not (eq a b))))))
                        (when-let* ((stage (and i (nth i stages))))
                          (when (and (equal (or (plist-get stage :owner) "human") "human")
                                     (eq (nth i (cdr progress)) 'no))
                            (cons (plist-get row :ref) (plist-get stage :name))))))))
                rows-progress)))

(defun agent-shell-crew-board--recompute (root)
  "Recompute what in ROOT's crew waits on the human, and remember it."
  (condition-case nil
      (let* ((stages (agent-shell-crew-board--stages root))
             (trunk (agent-shell-crew-board--trunk root))
             (rows (seq-remove #'agent-shell-crew-board--housekeeping-p
                               (agent-shell-crew-board--rows root)))
             (rp (mapcar (lambda (row)
                           (cons row (agent-shell-crew-board--progress root row trunk stages)))
                         rows)))
        (setf (alist-get root agent-shell-crew-board--waiting nil nil #'equal)
              (cons (current-time) (agent-shell-crew-board--waiting-in root rp stages)))
        rp)
    (error nil)))

(defun agent-shell-crew-board-waiting (root)
  "What in ROOT's crew waits on the human at a stage, as last computed.
Cheap enough for a status bar: recomputes on an idle timer once its
answer is older than `agent-shell-crew-check-minutes'."
  (let ((hit (alist-get root agent-shell-crew-board--waiting nil nil #'equal)))
    (when (or (not hit)
              (> (float-time (time-subtract nil (car hit))) (* 60 agent-shell-crew-check-minutes)))
      (setf (alist-get root agent-shell-crew-board--waiting nil nil #'equal)
            (cons (current-time) (cdr hit)))
      (run-with-idle-timer 2 nil #'agent-shell-crew-board--recompute root))
    (cdr hit)))

(defvar-local agent-shell-crew-board--all nil
  "Non-nil when this board also shows housekeeping rows.")

(defun agent-shell-crew-board--format (stages)
  "The `tabulated-list-format' for a board with STAGES."
  (vconcat [("Ref" 10 t) ("State" 9 t) ("Merged" 7 t)]
           (mapcar (lambda (st) (let ((n (plist-get st :name))) (list n (max 7 (1+ (length n))) t)))
                   stages)
           [("Title" 40 t) ("Status" 0 nil)]))

(defun agent-shell-crew-board--refresh ()
  "Recompute the current board's rows."
  (when agent-shell-crew-board--root
    (let* ((root agent-shell-crew-board--root)
           (stages (agent-shell-crew-board--stages root))
           (trunk (agent-shell-crew-board--trunk root))
           (rows (agent-shell-crew-board--rows root))
           (shown (if agent-shell-crew-board--all rows
                    (seq-remove #'agent-shell-crew-board--housekeeping-p rows)))
           (rp (mapcar (lambda (row)
                         (cons row (agent-shell-crew-board--progress root row trunk stages)))
                       shown)))
      (setf (alist-get root agent-shell-crew-board--waiting nil nil #'equal)
            (cons (current-time)
                  (agent-shell-crew-board--waiting-in
                   root (seq-remove (lambda (x) (agent-shell-crew-board--housekeeping-p (car x))) rp)
                   stages)))
      (setq tabulated-list-format (agent-shell-crew-board--format stages))
      (tabulated-list-init-header)
      (setq tabulated-list-entries
            (mapcar (lambda (x) (agent-shell-crew-board--entry (car x) (cdr x))) rp))
      (setq mode-line-process
            (format " trunk:%s%s" trunk
                    (if agent-shell-crew-board--all ""
                      (format "  (%d housekeeping hidden; a shows)"
                              (- (length rows) (length shown)))))))))

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

(defun agent-shell-crew-board-record-stage ()
  "Record, as the human, that this row's work reached a stage."
  (interactive)
  (let* ((row (agent-shell-crew-board--row-at-point))
         (names (mapcar (lambda (st) (plist-get st :name))
                        (agent-shell-crew-board--stages agent-shell-crew-board--root)))
         (stage (if names (completing-read "Stage reached: " names nil t)
                  (user-error "This crew declares no stages")))
         (evidence (read-string (format "How do you know %s reached %s? " (plist-get row :ref) stage))))
    (agent-shell-crew-queue-stage agent-shell-crew-board--root "human" (plist-get row :id) stage evidence)
    (revert-buffer)))

(defun agent-shell-crew-board-set-branch ()
  "Record this row's git branch."
  (interactive)
  (let ((row (agent-shell-crew-board--row-at-point)))
    (agent-shell-crew-queue-set-branch agent-shell-crew-board--root "human" (plist-get row :id)
                                       (read-string "Branch: " (plist-get row :branch)))
    (revert-buffer)))

(defun agent-shell-crew-board-toggle-all ()
  "Show or hide closed rows with no ref."
  (interactive)
  (setq agent-shell-crew-board--all (not agent-shell-crew-board--all))
  (revert-buffer))

(defvar-keymap agent-shell-crew-board-mode-map
  :parent tabulated-list-mode-map
  "RET" #'agent-shell-crew-board-show
  "e" #'agent-shell-crew-board-edit-status
  "s" #'agent-shell-crew-board-record-stage
  "b" #'agent-shell-crew-board-set-branch
  "a" #'agent-shell-crew-board-toggle-all)

(define-derived-mode agent-shell-crew-board-mode tabulated-list-mode "Crew board"
  "Major mode showing where each piece of a crew's work stands.
\\{agent-shell-crew-board-mode-map}"
  (setq tabulated-list-format (agent-shell-crew-board--format nil))
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
(defvar agent-shell-crew-waiting-function)
(setq agent-shell-crew-waiting-function #'agent-shell-crew-board-waiting)

(provide 'agent-shell-crew-board)
;;; agent-shell-crew-board.el ends here
