;;; collab-comments-test.el --- Tests for collab-comments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5

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
;; ERT suite for the model (threads, replies, dismissal, hiding,
;; navigation), anchors under text replacement, the thread view, and
;; persistence.  Run with `make test' (the Makefile has the direct
;; batch command).
;;
;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'collab-comments)

(defmacro collab-comments-test--with-buffer (content &rest body)
  "Run BODY in a fresh buffer holding CONTENT, cleaning up after."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "collab-comments-test")))
     (unwind-protect
         (with-current-buffer buffer
           (insert ,content)
           (goto-char (point-min))
           ,@body)
       (mapc #'collab-comments-dismiss-thread
             (collab-comments-threads buffer))
       (kill-buffer buffer))))

(defun collab-comments-test--thread-on (text comment)
  "Start a thread on the unique occurrence of TEXT with body COMMENT."
  (goto-char (point-min))
  (search-forward text)
  (collab-comments-add-thread (match-beginning 0) (match-end 0)
                              "tester" comment))

(defmacro collab-comments-test--with-store (&rest body)
  "Run BODY against a private, throwaway persistence store."
  (declare (indent 0))
  `(let ((collab-comments-store-file
          (make-temp-file "collab-store" nil ".eld"))
         (collab-comments--store 'unloaded))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p collab-comments-store-file)
         (delete-file collab-comments-store-file)))))

(defmacro collab-comments-test--with-file-buffer (content &rest body)
  "Run BODY with `file' visiting a temp file holding CONTENT.
Binds `file'; BODY manages buffers itself.  Cleans up file and any
surviving threads."
  (declare (indent 1))
  `(let ((file (make-temp-file "collab-persist" nil ".txt")))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,content))
           ,@body)
       (when-let* ((buffer (find-buffer-visiting file)))
         (mapc #'collab-comments-dismiss-thread
               (collab-comments-threads buffer))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-file file))))

(ert-deftest collab-comments-test-add-decorates-and-registers ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "first note")))
      (should (collab-comments-thread-p overlay))
      (should (eq overlay
                  (collab-comments-find
                   (collab-comments-thread-id overlay))))
      (should (eq (overlay-get overlay 'face) 'collab-comments-highlight))
      (should (equal "‹1›"
                     (substring-no-properties
                      (overlay-get overlay 'after-string))))
      (should (member overlay (collab-comments-threads))))))

(ert-deftest collab-comments-test-append-grows-thread-and-badge ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "first")))
      (collab-comments-append overlay "agent" "second")
      (should (= 2 (length (collab-comments-thread-comments overlay))))
      (should (equal "‹2›"
                     (substring-no-properties
                      (overlay-get overlay 'after-string)))))))

(ert-deftest collab-comments-test-render-thread ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((overlay (collab-comments-test--thread-on "beta" "first\nsecond line"))
           (rendered (progn (collab-comments-append overlay "agent" "reply")
                            (collab-comments-render-thread overlay))))
      (should (string-match-p (format "\\`#%d "
                                      (collab-comments-thread-id overlay))
                              rendered))
      (should (string-match-p "\"beta\"" rendered))
      (should (string-match-p "^  tester" rendered))
      (should (string-match-p "^    second line" rendered))
      (should (string-match-p "^  agent" rendered))
      (should (string-match-p "^    reply" rendered)))))

(ert-deftest collab-comments-test-timestamps-date-old-comments ()
  "Today's comments render bare HH:MM; older ones carry the date."
  (should (string-match-p "\\`[0-9][0-9]:[0-9][0-9]\\'"
                          (collab-comments--format-time (current-time))))
  (should-not (string-match-p
               "\\`[0-9][0-9]:[0-9][0-9]\\'"
               (collab-comments--format-time
                (time-subtract (current-time) (days-to-time 2))))))

(ert-deftest collab-comments-test-view-dividers-between-sections ()
  "The view wraps, rules off sections, and keeps every position id'd."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((first (collab-comments-test--thread-on "alpha" "one"))
           (second (collab-comments-test--thread-on "gamma" "two"))
           (view (collab-comments--view-buffer (current-buffer) t)))
      (unwind-protect
          (progn
            (collab-comments--view-render view)
            (with-current-buffer view
              (should visual-line-mode)
              (let ((divider (text-property-any
                              (point-min) (point-max)
                              'face 'collab-comments-divider)))
                (should divider)
                ;; One rule between two sections, none trailing.
                (should-not (text-property-any
                             (1+ divider) (point-max)
                             'face 'collab-comments-divider))
                ;; The rule belongs to the section above it; the tail
                ;; of the buffer still belongs to the last section.
                (should (eq (collab-comments-view--thread-id-at divider)
                            (collab-comments-thread-id first)))
                (should (eq (collab-comments-view--thread-id-at
                             (1- (point-max)))
                            (collab-comments-thread-id second))))))
        (kill-buffer view)))))

