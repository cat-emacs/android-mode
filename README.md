# android-mode

Android project helpers for Emacs.

`android-mode` provides commands for common Android development tasks:

- selecting Gradle modules and variants from project flavor data
- building, installing, uninstalling, testing, and running Android apps
- launching an emulator
- starting the currently built application on a connected device

## Installation

With `use-package` and `package-vc`:

```elisp
(use-package android-mode
  :vc (android-mode :url "https://github.com/chuxubank/emacs-studio"
                    :lisp-dir "android-mode/")
  :commands #'android-root)
```

From a local checkout:

```elisp
(add-to-list 'load-path "/path/to/emacs-studio/android-mode")
(require 'android-mode)
```

## Commands

- `M-x android-gradle-build`
- `M-x android-gradle-clean`
- `M-x android-gradle-install`
- `M-x android-gradle-uninstall`
- `M-x android-gradle-test`
- `M-x android-run`
- `M-x android-start-app`
- `M-x android-start-emulator`
- `M-x android-print-flavor`
- `M-x android-refresh-flavors`

## Configuration

```elisp
(setq android-mode-cache-dir (expand-file-name "android/" user-emacs-directory)
      android-mode-sdk-dir "/path/to/android-sdk")
```

`ANDROID_HOME` and a project `local.properties` `sdk.dir` value take precedence
over `android-mode-sdk-dir`.

## Development

Run package checks from this directory:

```sh
make install-deps
make lint
make build
make test
```
