;;; log-edit.el --- Major mode for editing CVS commit messages

;; Copyright (C) 1999, 2000  Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@cs.yale.edu>
;; Keywords: pcl-cvs cvs commit log
;; Revision: $Id: log-edit.el,v 1.1.1.1 2001/10/31 17:55:55 jevans Exp $

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Todo:

;; - Move in VC's code
;; - Add compatibility for VC's hook variables

;;; Code:

(eval-when-compile (require 'cl))
(require 'add-log)			; for all the ChangeLog goodies
(require 'pcvs-util)
(require 'ring)
(require 'vc)

;;;; 
;;;; Global Variables
;;;; 

(defgroup log-edit nil
  "Major mode for editing RCS and CVS commit messages."
  :group 'pcl-cvs
  :group 'vc				; It's used by VC.
  :version "21.1"
  :prefix "log-edit-")

;; compiler pacifiers
(defvar cvs-buffer)

(easy-mmode-defmap log-edit-mode-map
  `(("\C-c\C-c" . log-edit-done)
    ("\C-c\C-a" . log-edit-insert-changelog)
    ("\C-c\C-f" . log-edit-show-files)
    ("\C-c?" . log-edit-mode-help))
  "Keymap for the `log-edit-mode' (to edit version control log messages)."
  :group 'log-edit
  :inherit (if (boundp 'vc-log-entry-mode) vc-log-entry-mode
	     (if (boundp 'vc-log-mode-map) vc-log-mode-map)))

(easy-menu-define log-edit-menu log-edit-mode-map
  "Menu used for `log-edit-mode'."
  '("Log-Edit"
    ["Done" log-edit-done
     :help "Exit log-edit and proceed with the actual action."]
    "--"
    ["Insert ChangeLog" log-edit-insert-changelog]
    ["Add to ChangeLog" log-edit-add-to-changelog]
    "--"
    ["List files" log-edit-show-files
     :help "Show the list of relevant files."]
    "--"
    ["Previous comment" vc-previous-comment]
    ["Next comment" vc-next-comment]
    ["Search comment forward" vc-comment-search-forward]
    ["Search comment backward" vc-comment-search-reverse]))

(defcustom log-edit-confirm 'changed
  "*If non-nil, `log-edit-done' will request confirmation.
If 'changed, only request confirmation if the list of files has
  changed since the beginning of the log-edit session."
  :group 'log-edit
  :type '(choice (const changed) (const t) (const nil)))

(defcustom log-edit-keep-buffer nil
  "*If non-nil, don't hide the buffer after `log-edit-done'."
  :group 'log-edit
  :type 'boolean)

(defvar cvs-commit-buffer-require-final-newline t
  "Obsolete, use `log-edit-require-final-newline'.")

(defcustom log-edit-require-final-newline
  cvs-commit-buffer-require-final-newline
  "*Enforce a newline at the end of commit log messages.
Enforce it silently if t, query if non-nil and don't do anything if nil."
  :group 'log-edit
  :type '(choice (const ask) (const t) (const nil)))

(defcustom log-edit-setup-invert nil
  "*Non-nil means `log-edit' should invert the meaning of its SETUP arg.
If SETUP is 'force, this variable has no effect."
  :group 'log-edit
  :type 'boolean)

(defcustom log-edit-hook '(log-edit-insert-cvs-template
			   log-edit-insert-changelog)
  "*Hook run at the end of `log-edit'."
  :group 'log-edit
  :type '(hook :options (log-edit-insert-cvs-template
			 log-edit-insert-changelog)))

(defcustom log-edit-mode-hook (if (boundp 'vc-log-mode-hook) vc-log-mode-hook)
  "*Hook run when entering `log-edit-mode'."
  :group 'log-edit
  :type 'hook)

(defcustom log-edit-done-hook nil
  "*Hook run before doing the actual commit.
This hook can be used to cleanup the message, enforce various
conventions, or to allow recording the message in some other database,
such as a bug-tracking system.  The list of files about to be committed
can be obtained from `log-edit-files'."
  :group 'log-edit
  :type '(hook :options (log-edit-set-common-indentation
			 log-edit-add-to-changelog)))

(defvar cvs-changelog-full-paragraphs t
  "Obsolete, use `log-edit-changelog-full-paragraphs'.")

(defvar log-edit-changelog-full-paragraphs cvs-changelog-full-paragraphs
  "*If non-nil, include full ChangeLog paragraphs in the log.
This may be set in the ``local variables'' section of a ChangeLog, to
indicate the policy for that ChangeLog.

A ChangeLog paragraph is a bunch of log text containing no blank lines;
a paragraph usually describes a set of changes with a single purpose,
but perhaps spanning several functions in several files.  Changes in
different paragraphs are unrelated.

You could argue that the log entry for a file should contain the
full ChangeLog paragraph mentioning the change to the file, even though
it may mention other files, because that gives you the full context you
need to understand the change.  This is the behaviour you get when this
variable is set to t.

On the other hand, you could argue that the log entry for a change
should contain only the text for the changes which occurred in that
file, because the log is per-file.  This is the behaviour you get
when this variable is set to nil.")

;;;; Internal global or buffer-local vars

(defconst log-edit-files-buf "*log-edit-files*")
(defvar log-edit-initial-files nil)
(defvar log-edit-callback nil)
(defvar log-edit-listfun nil)
(defvar log-edit-parent-buffer nil)

;;;
;;; Actual code
;;;

;;;###autoload
(defun log-edit (callback &optional setup listfun buffer &rest ignore)
  "Setup a buffer to enter a log message.
\\<log-edit-mode-map>The buffer will be put in `log-edit-mode'.
If SETUP is non-nil, the buffer is then erased and `log-edit-hook' is run.
Mark and point will be set around the entire contents of the
buffer so that it is easy to kill the contents of the buffer with \\[kill-region].
Once you're done editing the message, pressing \\[log-edit-done] will call
`log-edit-done' which will end up calling CALLBACK to do the actual commit.
LISTFUN if non-nil is a function of no arguments returning the list of files
  that are concerned by the current operation (using relative names).
If BUFFER is non-nil `log-edit' will jump to that buffer, use it to edit the
  log message and go back to the current buffer when done.  Otherwise, it
  uses the current buffer."
  (let ((parent (current-buffer)))
    (if buffer (pop-to-buffer buffer))
    (when (and log-edit-setup-invert (not (eq setup 'force)))
      (setq setup (not setup)))
    (when setup (erase-buffer))
    (log-edit-mode)
    (set (make-local-variable 'log-edit-callback) callback)
    (set (make-local-variable 'log-edit-listfun) listfun)
    (if buffer (set (make-local-variable 'log-edit-parent-buffer) parent))
    (when setup (run-hooks 'log-edit-hook))
    (goto-char (point-min)) (push-mark (point-max))
    (set (make-local-variable 'log-edit-initial-files) (log-edit-files))
    (message (substitute-command-keys
	      "Press \\[log-edit-done] when you are done editing."))))

(define-derived-mode log-edit-mode text-mode "Log-Edit"
  "Major mode for editing version-control log messages.
When done editing the log entry, just type \\[log-edit-done] which
will trigger the actual commit of the file(s).
Several other handy support commands are provided of course and
the package from which this is used might also provide additional
commands (under C-x v for VC, for example).

\\{log-edit-mode-map}"
  (make-local-variable 'vc-comment-ring-index))

(defun log-edit-hide-buf (&optional buf where)
  (when (setq buf (get-buffer (or buf log-edit-files-buf)))
    (let ((win (get-buffer-window buf where)))
      (if win (ignore-errors (delete-window win))))
    (bury-buffer buf)))

(defun log-edit-done ()
  "Finish editing the log message and commit the files.
If you want to abort the commit, simply delete the buffer."
  (interactive)
  ;; Get rid of trailing empty lines
  (goto-char (point-max))
  (skip-syntax-backward " ")
  (when (equal (char-after) ?\n) (forward-char 1))
  (delete-region (point) (point-max))
  ;; Check for final newline
  (if (and (> (point-max) (point-min))
	   (/= (char-before (point-max)) ?\n)
	   (or (eq log-edit-require-final-newline t)
	       (and log-edit-require-final-newline
		    (y-or-n-p
		     (format "Buffer %s does not end in newline.  Add one? "
			     (buffer-name))))))
      (save-excursion
	(goto-char (point-max))
	(insert ?\n)))
  (let ((comment (buffer-string)))
    (when (or (ring-empty-p vc-comment-ring)
	      (not (equal comment (ring-ref vc-comment-ring 0))))
      (ring-insert vc-comment-ring comment)))
  (let ((win (get-buffer-window log-edit-files-buf)))
    (if (and log-edit-confirm
	     (not (and (eq log-edit-confirm 'changed)
		       (equal (log-edit-files) log-edit-initial-files)))
	     (progn
	       (log-edit-show-files)
	       (not (y-or-n-p "Really commit ? "))))
	(progn (when (not win) (log-edit-hide-buf))
	       (message "Oh, well!  Later maybe?"))
      (run-hooks 'log-edit-done-hook)
      (log-edit-hide-buf)
      (unless (or log-edit-keep-buffer (not log-edit-parent-buffer))
	(cvs-bury-buffer (current-buffer) log-edit-parent-buffer))
      (call-interactively log-edit-callback))))

(defun log-edit-files ()
  "Return the list of files that are about to be committed."
  (ignore-errors (funcall log-edit-listfun)))


(defun log-edit-insert-changelog ()
  "Insert a log message by looking at the ChangeLog.
The idea is to write your ChangeLog entries first, and then use this
command to commit your changes.

To select default log text, we:
- find the ChangeLog entries for the files to be checked in,
- verify that the top entry in the ChangeLog is on the current date
  and by the current user; if not, we don't provide any default text,
- search the ChangeLog entry for paragraphs containing the names of
  the files we're checking in, and finally
- use those paragraphs as the log text."
  (interactive)
  (log-edit-insert-changelog-entries (log-edit-files))
  (log-edit-set-common-indentation)
  (goto-char (point-min))
  (when (looking-at "\\*\\s-+")
    (forward-line 1)
    (when (not (re-search-forward "^\\*\\s-+" nil t))
      (goto-char (point-min))
      (skip-chars-forward "^():")
      (skip-chars-forward ": ")
      (delete-region (point-min) (point)))))

(defun log-edit-mode-help ()
  "Provide help for the `log-edit-mode-map'."
  (interactive)
  (if (eq last-command 'log-edit-mode-help)
      (describe-function major-mode)
    (message
     (substitute-command-keys
      "Type `\\[log-edit-done]' to finish commit.  Try `\\[describe-function] log-edit-done' for more help."))))

(defcustom log-edit-common-indent 0
  "Minimum indentation to use in `log-edit-set-common-indentation'."
  :group 'log-edit
  :type 'integer)

(defun log-edit-set-common-indentation ()
  "(Un)Indent the current buffer rigidly to `log-edit-common-indent'."
  (save-excursion
    (let ((common (point-max)))
      (goto-char (point-min))
      (while (< (point) (point-max))
        (if (not (looking-at "^[ \t]*$"))
            (setq common (min common (current-indentation))))
        (forward-line 1))
      (indent-rigidly (point-min) (point-max)
		      (- log-edit-common-indent common)))))

(defun log-edit-show-files ()
  "Show the list of files to be committed."
  (interactive)
  (let* ((files (log-edit-files))
	 (editbuf (current-buffer))
	 (buf (get-buffer-create log-edit-files-buf)))
    (with-current-buffer buf
      (log-edit-hide-buf buf 'all)
      (setq buffer-read-only nil)
      (erase-buffer)
      (cvs-insert-strings files)
      (setq buffer-read-only t)
      (goto-char (point-min))
      (save-selected-window
	(cvs-pop-to-buffer-same-frame buf)
	(shrink-window-if-larger-than-buffer)
	(selected-window)))))

(defun log-edit-insert-cvs-template ()
  "Insert the template specified by the CVS administrator, if any."
  (interactive)
  (when (file-readable-p "CVS/Template")
    (insert-file-contents "CVS/Template")))
  

(defun log-edit-add-to-changelog ()
  "Insert this log message into the appropriate ChangeLog file."
  (interactive)
  ;; Yuck!
  (unless (string= (buffer-string) (ring-ref vc-comment-ring 0))
    (ring-insert vc-comment-ring (buffer-string)))
  (dolist (f (log-edit-files))
    (let ((buffer-file-name (expand-file-name f)))
      (save-excursion
	(vc-comment-to-change-log)))))

;;;; 
;;;; functions for getting commit message from ChangeLog a file...
;;;; Courtesy Jim Blandy
;;;; 

(defun log-edit-narrow-changelog ()
  "Narrow to the top page of the current buffer, a ChangeLog file.
Actually, the narrowed region doesn't include the date line.
A \"page\" in a ChangeLog file is the area between two dates."
  (or (eq major-mode 'change-log-mode)
      (error "log-edit-narrow-changelog: current buffer isn't a ChangeLog"))

  (goto-char (point-min))

  ;; Skip date line and subsequent blank lines.
  (forward-line 1)
  (if (looking-at "[ \t\n]*\n")
      (goto-char (match-end 0)))

  (let ((start (point)))
    (forward-page 1)
    (narrow-to-region start (point))
    (goto-char (point-min))))

(defun log-edit-changelog-paragraph ()
  "Return the bounds of the ChangeLog paragraph containing point.
If we are between paragraphs, return the previous paragraph."
  (save-excursion
    (beginning-of-line)
    (if (looking-at "^[ \t]*$")
        (skip-chars-backward " \t\n" (point-min)))
    (list (progn
            (if (re-search-backward "^[ \t]*\n" nil 'or-to-limit)
                (goto-char (match-end 0)))
            (point))
          (if (re-search-forward "^[ \t\n]*$" nil t)
              (match-beginning 0)
            (point)))))

(defun log-edit-changelog-subparagraph ()
  "Return the bounds of the ChangeLog subparagraph containing point.
A subparagraph is a block of non-blank lines beginning with an asterisk.
If we are between sub-paragraphs, return the previous subparagraph."
  (save-excursion
    (end-of-line)
    (if (search-backward "*" nil t)
        (list (progn (beginning-of-line) (point))
              (progn
                (forward-line 1)
                (if (re-search-forward "^[ \t]*[\n*]" nil t)
                    (match-beginning 0)
                  (point-max))))
      (list (point) (point)))))

(defun log-edit-changelog-entry ()
  "Return the bounds of the ChangeLog entry containing point.
The variable `log-edit-changelog-full-paragraphs' decides whether an
\"entry\" is a paragraph or a subparagraph; see its documentation string
for more details."
  (if log-edit-changelog-full-paragraphs
      (log-edit-changelog-paragraph)
    (log-edit-changelog-subparagraph)))

(defvar user-full-name)
(defvar user-mail-address)
(defun log-edit-changelog-ours-p ()
  "See if ChangeLog entry at point is for the current user, today.
Return non-nil iff it is."
  ;; Code adapted from add-change-log-entry.
  (let ((name (or (and (boundp 'add-log-full-name) add-log-full-name)
		  (and (fboundp 'user-full-name) (user-full-name))
		  (and (boundp 'user-full-name) user-full-name)))
        (mail (or (and (boundp 'add-log-mailing-address) add-log-mailing-address)
		  ;;(and (fboundp 'user-mail-address) (user-mail-address))
		  (and (boundp 'user-mail-address) user-mail-address)))
	(time (or (and (boundp 'add-log-time-format)
		       (functionp add-log-time-format)
		       (funcall add-log-time-format))
		  (format-time-string "%Y-%m-%d"))))
    (looking-at (regexp-quote (format "%s  %s  <%s>" time name mail)))))

(defun log-edit-changelog-entries (file)
  "Return the ChangeLog entries for FILE, and the ChangeLog they came from.
The return value looks like this:
  (LOGBUFFER (ENTRYSTART . ENTRYEND) ...)
where LOGBUFFER is the name of the ChangeLog buffer, and each
\(ENTRYSTART . ENTRYEND\) pair is a buffer region."
  (save-excursion
    (let ((changelog-file-name
	   (let ((default-directory
		   (file-name-directory (expand-file-name file))))
	     ;; `find-change-log' uses `change-log-default-name' if set
	     ;; and sets it before exiting, so we need to work around
	     ;; that memoizing which is undesired here
	     (setq change-log-default-name nil)
	     (find-change-log))))
      (set-buffer (find-file-noselect changelog-file-name))
      (unless (eq major-mode 'change-log-mode) (change-log-mode))
      (goto-char (point-min))
      (if (looking-at "\\s-*\n") (goto-char (match-end 0)))
      (if (not (log-edit-changelog-ours-p))
	  (list (current-buffer))
	(save-restriction
	  (log-edit-narrow-changelog)
	  (goto-char (point-min))
	  
	  ;; Search for the name of FILE relative to the ChangeLog.  If that
	  ;; doesn't occur anywhere, they're not using full relative
	  ;; filenames in the ChangeLog, so just look for FILE; we'll accept
	  ;; some false positives.
	  (let ((pattern (file-relative-name
			  file (file-name-directory changelog-file-name))))
	    (if (or (string= pattern "")
		    (not (save-excursion
			   (search-forward pattern nil t))))
		(setq pattern (file-name-nondirectory file)))

	    (let (texts)
	      (while (search-forward pattern nil t)
		(let ((entry (log-edit-changelog-entry)))
		  (push entry texts)
		  (goto-char (elt entry 1))))

	      (cons (current-buffer) texts))))))))

(defun log-edit-changelog-insert-entries (buffer regions)
  "Insert those regions in BUFFER specified in REGIONS.
Sort REGIONS front-to-back first."
  (let ((regions (sort regions 'car-less-than-car))
        (last))
    (dolist (region regions)
      (when (and last (< last (car region))) (newline))
      (setq last (elt region 1))
      (apply 'insert-buffer-substring buffer region))))

(defun log-edit-insert-changelog-entries (files)
  "Given a list of files FILES, insert the ChangeLog entries for them."
  (let ((buffer-entries nil))

    ;; Add each buffer to buffer-entries, and associate it with the list
    ;; of entries we want from that file.
    (dolist (file files)
      (let* ((entries (log-edit-changelog-entries file))
             (pair (assq (car entries) buffer-entries)))
        (if pair
            (setcdr pair (cvs-union (cdr pair) (cdr entries)))
          (push entries buffer-entries))))

    ;; Now map over each buffer in buffer-entries, sort the entries for
    ;; each buffer, and extract them as strings.
    (dolist (buffer-entry buffer-entries)
      (log-edit-changelog-insert-entries (car buffer-entry) (cdr buffer-entry))
      (when (cdr buffer-entry) (newline)))))

(provide 'log-edit)

;;; log-edit.el ends here