(ert-deftest collab-comments-test-dismiss ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((overlay (collab-comments-test--thread-on "beta" "note"))
           (id (collab-comments-thread-id overlay)))
      (collab-comments-dismiss-thread overlay)
      (should-not (collab-comments-find id))
      (should-not (collab-comments-threads)))))

(ert-deftest collab-comments-test-dismiss-all ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (collab-comments-test--thread-on "alpha" "one")
    (collab-comments-test--thread-on "gamma" "two")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (collab-comments-dismiss-all))
    (should-not (collab-comments-threads))))

(ert-deftest collab-comments-test-toggle-hidden-keeps-threads ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "note")))
      (collab-comments-toggle-hidden)
      (should-not (overlay-get overlay 'face))
      (should-not (overlay-get overlay 'after-string))
      (should (= 1 (length (collab-comments-threads))))
      (collab-comments-toggle-hidden)
      (should (eq (overlay-get overlay 'face)
                  'collab-comments-highlight)))))

(ert-deftest collab-comments-test-next-previous-wrap ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((first (collab-comments-test--thread-on "alpha" "one"))
          (second (collab-comments-test--thread-on "gamma" "two")))
      (goto-char (point-min))
      (collab-comments-next)
      (should (= (point) (overlay-start second)))
      (collab-comments-next)
      (should (= (point) (overlay-start first)))
      (collab-comments-previous)
      (should (= (point) (overlay-start second))))))

(ert-deftest collab-comments-test-undo-restores-boundaries ()
  "Deleting at an anchor edge and undoing must not shift the boundary."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((overlay (collab-comments-test--thread-on "beta" "note"))
           (beg (overlay-start overlay))
           (end (overlay-end overlay)))
      ;; Front edge.
      (setq buffer-undo-list nil)
      (delete-region beg (1+ beg))
      (primitive-undo 1 buffer-undo-list)
      (should (= (overlay-start overlay) beg))
      (should (= (overlay-end overlay) end))
      ;; Rear edge.
      (setq buffer-undo-list nil)
      (delete-region (1- end) end)
      (primitive-undo 1 buffer-undo-list)
      (should (= (overlay-start overlay) beg))
      (should (= (overlay-end overlay) end))
      ;; Whole anchor deleted and restored.
      (setq buffer-undo-list nil)
      (delete-region beg end)
      (primitive-undo 1 buffer-undo-list)
      (should (equal "beta"
                     (buffer-substring-no-properties
                      (overlay-start overlay) (overlay-end overlay)))))))

(ert-deftest collab-comments-test-edge-insertions-join-the-thread ()
  "The accepted trade-off of undo-safe edges: typing at an edge grows it."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((overlay (collab-comments-test--thread-on "beta" "note"))
           (beg (overlay-start overlay)))
      (goto-char beg)
      (insert "x")
      (should (= (overlay-start overlay) beg))
      (should (equal "xbeta"
                     (buffer-substring-no-properties
                      (overlay-start overlay) (overlay-end overlay)))))))

(ert-deftest collab-comments-test-read-thread-disambiguates-overlaps ()
  "Several threads at point offer a choice instead of silently picking."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((first (collab-comments-test--thread-on "beta" "first note"))
          (second (collab-comments-test--thread-on "beta" "second note")))
      (goto-char (overlay-start first))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (car (seq-find
                         (lambda (candidate)
                           (string-prefix-p
                            (format "#%d " (collab-comments-thread-id
                                            second))
                            (car candidate)))
                         collection)))))
        (should (eq (collab-comments--read-thread "Reply to thread: ")
                    second)))
      ;; A single thread at point still needs no prompt.
      (collab-comments-dismiss-thread second)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (error "Should not prompt"))))
        (should (eq (collab-comments--read-thread "Reply to thread: ")
                    first))))))

