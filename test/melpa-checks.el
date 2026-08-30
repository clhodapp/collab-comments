;;; melpa-checks.el --- MELPA's checks, run against this checkout -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

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
;;
;; The checks MELPA asks of a submission, as batch entry points for
;; the Makefile: `collab-comments-checks-lint' runs package-lint on
;; the package file and checkdoc on every file, and
;; `collab-comments-checks-build' builds the package with
;; package-build the way MELPA does, from a recipe generated to point
;; at this checkout.  Both install their tool from MELPA into the
;; repository's .tools/ directory on first use.
;;
;;; Code:

(require 'checkdoc)
(require 'package)
(require 'subr-x)

(defconst collab-comments-checks--root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Root of the repository holding this file.")

(defun collab-comments-checks--ensure (&rest packages)
  "Install PACKAGES from MELPA into a scratch package directory and load them."
  (setq package-user-dir (expand-file-name ".tools" collab-comments-checks--root))
  (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
  (package-initialize)
  (dolist (package packages)
    (unless (package-installed-p package)
      (unless package-archive-contents
        (package-refresh-contents))
      (package-install package))
    (require package)))

(defun collab-comments-checks-lint ()
  "Run package-lint and checkdoc; exit non-zero on any finding."
  (collab-comments-checks--ensure 'package-lint)
  (let ((default-directory collab-comments-checks--root)
        (failed nil))
    (with-current-buffer (find-file-noselect "collab-comments.el")
      (dolist (finding (package-lint-buffer))
        (setq failed t)
        (message "collab-comments.el:%d:%d: %s: %s"
                 (nth 0 finding) (nth 1 finding) (nth 2 finding)
                 (nth 3 finding))))
    (setq sentence-end-double-space t)
    ;; With notes taken, checkdoc writes a section header per file to
    ;; its diagnostic buffer whether or not it finds anything, and sets
    ;; `checkdoc-pending-errors' only when it does.
    (let ((checkdoc-diagnostic-buffer "*checkdoc*")
          (checkdoc-failed nil))
      (dolist (file '("collab-comments.el"
                      "test/collab-comments-test.el"
                      "test/melpa-checks.el"))
        (with-current-buffer (find-file-noselect file)
          (checkdoc-current-buffer t)
          (when checkdoc-pending-errors
            (setq checkdoc-failed t))))
      (when checkdoc-failed
        (setq failed t)
        (with-current-buffer checkdoc-diagnostic-buffer
          (message "%s" (string-trim (buffer-string))))))
    (kill-emacs (if failed 1 0))))

(defun collab-comments-checks-build ()
  "Build the package with package-build, as MELPA would, from this checkout.
Builds the snapshot channel, then the stable channel (which needs a
release tag), into .tools/melpa/packages/."
  (collab-comments-checks--ensure 'package-build)
  (let* ((scratch (expand-file-name ".tools/melpa" collab-comments-checks--root))
         (package-build-recipes-dir (expand-file-name "recipes" scratch))
         (package-build-archive-dir (expand-file-name "packages" scratch))
         (package-build-working-dir (expand-file-name "working" scratch)))
    (when (file-directory-p scratch)
      (delete-directory scratch t))
    (dolist (dir (list package-build-recipes-dir
                       package-build-archive-dir
                       package-build-working-dir))
      (make-directory dir t))
    (with-temp-file (expand-file-name "collab-comments" package-build-recipes-dir)
      (prin1 `(collab-comments :fetcher git :url ,collab-comments-checks--root)
             (current-buffer)))
    (package-build-archive "collab-comments")
    (setq package-build-stable t)
    (package-build-archive "collab-comments")
    (message "Built: %s"
             (directory-files package-build-archive-dir nil "\\.tar\\'"))))

(provide 'melpa-checks)
;;; melpa-checks.el ends here
