EMACS ?= emacs

.PHONY: all compile test clean

all: compile test

# Byte-compile with warnings promoted to errors, so a warning under any
# supported Emacs fails the build.
compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile collab-comments.el

test:
	$(EMACS) -Q --batch -L . \
	  -l test/collab-comments-test.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
