;;; android-mode.el --- Minor mode for Android application development -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2018 R.W van 't Veer
;; Copyright (C) 2025 Gemini (Code optimizations and warning fixes)

;; Author: R.W. van 't Veer
;; Created: 20 Feb 2009
;; Keywords: tools processes
;; Version: 0.7.0
;; Package-Requires: ((emacs "28.1") (transient "0.3.0") (android-project "0.1.0") (adb "0.1.0"))
;; URL: https://github.com/cat-emacs/android-mode

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Provides support for running Android SDK subprocesses like the
;; emulator, build and install tasks.  When loaded `dired-mode' and
;; `find-file' hooks are added to automatically enable `android-mode'
;; when opening a file or directory in an android project.

;;; Code:

(require 'project)
(require 'android-project)
(require 'adb)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup android nil
  "A minor mode for Android application development."
  :prefix "android-mode-"
  :group 'applications)

(defcustom android-mode-avd ""
  "Default AVD to use."
  :type 'string
  :group 'android)

(defcustom android-mode-sdk-dir nil
  "Set to the directory containing the Android SDK.
This value will be overridden by ANDROID_HOME environment variable when
available."
  :type 'string
  :group 'android)

(defcustom android-mode-sdk-tool-subdirs
  '("emulator" "cmdline-tools/latest/bin" "tools" "platform-tools")
  "List of subdirectories in the SDK containing commandline tools."
  :type '(repeat string)
  :group 'android)

(defcustom android-mode-sdk-tool-extensions '("" ".bat" ".exe")
  "List of possible extensions for commandline tools."
  :type '(repeat string)
  :group 'android)

(defun android--log (format-string &rest args)
  "Log android-mode message FORMAT-STRING with ARGS."
  (apply #'message (concat "android-mode: " format-string) args))

(defun android-local-sdk-dir ()
  "Determine the Android SDK directory.
It prioritizes in the following order:
1. `sdk.dir` from `local.properties` in the project root.
2. `ANDROID_HOME` environment variable.
3. `android-mode-sdk-dir` custom variable."
  (or
   (ignore-errors
     (android-in-directory
      (android-root)
      (let ((local-properties "local.properties"))
        (and (file-exists-p local-properties)
             (with-temp-buffer
               (insert-file-contents local-properties)
               (goto-char (point-min))
               (and (re-search-forward "^sdk\\.dir=\\(.*\\)" nil t)
                    (let ((sdk-dir (match-string 1)))
                      (and (file-directory-p sdk-dir) sdk-dir))))))))
   (getenv "ANDROID_HOME")
   android-mode-sdk-dir
   (error "No SDK directory found.  Set `android-mode-sdk-dir` or ANDROID_HOME")))

(defun android-tool-path (name)
  "Find the full path to an SDK tool NAME.
Searches in `android-mode-sdk-tool-subdirs` for the executable."
  (or (cl-loop for subdir in (android--sdk-tool-subdirs)
               thereis (cl-loop for ext in android-mode-sdk-tool-extensions
                                for path = (expand-file-name (concat name ext)
                                                             (expand-file-name subdir (android-local-sdk-dir)))
                                when (file-exists-p path)
                                return path))
      (error "Can't find SDK tool: %s in SDK path %s" name (android-local-sdk-dir))))

(defun android--sdk-tool-subdirs ()
  "Return SDK tool subdirectories, including versioned cmdline-tools paths."
  (let* ((sdk-dir (android-local-sdk-dir))
         (cmdline-tools (expand-file-name "cmdline-tools" sdk-dir))
         (versioned
          (when (file-directory-p cmdline-tools)
            (mapcar (lambda (dir)
                      (file-relative-name (expand-file-name "bin" dir) sdk-dir))
                    (seq-filter
                     #'file-directory-p
                     (directory-files cmdline-tools t "^[^.]" t))))))
    (delete-dups (append android-mode-sdk-tool-subdirs versioned))))

(defun android-current-buffer-class-name ()
  "Try to determine the fully qualified class name defined in the current buffer."
  (save-excursion
    (when (and buffer-file-name (string-match "\\.java$" buffer-file-name))
      (goto-char (point-min))
      (let ((case-fold-search nil)
            package class)
        (when (re-search-forward "^[ \t]*package[ \t]+\\([a-z0-9_.]+\\);" nil t)
          (setq package (match-string-no-properties 1)))
        (goto-char (point-min))
        (when (re-search-forward "\\bpublic[ \t]+\\(?:class\\|interface\\|enum\\)[ \t]+\\([A-Za-z0-9_]+\\)" nil t)
          (setq class (match-string-no-properties 1)))
        (cond ((and package class) (concat package "." class))
              (class class))))))

(defun android--fd-lines (&rest args)
  "Run fd with ARGS, return output lines.
Returns nil instead of signaling on non-zero exit (e.g. no matches)."
  (with-temp-buffer
    (let ((exit (apply #'call-process "fd" nil t nil args)))
      (when (zerop exit)
        (split-string (buffer-string) "\n" t)))))

(defun android--find-module-dir (dir)
  "Return subdirectories of DIR that contain a Gradle build file.
Uses `fd' for speed when available, falls back to Elisp traversal."
  (when-let* ((dir (file-name-as-directory (expand-file-name dir))))
    (if (executable-find "fd")
        (delq nil
              (mapcar (lambda (line)
                        (let ((full (expand-file-name (file-name-directory line) dir)))
                          (unless (string= (file-truename full) (file-truename dir))
                            (directory-file-name full))))
                      (or (android--fd-lines "-t" "f"
                                             "^build\\.gradle(\\.kts)?$"
                                             dir)
                          '())))
      ;; fallback: recursive Elisp
      (let ((result '()))
        (dolist (entry (directory-files dir t "^[^.]" t))
          (when (file-directory-p entry)
            (let ((entry-dir (file-name-as-directory entry)))
              (when (or (file-exists-p (concat entry-dir "build.gradle"))
                        (file-exists-p (concat entry-dir "build.gradle.kts")))
                (push entry result))
              (setq result (nconc result (android--find-module-dir entry))))))
        result))))

(defun android--apk-path ()
  "Find the most recent APK in the project build output.
Uses `fd' when available, falls back to scanning module build directories."
  (android-in-directory
   (android-root)
   (let ((candidates
          (if (executable-find "fd")
              (mapcar (lambda (f) (expand-file-name f))
                      (or (android--fd-lines "--no-ignore" "-t" "f" "-e" "apk"
                                             "." (expand-file-name default-directory))
                          '()))
            ;; fallback: scan module build dirs
            (mapcan
             (lambda (mod)
               (let ((apk-dir (concat (file-name-as-directory mod)
                                      "build/outputs/apk/debug/")))
                 (when (file-directory-p apk-dir)
                   (directory-files apk-dir t "\\.apk$"))))
             (or (android--find-module-dir default-directory)
                 (list default-directory))))))
     (when candidates
       (car (sort candidates
                  (lambda (a b)
                    (time-less-p (file-attribute-modification-time (file-attributes b))
                                 (file-attribute-modification-time (file-attributes a))))))))))

(defun android--aapt2-dump (apk)
  "Run `aapt2 dump badging APK` and return the output."
  (shell-command-to-string
   (format "%s dump badging %s 2>&1"
           (android-tool-path "aapt2")
           (shell-quote-argument apk))))

(defun android-project-package ()
  "Return the package name of the Android project.
Parses the built APK via aapt2."
  (when-let* ((apk (android--apk-path)))
    (let ((output (android--aapt2-dump apk)))
      (when (string-match "^package: name='\\([^']+\\)'" output)
        (match-string 1 output)))))

(defun android-project-main-activities (&optional _category)
  "Return list of main activity class names.
Parses the built APK via aapt2."
  (when-let* ((apk (android--apk-path)))
    (let ((output (android--aapt2-dump apk))
          activities)
      (with-temp-buffer
        (insert output)
        (goto-char (point-min))
        (while (re-search-forward "^launchable-activity: name='\\([^']+\\)'" nil t)
          (push (match-string 1) activities)))
      (nreverse activities))))

(defun android-start-app (&optional prompt)
  "Start an application on the connected device.
Use the current project selection, or select module and variant.
With prefix argument PROMPT, select module and variant again.
Uses aapt2 to find the launchable activity from the built APK."
  (interactive "P")
  (let* ((target (android--select-target prompt))
         (module (car target))
         (variant (cdr target))
         (package (plist-get (android-project-target module variant) :application-id))
         (apk (android--apk-path)))
    (unless (and package (not (string-empty-p package)))
      (error "No applicationId for %s:%s" module variant))
    (let* ((dump (when apk (android--aapt2-dump apk)))
           launchable)
      (when dump
        (let ((pos 0))
          (while (string-match "launchable-activity: name='\\([^']+\\)'" dump pos)
            (push (match-string 1 dump) launchable)
            (setq pos (match-end 0))))
        (setq launchable (nreverse launchable)))
      (let* ((current (android-current-buffer-class-name))
             (activity (or (and current launchable
                                (seq-contains-p launchable current #'string=)
                                current)
                           (car launchable))))
        (let* ((device (adb-read-device))
               (output (if activity
                           (adb-query device "shell" "am" "start" "-n"
                                              (concat package "/" activity))
                         (adb-query device "shell" "monkey" "-p" package
                                            "-c" "android.intent.category.LAUNCHER" "1"))))
          (message "Starting %s" package)
          (when (string-match-p "^Error\\|No activities found" output)
            (error "Error starting app:\n%s" output)))))))

(defun android--select-target (&optional prompt)
  "Return the current (MODULE . VARIANT), selecting again with PROMPT."
  (let ((target (or (android-current-target prompt)
                    (android-current-target t))))
    (unless target (user-error "Android project model is loading; retry shortly"))
    (cons (plist-get target :module-name) (plist-get target :variant))))

(defun android--capitalize (s)
  "Capitalize first letter of S."
  (if (string-empty-p s) s
    (concat (upcase (substring s 0 1)) (substring s 1))))

;; --- Commands ---

(defun android--log-variants (variants)
  "Log Android project VARIANTS."
  (if variants
      (dolist (target variants)
        (android--log "module=%s variant=%s selected=%s appId=%s"
                      (plist-get target :module-id)
                      (plist-get target :variant)
                      (if (plist-get target :selected-p) "yes" "no")
                      (plist-get target :application-id)))
    (android--log "no application flavors found")))

(defun android-print-flavor ()
  "Print cached flavors and refresh asynchronously when unavailable."
  (interactive)
  (android--log "printing flavor data")
  (let* ((root (android-root))
         (variants (android-project-variants)))
    (if variants
        (android--log-variants variants)
      (android-refresh-project-model
       root
       (lambda (_data error-data)
         (if error-data
             (android--log "project model refresh failed: %s" error-data)
           (android--log-variants (android-project-variants root))))))))

(defun android-refresh-flavors ()
  "Refresh project metadata asynchronously and report completion."
  (interactive)
  (android-refresh-project-model
   nil
   (lambda (data error-data)
     (if error-data
         (android--log "project model refresh failed: %s" error-data)
       (android--log "refreshed %d flavors" (length data))))))

(defun android-gradle (tasks-or-goals)
  "Run gradle TASKS-OR-GOALS in the project root directory."
  (interactive "sTasks or Goals: ")
  (android-in-directory
   (android-root)
   (android--log "running Gradle in %s: ./gradlew %s" default-directory tasks-or-goals)
   (compile (format "./gradlew %s" tasks-or-goals))))

(defun android-gradle-build (&optional prompt)
  "Run assemble task for the current project selection.
With prefix argument PROMPT, select module and variant again."
  (interactive "P")
  (let* ((target (android--select-target prompt))
         (module (car target))
         (variant (cdr target))
         (task (format ":%s:assemble%s" module (android--capitalize variant))))
    (android--log "build task %s" task)
    (android-gradle task)))

(defun android-gradle-install (&optional prompt)
  "Run install task for the current project selection.
With prefix argument PROMPT, select module and variant again."
  (interactive "P")
  (let* ((target (android--select-target prompt))
         (module (car target))
         (variant (cdr target))
         (task (format ":%s:install%s" module (android--capitalize variant))))
    (android--log "install task %s" task)
    (android-gradle task)))

(defun android-gradle-uninstall (&optional prompt)
  "Run uninstall task for the current project selection.
With prefix argument PROMPT, select module and variant again."
  (interactive "P")
  (let* ((target (android--select-target prompt))
         (module (car target))
         (variant (cdr target))
         (task (format ":%s:uninstall%s" module (android--capitalize variant))))
    (android--log "uninstall task %s" task)
    (android-gradle task)))

(defun android-gradle-test (&optional prompt)
  "Run test task for the current project selection.
With prefix argument PROMPT, select module and variant again."
  (interactive "P")
  (let* ((target (android--select-target prompt))
         (module (car target))
         (variant (cdr target))
         (task (format ":%s:test%sUnitTest" module (android--capitalize variant))))
    (android--log "test task %s" task)
    (android-gradle task)))

(defun android-gradle-clean ()
  "Run clean on the whole project."
  (interactive)
  (android--log "clean task")
  (android-gradle "clean"))

(defun android--install-apk (device apk &optional callback)
  "Install APK on DEVICE asynchronously.
When CALLBACK is non-nil, call it with no arguments on success."
  (android--log "installing %s on %s" (file-name-nondirectory apk) device)
  (adb-install-apk
   device apk
   (lambda (status output)
     (let ((buffer (get-buffer
                    (format "*adb-install %s*"
                            (file-name-nondirectory apk)))))
       (if (and (zerop status) (string-match-p "Success" output))
           (progn
             (android--log "installed %s on %s"
                           (file-name-nondirectory apk) device)
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (when callback (funcall callback)))
         (when (buffer-live-p buffer) (pop-to-buffer buffer))
         (error "Install failed on %s" device))))))

(defun android--launch-app-on-device (device package &optional callback)
  "Launch PACKAGE on DEVICE asynchronously.
When CALLBACK is non-nil, call it with no arguments on success."
  (android--log "launching %s" package)
  (adb-launch-package
   device package
   (lambda (status output)
     (if (and (zerop status)
              (not (string-match-p "^Error\\|No activities found" output)))
         (progn
           (android--log "launched %s" package)
           (when callback (funcall callback)))
       (message "Error launching %s on %s: %s" device package
                (string-trim output))))))

(defun android--launch-app (module variant)
  "Launch the app for MODULE and VARIANT on the connected device."
  (let ((package (plist-get (android-project-target module variant)
                            :application-id)))
    (unless (and package (not (string-empty-p package)))
      (error "No applicationId for %s:%s" module variant))
    (android--launch-app-on-device (adb-read-device) package)))

(defun android--compilation-chain (steps)
  "Run build chain items sequentially.
STEPS is a list where each item is one of:
- a string: gradle command, run via `compile'.
- a function taking one arg (a continuation thunk): async step,
  must call the thunk when done to proceed to the next step.
- a function taking zero args: synchronous step, returns immediately.
Gradle steps chain via `compilation-finish-functions'."
  (when steps
    (let ((step (car steps))
          (rest (cdr steps)))
      (cond
       ;; string → gradle compile
       ((stringp step)
        (android-in-directory
         (android-root)
         (android--log "running chained Gradle step: ./gradlew %s" step)
         (compile (format "./gradlew %s" step)))
        (when rest
          (let (hook)
            (setq hook
                  (lambda (_buf status)
                    (remove-hook 'compilation-finish-functions hook)
                    (when (string-match-p "finished" status)
                      (android--log "chained Gradle step finished: %s" status)
                      (android--compilation-chain rest))))
            (add-hook 'compilation-finish-functions hook))))
       ;; function with 1 arg → async step, pass continuation
       ((and (functionp step)
             (= (car (func-arity step)) 1))
        (funcall step (lambda () (android--compilation-chain rest))))
       ;; function with 0 args → sync step
       ((functionp step)
        (funcall step)
        (android--compilation-chain rest))))))

(defun android-run (&optional prompt)
  "Build, install and launch the app.
Use the current project selection, select target device, then chain:
  gradle assemble → adb install → adb start.
All adb steps run asynchronously without blocking Emacs.
When only one device is connected, it is used automatically.
With prefix argument PROMPT, select module and variant again."
  (interactive "P")
  (let* ((target (android--select-target prompt))
         (module (car target))
         (variant (cdr target))
         (device (adb-read-device))
         (cap-variant (android--capitalize variant))
         (assemble-task (format ":%s:assemble%s" module cap-variant))
         (package (plist-get (android-project-target module variant) :application-id)))
    (unless (and package (not (string-empty-p package)))
      (error "No applicationId for %s:%s" module variant))
    (android--log "run module=%s variant=%s device=%s package=%s task=%s"
                  module variant device package assemble-task)
    (android--compilation-chain
     (list assemble-task
           (lambda (next)
             (let ((apk (android--apk-path)))
               (unless apk (error "No APK found after build"))
               (android--install-apk device apk next)))
           (lambda (next)
             (android--launch-app-on-device device package next))))))

;; Gradle (keep simple macro for custom tasks)
(defmacro android-defun-gradle-task (task)
  "Define an interactive Android Gradle command for TASK."
  `(defun ,(intern (concat "android-gradle-"
                           (replace-regexp-in-string "[[:space:]:]" "-" task)))
       ()
     ,(concat "Run `gradle " task "` in the project root directory.")
     (interactive)
     (android-gradle ,task)))

(autoload 'android-avd-start "android-mode-avd"
  "Launch an Android emulator." t)
(autoload 'android-avd-install-system-image "android-mode-avd"
  "Download and install an Android system image." t)
(autoload 'android-avd "android-mode-avd"
  "Create and manage Android Virtual Devices." t)
(autoload 'scrcpy-start "scrcpy"
  "Start scrcpy with the current transient arguments." t)
(autoload 'scrcpy "scrcpy"
  "Configure, start, and manage scrcpy (requires scrcpy)." t)
(define-obsolete-function-alias
  'android-start-emulator #'android-avd-start "0.8.0")

(defconst android-mode-keys
  '(("a" . android-start-app)
    ("r" . android-run)
    ("s" . scrcpy)
    ("e" . android-avd-start)
    ("f" . android-print-flavor)
    ("R" . android-refresh-flavors)
    ("C" . android-gradle-clean)
    ("t" . android-gradle-test)
    ("c" . android-gradle-build)
    ("i" . android-gradle-install)
    ("u" . android-gradle-uninstall)))

(defvar android-mode-map (make-sparse-keymap)
  "Keymap for `android-mode'.")

;;;###autoload
(define-minor-mode android-mode
  "Android application development minor mode."
  :lighter " Android"
  :keymap android-mode-map)

(defun android-mode-enable-if-project ()
  "Enable `android-mode' if the current file is in an Android project."
  (when (android-root)
    (android-mode 1)))

(add-hook 'dired-mode-hook #'android-mode-enable-if-project)
(add-hook 'find-file-hook #'android-mode-enable-if-project)

(defun android--latest-build-tools-subdir ()
  "Return the relative path to the latest build-tools subdirectory."
  (let* ((build-tools-dir (expand-file-name "build-tools" (android-local-sdk-dir)))
         (versions (and (file-directory-p build-tools-dir)
                        (directory-files build-tools-dir nil "^[0-9]"))))
    (when versions
      (concat "build-tools/" (car (last (sort versions #'string<)))))))

(when-let* ((subdir (ignore-errors (android--latest-build-tools-subdir))))
  (cl-pushnew subdir android-mode-sdk-tool-subdirs :test #'string=))

(provide 'android-mode)

;;; android-mode.el ends here
