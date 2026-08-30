# collab-comments

Review-style comment threads on regions of Emacs buffer text, shared
between a person and coding agents editing the same buffers.

A thread is an overlay over the annotated text carrying a list of
comments (author, timestamp, body). Overlays never change the text they
annotate, so a comment is a margin note, not an edit. Commented text is
highlighted and followed by a `‹2›` badge with the comment count; the
thread shows on mouse hover and, through eldoc, whenever point enters
the text. Rendered, a thread looks like this:

```
#3  README.md:96  "would otherwise highlight the entire replacement"
  chris  10:42
    Is "otherwise" doing any work in this sentence?
  claude  10:43
    It is: without the change hooks the collapsed anchor absorbs the
    insertion.  I can reword it to say that outright.
```

The thread view lists every thread in a buffer that way, with keys to
reply, dismiss, and visit.

The package is the Emacs half of that collaboration. It keeps the
threads, draws them, and exposes them to Lisp; it does not talk to any
agent itself. For an agent to read your comments and leave its own, it
needs a channel into the running Emacs through which it can call the
functions under [Programmatic use](#programmatic-use): an MCP server
hosted inside Emacs, `emacsclient --eval` run from an agent tool or
hook, or any similar bridge. Without one, the package is an annotation
tool for a single person. [Connecting an agent](#connecting-an-agent)
describes what to expose.

Requires Emacs 26.1 or later. No other dependencies.

## Installing

The package is a single file, `collab-comments.el`, in this repository;
it is not on MELPA yet. Pick the route for your Emacs. The version is
pre-1.0: the commands and the model functions are stable in intent, but
names and signatures may still change before 1.0.

### Emacs 30 and later

`use-package` fetches and installs it with the `:vc` keyword; see the
setup block below. `package-vc-upgrade` pulls later commits.

### Emacs 29

`package-vc-install` does the same fetch as a one-off, and
`package-vc-upgrade` pulls later commits:

```elisp
(package-vc-install "https://github.com/clhodapp/collab-comments")
```

### Emacs 26 through 28

`package-install-file` has been part of package.el since long before
package-vc. Clone the repository, then install from the file; package.el
copies it into `package-user-dir`, byte-compiles it, and generates its
autoloads, exactly as an archive install would:

```
git clone https://github.com/clhodapp/collab-comments ~/src/collab-comments
```

```
M-x package-install-file RET ~/src/collab-comments/collab-comments.el RET
```

To upgrade, `git pull` in the clone and run `package-install-file` again.

If you use straight.el, a recipe does the clone, build, and upgrades for
you (elpaca accepts the same recipe form):

```elisp
(straight-use-package
 '(collab-comments :type git :host github :repo "clhodapp/collab-comments"))
```

Or skip installation altogether: clone, add the directory to
`load-path`, and `require` the package (there are no autoloads this way,
so the `require` is needed before the commands exist; `make compile` in
the clone byte-compiles it):

```elisp
(add-to-list 'load-path "~/src/collab-comments")
(require 'collab-comments)
```

## Setting up

The package installs no global keys. It provides
`collab-comments-command-map`, a prefix keymap holding every command
under a mnemonic letter, for you to bind where you like; `C-c k` is a
reasonable choice (`C-c` plus a letter is reserved for users). With
`use-package`:

```elisp
(use-package collab-comments
  ;; Emacs 30+: fetches the package as well.  On 29 (after
  ;; package-vc-install) and on 26–28 after package-install-file, drop
  ;; this line; on 26–28 with a plain clone use
  ;;   :load-path "~/src/collab-comments"
  ;; instead, and with straight.el
  ;;   :straight (:type git :host github :repo "clhodapp/collab-comments")
  :vc (:url "https://github.com/clhodapp/collab-comments" :rev :newest)
  :bind-keymap ("C-c k" . collab-comments-command-map)
  :hook (find-file . my/collab-comments-restore-on-visit)
  :config
  ;; Show the thread at point as point moves onto commented text.
  (collab-comments-auto-show-mode 1))

;; Rebuild a file's persisted threads when it is visited.  The bare
;; existence check keeps ordinary file visits from loading the package
;; when nothing has ever been persisted.
(defun my/collab-comments-restore-on-visit ()
  (when (file-exists-p (locate-user-emacs-file "collab-comments.eld"))
    (require 'collab-comments)
    (collab-comments-restore)))
```

The same without `use-package`:

```elisp
(require 'collab-comments)
(global-set-key (kbd "C-c k") 'collab-comments-command-map)
(add-hook 'find-file-hook #'my/collab-comments-restore-on-visit)
(collab-comments-auto-show-mode 1)
```

With `repeat-mode` (Emacs 28) enabled, a bare `n` or `p` keeps cycling
threads after one `C-c k n` or `C-c k p`.

## Commands

Under the prefix (`C-c k` in the setup above):

| Key | Command | Does |
|---|---|---|
| `a` | `collab-comments-add` | start a thread on the region (or the current line) |
| `r` | `collab-comments-reply` | append to the thread at point; with none there, start a thread instead so the typed text is not lost |
| `k` | `collab-comments-show` | open the thread view for this buffer, focused on the thread at point |
| `b` | `collab-comments-browse` | jump to a thread chosen with `completing-read` |
| `n` / `p` | `collab-comments-next` / `-previous` | cycle through thread anchors, echoing each thread |
| `d` | `collab-comments-dismiss` | delete the thread at point (or pick one) |
| `D` | `collab-comments-dismiss-all` | delete every thread in the buffer, after confirming |
| `h` | `collab-comments-toggle-hidden` | hide or show the decorations; the threads stay |
| `t` | `collab-comments-auto-show-mode` | global minor mode: show the thread at point through eldoc as point moves |
| `g` | `collab-comments-restore` | rebuild this buffer's threads from the persisted store |

Threads stacked on the same text are disambiguated wherever a thread is
picked: overlapping threads at point prompt with the thread id and its
first comment.

### The thread view

`collab-comments-show` opens `*comments: <buffer>*`, a `special-mode`
buffer listing the source buffer's threads in position order:

| Key | Does |
|---|---|
| `n` / `p` | next / previous thread |
| `RET` | visit the anchor in the source buffer |
| `r` | reply to the thread at point |
| `d` / `D` | dismiss the thread at point / every thread |
| `g` / `q` | revert / quit |

Any change to the threads, from either side, re-renders a live view, so
it doubles as a feed of an agent's comments. While the view is visible,
moving point in the source buffer onto a thread moves the view to that
thread's section, and moving between sections in the view points the
source window at the matching anchor.

## Anchors

Anchor edges are inclusive on both sides. Undo does not adjust overlay
positions, so exclusive edges turn "delete at the boundary, then undo"
into a silent permanent boundary shift; inclusive edges restore the
boundary under undo and re-cover a fully deleted-then-undone anchor.
The cost is that typing directly at an edge extends the thread.

Inclusive edges have a second consequence: an anchor whose text is
deleted collapses to a point and then absorbs whatever is inserted
there. A `replace-match` over it, or an erase-and-reinsert of the whole
buffer (the way many viewers refresh), would otherwise highlight the
entire replacement. Buffer-local change hooks prevent that: before a
change, every thread lying entirely inside the replaced range is noted
with its anchor text; after it, each is moved onto the nearest
occurrence of that text within the new range, or collapsed at its old
position when the text is gone. A collapsed thread remembers the text
it last held, so typing it back re-covers it. Whenever a change leaves
a thread covering the entire document, it is folded to an empty anchor
at the document's end, rendering as `(anchor text deleted)`.

Anchor text can be deleted out from under a thread; the thread survives
and renders as `(anchor text deleted)` rather than losing the
conversation.

## Persistence

Threads on buffers with a document key persist across Emacs restarts
and crashes. A file-visiting buffer's key is its file truename; a
non-file buffer whose mode declares `collab-comments-document-key`
(buffer-local, set after the major mode is established) persists under
that key. Non-file buffers with no key are session-scoped.

The store, `collab-comments-store-file` (a Lisp-data file under
`user-emacs-directory`), is written through on every thread mutation
(temp file plus rename) and refreshed at the `after-save-hook` and
`auto-save-hook` checkpoints. Each entry carries the thread records
(positions, anchor text, comment bodies) plus a SHA-256 of the buffer
content at persist time.

`collab-comments-restore` compares that hash against the current
buffer. When it matches (the same saved file, or a recovered auto-save
taken at the same checkpoint), positions restore exactly. When it
differs, each anchor is re-found by its text: the unique occurrence,
else the occurrence nearest the stored position, else a collapsed
anchor at the stored position. Restoration runs on `after-revert-hook`
and after `recover-this-file` on its own; the `find-file-hook` recipe
above covers visiting, and a mode that re-renders a keyed buffer calls
it after each re-render. Thread ids are session-unique and not
persisted; restored threads get fresh ids.

## Customization

Variables (`M-x customize-group RET collab-comments`):

| Variable | Default | Meaning |
|---|---|---|
| `collab-comments-author` | `nil` | author name on interactively added comments; `nil` means `user-login-name` |
| `collab-comments-excerpt-length` | `48` | characters of anchor text shown in thread headers and pickers |
| `collab-comments-store-file` | `collab-comments.eld` under `user-emacs-directory` | the persistence store |

Faces:

| Face | Used for |
|---|---|
| `collab-comments-highlight` | commented text |
| `collab-comments-badge` | the `‹N›` count badge and the `#N` thread id |
| `collab-comments-author-face` | author names |
| `collab-comments-time-face` | timestamps |
| `collab-comments-location-face` | the `buffer:line` in thread headers |
| `collab-comments-excerpt-face` | the quoted anchor excerpt (inherits the highlight) |
| `collab-comments-divider` | the rule between threads in the view |

## Connecting an agent

Nothing in this package opens a connection. Whatever runs your agent
has to be able to evaluate Lisp in your Emacs session, and two
operations are enough to make the threads a shared surface:

- **add-comment.** Given a buffer (or file), literal anchor text, and a
  body: find the anchor's unique occurrence in the buffer and call
  `collab-comments-add-thread` over it. Given a thread id and a body:
  `collab-comments-append`. Matching literal text, and refusing a
  missing or ambiguous match with the count, is the same contract
  coding agents already follow for edits, so an agent addresses text
  for a comment the way it does for an edit.
- **list-comments.** `collab-comments-all-threads` (or
  `collab-comments-threads` for one buffer), each rendered with
  `collab-comments-render-thread`, so the agent reads your notes with
  their location and excerpt and can answer in the thread by id.

Those two are the minimum. Two more are worth adding once the
conversation moves beyond files on disk: a way to **list buffers**
(`buffer-list`, with each buffer's name and file, if any), so that when
you say "the comment in the draft buffer" the agent can find the buffer
you mean and pass its name to the operations above; and a way to
**read a buffer's text** (`buffer-string` in that buffer), so the agent
can see what a comment is about and quote the exact anchor text for a
comment of its own. Non-file buffers, such as a co-drafted document
that lives only in Emacs, and the unsaved state of any buffer are
otherwise invisible to an agent that knows the filesystem and nothing
else.

How those reach the agent depends on the agent. An MCP server hosted
inside Emacs (for example with `mcp-server-lib`) can offer them as
tools directly; a shell-driven agent can run the same forms through
`emacsclient --eval`. The author's setup is the first: an in-Emacs MCP
server whose `add-comment` and `list-comments` tools wrap the calls
above, with buffer-editing tools beside them so the agent can act on a
comment and reply in the same thread. That server is not part of this
package.

## Programmatic use

Agents (or anything else) reach threads through the model functions;
nothing here reads the minibuffer:

- `collab-comments-add-thread BEG END AUTHOR TEXT &optional BUFFER`
  starts a thread and returns its overlay.
- `collab-comments-append OVERLAY AUTHOR TEXT` appends a comment.
- `collab-comments-find ID` returns the live thread with that id.
- `collab-comments-threads &optional BUFFER` lists a buffer's threads
  by position; `collab-comments-all-threads` lists every buffer's.
- `collab-comments-threads-at POSITION &optional BUFFER` lists the
  threads covering or touching a position.
- `collab-comments-thread-id`, `collab-comments-thread-comments` read
  a thread; each comment is a plist with `:author`, `:time`, `:text`.
- `collab-comments-render-thread OVERLAY` renders a thread as text: a
  `#ID buffer:line "excerpt"` header, then each comment as an author
  line and an indented body (the sample above).
- `collab-comments-dismiss-thread OVERLAY` deletes a thread.

## Development

`make` byte-compiles with warnings as errors and runs the ERT suite
(`test/collab-comments-test.el`); `make test` runs the suite alone. CI
runs both on Emacs 26.1, 26.3, 27.2, 28.2, 29.4, 30.1, 31.1, and the
current development snapshot.

`make lint` runs `package-lint` on the package file and `checkdoc` on
every file, failing on any finding. `make melpa` builds the package
with `package-build` from a recipe generated to point at the checkout,
on the snapshot channel and the stable channel; the tarballs land in
`.tools/melpa/packages/`. Both targets install their tool from MELPA
into `.tools/` on first use, and CI runs them on Emacs 30.1 alongside
the matrix. Release tags are `vX.Y.Z`, matching the `Version` header
in `collab-comments.el`.

## License

GPL-3.0-or-later. See `LICENSE`.
