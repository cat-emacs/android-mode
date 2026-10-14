EMACS ?= emacs
BATCH = $(EMACS) --batch --quick
TEST_DEPS_DIR ?= .test-deps
PACKAGE_USER_DIR ?= $(abspath $(TEST_DEPS_DIR)/elpa)
ANDROID_PROJECT_DIR ?= $(abspath $(TEST_DEPS_DIR)/android-project)
ANDROID_ADB_DIR ?= $(abspath $(TEST_DEPS_DIR)/android-adb)
LOAD_PATH = -L . -L "$(ANDROID_PROJECT_DIR)" -L "$(ANDROID_ADB_DIR)"

ARCHIVES = --eval "(setq package-user-dir \"$(PACKAGE_USER_DIR)\")" \
           --eval "(require 'package)" \
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
	mkdir -p "$(TEST_DEPS_DIR)"
	test -d "$(ANDROID_PROJECT_DIR)/.git" || git clone --depth 1 https://github.com/cat-emacs/android-project "$(ANDROID_PROJECT_DIR)"
	test -d "$(ANDROID_ADB_DIR)/.git" || git clone --depth 1 https://github.com/cat-emacs/android-adb "$(ANDROID_ADB_DIR)"
	$(BATCH) $(ARCHIVES) \
	  --eval "(require 'package-vc)" \
	  --eval "(unless (package-installed-p 'android-project) (package-vc-install-from-checkout \"$(ANDROID_PROJECT_DIR)\"))" \
	  --eval "(unless (package-installed-p 'android-adb) (package-vc-install-from-checkout \"$(ANDROID_ADB_DIR)\"))"

lint:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(require 'package-lint)" \
	  --eval "(package-lint-batch-and-exit)" \
	  android-mode.el
	$(BATCH) $(LOAD_PATH) \
	  --eval "(checkdoc-file \"android-mode.el\")" \
	  --eval "(checkdoc-file \"android-mode-avd.el\")"

build:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(byte-compile-file \"android-mode.el\")" \
	  --eval "(byte-compile-file \"android-mode-avd.el\")"

test:
	$(BATCH) $(ARCHIVES) $(LOAD_PATH) \
	  -l android-mode.el \
	  -l android-mode-avd.el \
	  -l android-mode-tests.el \
	  -l android-mode-avd-tests.el \
	  --eval "(ert-run-tests-batch-and-exit)"

clean:
	rm -f *.elc