(ert-deftest collab-comments-test-eldoc-documents-thread-at-point ()
  "The eldoc doc function yields the thread inside, nil outside."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "eldoc note")))
      ;; Thread creation wires the buffer into eldoc.
      (should (if (boundp 'eldoc-documentation-functions)
                  (memq #'collab-comments--eldoc
                        eldoc-documentation-functions)
                (advice-function-member-p #'collab-comments--eldoc
                                          eldoc-documentation-function)))
      (let ((collab-comments-auto-show-mode t))
        (goto-char (point-min))
        (should-not (collab-comments--eldoc #'ignore))
        (goto-char (overlay-start overlay))
        (should (string-match-p "eldoc note"
                                (collab-comments--eldoc #'ignore)))
        ;; Hidden decorations silence it.
        (setq collab-comments-hidden t)
        (should-not (collab-comments--eldoc #'ignore))
        (setq collab-comments-hidden nil))
      ;; So does a disabled mode.
      (let ((collab-comments-auto-show-mode nil))
        (should-not (collab-comments--eldoc #'ignore))))))

(ert-deftest collab-comments-test-reply-falls-back-to-new-thread ()
  "Replying with no thread at point starts a thread; text is not lost."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (goto-char (point-min))
    (collab-comments-reply "fallback note")
    (let ((threads (collab-comments-threads)))
      (should (= 1 (length threads)))
      (should (= 1 (length (collab-comments-thread-comments
                            (car threads)))))
      (should (string-match-p
               "fallback note"
               (collab-comments-render-thread (car threads))))
      ;; On the new thread, reply now appends instead of nesting.
      (goto-char (overlay-start (car threads)))
      (collab-comments-reply "second")
      (should (= 1 (length (collab-comments-threads))))
      (should (= 2 (length (collab-comments-thread-comments
                            (car threads))))))))

(ert-deftest collab-comments-test-view-follows-into-source ()
  "Moving between view sections points the source window at the anchor."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((first (collab-comments-test--thread-on "alpha" "one"))
           (second (collab-comments-test--thread-on "gamma" "two"))
           (source (current-buffer))
           (view (collab-comments--view-buffer source t)))
      (unwind-protect
          (progn
            (collab-comments--view-render view)
            (set-window-buffer (selected-window) source)
            (with-current-buffer view
              (collab-comments-view-goto (collab-comments-thread-id second))
              (collab-comments-view--follow))
            (should (= (window-point (get-buffer-window source))
                       (overlay-start second)))
            (with-current-buffer view
              (collab-comments-view-goto (collab-comments-thread-id first))
              (collab-comments-view--follow))
            (should (= (window-point (get-buffer-window source))
                       (overlay-start first))))
        (kill-buffer view)))))

(ert-deftest collab-comments-test-source-syncs-visible-view ()
  "Entering a thread moves a visible view window to its section."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((first (collab-comments-test--thread-on "alpha" "one"))
           (second (collab-comments-test--thread-on "gamma" "two"))
           (source (current-buffer))
           (view (collab-comments--view-buffer source t)))
      (unwind-protect
          (progn
            (collab-comments--view-render view)
            (set-window-buffer (selected-window) view)
            ;; With the view visible, eldoc yields to the window sync.
            (goto-char (overlay-start second))
            (should-not (collab-comments--eldoc #'ignore))
            (collab-comments--auto-show)
            (should (eq (with-current-buffer view
                          (collab-comments-view--thread-id-at
                           (window-point (get-buffer-window view))))
                        (collab-comments-thread-id second)))
            (goto-char (overlay-start first))
            (collab-comments--auto-show)
            (should (eq (with-current-buffer view
                          (collab-comments-view--thread-id-at
                           (window-point (get-buffer-window view))))
                        (collab-comments-thread-id first))))
        (kill-buffer view)))))

(ert-deftest collab-comments-test-view-dismiss-all ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (collab-comments-test--thread-on "alpha" "one")
    (collab-comments-test--thread-on "gamma" "two")
    (let ((view (collab-comments--view-buffer (current-buffer) t)))
      (unwind-protect
          (progn
            (collab-comments--view-render view)
            (with-current-buffer view
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
                (collab-comments-view-dismiss-all))))
        (should-not (collab-comments-threads))
        (kill-buffer view)))))

(ert-deftest collab-comments-test-anchor-deletion-is-legible ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "note")))
      (delete-region (overlay-start overlay) (overlay-end overlay))
      (should (string-match-p "anchor text deleted"
                              (collab-comments-render-thread overlay))))))

;;; Anchors under text replacement

(defun collab-comments-test--anchor (overlay)
  "Anchor text of OVERLAY."
  (buffer-substring-no-properties (overlay-start overlay)
                                  (overlay-end overlay)))

(ert-deftest collab-comments-test-rewrite-refinds-anchors ()
  "Erase-and-reinsert (as a re-rendering viewer does) keeps threads on their text.
Without re-anchoring every collapsed thread would absorb the whole
insertion; a vanished anchor collapses instead of spanning the buffer."
  (collab-comments-test--with-buffer "alpha beta gamma\ndelta\n"
    (let ((kept (collab-comments-test--thread-on "beta" "kept"))
          (lost (collab-comments-test--thread-on "delta" "lost")))
      (erase-buffer)
      (insert "intro line\nalpha beta gamma\nepsilon\n")
      (should (equal "beta" (collab-comments-test--anchor kept)))
      (should (= (overlay-start lost) (overlay-end lost)))
      (should (string-match-p "anchor text deleted"
                              (collab-comments-render-thread lost))))))

(ert-deftest collab-comments-test-replace-match-does-not-swallow ()
  "A literal replacement never highlights the new text.
An anchor inside the replaced text is re-found in the replacement, or
collapses at the replacement's start when it is gone."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "note")))
      (goto-char (point-min))
      (search-forward "beta gamma")
      (replace-match "beta delta" t t)
      (should (equal "beta" (collab-comments-test--anchor overlay)))
      (goto-char (point-min))
      (search-forward "beta")
      (replace-match "a much longer replacement" t t)
      (should (= (overlay-start overlay) (overlay-end overlay)))
      (should (= (overlay-start overlay) 7)))))

