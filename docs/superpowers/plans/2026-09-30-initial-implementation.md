# agent-shell-crew Initial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build agent-shell-crew 0.1.0 — a per-project Org work queue, an MCP tool that gives each agent-shell session typed access to it under its own identity, crew session startup with nudges, and the human commands — as a standalone, MELPA-shaped Emacs package.

**Architecture:** Three Emacs Lisp files split by responsibility — `agent-shell-crew-queue.el` (the Org file; no agent-shell dependency), `agent-shell-crew-rpc.el` (one base64-JSON entry point for the MCP program), `agent-shell-crew.el` (sessions, nudges, commands, mode-line) — plus `bin/agent-shell-crew-mcp`, a standard-library Python MCP server that forwards each tool call to Emacs through `emacsclient`. Tests run hermetically against stub agent-shell features; a separate API check runs against the real agent-shell.

**Tech Stack:** Emacs Lisp (Org, ERT, checkdoc), Python 3 standard library (`unittest`), GNU Make.

**Spec:** `docs/design.md`

## Global Constraints

- Nothing personal in the package: no user paths, hosts, repositories, theme or tab-bar assumptions. Everything site-specific is a setting with a default.
- Depends only on Emacs, agent-shell, and `python3`.
- Every public symbol is prefixed `agent-shell-crew-`; internal ones `agent-shell-crew--`.
- GPLv3-or-later; every `.el` file has the standard header, `lexical-binding: t`, and passes `byte-compile-error-on-warn` and `checkdoc` with no messages.
- Only Emacs writes a queue file. The acting agent is always taken from the MCP process environment (`CREW_AGENT`), never from a tool argument.
- State is the Org TODO keyword: `#+TODO: PENDING ACTIVE PARKED | DONE HANDED CANCELED`. The log is append-only.
- One owner per item; a hand-off closes the item `HANDED` and creates a linked item (`:PARENT:`).
- Member names are `ROLE@PROJECT`; `human` is the human.
- A nudge is never typed into a busy session or into a session whose input is non-empty.
- `agent-shell-crew-rpc` never signals; it always returns base64-encoded JSON.

## Review Focus

1. **The queue file changed on disk while Emacs has it open** (hand edit elsewhere, or a sync) — expected: the change is kept, not overwritten; an unsaved hand edit in the buffer makes the operation refuse with a clear message. Pinned in Task 1 (`crew-queue-keeps-external-edits`, `crew-queue-refuses-unsaved-buffer`).
2. **A brief whose lines start with `*`** — expected: stays inside the item; never becomes a new heading. Pinned in Task 1 (`crew-queue-brief-stars-stay-inside`).
3. **Non-ASCII and quotes through the MCP path** (emoji, CJK, curly and straight quotes, backslashes) — expected: round-trip byte-exact. Pinned in Task 3 (`crew-rpc-unicode-round-trip`) and Task 4 (`test_unicode_arguments_pass_through`).
4. **Many items created within one second** — expected: every id distinct. Pinned in Task 1 (`crew-queue-ids-distinct`).
5. **Deciding an item whose owner session is not running** — expected: the decision is recorded, no error; the owner learns of it at its next start. Pinned in Task 6 (`crew-decide-owner-not-running`).

---

## File Structure

| File | Responsibility |
|---|---|
| `agent-shell-crew-queue.el` | Queue files: create, read, list, transitions, `agent-shell-crew-parked`, `agent-shell-crew-changed-hook`. Requires only `org`. |
| `agent-shell-crew-rpc.el` | `agent-shell-crew-rpc`: decode, validate, dispatch to the queue, encode. Knows nothing of agent-shell; notification and membership come in through two function variables. |
| `agent-shell-crew.el` | Package entry: settings, roles, `agent-shell-crew-start`, nudges, human commands, `agent-shell-crew-mode-line-mode`. Requires agent-shell. |
| `bin/agent-shell-crew-mcp` | Python MCP server over stdio. |
| `briefs/{lead,owner,check}.md` | Generic role briefs. |
| `test/stubs/agent-shell.el`, `test/stubs/agent-shell-anthropic.el` | Minimal stand-ins so tests run without agent-shell. |
| `test/agent-shell-crew-*-test.el`, `test/test_mcp.py` | Tests. |
| `test/agent-shell-crew-api-test.el` | Guard against the real agent-shell (run by `make api-check`). |
| `test/checkdoc.el` | Fails the build on any checkdoc message. |
| `Makefile`, `README.md`, `LICENSE`, `.gitignore` | Packaging. |

---

### Task 1: Scaffold and the queue file (create, read, list)

**Files:**
- Create: `LICENSE`, `.gitignore`, `Makefile`, `test/checkdoc.el`, `agent-shell-crew-queue.el`
- Test: `test/agent-shell-crew-queue-test.el`

**Interfaces:**
- Produces: `agent-shell-crew-directory` (defcustom, directory); `agent-shell-crew-changed-hook` (called with ROOT ID VERB-symbol); error symbol `agent-shell-crew-error`; `(agent-shell-crew-project-name ROOT)` → string; `(agent-shell-crew-queue-file ROOT)` → file name; `(agent-shell-crew-queue-create ROOT ACTOR &key TITLE BRIEF OWNER EVIDENCE REF PARENT)` → id string; `(agent-shell-crew-queue-get ROOT ID)` → item plist `(:id :title :state :owner :from :parent :evidence :ref :question :decision :brief :log)`; `(agent-shell-crew-queue-list ROOT &optional OWNER)` → list of item plists; internal `agent-shell-crew--with-queue`, `agent-shell-crew--goto`, `agent-shell-crew--log`, `agent-shell-crew--fail`.

- [ ] **Step 1: Scaffold**

```bash
cd ~/projects/agent-shell-crew
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o LICENSE
printf '*.elc\n__pycache__/\n.superpowers/\n' > .gitignore
mkdir -p test/stubs bin briefs
```

`Makefile`:

```make
EMACS  ?= emacs
PYTHON ?= python3
# Where agent-shell and its dependencies live. The default is the stubs, so
# `make check' runs anywhere; point it at the real packages for `api-check'.
DEPS   ?= -L test/stubs
EL      = agent-shell-crew-queue.el agent-shell-crew-rpc.el agent-shell-crew.el
TESTS   = $(wildcard test/agent-shell-crew-*-test.el)
UNIT    = $(filter-out test/agent-shell-crew-api-test.el,$(TESTS))

.PHONY: check compile checkdoc test api-check clean

check: compile checkdoc test

compile:
	$(EMACS) -Q --batch -L . $(DEPS) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard $(EL))

checkdoc:
	$(EMACS) -Q --batch -L . $(DEPS) -l test/checkdoc.el $(wildcard $(EL))

test:
	$(EMACS) -Q --batch -L . $(DEPS) -l ert \
	  $(foreach t,$(UNIT),-l $(t)) -f ert-run-tests-batch-and-exit
	$(PYTHON) -m unittest discover -s test -p 'test_*.py'

api-check:
	$(EMACS) -Q --batch -L . $(DEPS) -l ert \
	  -l test/agent-shell-crew-api-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
```

`test/checkdoc.el`:

```elisp
;;; checkdoc.el --- Fail on any checkdoc message -*- lexical-binding: t; -*-
;;; Commentary:
;; Usage: emacs -Q --batch -l test/checkdoc.el FILE...
;;; Code:
(require 'checkdoc)
(let ((failed nil))
  (dolist (file command-line-args-left)
    (let ((checkdoc-diagnostic-buffer "*checkdoc*"))
      (with-current-buffer (get-buffer-create "*checkdoc*") (erase-buffer))
      (checkdoc-file file)
      (with-current-buffer "*checkdoc*"
        (goto-char (point-min))
        (when (re-search-forward "^[^ \n].*:[0-9]+:" nil t)
          (setq failed t)
          (princ (buffer-string))))))
  (setq command-line-args-left nil)
  (kill-emacs (if failed 1 0)))
;;; checkdoc.el ends here
```

- [ ] **Step 2: Write the failing tests** — `test/agent-shell-crew-queue-test.el`:

```elisp
;;; agent-shell-crew-queue-test.el --- Queue tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Hermetic: every test gets its own queue directory and project root.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-crew-queue)

(defmacro crew-test--with-project (root &rest body)
  "Bind ROOT to a fresh project directory and run BODY with a fresh queue directory."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-q" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (agent-shell-crew-changed-hook nil))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p agent-shell-crew-directory (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(ert-deftest crew-queue-create-then-get ()
  (crew-test--with-project root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "Do the thing"
                                              :brief "Details here." :owner "owner@x"
                                              :evidence "notes/a.md" :ref "T-1"))
           (item (agent-shell-crew-queue-get root id)))
      (should (string-match-p "\\`c-[0-9]\\{4\\}-[0-9]\\{6\\}-[0-9a-f]\\{4\\}\\'" id))
      (should (equal (plist-get item :title) "Do the thing"))
      (should (equal (plist-get item :state) "PENDING"))
      (should (equal (plist-get item :owner) "owner@x"))
      (should (equal (plist-get item :from) "human"))
      (should (equal (plist-get item :evidence) "notes/a.md"))
      (should (equal (plist-get item :ref) "T-1"))
      (should (equal (plist-get item :brief) "Details here."))
      (should (= (length (plist-get item :log)) 1))
      (should (string-match-p "created by human for owner@x" (car (plist-get item :log)))))))

