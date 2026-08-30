;;; collab-comments.el --- Comment threads on buffer text, shared with agents -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5
;; Maintainer: Chris Hodapp <chris@hodapp.email>
;; URL: https://github.com/clhodapp/collab-comments
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: convenience, tools

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
;; Review-style comment threads anchored to regions of buffer text, for
;; collaboration between a person and coding agents editing the same
;; buffers.  Threads live in overlays: they never modify the text they
;; annotate.  Threads on buffers with a document key (a visited file, or
;; a declared `collab-comments-document-key') persist across restarts;
;; other buffers are session-scoped.  Commented text is highlighted and
;; carries a comment-count badge and a hover preview; the thread view
;; (`collab-comments-show') is a side buffer listing threads with keys
;; to reply, dismiss, and visit.
;;
;; Agents reach the same threads through the model functions
;; (`collab-comments-add-thread', `collab-comments-append',
;; `collab-comments-find', `collab-comments-threads',
;; `collab-comments-all-threads', `collab-comments-render-thread'),
;; typically wrapped by whatever tool protocol the agent speaks.
;;
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eldoc)

(defgroup collab-comments nil
  "Comment threads on buffer text, shared with coding agents."
  :group 'convenience
  :prefix "collab-comments-")

(defcustom collab-comments-author nil
  "Author name attached to interactively added comments.
When nil, the value of function `user-login-name' is used."
  :type '(choice (const :tag "Login name" nil) string))

(defcustom collab-comments-excerpt-length 48
  "Max characters of anchor text shown in thread listings."
  :type 'integer)

(defface collab-comments-highlight
  '((((background dark)) :background "#3d3425")
    (t :background "#fdf3c5"))
  "Face for text that carries a comment thread.")

(defface collab-comments-badge
  '((((background dark)) :foreground "#e5c07b" :weight bold)
    (t :foreground "#b58900" :weight bold))
  "Face for the comment-count badge after commented text.")

(defface collab-comments-author-face
  '((t :weight bold))
  "Face for author names in thread renderings.")

(defface collab-comments-location-face
  '((t :inherit shadow))
  "Face for the buffer:line location in thread headers.")

(defface collab-comments-excerpt-face
  '((t :inherit (italic collab-comments-highlight)))
  "Face for the quoted anchor excerpt in thread headers.
Inherits the anchor highlight so the excerpt reads as a swatch of the
commented text.")

(defface collab-comments-time-face
  '((t :inherit shadow))
  "Face for comment timestamps in thread renderings.")

(defface collab-comments-divider
  '((((background dark)) :strike-through "grey70")
    (t :strike-through "grey50"))
  "Face for the rule separating thread sections in the thread view.
Drawn as a strike-through stretch glyph spanning the window; the line
takes the colors of the `shadow' face without inheriting it, so a
theme can restyle it outright.")

(defvar collab-comments--next-id 1
  "Session-unique id handed to the next new thread.")

(defvar collab-comments--registry (make-hash-table :test #'eql)
  "Map from thread id to overlay.
Overlays are the source of truth; entries whose overlay no longer
lives in a buffer are stale and skipped.")

(defvar-local collab-comments-hidden nil
  "When non-nil, thread decorations in this buffer are invisible.
The threads themselves are retained; toggle with
`collab-comments-toggle-hidden'.")

(defvar-local collab-comments-document-key nil
  "Persistence key of the document this buffer displays, or nil.
Nil means the buffer stands for the file it visits (threads persist
under the file truename) and a non-file buffer is session-scoped.
A mode whose buffer renders a durable document that is not a file
declares the document here (a transcript viewer might use
session:<session-id>) so threads persist under that key and
`collab-comments-restore' can rebuild them after the mode re-renders
the buffer, and across Emacs restarts.  Set it after the major mode
is established: changing modes kills buffer-local variables.")

;;; Model

(defun collab-comments-thread-p (overlay)
  "Whether OVERLAY is a live comment-thread anchor."
  (and (overlayp overlay)
       (overlay-buffer overlay)
       (overlay-get overlay 'collab-comments-id)))

(defun collab-comments-thread-id (overlay)
  "Id of the thread OVERLAY."
  (overlay-get overlay 'collab-comments-id))

(defun collab-comments-thread-comments (overlay)
  "Comments of the thread OVERLAY, oldest first.
Each comment is a plist with :author, :time, and :text."
  (overlay-get overlay 'collab-comments-comments))

(defun collab-comments-find (id)
  "Live thread overlay with ID, or nil."
  (let ((overlay (gethash id collab-comments--registry)))
    (and (collab-comments-thread-p overlay) overlay)))

(defun collab-comments-threads (&optional buffer)
  "Live thread overlays in BUFFER (default current), by position."
  (with-current-buffer (or buffer (current-buffer))
    (sort (seq-filter #'collab-comments-thread-p
                      (overlays-in (point-min) (point-max)))
          (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(defun collab-comments-all-threads ()
  "Live thread overlays across all buffers, grouped by buffer.
Also drops stale registry entries encountered along the way."
  (let (threads stale)
    (maphash (lambda (id overlay)
               (if (collab-comments-thread-p overlay)
                   (push overlay threads)
                 (push id stale)))
             collab-comments--registry)
    (dolist (id stale) (remhash id collab-comments--registry))
    (sort threads
          (lambda (a b)
            (let ((buffer-a (buffer-name (overlay-buffer a)))
                  (buffer-b (buffer-name (overlay-buffer b))))
              (if (string= buffer-a buffer-b)
                  (< (overlay-start a) (overlay-start b))
                (string< buffer-a buffer-b)))))))

(defun collab-comments-threads-at (position &optional buffer)
  "Live thread overlays covering or touching POSITION in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (sort (seq-filter #'collab-comments-thread-p
                      (overlays-in (max (point-min) (1- position))
                                   (min (point-max) (1+ position))))
          (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(defun collab-comments--author ()
  "Author name for comments added interactively."
  (or collab-comments-author (user-login-name)))

(defun collab-comments--make-thread (beg end comments &optional buffer)
  "Create a thread overlay over BEG..END in BUFFER carrying COMMENTS.
The model-level constructor shared by `collab-comments-add-thread' and
restoration from the persisted store."
  (with-current-buffer (or buffer (current-buffer))
    ;; Both edges inclusive (front-advance nil, rear-advance t): undo
    ;; does not adjust overlay markers, so with exclusive edges a
    ;; deletion at an anchor edge undone re-inserts the text OUTSIDE
    ;; the thread — a silent, permanent boundary shift.  Inclusive
    ;; edges restore the boundary under undo (and re-cover a fully
    ;; deleted anchor); the price is that typing directly at an edge
    ;; grows the thread, which is visible and easy to live with.  The
    ;; other consequence — a collapsed anchor swallowing whatever is
    ;; inserted at its point — is undone by the change hooks
    ;; (`collab-comments--after-change'), which re-find a wholesale
    ;; replaced anchor by its text.
    (let ((overlay (make-overlay beg end nil nil t))
          (id collab-comments--next-id))
      (setq collab-comments--next-id (1+ collab-comments--next-id))
      (overlay-put overlay 'collab-comments-id id)
      (overlay-put overlay 'collab-comments-comments comments)
      (puthash id overlay collab-comments--registry)
      (collab-comments--decorate overlay)
      (collab-comments--install-hooks)
      (collab-comments--view-refresh (current-buffer))
      overlay)))

(defun collab-comments--install-hooks ()
  "Install the buffer-local hooks a buffer holding threads needs.
Idempotent.  Run at thread creation and again after a major-mode
change, which drops buffer-local hooks while the overlays survive."
  ;; Ahead (depth -50) of the buffer-local LSP/flymake doc functions:
  ;; inside commented text the thread is the documentation.  Before
  ;; Emacs 28 eldoc consults the single `eldoc-documentation-function'
  ;; instead; advise its buffer-local value.
  (if (boundp 'eldoc-documentation-functions)
      (add-hook 'eldoc-documentation-functions #'collab-comments--eldoc -50 t)
    (add-function :before-until (local 'eldoc-documentation-function)
                  #'collab-comments--eldoc))
  (eldoc-mode 1)
  (add-hook 'before-change-functions #'collab-comments--before-change nil t)
  (add-hook 'after-change-functions #'collab-comments--after-change nil t))

(defun collab-comments--rehook ()
  "Re-install the local hooks when the new major mode's buffer has threads."
  (when (collab-comments-threads)
    (collab-comments--install-hooks)))

(add-hook 'after-change-major-mode-hook #'collab-comments--rehook)

;;; Anchors under text replacement

(defvar-local collab-comments--displaced nil
  "Threads the change in progress replaces wholesale.
Recorded by `collab-comments--before-change' for
`collab-comments--after-change' to re-anchor.")

(defun collab-comments--anchor-text (overlay)
  "Current anchor text of the thread OVERLAY, without properties."
  (with-current-buffer (overlay-buffer overlay)
    (buffer-substring-no-properties (overlay-start overlay)
                                    (overlay-end overlay))))

(defun collab-comments--remembered-anchor (overlay)
  "Last non-empty anchor of OVERLAY as (TEXT . START), or nil.
The live anchor when it holds text; otherwise what the thread held
before its anchor was deleted, so a collapsed thread still knows the
text that would bring it back."
  (if (< (overlay-start overlay) (overlay-end overlay))
      (cons (collab-comments--anchor-text overlay) (overlay-start overlay))
    (overlay-get overlay 'collab-comments-anchor)))

(defun collab-comments--locate (anchor origin beg end)
  "Range (B . E) of the ANCHOR text within BEG..END nearest to ORIGIN.
With no occurrence (or an empty ANCHOR) the range is empty, at ORIGIN
clamped into BEG..END: the thread collapses where its text was rather
than being dropped."
  (let ((case-fold-search nil)
        matches)
    (unless (or (null anchor) (string-empty-p anchor))
      (save-excursion
        (goto-char beg)
        (while (search-forward anchor end t)
          (push (cons (match-beginning 0) (match-end 0)) matches))))
    (or (car (sort matches
                   (lambda (a b) (< (abs (- (car a) origin))
                                    (abs (- (car b) origin))))))
        (let ((pos (min (max beg origin) end)))
          (cons pos pos)))))

(defun collab-comments--before-change (beg end)
  "Record the threads replaced wholesale by the impending change of BEG..END.
A thread whose anchor lies entirely inside the range (an empty anchor
at the change point included) is about to collapse and, with
inclusive edges, to absorb whatever replaces the range; its anchor is
remembered here so `collab-comments--after-change' can re-find it.
The match data is preserved: `replace-match' runs these hooks and,
before Emacs 28, rejects ones that clobber it."
  (with-demoted-errors "collab-comments before-change: %S"
    (save-match-data
      (setq collab-comments--displaced nil)
      (dolist (overlay (overlays-in (max (point-min) (1- beg))
                                    (min (point-max) (1+ end))))
        (when (and (collab-comments-thread-p overlay)
                   (>= (overlay-start overlay) beg)
                   (<= (overlay-end overlay) end))
          (when-let* ((anchor (collab-comments--remembered-anchor overlay)))
            (overlay-put overlay 'collab-comments-anchor anchor))
          (push overlay collab-comments--displaced))))))

(defun collab-comments--after-change (beg end _old-length)
  "Re-anchor the threads displaced by the change that produced BEG..END.
Each displaced thread moves onto its remembered anchor text within the
new range (the occurrence nearest its old position), or collapses at
that position when the text is gone — the policy
`collab-comments--reanchor' applies across restarts, applied live.
Whole-buffer rewrites (erase and reinsert, as re-rendering viewers
do) and literal replacements (`replace-match') thus keep threads on
their text instead of highlighting the whole insertion.
Independently, a thread that ends up spanning the whole document is
folded to an empty anchor at its end
\(`collab-comments--fold-runaway')."
  (with-demoted-errors "collab-comments after-change: %S"
    (save-match-data
      (let ((displaced collab-comments--displaced)
            moved)
        (setq collab-comments--displaced nil)
        (dolist (overlay displaced)
          (when (collab-comments-thread-p overlay)
            (pcase-let ((`(,anchor . ,origin)
                         (or (overlay-get overlay 'collab-comments-anchor)
                             (cons nil beg))))
              (let ((range (collab-comments--locate anchor origin beg end)))
                (move-overlay overlay (car range) (cdr range))
                (push overlay moved)))))
        (save-restriction
          (widen)
          (when (or (= beg (point-min)) (= end (point-max)))
            (dolist (overlay (collab-comments-threads))
              (when (collab-comments--fold-runaway overlay)
                (push overlay moved)))))
        (when moved
          (mapc #'collab-comments--decorate moved)
          (collab-comments--view-refresh (current-buffer)))))))

(defun collab-comments--fold-runaway (overlay)
  "Fold OVERLAY to an empty anchor at the document's end when it spans it all.
A thread covering the whole document marks nothing; it is the residue
of an anchor that swallowed a wholesale rewrite.  Returns non-nil when
OVERLAY was moved."
  (with-current-buffer (overlay-buffer overlay)
    (save-restriction
      (widen)
      (when (and (= (overlay-start overlay) (point-min))
                 (= (overlay-end overlay) (point-max))
                 (< (point-min) (point-max)))
        (move-overlay overlay (point-max) (point-max))
        ;; Its text is no anchor to re-find; under later rewrites the
        ;; thread stays near the end rather than seeking that text.
        (overlay-put overlay 'collab-comments-anchor (cons nil (point-max)))
        t))))

(defun collab-comments-add-thread (beg end author text &optional buffer)
  "Start a thread over BEG..END in BUFFER with a comment by AUTHOR.
TEXT is the comment body.  Returns the thread overlay."
  (let ((overlay (collab-comments--make-thread
                  beg end
                  (list (list :author author :time (current-time)
                              :text text))
                  buffer)))
    (collab-comments-persist (overlay-buffer overlay))
    overlay))

(defun collab-comments-append (overlay author text)
  "Append a comment by AUTHOR with body TEXT to the thread OVERLAY."
  (unless (collab-comments-thread-p overlay)
    (error "Not a live comment thread"))
  (overlay-put overlay 'collab-comments-comments
               (append (collab-comments-thread-comments overlay)
                       (list (list :author author :time (current-time)
                                   :text text))))
  (collab-comments--decorate overlay)
  (collab-comments--view-refresh (overlay-buffer overlay))
  (collab-comments-persist (overlay-buffer overlay))
  overlay)

(defun collab-comments-dismiss-thread (overlay)
  "Delete the thread OVERLAY and all its comments."
  (when (collab-comments-thread-p overlay)
    (let ((buffer (overlay-buffer overlay)))
      (remhash (collab-comments-thread-id overlay)
               collab-comments--registry)
      (delete-overlay overlay)
      (collab-comments--view-refresh buffer)
      (collab-comments-persist buffer))))

;;; Persistence (buffers with a document key)

(defvar collab-comments-store-file
  (locate-user-emacs-file "collab-comments.eld")
  "File persisting the comment threads of keyed buffers.
Written through on every thread mutation and refreshed at the save and
auto-save checkpoints, so threads survive an Emacs crash.  A
`find-file-hook' can check this file's existence before loading the
package, keeping ordinary file visits cheap (see the README).")

(defvar collab-comments--store 'unloaded
  "Alist of document key -> (:hash :modified :time :threads ...).
The key is a file truename or a declared
`collab-comments-document-key'.  Each thread record is
\(:beg :end :anchor :comments ...).  The symbol `unloaded' until
`collab-comments-store-file' has been read.")

(defvar collab-comments--inhibit-persist nil
  "Non-nil while restoring, so rebuilt threads do not rewrite the store.")

(defun collab-comments--store ()
  "The persisted store, reading it from disk on first use."
  (when (eq collab-comments--store 'unloaded)
    (setq collab-comments--store
          (when (file-readable-p collab-comments-store-file)
            (with-temp-buffer
              (insert-file-contents collab-comments-store-file)
              (condition-case nil
                  (read (current-buffer))
                (error nil))))))
  collab-comments--store)

(defun collab-comments--store-write ()
  "Write the store to disk atomically (temp file, then rename)."
  (let ((temp (make-temp-file "collab-comments-store")))
    (with-temp-file temp
      (let ((print-length nil)
            (print-level nil))
        (prin1 collab-comments--store (current-buffer))))
    (rename-file temp collab-comments-store-file t)))

(defun collab-comments--document-key (buffer)
  "Store key for BUFFER: its declared key, else its file truename.
Nil for an undeclared non-file buffer — its threads stay
session-scoped."
  (or (buffer-local-value 'collab-comments-document-key buffer)
      (when-let* ((file (buffer-file-name buffer)))
        (file-truename file))))

(defun collab-comments--buffer-sha (buffer)
  "Content hash identifying the version BUFFER's threads anchor to."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (secure-hash 'sha256 (current-buffer)))))

(defun collab-comments-persist (&optional buffer)
  "Record BUFFER's threads in the store.
A no-op for buffers with no document key (non-file buffers that
declare none).  The stored content hash and modified flag identify
which version of the document (saved, or the auto-saved buffer state)
the positions belong to; `collab-comments-restore' uses them to
re-anchor correctly."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* (((not collab-comments--inhibit-persist))
                (key (collab-comments--document-key buffer)))
      (collab-comments--store)
      (let ((records
             (mapcar
              (lambda (overlay)
                ;; The anchor text is what re-finds the thread against
                ;; a changed document; a collapsed thread stores the
                ;; text it last held so re-typed text brings it back.
                (list :beg (overlay-start overlay)
                      :end (overlay-end overlay)
                      :anchor (or (car (collab-comments--remembered-anchor
                                        overlay))
                                  "")
                      :comments (collab-comments-thread-comments overlay)))
              (collab-comments-threads buffer))))
        ;; Not `assoc-delete-all': that is Emacs 26.2.
        (setq collab-comments--store
              (seq-remove (lambda (entry) (equal (car entry) key))
                          collab-comments--store))
        (when records
          (push (cons key (list :hash (collab-comments--buffer-sha buffer)
                                :modified (buffer-modified-p buffer)
                                :time (current-time)
                                :threads records))
                collab-comments--store))
        (collab-comments--store-write)))))

(defun collab-comments--reanchor (record same-content)
  "Anchor range (BEG . END) for the stored thread RECORD.
With SAME-CONTENT the stored positions hold exactly.  Otherwise the
anchor text is re-found: its unique occurrence, or the occurrence
nearest the stored position; a vanished anchor collapses at the stored
position (rendering as deleted) — the conversation is never dropped."
  (let ((beg (plist-get record :beg)))
    (if same-content
        (cons beg (plist-get record :end))
      (collab-comments--locate (plist-get record :anchor) beg
                               (point-min) (point-max)))))

;;;###autoload
(defun collab-comments-restore (&optional buffer)
  "Rebuild BUFFER's comment threads from the persisted store.
Runs when a file with stored threads is visited, after revert and
`recover-this-file' (both replace buffer text, scrambling overlays),
after a keyed buffer's owning mode re-renders it, and manually.
Authoritative: replaces the
buffer's live threads, including any scrambled remnants when the
store holds nothing.  Positions restore exactly when the content
matches the persisted version — whichever of the saved file or the
recovered auto-save that is; against the other version anchors are
re-found by their text."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (when-let* ((key (collab-comments--document-key (current-buffer))))
      (let* ((entry (cdr (assoc key (collab-comments--store))))
             (collab-comments--inhibit-persist t)
             (same (and entry
                        (equal (plist-get entry :hash)
                               (collab-comments--buffer-sha
                                (current-buffer))))))
        (dolist (overlay (collab-comments-threads))
          (remhash (collab-comments-thread-id overlay)
                   collab-comments--registry)
          (delete-overlay overlay))
        (save-restriction
          (widen)
          (dolist (record (plist-get entry :threads))
            (let* ((range (collab-comments--reanchor record same))
                   (overlay (collab-comments--make-thread
                             (car range) (cdr range)
                             (plist-get record :comments))))
              ;; A thread restored collapsed still knows its text.
              (overlay-put overlay 'collab-comments-anchor
                           (cons (plist-get record :anchor)
                                 (plist-get record :beg)))
              ;; A whole-document span persisted before the change
              ;; hooks existed is a runaway, not an anchor.
              (when (collab-comments--fold-runaway overlay)
                (collab-comments--decorate overlay)))))))))

(defun collab-comments--persist-all ()
  "Persist every buffer holding threads.
The auto-save and `kill-emacs' checkpoint: at auto-save time the stored
hash matches what the auto-save file is about to contain, so a crash
recovery re-anchors exactly."
  (let (done)
    (maphash (lambda (_id overlay)
               (when-let* ((buffer (and (overlayp overlay)
                                        (overlay-buffer overlay))))
                 (unless (memq buffer done)
                   (push buffer done)
                   (collab-comments-persist buffer))))
             collab-comments--registry)))

(defun collab-comments--persist-current ()
  "Persist the current buffer's threads (the after-save checkpoint)."
  (when (collab-comments-threads)
    (collab-comments-persist)))

(defun collab-comments--after-recover (&rest _)
  "Re-anchor threads after `recover-this-file' replaced the text."
  (collab-comments-restore))

(add-hook 'after-save-hook #'collab-comments--persist-current)
(add-hook 'auto-save-hook #'collab-comments--persist-all)
(add-hook 'kill-emacs-hook #'collab-comments--persist-all)
(add-hook 'after-revert-hook #'collab-comments-restore)
(advice-add 'recover-this-file :after #'collab-comments--after-recover)

;;; Rendering

(defun collab-comments--excerpt (overlay)
  "Anchor text of OVERLAY, single-line and truncated for listings."
  (let* ((raw (with-current-buffer (overlay-buffer overlay)
                (buffer-substring-no-properties (overlay-start overlay)
                                                (overlay-end overlay))))
         (flat (string-trim (replace-regexp-in-string "[ \t\n]+" " " raw))))
    (cond
     ((string-empty-p flat) "(anchor text deleted)")
     ((> (length flat) collab-comments-excerpt-length)
      (concat (substring flat 0 collab-comments-excerpt-length) "…"))
     (t flat))))

(defun collab-comments--format-time (time)
  "TIME as HH:MM, carrying the date when it is not today's."
  (if (equal (format-time-string "%F" time) (format-time-string "%F"))
      (format-time-string "%H:%M" time)
    (format-time-string "%b %e %H:%M" time)))

(defun collab-comments--render-comment (comment)
  "Render one COMMENT plist as indented lines.
Body lines carry a `wrap-prefix' matching their indent, so under
visual-line wrapping (the thread view) continuations stay aligned
with the body instead of snapping to column zero."
  (format "  %s  %s\n%s"
          (propertize (plist-get comment :author)
                      'face 'collab-comments-author-face)
          (propertize (collab-comments--format-time
                       (plist-get comment :time))
                      'face 'collab-comments-time-face)
          (mapconcat (lambda (line)
                       (propertize (concat "    " line)
                                   'wrap-prefix "    "))
                     (split-string (plist-get comment :text) "\n")
                     "\n")))

(defun collab-comments-render-thread (overlay)
  "Render the thread OVERLAY: header line plus each comment."
  (with-current-buffer (overlay-buffer overlay)
    (format "%s  %s  %s\n%s"
            (propertize (format "#%d" (collab-comments-thread-id overlay))
                        'face 'collab-comments-badge)
            (propertize (format "%s:%d" (buffer-name)
                                (line-number-at-pos (overlay-start overlay)
                                                    t))
                        'face 'collab-comments-location-face)
            (propertize (format "\"%s\"" (collab-comments--excerpt overlay))
                        'face 'collab-comments-excerpt-face)
            (mapconcat #'collab-comments--render-comment
                       (collab-comments-thread-comments overlay)
                       "\n"))))

(defun collab-comments--decorate (overlay)
  "Apply or remove OVERLAY's visuals per the buffer's hidden state."
  (with-current-buffer (overlay-buffer overlay)
    (if collab-comments-hidden
        (progn (overlay-put overlay 'face nil)
               (overlay-put overlay 'after-string nil)
               (overlay-put overlay 'help-echo nil))
      (overlay-put overlay 'face 'collab-comments-highlight)
      (overlay-put overlay 'after-string
                    (propertize
                     (format "‹%d›"
                             (length (collab-comments-thread-comments
                                      overlay)))
                     'face 'collab-comments-badge))
      (overlay-put overlay 'help-echo
                    (collab-comments-render-thread overlay)))))

;;; Showing the thread at point (eldoc + linked view)

(defvar-local collab-comments--synced-ids nil
  "Thread ids point was last inside, for view-sync deduplication.")

;; Defined by the minor mode below; referenced by the doc function first.
(defvar collab-comments-auto-show-mode)

(defun collab-comments--view-window (source)
  "Window showing SOURCE's thread view, or nil."
  (when-let* ((view (collab-comments--view-buffer source)))
    (get-buffer-window view)))

(defun collab-comments--eldoc (&optional _callback &rest _)
  "Document the comment thread(s) at point, for eldoc.
Called with no arguments as the pre-28 `eldoc-documentation-function'.
Registered buffer-locally ahead of the LSP/flymake doc functions, so
inside commented text the thread outranks hover and code-action hints;
outside it yields.  Yields to a visible thread view as well — there
the view window follows point instead (`collab-comments--auto-show')."
  (and collab-comments-auto-show-mode
       (not collab-comments-hidden)
       (not (collab-comments--view-window (current-buffer)))
       (when-let* ((threads (collab-comments-threads-at (point))))
         (mapconcat #'collab-comments-render-thread threads "\n\n"))))

(defun collab-comments--auto-show ()
  "Follow point into threads: sync a visible view window to the thread.
Runs on `post-command-hook' under `collab-comments-auto-show-mode'; the
echo-area half of auto-show lives in `collab-comments--eldoc'."
  (with-demoted-errors "collab-comments auto-show: %S"
    (let* ((threads (and (not collab-comments-hidden)
                         (not (minibufferp))
                         (collab-comments-threads-at (point))))
           (ids (mapcar #'collab-comments-thread-id threads)))
      (cond
       ((null threads)
        (setq collab-comments--synced-ids nil))
       ((not (equal ids collab-comments--synced-ids))
        (setq collab-comments--synced-ids ids)
        (when-let* ((window (collab-comments--view-window (current-buffer)))
                    (pos (with-current-buffer (window-buffer window)
                           (text-property-any (point-min) (point-max)
                                              'collab-comments-view-id
                                              (car ids)))))
          (set-window-point window pos)))))))

;;;###autoload
(define-minor-mode collab-comments-auto-show-mode
  "Show the comment thread at point as point moves onto commented text.
Global.  The thread renders through
eldoc (so it composes with, and inside comments outranks, LSP output),
and a visible thread view window follows point instead of echoing."
  :global t
  (if collab-comments-auto-show-mode
      (add-hook 'post-command-hook #'collab-comments--auto-show)
    (remove-hook 'post-command-hook #'collab-comments--auto-show)))

;;; Thread view buffer

(defvar-local collab-comments-view--source nil
  "Source buffer whose threads this view buffer lists.")

(defvar collab-comments-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'collab-comments-view-next)
    (define-key map (kbd "p") #'collab-comments-view-previous)
    (define-key map (kbd "RET") #'collab-comments-view-visit)
    (define-key map (kbd "r") #'collab-comments-view-reply)
    (define-key map (kbd "d") #'collab-comments-view-dismiss)
    (define-key map (kbd "D") #'collab-comments-view-dismiss-all)
    map)
  "Keymap for `collab-comments-view-mode'.")

(defvar-local collab-comments-view--followed-id nil
  "Thread id the source window was last pointed at, for deduplication.")

(defun collab-comments-view--follow ()
  "Point the source buffer's window at the thread under point.
Buffer-local `post-command-hook' of the view: moving between sections
scrolls the source window to the matching anchor."
  (with-demoted-errors "collab-comments view follow: %S"
    (let ((id (collab-comments-view--thread-id-at (point))))
      (unless (eq id collab-comments-view--followed-id)
        (setq collab-comments-view--followed-id id)
        (when-let* ((overlay (and id (collab-comments-find id)))
                    (window (get-buffer-window (overlay-buffer overlay))))
          (set-window-point window (overlay-start overlay)))))))

(define-derived-mode collab-comments-view-mode special-mode "Comments"
  "Major mode listing the comment threads of a source buffer."
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (collab-comments--view-render (current-buffer))))
  ;; Comment bodies are prose; wrap them at the window edge (their
  ;; wrap-prefix keeps continuations aligned with the indent).
  (visual-line-mode 1)
  (add-hook 'post-command-hook #'collab-comments-view--follow nil t))

(defun collab-comments--view-buffer (source &optional create)
  "View buffer for SOURCE, creating it when CREATE."
  (let ((name (format "*comments: %s*" (buffer-name source))))
    (or (get-buffer name)
        (and create
             (with-current-buffer (get-buffer-create name)
               (collab-comments-view-mode)
               (setq collab-comments-view--source source)
               (current-buffer))))))

(defun collab-comments--view-divider ()
  "Horizontal rule spanning the window, ending in a newline.
A stretch glyph, so it tracks the window width instead of wrapping or
falling short the way a fixed run of line-drawing characters would."
  (concat (propertize " " 'display '(space :align-to right)
                      'face 'collab-comments-divider)
          "\n"))

(defun collab-comments--view-render (view)
  "Fill VIEW with the rendered threads of its source buffer.
Sections are separated by a rule; each section — rule included —
carries its thread id as the `collab-comments-view-id' text property,
which navigation and the window syncs key off."
  (with-current-buffer view
    (let* ((source collab-comments-view--source)
           (threads (and (buffer-live-p source)
                         (collab-comments-threads source)))
           (at-id (collab-comments-view--thread-id-at (point)))
           (inhibit-read-only t))
      (erase-buffer)
      (if (null threads)
          (insert "No comment threads.\n")
        (let ((last (car (last threads))))
          (dolist (overlay threads)
            (let ((start (point)))
              (insert (collab-comments-render-thread overlay) "\n")
              (unless (eq overlay last)
                (insert "\n" (collab-comments--view-divider) "\n"))
              (put-text-property start (point) 'collab-comments-view-id
                                 (collab-comments-thread-id overlay))))))
      (goto-char (point-min))
      (when at-id (collab-comments-view-goto at-id)))))

(defun collab-comments-view--thread-id-at (position)
  "Thread id of the view section at POSITION, or nil."
  (get-text-property position 'collab-comments-view-id))

(defun collab-comments-view-goto (id)
  "Move point to the section of thread ID in the current view buffer."
  (let ((found (text-property-any (point-min) (point-max)
                                  'collab-comments-view-id id)))
    (when found (goto-char found))
    found))

(defun collab-comments-view--thread-at-point ()
  "Thread overlay for the view section at point, or a user error."
  (or (collab-comments-find
       (or (collab-comments-view--thread-id-at (point))
           (user-error "No comment thread at point")))
      (user-error "This thread no longer exists (refresh with g)")))

(defun collab-comments-view--ids ()
  "Thread ids listed in this view buffer, in section order."
  (mapcar #'collab-comments-thread-id
          (and (buffer-live-p collab-comments-view--source)
               (collab-comments-threads collab-comments-view--source))))

(defun collab-comments-view-next ()
  "Move to the next thread section in the view."
  (interactive)
  (let* ((ids (collab-comments-view--ids))
         (current (collab-comments-view--thread-id-at (point)))
         (rest (if current (cdr (member current ids)) ids)))
    (unless (and rest (collab-comments-view-goto (car rest)))
      (user-error "No next thread"))))

(defun collab-comments-view-previous ()
  "Move to the previous thread section in the view."
  (interactive)
  (let* ((ids (reverse (collab-comments-view--ids)))
         (current (collab-comments-view--thread-id-at (point)))
         (rest (and current (cdr (member current ids)))))
    (unless (and rest (collab-comments-view-goto (car rest)))
      (user-error "No previous thread"))))

(defun collab-comments-view-visit ()
  "Visit the anchor of the thread at point in the source buffer."
  (interactive)
  (let ((overlay (collab-comments-view--thread-at-point)))
    (pop-to-buffer (overlay-buffer overlay))
    (goto-char (overlay-start overlay))))

(defun collab-comments-view-reply (text)
  "Append a reply with body TEXT to the thread at point."
  (interactive (list (read-string "Reply: ")))
  (collab-comments-append (collab-comments-view--thread-at-point)
                          (collab-comments--author)
                          text))

(defun collab-comments-view-dismiss ()
  "Dismiss the thread at point."
  (interactive)
  (collab-comments-dismiss-thread
   (collab-comments-view--thread-at-point)))

(defun collab-comments-view-dismiss-all ()
  "Dismiss every thread of this view's source buffer."
  (interactive)
  (let ((threads (or (and (buffer-live-p collab-comments-view--source)
                          (collab-comments-threads
                           collab-comments-view--source))
                     (user-error "No comment threads to dismiss"))))
    (when (y-or-n-p (format "Dismiss all %d comment threads? "
                            (length threads)))
      (mapc #'collab-comments-dismiss-thread threads))))

(defun collab-comments--view-refresh (source)
  "Re-render SOURCE's view buffer, when one exists."
  (when (buffer-live-p source)
    (when-let* ((view (collab-comments--view-buffer source)))
      (collab-comments--view-render view))))

;;; Interactive entry points

(defun collab-comments--target-region ()
  "Region to comment on: the active region, else the current line."
  (if (use-region-p)
      (list (region-beginning) (region-end))
    (list (line-beginning-position) (line-end-position))))

;;;###autoload
(defun collab-comments-add (beg end text)
  "Start a comment thread with body TEXT over BEG..END.
Interactively, the region when active, else the current line."
  (interactive
   (append (collab-comments--target-region)
           (list (read-string "Comment: "))))
  (when (string-empty-p (string-trim text))
    (user-error "Empty comment"))
  (when (= beg end)
    (user-error "Cannot comment on empty text"))
  (deactivate-mark)
  (let ((overlay (collab-comments-add-thread
                  beg end (collab-comments--author) text)))
    (message "Comment thread #%d started"
             (collab-comments-thread-id overlay))
    overlay))

(defun collab-comments--thread-label (overlay)
  "One-line label for OVERLAY in pickers.
The first comment disambiguates threads sharing the same anchor."
  (let* ((first (car (collab-comments-thread-comments overlay)))
         (snippet (replace-regexp-in-string
                   "[ \t\n]+" " " (plist-get first :text))))
    (format "#%d \"%s\" — %s: %s"
            (collab-comments-thread-id overlay)
            (collab-comments--excerpt overlay)
            (plist-get first :author)
            (if (> (length snippet) 40)
                (concat (substring snippet 0 40) "…")
              snippet))))

(defun collab-comments--choose-thread (prompt threads)
  "Pick one of THREADS by PROMPT; a single candidate needs no prompt."
  (if (null (cdr threads))
      (car threads)
    (let ((candidates (mapcar (lambda (overlay)
                                (cons (collab-comments--thread-label overlay)
                                      overlay))
                              threads)))
      (cdr (assoc (completing-read prompt candidates nil t)
                  candidates)))))

(defun collab-comments--read-thread (prompt)
  "Thread at point (choosing when several overlap), else pick by PROMPT."
  (collab-comments--choose-thread
   prompt
   (or (collab-comments-threads-at (point))
       (collab-comments-threads)
       (user-error "No comment threads in this buffer"))))

;;;###autoload
(defun collab-comments-reply (text)
  "Append a reply with body TEXT to the thread at point.
With no thread at point, fall back to starting a new thread on the
region or current line — typed text is never dropped.  The prompt
names which of the two will happen."
  (interactive
   (list (read-string (if (collab-comments-threads-at (point))
                          "Reply: "
                        "Comment (new thread): "))))
  (when (string-empty-p (string-trim text))
    (user-error "Empty comment"))
  (let ((at (collab-comments-threads-at (point))))
    (if (null at)
        (apply #'collab-comments-add
               (append (collab-comments--target-region) (list text)))
      (let ((overlay (collab-comments--choose-thread "Reply to thread: " at)))
        (collab-comments-append overlay (collab-comments--author) text)
        (message "Replied to thread #%d"
                 (collab-comments-thread-id overlay))))))

;;;###autoload
(defun collab-comments-show ()
  "Show the thread view for this buffer, focused on the thread at point."
  (interactive)
  (let ((at (car (collab-comments-threads-at (point))))
        (view (collab-comments--view-buffer (current-buffer) t)))
    (collab-comments--view-render view)
    (pop-to-buffer view)
    (when at
      (collab-comments-view-goto (collab-comments-thread-id at)))))

;;;###autoload
(defun collab-comments-browse ()
  "Jump to a comment thread in this buffer via `completing-read'."
  (interactive)
  (let ((overlay (collab-comments--read-thread "Comment thread: ")))
    (goto-char (overlay-start overlay))
    (message "%s" (collab-comments-render-thread overlay))))

;;;###autoload
(defun collab-comments-next ()
  "Jump to the next comment thread in the buffer, wrapping around."
  (interactive)
  (collab-comments--cycle 'next))

;;;###autoload
(defun collab-comments-previous ()
  "Jump to the previous comment thread in the buffer, wrapping around."
  (interactive)
  (collab-comments--cycle 'previous))

(defun collab-comments--cycle (direction)
  "Move point to the adjacent thread anchor in DIRECTION, wrapping."
  (let ((threads (or (collab-comments-threads)
                     (user-error "No comment threads in this buffer"))))
    (when (eq direction 'previous)
      (setq threads (reverse threads)))
    (let ((target
           (or (seq-find (lambda (overlay)
                           (if (eq direction 'next)
                               (> (overlay-start overlay) (point))
                             (< (overlay-start overlay) (point))))
                         threads)
               (car threads))))
      (goto-char (overlay-start target))
      (message "%s" (collab-comments-render-thread target)))))

;;;###autoload
(defun collab-comments-dismiss ()
  "Dismiss the comment thread at point (pick one when none is there)."
  (interactive)
  (let* ((overlay (collab-comments--read-thread "Dismiss thread: "))
         (id (collab-comments-thread-id overlay)))
    (collab-comments-dismiss-thread overlay)
    (message "Dismissed thread #%d" id)))

;;;###autoload
(defun collab-comments-dismiss-all ()
  "Dismiss every comment thread in the current buffer."
  (interactive)
  (let ((threads (or (collab-comments-threads)
                     (user-error "No comment threads in this buffer"))))
    (when (y-or-n-p (format "Dismiss all %d comment threads here? "
                            (length threads)))
      (mapc #'collab-comments-dismiss-thread threads)
      (message "Dismissed %d threads" (length threads)))))

;;;###autoload
(defun collab-comments-toggle-hidden ()
  "Toggle visibility of comment decorations in this buffer.
Threads are retained either way."
  (interactive)
  (setq collab-comments-hidden (not collab-comments-hidden))
  (mapc #'collab-comments--decorate (collab-comments-threads))
  (message "Comment decorations %s"
           (if collab-comments-hidden "hidden" "shown")))

;;; Key maps

(defvar collab-comments-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'collab-comments-add)
    (define-key map (kbd "r") #'collab-comments-reply)
    (define-key map (kbd "k") #'collab-comments-show)
    (define-key map (kbd "b") #'collab-comments-browse)
    (define-key map (kbd "n") #'collab-comments-next)
    (define-key map (kbd "p") #'collab-comments-previous)
    (define-key map (kbd "d") #'collab-comments-dismiss)
    (define-key map (kbd "D") #'collab-comments-dismiss-all)
    (define-key map (kbd "h") #'collab-comments-toggle-hidden)
    (define-key map (kbd "t") #'collab-comments-auto-show-mode)
    (define-key map (kbd "g") #'collab-comments-restore)
    map)
  "Keymap of the collab-comments commands, to bind under a prefix key.
Nothing binds it by default; `C-c k' is a reasonable choice.")

;; Usable as a prefix command, e.g. with `global-set-key'.
(fset 'collab-comments-command-map collab-comments-command-map)

(defvar collab-comments-repeat-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'collab-comments-next)
    (define-key map (kbd "p") #'collab-comments-previous)
    map)
  "Keymap for cycling threads with bare `n' and `p' after one jump.
Consulted by `repeat-mode' (Emacs 28); ignored before that.")

(dolist (command '(collab-comments-next collab-comments-previous))
  (put command 'repeat-map 'collab-comments-repeat-map))

(provide 'collab-comments)
;;; collab-comments.el ends here
