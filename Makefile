EMACS ?= emacs

.PHONY: all compile test lint melpa clean

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

# The checks MELPA asks of a submission: package-lint on the package
# file and checkdoc on every file, failing on any finding.  Installs
# package-lint from MELPA into .tools/ on first use.
lint:
	$(EMACS) -Q --batch -l test/melpa-checks.el -f collab-comments-checks-lint

# Build the package with package-build the way MELPA does, from a
# recipe generated to point at this checkout, on the snapshot and the
# stable channel.  Installs package-build from MELPA into .tools/ on
# first use; the tarballs land in .tools/melpa/packages/.
melpa:
	$(EMACS) -Q --batch -l test/melpa-checks.el -f collab-comments-checks-build

clean:
	rm -rf *.elc test/*.elc .tools