(ert-deftest collab-comments-test-retyped-anchor-recovers-thread ()
  "Inserting a deleted anchor's text at its point re-covers it."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "note")))
      (delete-region (overlay-start overlay) (overlay-end overlay))
      (goto-char (overlay-start overlay))
      (insert "other")
      (should (= (overlay-start overlay) (overlay-end overlay)))
      (goto-char (overlay-start overlay))
      (insert "beta")
      (should (equal "beta" (collab-comments-test--anchor overlay))))))

(ert-deftest collab-comments-test-runaway-folds-to-end ()
  "A thread spanning the whole document folds to an empty anchor at its end."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "note")))
      ;; A straddling thread that a change stretches over everything.
      (move-overlay overlay (point-min) (1- (point-max)))
      (goto-char (point-max))
      (delete-char -1)
      (should (= (overlay-start overlay) (point-max)))
      (should (= (overlay-end overlay) (point-max)))
      (should (string-match-p "anchor text deleted"
                              (collab-comments-render-thread overlay))))))

(ert-deftest collab-comments-test-hooks-survive-mode-change ()
  "A major-mode change drops local hooks; threads get them back."
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let ((overlay (collab-comments-test--thread-on "beta" "note")))
      (text-mode)
      (should (memq #'collab-comments--after-change after-change-functions))
      (erase-buffer)
      (insert "alpha beta gamma\nmore\n")
      (should (equal "beta" (collab-comments-test--anchor overlay))))))

