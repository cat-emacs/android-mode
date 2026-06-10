EMACS ?= emacs
BATCH = $(EMACS) --batch --quick
LOAD_PATH = -L .

ARCHIVES = --eval "(require 'package)" \
           --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
           --eval "(package-initialize)"

.PHONY: help install-deps lint build test clean

help:
	@echo "Targets:"
	@echo "  install-deps  - Install package-lint"
	@echo "  lint          - Run package-lint and checkdoc"
	@echo "  build         - Byte-compile android-mode"
	@echo "  test          - Run android-mode ERT tests"
	@echo "  clean         - Remove .elc files"

install-deps:
	$(BATCH) $(ARCHIVES) \
	  --eval "(package-refresh-contents)" \
	  --eval "(package-install 'package-lint)"

lint:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(require 'package-lint)" \
	  --eval "(package-lint-batch-and-exit)" \
	  android-mode.el
	$(BATCH) $(LOAD_PATH) \
	  --eval "(checkdoc-file \"android-mode.el\")"

build:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(byte-compile-file \"android-mode.el\")"

test:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  -l android-mode.el \
	  -l android-mode-tests.el \
	  --eval "(ert-run-tests-batch-and-exit)"

clean:
	rm -f *.elc