(ert-deftest crew-queue-file-header ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@x")
    (let ((text (with-temp-buffer (insert-file-contents (agent-shell-crew-queue-file root))
                                  (buffer-string))))
      (should (string-match-p "^#\\+TODO: PENDING ACTIVE PARKED | DONE HANDED CANCELED$" text))
      (should (string-match-p (concat "^#\\+CREW_ROOT: " (regexp-quote root) "$") text))
      (should (string-match-p "^\\* PENDING T +:crew:$" text)))))

(ert-deftest crew-queue-list-and-filter ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "owner@x")
    (agent-shell-crew-queue-create root "human" :title "B" :owner "check@x")
    (should (equal (mapcar (lambda (i) (plist-get i :title)) (agent-shell-crew-queue-list root))
                   '("A" "B")))
    (should (equal (mapcar (lambda (i) (plist-get i :title))
                           (agent-shell-crew-queue-list root "check@x"))
                   '("B")))))

(ert-deftest crew-queue-requires-title-and-owner ()
  (crew-test--with-project root
    (should-error (agent-shell-crew-queue-create root "human" :title " " :owner "o@x")
                  :type 'agent-shell-crew-error)
    (should-error (agent-shell-crew-queue-create root "human" :title "T" :owner "")
                  :type 'agent-shell-crew-error)))

(ert-deftest crew-queue-unknown-id ()
  (crew-test--with-project root
    (should-error (agent-shell-crew-queue-get root "c-0000-000000-0000")
                  :type 'agent-shell-crew-error)))

(ert-deftest crew-queue-ids-distinct ()
  (crew-test--with-project root
    (let ((ids (cl-loop repeat 50 collect
                        (agent-shell-crew-queue-create root "human" :title "T" :owner "o@x"))))
      (should (= (length (delete-dups (copy-sequence ids))) 50)))))

(ert-deftest crew-queue-brief-stars-stay-inside ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "T" :owner "o@x"
                                   :brief "first\n* not a heading\n** nor this")
    (should (= (length (agent-shell-crew-queue-list root)) 1))))

(ert-deftest crew-queue-title-newlines-collapse ()
  (crew-test--with-project root
    (let ((id (agent-shell-crew-queue-create root "human" :title "one\ntwo" :owner "o@x")))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :title) "one two")))))

(ert-deftest crew-queue-hook-runs ()
  (crew-test--with-project root
    (let* ((seen nil)
           (agent-shell-crew-changed-hook (list (lambda (r i v) (push (list r i v) seen))))
           (id (agent-shell-crew-queue-create root "human" :title "T" :owner "o@x")))
      (should (equal seen (list (list root id 'create)))))))

(ert-deftest crew-queue-keeps-external-edits ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "o@x")
    (let ((file (agent-shell-crew-queue-file root)))
      (write-region "\n* PENDING Added elsewhere :crew:\n:PROPERTIES:\n:CREW_ID: c-9999-999999-ffff\n:OWNER: o@x\n:END:\n** Log\n"
                    nil file t)
      (set-file-times file (time-add nil 5))
      (agent-shell-crew-queue-create root "human" :title "B" :owner "o@x")
      (should (equal (mapcar (lambda (i) (plist-get i :title)) (agent-shell-crew-queue-list root))
                     '("A" "Added elsewhere" "B"))))))

(ert-deftest crew-queue-refuses-unsaved-buffer ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "o@x")
    (with-current-buffer (find-file-noselect (agent-shell-crew-queue-file root))
      (goto-char (point-max))
      (insert "hand edit, not saved\n"))
    (should-error (agent-shell-crew-queue-create root "human" :title "B" :owner "o@x")
                  :type 'agent-shell-crew-error)))

(provide 'agent-shell-crew-queue-test)
;;; agent-shell-crew-queue-test.el ends here
```

- [ ] **Step 3: Run to verify it fails**

Run: `make test 2>&1 | tail -3`
Expected: FAIL — `Cannot open load file ... agent-shell-crew-queue`.

- [ ] **Step 4: Implement** — `agent-shell-crew-queue.el`:

```elisp
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
     (with-current-buffer (let ((find-file-hook nil)) (find-file-noselect file))
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `make compile checkdoc test 2>&1 | tail -5`
Expected: compile and checkdoc silent; `Ran 11 tests, 11 results as expected`; Python `Ran 0 tests` (no Python tests yet — `OK`).

- [ ] **Step 6: Commit**

```bash
git add LICENSE .gitignore Makefile test/checkdoc.el agent-shell-crew-queue.el test/agent-shell-crew-queue-test.el
git commit -m "queue: one Org file per project, items created and read back"
```

### Task 2: Queue transitions and `agent-shell-crew-parked`

**Files:**
- Modify: `agent-shell-crew-queue.el` (before `(provide …)`)
- Test: `test/agent-shell-crew-queue-test.el` (append before `(provide …)`)

**Interfaces:**
- Consumes: Task 1's internals.
- Produces: `(agent-shell-crew-queue-claim ROOT ACTOR ID)`; `(agent-shell-crew-queue-note ROOT ACTOR ID TEXT)`; `(agent-shell-crew-queue-park ROOT ACTOR ID QUESTION &optional EVIDENCE)`; `(agent-shell-crew-queue-decide ROOT ID DECISION)` → owner string; `(agent-shell-crew-queue-done ROOT ACTOR ID REASON &optional CANCELED)`; `(agent-shell-crew-queue-handoff ROOT ACTOR ID TO SUMMARY &optional BRIEF)` → new id; `(agent-shell-crew-parked)` → list of `(ROOT . ITEM)`. Each mutation runs `agent-shell-crew-changed-hook` with verb `claim`/`note`/`park`/`decide`/`done`/`handoff`.

- [ ] **Step 1: Write the failing tests**

```elisp
(defun crew-test--new (root &optional owner)
  "Create a PENDING item in ROOT for OWNER (default owner@x) and return its id."
  (agent-shell-crew-queue-create root "human" :title "T" :owner (or owner "owner@x")))

(ert-deftest crew-queue-claim ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :state) "ACTIVE"))
      (should-error (agent-shell-crew-queue-claim root "owner@x" id) :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-only-owner-acts ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (should-error (agent-shell-crew-queue-claim root "check@x" id) :type 'agent-shell-crew-error)
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should-error (agent-shell-crew-queue-park root "check@x" id "Q?") :type 'agent-shell-crew-error)
      (should-error (agent-shell-crew-queue-done root "check@x" id "r") :type 'agent-shell-crew-error)
      (should-error (agent-shell-crew-queue-handoff root "check@x" id "human" "s")
                    :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-note-appends ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (agent-shell-crew-queue-note root "owner@x" id "looked at it")
      (agent-shell-crew-queue-note root "human" id "fine by me")
      (let ((log (plist-get (agent-shell-crew-queue-get root id) :log)))
        (should (= (length log) 3))
        (should (string-match-p "note by owner@x: looked at it" (nth 1 log)))
        (should (string-match-p "note by human: fine by me" (nth 2 log)))))))

(ert-deftest crew-queue-park-and-decide ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should-error (agent-shell-crew-queue-park root "owner@x" id "  ") :type 'agent-shell-crew-error)
      (agent-shell-crew-queue-park root "owner@x" id "Pick: (1) a; (2) b" "notes/q.md")
      (let ((item (agent-shell-crew-queue-get root id)))
        (should (equal (plist-get item :state) "PARKED"))
        (should (equal (plist-get item :question) "Pick: (1) a; (2) b"))
        (should (equal (plist-get item :evidence) "notes/q.md")))
      (should (equal (agent-shell-crew-queue-decide root id "1 — a") "owner@x"))
      (let ((item (agent-shell-crew-queue-get root id)))
        (should (equal (plist-get item :state) "ACTIVE"))
        (should (equal (plist-get item :decision) "1 — a"))
        (should (string-match-p "decided by human: 1 — a" (car (last (plist-get item :log))))))
      (should-error (agent-shell-crew-queue-decide root id "again") :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-done-and-canceled ()
  (crew-test--with-project root
    (let ((a (crew-test--new root)) (b (crew-test--new root)))
      (agent-shell-crew-queue-claim root "owner@x" a)
      (agent-shell-crew-queue-done root "owner@x" a "shipped")
      (agent-shell-crew-queue-done root "owner@x" b "not needed" t)
      (should (equal (plist-get (agent-shell-crew-queue-get root a) :state) "DONE"))
      (should (equal (plist-get (agent-shell-crew-queue-get root b) :state) "CANCELED"))
      (should-error (agent-shell-crew-queue-done root "owner@x" a "twice") :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-handoff-links ()
  (crew-test--with-project root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "Build it" :owner "owner@x"
                                              :evidence "e.md" :ref "T-2")))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should-error (agent-shell-crew-queue-handoff root "owner@x" id "owner@x" "self")
                    :type 'agent-shell-crew-error)
      (let* ((new (agent-shell-crew-queue-handoff root "owner@x" id "check@x" "built; please verify"
                                                  "Run the tests."))
             (old (agent-shell-crew-queue-get root id))
             (item (agent-shell-crew-queue-get root new)))
        (should (equal (plist-get old :state) "HANDED"))
        (should (string-match-p "handed to check@x: built; please verify"
                                (car (last (plist-get old :log)))))
        (should (equal (plist-get item :owner) "check@x"))
        (should (equal (plist-get item :from) "owner@x"))
        (should (equal (plist-get item :parent) id))
        (should (equal (plist-get item :title) "Build it"))
        (should (equal (plist-get item :evidence) "e.md"))
        (should (equal (plist-get item :ref) "T-2"))
        (should (string-match-p "built; please verify" (plist-get item :brief)))
        (should (string-match-p "Run the tests." (plist-get item :brief)))))))

(ert-deftest crew-queue-log-only-grows ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)) (counts nil))
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (agent-shell-crew-queue-claim root "owner@x" id)
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (agent-shell-crew-queue-park root "owner@x" id "Q?")
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (agent-shell-crew-queue-decide root id "yes")
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (should (equal (nreverse counts) '(1 2 3 4))))))

(ert-deftest crew-queue-parked-across-projects ()
  (crew-test--with-project root
    (let* ((other (let ((d (expand-file-name "other-app/" (make-temp-file "crew-root" t))))
                    (make-directory d t) d))
           (a (crew-test--new root)) (b (crew-test--new other)))
      (dolist (pair (list (cons root a) (cons other b)))
        (agent-shell-crew-queue-claim (car pair) "owner@x" (cdr pair))
        (agent-shell-crew-queue-park (car pair) "owner@x" (cdr pair) "Q?"))
      (let ((parked (agent-shell-crew-parked)))
        (should (= (length parked) 2))
        (should (member root (mapcar #'car parked)))
        (should (member other (mapcar #'car parked)))))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E '^Ran|void-function' | head -3`
Expected: FAIL — `void-function agent-shell-crew-queue-claim`.

- [ ] **Step 3: Implement** (append to `agent-shell-crew-queue.el` before `(provide …)`):

```elisp
(defmacro agent-shell-crew--mutate (root id verb &rest body)
  "Run BODY at item ID in ROOT's queue, then run the hook with VERB."
  (declare (indent 3) (debug t))
  `(prog1 (agent-shell-crew--with-queue ,root
            (agent-shell-crew--goto ,id)
            ,@body)
     (run-hook-with-args 'agent-shell-crew-changed-hook ,root ,id ,verb)))

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
  (let ((org-inhibit-logging t)
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

(defun agent-shell-crew-queue-park (root actor id question &optional evidence)
  "ACTOR parks item ID in ROOT's queue on the human with QUESTION.
EVIDENCE, when non-blank, replaces the item's evidence."
  (when (agent-shell-crew--blank-p question) (agent-shell-crew--fail "Parking needs a question"))
  (agent-shell-crew--mutate root id 'park
    (agent-shell-crew--require-owner actor)
    (agent-shell-crew--require-state "ACTIVE")
    (org-entry-put nil "QUESTION" (agent-shell-crew--clean-line question))
    (unless (agent-shell-crew--blank-p evidence) (org-entry-put nil "EVIDENCE" evidence))
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

(defun agent-shell-crew-queue-done (root actor id reason &optional canceled)
  "ACTOR closes item ID in ROOT's queue for REASON.
The item becomes CANCELED when CANCELED is non-nil, DONE otherwise."
  (agent-shell-crew--mutate root id 'done
    (agent-shell-crew--require-owner actor)
    (agent-shell-crew--require-state "PENDING" "ACTIVE")
    (agent-shell-crew--set-state (if canceled "CANCELED" "DONE"))
    (agent-shell-crew--log "%s by %s: %s" (if canceled "canceled" "done") actor
                           (if (agent-shell-crew--blank-p reason) "-"
                             (agent-shell-crew--clean-line reason)))))

(defun agent-shell-crew-queue-handoff (root actor id to summary &optional brief)
  "ACTOR hands item ID in ROOT's queue to TO with SUMMARY and BRIEF.
Closes ID as HANDED and returns the id of the new item TO owns."
  (when (agent-shell-crew--blank-p to) (agent-shell-crew--fail "A hand-off needs a recipient"))
  (when (equal to actor) (agent-shell-crew--fail "%s cannot hand off to itself" actor))
  (when (agent-shell-crew--blank-p summary) (agent-shell-crew--fail "A hand-off needs a summary"))
  (let ((source (agent-shell-crew--mutate root id 'handoff
                  (agent-shell-crew--require-owner actor)
                  (agent-shell-crew--require-state "ACTIVE")
                  (agent-shell-crew--set-state "HANDED")
                  (agent-shell-crew--log "handed to %s: %s" to (agent-shell-crew--clean-line summary))
                  (agent-shell-crew--read-item))))
    (agent-shell-crew-queue-create
     root actor
     :title (plist-get source :title)
     :owner to
     :parent id
     :evidence (plist-get source :evidence)
     :ref (plist-get source :ref)
     :brief (concat "Handed off by " actor ": " summary
                    (if (agent-shell-crew--blank-p brief) "" (concat "\n\n" brief))))))

(defun agent-shell-crew--file-root (file)
  "Return the project root recorded in queue FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (when (re-search-forward "^#\\+CREW_ROOT: \\(.+\\)$" nil t)
      (match-string-no-properties 1))))

(defun agent-shell-crew-parked ()
  "Return every PARKED item in every project as (ROOT . ITEM) pairs."
  (when (file-directory-p agent-shell-crew-directory)
    (apply #'append
           (mapcar
            (lambda (file)
              (when-let* ((root (agent-shell-crew--file-root file))
                          ((file-directory-p root)))
                (mapcar (lambda (item) (cons root item))
                        (seq-filter (lambda (item) (equal (plist-get item :state) "PARKED"))
                                    (agent-shell-crew-queue-list root)))))
            (directory-files agent-shell-crew-directory t "\\.org\\'")))))
```

- [ ] **Step 4: Run to verify it passes**

Run: `make check 2>&1 | tail -4`
Expected: `Ran 19 tests, 19 results as expected`; compile and checkdoc silent.

- [ ] **Step 5: Commit**

```bash
git add agent-shell-crew-queue.el test/agent-shell-crew-queue-test.el
git commit -m "queue: claim, note, park, decide, done, hand-off; parked items across projects"
```

### Task 3: `agent-shell-crew-rpc`

**Files:**
- Create: `agent-shell-crew-rpc.el`
- Test: `test/agent-shell-crew-rpc-test.el`

**Interfaces:**
- Consumes: Task 1–2 queue API.
- Produces: `(agent-shell-crew-rpc PAYLOAD)` → base64 JSON string, never signals; `agent-shell-crew-rpc-notify-function` (called `(MEMBER ROOT TEXT)`); `agent-shell-crew-rpc-members-function` (called `(ROOT)` → list of names); `(agent-shell-crew--nudge-text ID TITLE)` → string; `(agent-shell-crew--item-json ITEM)` → alist; `(agent-shell-crew--rpc-encode OBJ)`.
- Request shape: `{"actor": str, "project": str, "verb": str, "args": {...}}`. Reply: `{"ok": true, "result": …}` or `{"ok": false, "error": str}`.

- [ ] **Step 1: Write the failing tests** — `test/agent-shell-crew-rpc-test.el`:

```elisp
;;; agent-shell-crew-rpc-test.el --- RPC tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Drives `agent-shell-crew-rpc' exactly as the MCP program does.
;;; Code:
(require 'ert)
(require 'json)
(require 'agent-shell-crew-rpc)

(defmacro crew-rpc-test--with (root &rest body)
  "Fresh queue dir and project ROOT; notifications captured in `crew-rpc-test--notified'."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-r" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (crew-rpc-test--notified nil)
          (agent-shell-crew-rpc-notify-function
           (lambda (m r tx) (push (list m r tx) crew-rpc-test--notified)))
          (agent-shell-crew-rpc-members-function
           (lambda (_r) '("human" "owner@my-app" "check@my-app"))))
     (ignore crew-rpc-test--notified)
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p agent-shell-crew-directory (buffer-file-name b)))
           (kill-buffer b))))))

(defvar crew-rpc-test--notified nil)

(defun crew-rpc-test--call (actor root verb &optional args)
  "Call the RPC as ACTOR in ROOT with VERB and ARGS; return the decoded reply."
  (let* ((req `((actor . ,actor) (project . ,root) (verb . ,verb) (args . ,(or args (make-hash-table)))))
         (payload (base64-encode-string (encode-coding-string (json-encode req) 'utf-8) t)))
    (json-parse-string (decode-coding-string (base64-decode-string (agent-shell-crew-rpc payload)) 'utf-8)
                       :object-type 'alist :null-object nil :false-object :false)))

(ert-deftest crew-rpc-create-show-list ()
  (crew-rpc-test--with root
    (let* ((reply (crew-rpc-test--call "owner@my-app" root "create"
                                       '((title . "Check it") (brief . "b") (owner . "check@my-app"))))
           (id (alist-get 'id (alist-get 'result reply))))
      (should (eq (alist-get 'ok reply) t))
      (should (stringp id))
      (should (equal (car (car crew-rpc-test--notified)) "check@my-app"))
      (should (string-match-p (regexp-quote id) (nth 2 (car crew-rpc-test--notified))))
      (let ((shown (alist-get 'result (crew-rpc-test--call "check@my-app" root "show" `((id . ,id))))))
        (should (equal (alist-get 'owner shown) "check@my-app"))
        (should (equal (alist-get 'from shown) "owner@my-app")))
      (should (= (length (alist-get 'result (crew-rpc-test--call "check@my-app" root "mine"))) 1))
      (should (= (length (alist-get 'result (crew-rpc-test--call "owner@my-app" root "mine"))) 0))
      (should (= (length (alist-get 'result (crew-rpc-test--call "owner@my-app" root "list"))) 1)))))

(ert-deftest crew-rpc-actor-is-the-request-actor-not-an-arg ()
  (crew-rpc-test--with root
    (let* ((id (alist-get 'id (alist-get 'result (crew-rpc-test--call "human" root "create"
                                                                    '((title . "T") (owner . "owner@my-app")))))))
      ;; An `actor' smuggled into args is ignored: check@ still does not own it.
      (let ((reply (crew-rpc-test--call "check@my-app" root "claim" `((id . ,id) (actor . "owner@my-app")))))
        (should (eq (alist-get 'ok reply) :false))
        (should (string-match-p "does not own" (alist-get 'error reply)))))))

(ert-deftest crew-rpc-membership ()
  (crew-rpc-test--with root
    (let ((reply (crew-rpc-test--call "owner@my-app" root "create"
                                      '((title . "T") (owner . "stranger@my-app")))))
      (should (eq (alist-get 'ok reply) :false))
      (should (string-match-p "not a member" (alist-get 'error reply))))))

(ert-deftest crew-rpc-full-cycle ()
  (crew-rpc-test--with root
    (let* ((id (alist-get 'id (alist-get 'result (crew-rpc-test--call "human" root "create"
                                                                    '((title . "T") (owner . "owner@my-app")))))))
      (crew-rpc-test--call "owner@my-app" root "claim" `((id . ,id)))
      (crew-rpc-test--call "owner@my-app" root "note" `((id . ,id) (text . "started")))
      (let* ((reply (crew-rpc-test--call "owner@my-app" root "handoff"
                                         `((id . ,id) (to . "check@my-app") (summary . "built"))))
             (new (alist-get 'id (alist-get 'result reply))))
        (should (eq (alist-get 'ok reply) t))
        (should (equal (car (car crew-rpc-test--notified)) "check@my-app"))
        (crew-rpc-test--call "check@my-app" root "claim" `((id . ,new)))
        (should (eq (alist-get 'ok (crew-rpc-test--call "check@my-app" root "park"
                                                        `((id . ,new) (question . "OK? (1) yes; (2) no")))) t))
        (should (eq (alist-get 'ok (crew-rpc-test--call "check@my-app" root "done"
                                                        `((id . ,new) (reason . "x"))))
                    :false))))))

(ert-deftest crew-rpc-unknown-verb ()
  (crew-rpc-test--with root
    (let ((reply (crew-rpc-test--call "owner@my-app" root "rm-rf")))
      (should (eq (alist-get 'ok reply) :false))
      (should (string-match-p "Unknown verb" (alist-get 'error reply))))))

(ert-deftest crew-rpc-malformed-input-never-signals ()
  (dolist (payload (list "!!!not base64!!!"
                         (base64-encode-string "not json" t)
                         (base64-encode-string "{\"verb\":\"list\"}" t)))
    (let ((reply (json-parse-string (base64-decode-string (agent-shell-crew-rpc payload))
                                    :object-type 'alist :false-object :false)))
      (should (eq (alist-get 'ok reply) :false))
      (should (stringp (alist-get 'error reply))))))

(ert-deftest crew-rpc-unicode-round-trip ()
  (crew-rpc-test--with root
    (let* ((title "Fix “quotes” and \"these\" and \\ and 日本 and 🚀")
           (id (alist-get 'id (alist-get 'result (crew-rpc-test--call "human" root "create"
                                                                    `((title . ,title) (owner . "owner@my-app")))))))
      (should (equal (alist-get 'title (alist-get 'result (crew-rpc-test--call "owner@my-app" root "show" `((id . ,id)))))
                     title)))))

(provide 'agent-shell-crew-rpc-test)
;;; agent-shell-crew-rpc-test.el ends here
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E 'Cannot open|^Ran' | head -2`
Expected: FAIL — `Cannot open load file ... agent-shell-crew-rpc`.

- [ ] **Step 3: Implement** — `agent-shell-crew-rpc.el` (same GPL header block as Task 1, file name and summary line adjusted):

```elisp
;;; agent-shell-crew-rpc.el --- The entry point for the crew MCP program -*- lexical-binding: t; -*-

;; [GPL header exactly as in agent-shell-crew-queue.el]

;;; Commentary:

;; `agent-shell-crew-rpc' is the only function the MCP program calls.  Its
;; single argument is a base64-encoded JSON request, so no Lisp is ever
;; built from text; it always returns base64-encoded JSON and never signals.

;;; Code:

(require 'json)
(require 'agent-shell-crew-queue)

(defvar agent-shell-crew-rpc-notify-function nil
  "Function called with MEMBER, ROOT and TEXT to tell a member about work.
Nil means nobody is told; items still wait in the queue.")

(defvar agent-shell-crew-rpc-members-function nil
  "Function called with ROOT that returns the names allowed as owners.
Nil accepts any name.")

(defun agent-shell-crew--rpc-encode (object)
  "Return OBJECT as base64-encoded JSON."
  (base64-encode-string (encode-coding-string (json-encode object) 'utf-8) t))

(defun agent-shell-crew--nudge-text (id title)
  "Return the one-line nudge for new item ID titled TITLE."
  (format "New crew item %s for you: %s. Call crew_show with id %s." id title id))

(defun agent-shell-crew--item-json (item)
  "Return ITEM, a plist, as an alist for `json-encode'."
  `((id . ,(plist-get item :id))
    (title . ,(plist-get item :title))
    (state . ,(plist-get item :state))
    (owner . ,(plist-get item :owner))
    (from . ,(plist-get item :from))
    (parent . ,(plist-get item :parent))
    (evidence . ,(plist-get item :evidence))
    (ref . ,(plist-get item :ref))
    (question . ,(plist-get item :question))
    (decision . ,(plist-get item :decision))
    (brief . ,(plist-get item :brief))
    (log . ,(vconcat (plist-get item :log)))))

(defun agent-shell-crew--rpc-arg (args key &optional required)
  "Return KEY from ARGS, failing when REQUIRED and blank."
  (let ((value (alist-get key args)))
    (when (and required (agent-shell-crew--blank-p value))
      (agent-shell-crew--fail "Missing argument: %s" key))
    value))

(defun agent-shell-crew--rpc-check-member (root name)
  "Fail unless NAME may own items in ROOT."
  (when agent-shell-crew-rpc-members-function
    (let ((members (funcall agent-shell-crew-rpc-members-function root)))
      (unless (member name members)
        (agent-shell-crew--fail "%s is not a member of this crew (members: %s)"
                                name (string-join members ", "))))))

(defun agent-shell-crew--rpc-notify (member root text)
  "Tell MEMBER of ROOT's crew TEXT, unless MEMBER is the human."
  (when (and agent-shell-crew-rpc-notify-function (not (equal member "human")))
    (condition-case nil
        (funcall agent-shell-crew-rpc-notify-function member root text)
      (error nil))))

(defun agent-shell-crew--rpc-dispatch (actor root verb args)
  "Run VERB with ARGS in ROOT's queue on behalf of ACTOR."
  (let ((arg (lambda (key &optional required) (agent-shell-crew--rpc-arg args key required))))
    (pcase verb
      ("mine" (vconcat (mapcar #'agent-shell-crew--item-json (agent-shell-crew-queue-list root actor))))
      ("list" (vconcat (mapcar #'agent-shell-crew--item-json (agent-shell-crew-queue-list root))))
      ("show" (agent-shell-crew--item-json (agent-shell-crew-queue-get root (funcall arg 'id t))))
      ("create"
       (let ((owner (funcall arg 'owner t)) (title (funcall arg 'title t)))
         (agent-shell-crew--rpc-check-member root owner)
         (let ((id (agent-shell-crew-queue-create root actor :title title :owner owner
                                                  :brief (funcall arg 'brief)
                                                  :evidence (funcall arg 'evidence)
                                                  :ref (funcall arg 'ref))))
           (agent-shell-crew--rpc-notify owner root (agent-shell-crew--nudge-text id title))
           `((id . ,id)))))
      ("claim" (agent-shell-crew-queue-claim root actor (funcall arg 'id t)) '((done . t)))
      ("note" (agent-shell-crew-queue-note root actor (funcall arg 'id t) (funcall arg 'text t))
              '((done . t)))
      ("handoff"
       (let ((to (funcall arg 'to t)))
         (agent-shell-crew--rpc-check-member root to)
         (let* ((new (agent-shell-crew-queue-handoff root actor (funcall arg 'id t) to
                                                     (funcall arg 'summary t) (funcall arg 'brief)))
                (title (plist-get (agent-shell-crew-queue-get root new) :title)))
           (agent-shell-crew--rpc-notify to root (agent-shell-crew--nudge-text new title))
           `((id . ,new)))))
      ("park" (agent-shell-crew-queue-park root actor (funcall arg 'id t) (funcall arg 'question t)
                                           (funcall arg 'evidence))
              '((done . t)))
      ("done" (agent-shell-crew-queue-done root actor (funcall arg 'id t) (funcall arg 'reason)
                                           (eq (funcall arg 'canceled) t))
              '((done . t)))
      (_ (agent-shell-crew--fail "Unknown verb: %s" verb)))))

;;;###autoload
(defun agent-shell-crew-rpc (payload)
  "Handle one request from the crew MCP program.
PAYLOAD is base64-encoded JSON with keys actor, project, verb and args.
Returns base64-encoded JSON, {\"ok\": true, \"result\": ...} or
{\"ok\": false, \"error\": ...}.  Never signals."
  (agent-shell-crew--rpc-encode
   (condition-case err
       (let* ((request (json-parse-string
                        (decode-coding-string (base64-decode-string payload) 'utf-8)
                        :object-type 'alist :null-object nil :false-object nil))
              (actor (alist-get 'actor request))
              (root (alist-get 'project request))
              (verb (alist-get 'verb request))
              (args (alist-get 'args request)))
         (unless (and (stringp actor) (not (string-empty-p actor)))
           (agent-shell-crew--fail "Request has no actor"))
         (unless (and (stringp root) (file-directory-p root))
           (agent-shell-crew--fail "Request has no valid project"))
         (unless (stringp verb) (agent-shell-crew--fail "Request has no verb"))
         `((ok . t) (result . ,(agent-shell-crew--rpc-dispatch actor root verb args))))
     (agent-shell-crew-error `((ok . :json-false) (error . ,(cadr err))))
     (error `((ok . :json-false)
              (error . ,(format "Malformed request: %s" (error-message-string err))))))))

(provide 'agent-shell-crew-rpc)
;;; agent-shell-crew-rpc.el ends here
```

- [ ] **Step 4: Run to verify it passes**

Run: `make check 2>&1 | tail -4`
Expected: `Ran 26 tests, 26 results as expected`; compile and checkdoc silent.

- [ ] **Step 5: Commit**

```bash
git add agent-shell-crew-rpc.el test/agent-shell-crew-rpc-test.el
git commit -m "rpc: one base64-JSON entry point; actor from the request envelope, never args"
```

### Task 4: The MCP program

**Files:**
- Create: `bin/agent-shell-crew-mcp` (mode 0755)
- Test: `test/test_mcp.py`

**Interfaces:**
- Consumes: `agent-shell-crew-rpc` reply shape (Task 3). Environment: `CREW_AGENT`, `CREW_PROJECT`, `CREW_EMACS_SOCKET` (optional), `CREW_EMACSCLIENT` (optional, default `emacsclient`).
- Produces: MCP stdio server named `agent-shell-crew` with tools `crew_mine`, `crew_list`, `crew_show`, `crew_create`, `crew_claim`, `crew_note`, `crew_handoff`, `crew_park`, `crew_done`.

- [ ] **Step 1: Write the failing tests** — `test/test_mcp.py`:

```python
"""Tests for bin/agent-shell-crew-mcp, with emacsclient replaced by a fake."""
import base64, json, os, stat, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROGRAM = os.path.join(ROOT, "bin", "agent-shell-crew-mcp")

FAKE = r"""#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
sys.stdout.write(os.environ.get("FAKE_REPLY", ""))
sys.exit(int(os.environ.get("FAKE_RC", "0")))
"""

def reply(obj):
    return '"' + base64.b64encode(json.dumps(obj).encode()).decode() + '"\n'

class McpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.fake = os.path.join(self.tmp, "emacsclient")
        with open(self.fake, "w") as f:
            f.write(FAKE)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)
        self.log = os.path.join(self.tmp, "calls.log")
        self.env = dict(os.environ, CREW_AGENT="owner@my-app", CREW_PROJECT="/tmp/my-app/",
                        CREW_EMACS_SOCKET="/tmp/sock", CREW_EMACSCLIENT=self.fake,
                        FAKE_LOG=self.log, FAKE_REPLY=reply({"ok": True, "result": {"id": "c-1"}}))

    def run_session(self, messages, **env):
        e = dict(self.env, **env)
        data = "".join(json.dumps(m) + "\n" for m in messages)
        out = subprocess.run([sys.executable, PROGRAM], input=data, capture_output=True,
                             text=True, env=e, timeout=30)
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()]

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def request(self, argv):
        """Decode the request the MCP program sent to Emacs."""
        expr = argv[-1]
        payload = expr.split('"')[1]
        return json.loads(base64.b64decode(payload))

    def test_initialize_and_list_tools(self):
        out = self.run_session([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "agent-shell-crew")
        self.assertEqual(out[0]["result"]["protocolVersion"], "2025-06-18")
        names = {t["name"] for t in out[1]["result"]["tools"]}
        self.assertEqual(names, {"crew_mine", "crew_list", "crew_show", "crew_create", "crew_claim",
                                 "crew_note", "crew_handoff", "crew_park", "crew_done"})

    def test_call_forwards_with_identity_from_environment(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                 "params": {"name": "crew_claim",
                                            "arguments": {"id": "c-1", "actor": "human"}}}])
        self.assertFalse(out[0]["result"]["isError"])
        argv = self.calls()[0]
        self.assertEqual(argv[:2], ["-s", "/tmp/sock"])
        self.assertTrue(argv[-1].startswith("(agent-shell-crew-rpc \""))
        req = self.request(argv)
        self.assertEqual(req["actor"], "owner@my-app")
        self.assertEqual(req["project"], "/tmp/my-app/")
        self.assertEqual(req["verb"], "claim")
        self.assertEqual(req["args"], {"id": "c-1"})  # smuggled actor dropped

    def test_emacs_error_becomes_tool_error(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                 "params": {"name": "crew_claim", "arguments": {"id": "c-1"}}}],
                               FAKE_REPLY=reply({"ok": False, "error": "check@x does not own c-1"}))
        self.assertTrue(out[0]["result"]["isError"])
        self.assertIn("does not own", out[0]["result"]["content"][0]["text"])

    def test_unreachable_emacs_becomes_tool_error(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                 "params": {"name": "crew_list", "arguments": {}}}],
                               FAKE_RC="1", FAKE_REPLY="")
        self.assertTrue(out[0]["result"]["isError"])
        self.assertIn("reach Emacs", out[0]["result"]["content"][0]["text"])

    def test_unknown_tool_and_method(self):
        out = self.run_session([
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "rm", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 7, "method": "nope"}])
        self.assertTrue(out[0]["result"]["isError"])
        self.assertEqual(out[1]["error"]["code"], -32601)

    def test_unicode_arguments_pass_through(self):
        title = "Fix “quotes” and \"these\" and \\ and 日本 and 🚀"
        self.run_session([{"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                           "params": {"name": "crew_create",
                                      "arguments": {"title": title, "owner": "check@my-app", "brief": "b"}}}])
        self.assertEqual(self.request(self.calls()[0])["args"]["title"], title)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s test -p 'test_*.py' 2>&1 | tail -3`
Expected: FAIL — errors because `bin/agent-shell-crew-mcp` does not exist.

- [ ] **Step 3: Implement** — `bin/agent-shell-crew-mcp`:

```python
#!/usr/bin/env python3
# agent-shell-crew-mcp --- MCP server for agent-shell-crew  -*- mode: python -*-
#
# Copyright (C) 2026 Scott Whitson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Speaks MCP (JSON-RPC 2.0, one message per line) on stdio and forwards each
# crew_* tool call to Emacs as ONE call of `agent-shell-crew-rpc', with the
# request base64-encoded JSON. The acting agent is CREW_AGENT from this
# process's environment -- never a tool argument.
"""agent-shell-crew MCP server."""
import base64
import json
import os
import subprocess
import sys

VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2025-06-18"

def _tool(name, description, properties=None, required=()):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {},
                            "required": list(required), "additionalProperties": False}}

S = {"type": "string"}
TOOLS = [
    _tool("crew_mine", "List the crew items you own."),
    _tool("crew_list", "List every crew item in this project."),
    _tool("crew_show", "Show one crew item: brief, properties and log.", {"id": S}, ["id"]),
    _tool("crew_create", "Create a crew item for a crew member, or for `human`.",
          {"title": S, "brief": S, "owner": S, "evidence": S, "ref": S}, ["title", "brief", "owner"]),
    _tool("crew_claim", "Claim an item you own: PENDING to ACTIVE.", {"id": S}, ["id"]),
    _tool("crew_note", "Append a line to an item's log.", {"id": S, "text": S}, ["id", "text"]),
    _tool("crew_handoff", "Close your item as HANDED and open a new item for `to`.",
          {"id": S, "to": S, "summary": S, "brief": S}, ["id", "to", "summary"]),
    _tool("crew_park", "Park your item on the human with a question. Write options inline as "
          "`(1) ...; (2) ...` and point `evidence` at a file the human should read.",
          {"id": S, "question": S, "evidence": S}, ["id", "question"]),
    _tool("crew_done", "Close your item as DONE, or CANCELED when `canceled` is true.",
          {"id": S, "reason": S, "canceled": {"type": "boolean"}}, ["id", "reason"]),
]
ALLOWED = {t["name"]: set(t["inputSchema"]["properties"]) for t in TOOLS}

def call_emacs(verb, args):
    """Send one request to Emacs; return (result, error)."""
    request = {"actor": os.environ.get("CREW_AGENT", ""),
               "project": os.environ.get("CREW_PROJECT", ""),
               "verb": verb, "args": args}
    payload = base64.b64encode(json.dumps(request).encode("utf-8")).decode("ascii")
    cmd = [os.environ.get("CREW_EMACSCLIENT", "emacsclient")]
    if os.environ.get("CREW_EMACS_SOCKET"):
        cmd += ["-s", os.environ["CREW_EMACS_SOCKET"]]
    cmd += ["--eval", '(agent-shell-crew-rpc "%s")' % payload]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        return None, "Could not reach Emacs: emacsclient not found"
    except subprocess.TimeoutExpired:
        return None, "Could not reach Emacs: no answer within 30 seconds"
    if out.returncode != 0:
        return None, "Could not reach Emacs: %s" % ((out.stderr or out.stdout).strip() or "exit %d" % out.returncode)
    text = out.stdout.strip()
    if len(text) >= 2 and text[0] == text[-1] == '"':
        text = text[1:-1]
    try:
        reply = json.loads(base64.b64decode(text).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None, "Unexpected reply from Emacs: %s" % out.stdout.strip()[:200]
    if reply.get("ok"):
        return reply.get("result"), None
    return None, reply.get("error") or "unknown error"

def tool_result(text, is_error):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}

def handle(message):
    """Return the response for MESSAGE, or None for a notification."""
    method, mid = message.get("method"), message.get("id")
    if mid is None:
        return None
    if method == "initialize":
        params = message.get("params") or {}
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": params.get("protocolVersion") or DEFAULT_PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "agent-shell-crew", "version": VERSION}}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        if name not in ALLOWED:
            return {"jsonrpc": "2.0", "id": mid, "result": tool_result("Unknown tool: %s" % name, True)}
        arguments = params.get("arguments") or {}
        args = {k: v for k, v in arguments.items() if k in ALLOWED[name]}
        result, error = call_emacs(name[len("crew_"):], args)
        if error:
            return {"jsonrpc": "2.0", "id": mid, "result": tool_result(error, True)}
        return {"jsonrpc": "2.0", "id": mid,
                "result": tool_result(json.dumps(result, indent=2, ensure_ascii=False), False)}
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found: %s" % method}}

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
```

Run: `chmod +x bin/agent-shell-crew-mcp`

- [ ] **Step 4: Run to verify it passes**

Run: `make check 2>&1 | tail -4`
Expected: ERT `Ran 26 tests, 26 results as expected`; Python `Ran 6 tests ... OK`.

- [ ] **Step 5: Commit**

```bash
git add bin/agent-shell-crew-mcp test/test_mcp.py
git commit -m "mcp: a stdlib-Python MCP server; identity from the environment, one emacsclient call per tool"
```

### Task 5: Sessions, briefs and nudges

**Files:**
- Create: `agent-shell-crew.el`, `briefs/lead.md`, `briefs/owner.md`, `briefs/check.md`, `test/stubs/agent-shell.el`, `test/stubs/agent-shell-anthropic.el`
- Test: `test/agent-shell-crew-test.el`

**Interfaces:**
- Consumes: agent-shell — `(agent-shell-start &key config)` → buffer; `(agent-shell-insert &key text submit no-focus shell-buffer)`; `(agent-shell-busy-submit-queue PROMPT)` (called in the shell buffer); `(agent-shell-subscribe-to &key shell-buffer event on-event)`; `(shell-maker-busy)`; `agent-shell-mcp-servers`; `(agent-shell-anthropic-make-claude-code-config)`. Queue and RPC from Tasks 1–3.
- Produces: `agent-shell-crew-roles`, `agent-shell-crew-mcp-program`, `agent-shell-crew-python` (defcustoms); `(agent-shell-crew-member-name ROLE ROOT)`; `(agent-shell-crew-members ROOT)`; `(agent-shell-crew-start ROOT ROLES)`; `(agent-shell-crew--session-config ROLE ROOT SOCKET)` → config alist; `(agent-shell-crew--member-buffer MEMBER)`; `(agent-shell-crew--deliver BUFFER TEXT)`; `(agent-shell-crew--notify MEMBER ROOT TEXT)`; `(agent-shell-crew--input-empty-p BUFFER)`; buffer-local `agent-shell-crew--member`, `agent-shell-crew--pending`.

- [ ] **Step 1: Stubs**

`test/stubs/agent-shell.el`:

```elisp
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
```

`test/stubs/agent-shell-anthropic.el`:

```elisp
;;; agent-shell-anthropic.el --- Test stand-in -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:
(defun agent-shell-anthropic-make-claude-code-config ()
  "Stub config."
  (list (cons :identifier 'claude-code) (cons :buffer-name "Claude")
        (cons :mcp-servers nil)))
(provide 'agent-shell-anthropic)
;;; agent-shell-anthropic.el ends here
```

- [ ] **Step 2: Briefs** (generic; no project specifics)

`briefs/owner.md`:

```markdown
You build. You are one member of a small crew that shares a work queue, reached
through the crew_* tools.

- Start with crew_mine. Claim an item (crew_claim) before working on it.
- Follow this repository's own instructions (AGENTS.md, CLAUDE.md, README) for
  how to build, test and commit.
- Log progress that matters with crew_note.
- When the work is done and tested, hand it to the checker with crew_handoff
  (to: check@ this project). Say what you did and how you tested it.
- When you need a decision only the human can make, crew_park it: a clear
  question with numbered options inline — (1) …; (2) … — and your
  recommendation, with `evidence` pointing at a file that explains it.
- Never push, publish or deploy unless the human has said so in this session.
```

`briefs/check.md`:

```markdown
You verify. You are one member of a small crew that shares a work queue,
reached through the crew_* tools.

- Start with crew_mine and claim what is yours (crew_claim).
- Verify independently: read the change, run the tests yourself, try the
  cases the builder may have missed. Do not trust the hand-off summary.
- If it needs fixing, hand it back with crew_handoff (to: owner@ this project)
  saying exactly what fails and how to reproduce it.
- If it is good, close it with crew_done, stating what you checked.
- If a decision only the human can make blocks you, crew_park it with numbered
  options and evidence.
```

`briefs/lead.md`:

```markdown
You lead. You are one member of a small crew that shares a work queue, reached
through the crew_* tools. The human talks to you; you turn what they want into
work for the crew.

- Break requests into items small enough for one member to finish, and create
  them with crew_create, one owner each, with a brief that says what done means.
- Keep track with crew_list and report progress to the human when asked.
- Do not do the members' work yourself.
- Anything the human must decide goes to them through crew_park, not chat,
  so it is recorded.
```

- [ ] **Step 3: Write the failing tests** — `test/agent-shell-crew-test.el`:

```elisp
;;; agent-shell-crew-test.el --- Session and command tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Runs against test/stubs, never a real agent.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-crew)

(defmacro crew-main-test--with (root &rest body)
  "Fresh queue dir, project ROOT, and clean stub state for BODY."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-m" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (agent-shell-test--calls nil)
          (agent-shell-test--subscriptions nil)
          (agent-shell-test--busy nil))
     (cl-letf (((symbol-function 'agent-shell-crew--server-socket) (lambda () "/tmp/test-socket")))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (or (buffer-local-value 'agent-shell-crew--member b)
                     (and (buffer-file-name b)
                          (string-prefix-p agent-shell-crew-directory (buffer-file-name b))))
             (kill-buffer b)))))))

(ert-deftest crew-member-names ()
  (should (equal (agent-shell-crew-member-name "owner" "/x/my-app/") "owner@my-app"))
  (should (equal (agent-shell-crew-members "/x/my-app/")
                 '("human" "lead@my-app" "owner@my-app" "check@my-app"))))

(ert-deftest crew-session-config-attaches-mcp-with-identity ()
  (let* ((agent-shell-mcp-servers '(((name . "user-server") (command . "x"))))
         (config (agent-shell-crew--session-config "owner" "/x/my-app/" "/tmp/sock"))
         (servers (alist-get :mcp-servers config))
         (crew (seq-find (lambda (s) (equal (alist-get 'name s) "agent-shell-crew")) servers))
         (env (alist-get 'env crew)))
    (should (equal (alist-get :buffer-name config) "owner@my-app"))
    (should (seq-find (lambda (s) (equal (alist-get 'name s) "user-server")) servers))
    (should (equal (alist-get 'command crew) agent-shell-crew-python))
    (should (equal (alist-get 'args crew) (list agent-shell-crew-mcp-program)))
    (should (seq-find (lambda (e) (and (equal (alist-get 'name e) "CREW_AGENT")
                                       (equal (alist-get 'value e) "owner@my-app")))
                      env))
    (should (seq-find (lambda (e) (and (equal (alist-get 'name e) "CREW_PROJECT")
                                       (equal (alist-get 'value e) "/x/my-app/")))
                      env))
    (should (seq-find (lambda (e) (equal (alist-get 'value e) "/tmp/sock")) env))))

(ert-deftest crew-start-names-buffers-and-sends-brief-when-ready ()
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner" "check"))
    (let ((owner (agent-shell-crew--member-buffer "owner@my-app"))
          (check (agent-shell-crew--member-buffer "check@my-app")))
      (should (buffer-live-p owner))
      (should (buffer-live-p check))
      (should (equal (buffer-name owner) "owner@my-app"))
      (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 2))
      ;; Nothing is sent before the session says it is ready.
      (should-not (seq-find (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit owner 'prompt-ready)
        (agent-shell-test--emit owner 'prompt-ready))
      (let ((inserts (seq-filter (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls)))
        (should (= (length inserts) 1))
        (should (string-match-p "You are owner@my-app" (nth 1 (car inserts))))
        (should (string-match-p "You build" (nth 1 (car inserts))))))))

(ert-deftest crew-start-skips-running-member ()
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner"))
    (agent-shell-crew-start root '("owner"))
    (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 1))))

(ert-deftest crew-deliver-busy-queues ()
  (with-temp-buffer
    (let ((agent-shell-test--calls nil) (agent-shell-test--busy t))
      (agent-shell-crew--deliver (current-buffer) "hello")
      (should (equal (car agent-shell-test--calls) (list 'queue "hello" (current-buffer)))))))

(ert-deftest crew-deliver-idle-empty-submits ()
  (with-temp-buffer
    (let ((agent-shell-test--calls nil) (agent-shell-test--busy nil))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-crew--deliver (current-buffer) "hello"))
      (should (equal (car agent-shell-test--calls)
                     (list 'insert "hello" t t (current-buffer)))))))

(ert-deftest crew-deliver-never-submits-a-draft ()
  (with-temp-buffer
    (let ((agent-shell-test--calls nil) (agent-shell-test--busy nil) (buffer (current-buffer)))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) nil)))
        (agent-shell-crew--deliver buffer "hello"))
      (should (null agent-shell-test--calls))
      (should (equal agent-shell-crew--pending '("hello")))
      ;; Once the human submits and the turn runs, it is queued, not typed.
      (setq agent-shell-test--busy t)
      (agent-shell-crew--flush buffer)
      (should (equal (car agent-shell-test--calls) (list 'queue "hello" buffer)))
      (should (null agent-shell-crew--pending)))))

(ert-deftest crew-input-empty-without-process-is-not-empty ()
  (with-temp-buffer
    (should-not (agent-shell-crew--input-empty-p (current-buffer)))))

(ert-deftest crew-notify-unknown-member-is-quiet ()
  (let ((agent-shell-test--calls nil))
    (agent-shell-crew--notify "nobody@my-app" "/x/my-app/" "hello")
    (should (null agent-shell-test--calls))))

(ert-deftest crew-rpc-wired-to-members-and-notify ()
  (should (eq agent-shell-crew-rpc-members-function #'agent-shell-crew-members))
  (should (eq agent-shell-crew-rpc-notify-function #'agent-shell-crew--notify)))

(provide 'agent-shell-crew-test)
;;; agent-shell-crew-test.el ends here
```

- [ ] **Step 4: Run to verify it fails**

Run: `make test 2>&1 | grep -E 'Cannot open|^Ran' | head -2`
Expected: FAIL — `Cannot open load file ... agent-shell-crew`.

- [ ] **Step 5: Implement** — `agent-shell-crew.el` (GPL header as in Task 1, plus the package header lines below):

```elisp
;;; agent-shell-crew.el --- A crew of agent-shell sessions sharing a work queue -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson

;; Author: Scott Whitson <scott@scottwhitson.com>
;; URL: https://github.com/scott-whitson/agent-shell-crew
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.81.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; [GPL notice exactly as in agent-shell-crew-queue.el]

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
  :type '(alist :key-type string :value-type plist))

(defcustom agent-shell-crew-mcp-program
  (expand-file-name "bin/agent-shell-crew-mcp" agent-shell-crew--package-dir)
  "The crew MCP program each session starts."
  :type 'file)

(defcustom agent-shell-crew-python "python3"
  "Python interpreter that runs `agent-shell-crew-mcp-program'."
  :type 'string)

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
    (user-error "agent-shell-crew needs a local-socket Emacs server; `server-use-tcp' is set"))
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

(setq agent-shell-crew-rpc-members-function #'agent-shell-crew-members
      agent-shell-crew-rpc-notify-function #'agent-shell-crew--notify)

(provide 'agent-shell-crew)
;;; agent-shell-crew.el ends here
```

- [ ] **Step 6: Run to verify it passes**

Run: `make check 2>&1 | tail -4`
Expected: ERT `Ran 36 tests, 36 results as expected`; Python OK; compile and checkdoc silent.

- [ ] **Step 7: Commit**

```bash
git add agent-shell-crew.el briefs test/stubs test/agent-shell-crew-test.el
git commit -m "crew: start sessions as ROLE@PROJECT with the MCP tool attached; nudges never submit a draft"
```

### Task 6: Human commands and the optional mode-line indicator

**Files:**
- Modify: `agent-shell-crew.el` (before the `(setq agent-shell-crew-rpc-...)` form)
- Test: `test/agent-shell-crew-test.el` (append before `(provide …)`)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `(agent-shell-crew-new ROOT OWNER TITLE BRIEF &optional EVIDENCE)` → id; `(agent-shell-crew-decide)`; `(agent-shell-crew-open ROOT)`; `(agent-shell-crew--options QUESTION)` → list of strings; `agent-shell-crew-mode-line-mode` (global minor mode); `agent-shell-crew--parked-count`.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest crew-options-parse ()
  (should (equal (agent-shell-crew--options "Pick: (1) numbers only - raise; (2) accept strings; (3) leave it.")
                 '("1 — numbers only - raise" "2 — accept strings" "3 — leave it")))
  (should (equal (agent-shell-crew--options "(1) yes (2) no") '("1 — yes" "2 — no")))
  (should (null (agent-shell-crew--options "Should it?"))))

(ert-deftest crew-new-creates-and-nudges ()
  (crew-main-test--with root
    (let ((told nil))
      (cl-letf (((symbol-function 'agent-shell-crew--notify)
                 (lambda (m _r tx) (push (list m tx) told))))
        (let* ((id (agent-shell-crew-new root "owner@my-app" "Do it" "brief" "notes/e.md"))
               (item (agent-shell-crew-queue-get root id)))
          (should (equal (plist-get item :from) "human"))
          (should (equal (plist-get item :evidence) "notes/e.md"))
          (should (equal (car (car told)) "owner@my-app")))))))

(ert-deftest crew-decide-records-and-nudges ()
  (crew-main-test--with root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app"))
           (told nil))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "Pick (1) a; (2) b")
      (cl-letf (((symbol-function 'agent-shell-crew--notify) (lambda (m _r tx) (push (list m tx) told)))
                ((symbol-function 'completing-read)
                 (lambda (_p coll &rest _) (if (equal coll '("1 — a" "2 — b")) "1 — a" (car coll)))))
        (agent-shell-crew-decide))
      (let ((item (agent-shell-crew-queue-get root id)))
        (should (equal (plist-get item :state) "ACTIVE"))
        (should (equal (plist-get item :decision) "1 — a")))
      (should (equal (car (car told)) "owner@my-app"))
      (should (string-match-p "1 — a" (nth 1 (car told)))))))

(ert-deftest crew-decide-owner-not-running ()
  (crew-main-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "OK?")
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "yes")))
        (agent-shell-crew-decide))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :decision) "yes"))
      (should (string-match-p (regexp-quote id)
                              (agent-shell-crew--intro "owner" "owner@my-app" root))))))

(ert-deftest crew-decide-nothing-waiting ()
  (crew-main-test--with root
    (ignore root)
    (should-error (agent-shell-crew-decide) :type 'user-error)))

(ert-deftest crew-mode-line-counts-parked ()
  (crew-main-test--with root
    (let ((global-mode-string nil))
      (agent-shell-crew-mode-line-mode 1)
      (unwind-protect
          (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
            (should (= agent-shell-crew--parked-count 0))
            (agent-shell-crew-queue-claim root "owner@my-app" id)
            (agent-shell-crew-queue-park root "owner@my-app" id "Q?")
            (should (= agent-shell-crew--parked-count 1))
            (should (member agent-shell-crew--mode-line global-mode-string)))
        (agent-shell-crew-mode-line-mode -1))
      (should-not (member agent-shell-crew--mode-line global-mode-string)))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -E 'void-function|^Ran' | head -2`
Expected: FAIL — `void-function agent-shell-crew--options`.

- [ ] **Step 3: Implement** (insert before the `(setq agent-shell-crew-rpc-...)` form):

```elisp
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
  (if agent-shell-crew-mode-line-mode
      (progn
        (unless (listp global-mode-string)
          (setq global-mode-string (list global-mode-string)))
        (add-to-list 'global-mode-string agent-shell-crew--mode-line t)
        (add-hook 'agent-shell-crew-changed-hook #'agent-shell-crew--refresh-count)
        (agent-shell-crew--refresh-count))
    (setq global-mode-string (delete agent-shell-crew--mode-line global-mode-string))
    (remove-hook 'agent-shell-crew-changed-hook #'agent-shell-crew--refresh-count)))
```

- [ ] **Step 4: Run to verify it passes**

Run: `make check 2>&1 | tail -4`
Expected: ERT `Ran 42 tests, 42 results as expected`; Python OK; compile and checkdoc silent.

- [ ] **Step 5: Commit**

```bash
git add agent-shell-crew.el test/agent-shell-crew-test.el
git commit -m "crew: new, decide and open for the human; optional crew:N in the mode line"
```

### Task 7: API guard against the real agent-shell, README, live acceptance

**Files:**
- Create: `test/agent-shell-crew-api-test.el`, `README.md`

- [ ] **Step 1: Write the API guard** — `test/agent-shell-crew-api-test.el`:

```elisp
;;; agent-shell-crew-api-test.el --- Guard the real agent-shell API -*- lexical-binding: t; -*-
;;; Commentary:
;; Run with `make api-check DEPS="-L <agent-shell> -L <acp> -L <shell-maker> ..."'.
;; Fails when agent-shell renames or drops anything crew relies on.
;;; Code:
(require 'ert)
(require 'agent-shell)
(require 'agent-shell-anthropic)
(require 'help-fns)

(ert-deftest crew-api-functions-exist ()
  (dolist (fn '(agent-shell-start agent-shell-insert agent-shell-busy-submit-queue
                agent-shell-subscribe-to agent-shell-buffers shell-maker-busy
                agent-shell-anthropic-make-claude-code-config))
    (should (fboundp fn))))

(ert-deftest crew-api-events-documented ()
  (let ((doc (documentation 'agent-shell-subscribe-to)))
    (dolist (event '("prompt-ready" "input-submitted" "turn-complete"))
      (should (string-match-p event doc)))))

(ert-deftest crew-api-insert-keywords ()
  (let ((arglist (format "%S" (help-function-arglist 'agent-shell-insert t))))
    (dolist (key '("text" "submit" "no-focus" "shell-buffer"))
      (should (string-match-p key arglist)))))

(ert-deftest crew-api-config-keys ()
  (let ((config (agent-shell-anthropic-make-claude-code-config)))
    (should (assq :buffer-name config))
    (should (assq :mcp-servers config))))

(ert-deftest crew-api-mcp-servers-variable ()
  (should (boundp 'agent-shell-mcp-servers)))

(provide 'agent-shell-crew-api-test)
;;; agent-shell-crew-api-test.el ends here
```

- [ ] **Step 2: Run it against the real agent-shell**

Run (DEPS names the real package directories on the machine doing the check):
```bash
make api-check DEPS="$(emacsclient -e '(mapconcat (lambda (d) (concat "-L " d)) (seq-filter (lambda (d) (string-match-p "agent-shell\\|/acp\\|shell-maker\\|transient\\|compat" d)) load-path) " ")' | tr -d '"')" 2>&1 | tail -2
```
Expected: `Ran 5 tests, 5 results as expected`. A failure here is a finding about agent-shell, not the test — stop and report it.

- [ ] **Step 3: README.md**

````markdown
# agent-shell-crew

A small crew of [agent-shell](https://github.com/xenodium/agent-shell)
sessions sharing a work queue. One agent builds, another checks the work, a
lead can split tasks up — and anything that needs a human decision is parked
for you, with the evidence attached, and answered from Emacs.

Every piece of work has exactly one owner. Hand-offs are recorded. The queue is
an Org file per project, outside the repository, so it shows up in your
agenda. Agents reach it through an MCP tool that knows which session is
calling.

See [docs/design.md](docs/design.md) for the design and the reasoning.

## Requirements

- Emacs 29.1+, agent-shell 0.81.1+
- `python3` (standard library only) for the MCP program
- An Emacs server on a local socket (crew starts one if none is running)
- An agent that accepts MCP servers over ACP (Claude Code does)

## Install

Clone and add to `load-path`, or with `use-package`:

```elisp
(use-package agent-shell-crew
  :load-path "~/src/agent-shell-crew"
  :after agent-shell
  :config (agent-shell-crew-mode-line-mode 1))
```

## Five minutes

1. `M-x agent-shell-crew-start` in a project: pick `owner` and `check`.
   Two sessions open, `owner@PROJECT` and `check@PROJECT`, each briefed.
2. `M-x agent-shell-crew-new`: give `owner@PROJECT` something to do.
3. Watch it claim the item, build, and hand it to `check@PROJECT`.
4. When a member parks a question on you, the mode line shows `crew:1`.
   `M-x agent-shell-crew-decide` opens the evidence and offers the options.
5. `M-x agent-shell-crew-open` shows the queue — it is just Org.

## Settings

| Setting | Default |
|---|---|
| `agent-shell-crew-directory` | `~/.emacs.d/agent-shell-crew/` |
| `agent-shell-crew-roles` | `lead`, `owner`, `check`, with the briefs in `briefs/`, on Claude Code |
| `agent-shell-crew-mcp-program` | the bundled `bin/agent-shell-crew-mcp` |
| `agent-shell-crew-python` | `python3` |

To show parked items in your agenda:
`(add-to-list 'org-agenda-files agent-shell-crew-directory)`.

For your own status display, use `agent-shell-crew-parked` and
`agent-shell-crew-changed-hook` instead of the mode-line mode.

## Development

`make check` byte-compiles, runs checkdoc and all tests against stub
agent-shell features. `make api-check DEPS="-L …"` checks the real
agent-shell still provides what crew uses.

## License

GPL-3.0-or-later.
````

- [ ] **Step 4: Full check**

Run: `make clean check 2>&1 | tail -4`
Expected: ERT 42/42, Python 6/6, compile and checkdoc silent.

- [ ] **Step 5: Commit**

```bash
git add test/agent-shell-crew-api-test.el README.md
git commit -m "api guard against the real agent-shell; README"
```

- [ ] **Step 6: Live acceptance (with the human)** — in a real Emacs with agent-shell, on a scratch project directory:
  1. `agent-shell-crew-start` → `owner` + `check` sessions open named `owner@…`/`check@…`, each receives its brief.
  2. `agent-shell-crew-new` for `owner@…` → owner is nudged, calls `crew_show`, claims.
  3. Owner builds something trivial and hands off → check is nudged, claims, verifies.
  4. Check parks a question with numbered options → `agent-shell-crew-parked` returns it; `agent-shell-crew-decide` shows the options; decision recorded; check is nudged and continues.
  5. The queue file shows every step in each item's log.
  Record the result in the design doc's Status line.