(ert-deftest collab-comments-test-view-render-and-actions ()
  (collab-comments-test--with-buffer "alpha beta gamma\n"
    (let* ((first (collab-comments-test--thread-on "alpha" "one"))
           (second (collab-comments-test--thread-on "gamma" "two"))
           (source (current-buffer))
           (view (collab-comments--view-buffer source t)))
      (unwind-protect
          (progn
            (collab-comments--view-render view)
            (with-current-buffer view
              (goto-char (point-min))
              (should (eq (collab-comments-view--thread-id-at (point))
                          (collab-comments-thread-id first)))
              (collab-comments-view-next)
              (should (eq (collab-comments-view--thread-id-at (point))
                          (collab-comments-thread-id second)))
              (should-error (collab-comments-view-next) :type 'user-error)
              (collab-comments-view-previous)
              (should (eq (collab-comments-view--thread-id-at (point))
                          (collab-comments-thread-id first)))
              (collab-comments-view-dismiss)
              ;; Dismissal re-renders the view; only the second remains.
              (should-not (collab-comments-find
                           (collab-comments-thread-id first)))
              (goto-char (point-min))
              (should (eq (collab-comments-view--thread-id-at (point))
                          (collab-comments-thread-id second)))))
        (kill-buffer view)))))

;;; Persistence

(ert-deftest collab-comments-test-persist-restore-exact ()
  "Threads survive buffer death and restore at exact positions."
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "alpha beta gamma\n"
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (collab-comments-test--thread-on "beta" "persisted note"))
        (kill-buffer buffer))                       ; the "crash"
      (with-current-buffer (find-file-noselect file)
        (should-not (collab-comments-threads))
        (collab-comments-restore)
        (let ((overlay (car (collab-comments-threads))))
          (should overlay)
          (should (equal "beta"
                         (buffer-substring-no-properties
                          (overlay-start overlay) (overlay-end overlay))))
          (should (string-match-p
                   "persisted note"
                   (collab-comments-render-thread overlay))))))))

(ert-deftest collab-comments-test-persist-runaway-record-folds ()
  "A persisted whole-document span restores as an empty anchor at the end."
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "alpha beta gamma\n"
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (let ((overlay (collab-comments-test--thread-on "beta" "note")))
            (move-overlay overlay (point-min) (point-max))
            (collab-comments-persist)))
        (kill-buffer buffer))
      (with-current-buffer (find-file-noselect file)
        (collab-comments-restore)
        (let ((overlay (car (collab-comments-threads))))
          (should overlay)
          (should (= (overlay-start overlay) (point-max)))
          (should (= (overlay-end overlay) (point-max)))
          (should (string-match-p "note"
                                  (collab-comments-render-thread overlay))))))))

(ert-deftest collab-comments-test-persist-reanchors-against-changed-file ()
  "Content drift re-finds anchors by text instead of trusting positions."
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "alpha beta gamma\n"
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (collab-comments-test--thread-on "beta" "note"))
        (kill-buffer buffer))
      (with-temp-file file (insert "an inserted line\nalpha beta gamma\n"))
      (with-current-buffer (find-file-noselect file)
        (collab-comments-restore)
        (let ((overlay (car (collab-comments-threads))))
          (should (equal "beta"
                         (buffer-substring-no-properties
                          (overlay-start overlay)
                          (overlay-end overlay)))))))))

(ert-deftest collab-comments-test-persist-ambiguous-anchor-picks-nearest ()
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "beta alpha\nbeta gamma\n"
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          ;; Thread on the SECOND beta.
          (goto-char (point-min))
          (search-forward "beta")
          (search-forward "beta")
          (collab-comments-add-thread (match-beginning 0) (match-end 0)
                                      "tester" "second beta"))
        (kill-buffer buffer))
      (with-temp-file file (insert "zzz\nbeta alpha\nbeta gamma\n"))
      (with-current-buffer (find-file-noselect file)
        (collab-comments-restore)
        (let ((overlay (car (collab-comments-threads))))
          ;; Nearest occurrence to the stored position: still the second.
          (should (> (overlay-start overlay)
                     (progn (goto-char (point-min))
                            (search-forward "beta")
                            (point)))))))))

(ert-deftest collab-comments-test-persist-vanished-anchor-keeps-conversation ()
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "alpha beta gamma\n"
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (collab-comments-test--thread-on "beta" "orphan me"))
        (kill-buffer buffer))
      (with-temp-file file (insert "nothing left\n"))
      (with-current-buffer (find-file-noselect file)
        (collab-comments-restore)
        (let ((overlay (car (collab-comments-threads))))
          (should overlay)
          (should (string-match-p "anchor text deleted"
                                  (collab-comments-render-thread overlay)))
          (should (string-match-p "orphan me"
                                  (collab-comments-render-thread
                                   overlay))))))))

(ert-deftest collab-comments-test-persist-dismissal-is-persistent ()
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "alpha beta gamma\n"
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (collab-comments-dismiss-thread
           (collab-comments-test--thread-on "beta" "gone"))
          (kill-buffer buffer)))
      (with-current-buffer (find-file-noselect file)
        (collab-comments-restore)
        (should-not (collab-comments-threads))))))

(ert-deftest collab-comments-test-persist-autosave-version-round-trip ()
  "Unsaved-text comments restore against recovered content, not the file.
Against the recovered auto-save content they restore exactly; against
the saved file they degrade to an orphan."
  (collab-comments-test--with-store
    (collab-comments-test--with-file-buffer "alpha\n"
     (let (modified-content)
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          ;; Unsaved edit introduces text existing only in the buffer.
          (goto-char (point-max))
          (insert "beta gamma\n")
          (setq modified-content (buffer-string))
          (collab-comments-test--thread-on "beta" "against autosave")
          ;; The auto-save checkpoint records the modified version.
          (collab-comments--persist-all)
          (set-buffer-modified-p nil))
        (kill-buffer buffer))                       ; crash, unsaved
      ;; Reopened without recovering: the anchor is gone from the
      ;; saved file; the conversation survives as an orphan.
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (collab-comments-restore)
          (should (string-match-p
                   "anchor text deleted"
                   (collab-comments-render-thread
                    (car (collab-comments-threads)))))
          ;; The user recovers the auto-saved content: the hash now
          ;; matches the persisted version and the anchor is exact.
          (erase-buffer)
          (insert modified-content)
          (collab-comments-restore)
          (let ((overlay (car (collab-comments-threads))))
            (should (equal "beta"
                           (buffer-substring-no-properties
                            (overlay-start overlay)
                            (overlay-end overlay)))))))))))

(ert-deftest collab-comments-test-persist-keyed-non-file-buffer ()
  "A declared document key persists a non-file buffer's threads.
A fresh buffer carrying the same key and content restores them at
exact positions (the content hash matches)."
  (collab-comments-test--with-store
    (let ((buffer (generate-new-buffer "keyed-doc")))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local collab-comments-document-key "agent-session:ert")
            (insert "alpha beta gamma\n")
            (collab-comments-test--thread-on "beta" "keyed note"))
        (kill-buffer buffer)))                      ; the "restart"
    (let ((buffer (generate-new-buffer "keyed-doc-reborn")))
      (unwind-protect
          (with-current-buffer buffer
            (insert "alpha beta gamma\n")
            (setq-local collab-comments-document-key "agent-session:ert")
            (should-not (collab-comments-threads))
            (collab-comments-restore)
            (let ((overlay (car (collab-comments-threads))))
              (should overlay)
              (should (equal "beta"
                             (buffer-substring-no-properties
                              (overlay-start overlay)
                              (overlay-end overlay))))
              (should (string-match-p
                       "keyed note"
                       (collab-comments-render-thread overlay)))))
        (mapc #'collab-comments-dismiss-thread
              (collab-comments-threads buffer))
        (kill-buffer buffer)))))

(ert-deftest collab-comments-test-persist-undeclared-buffer-stays-session-scoped ()
  "A non-file buffer with no document key never reaches the store."
  (collab-comments-test--with-store
    (collab-comments-test--with-buffer "alpha beta gamma\n"
      (collab-comments-test--thread-on "beta" "ephemeral")
      (should (null (collab-comments--store))))))

(ert-deftest collab-comments-test-command-map-covers-commands ()
  "The prefix map binds every interactive entry point; nothing is global."
  (dolist (pair '(("a" . collab-comments-add)
                  ("r" . collab-comments-reply)
                  ("k" . collab-comments-show)
                  ("b" . collab-comments-browse)
                  ("n" . collab-comments-next)
                  ("p" . collab-comments-previous)
                  ("d" . collab-comments-dismiss)
                  ("D" . collab-comments-dismiss-all)
                  ("h" . collab-comments-toggle-hidden)
                  ("t" . collab-comments-auto-show-mode)
                  ("g" . collab-comments-restore)))
    (should (eq (lookup-key collab-comments-command-map (kbd (car pair)))
                (cdr pair))))
  (should (keymapp (symbol-function 'collab-comments-command-map)))
  (should-not (where-is-internal 'collab-comments-add global-map))
  (should (eq (get 'collab-comments-next 'repeat-map)
              'collab-comments-repeat-map)))

(provide 'collab-comments-test)
;;; collab-comments-test.el ends here
