;;; android-mode.el --- Minor mode for Android application development -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2018 R.W van 't Veer
;; Copyright (C) 2025 Gemini (Code optimizations and warning fixes)

;; Author: R.W. van 't Veer
;; Created: 20 Feb 2009
;; Keywords: tools processes
;; Version: 0.7.0
;; Package-Requires: ((emacs "28.1") (transient "0.3.0"))
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
(require 'filenotify nil t)
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

(defvar android-mode-flavor-script
  (expand-file-name "listFlavorAppId.gradle"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Gradle init script path relative to this Emacs Lisp file.")

(defvar android--selected-modules nil
  "Alist of current Android module IDs keyed by project root.")

(defvar android--selected-variants nil
  "Alist of per-module selected variants keyed by project root.
Each value is an alist whose keys are module IDs and values are variants.")

(defun android--log (format-string &rest args)
  "Log android-mode message FORMAT-STRING with ARGS."
  (apply #'message (concat "android-mode: " format-string) args))

;;;###autoload
(defun android-root ()
  "Find the root directory of the Android project.
The root is the directory containing the project's `gradlew` file."
  (locate-dominating-file default-directory "gradlew"))

(defmacro android-in-directory (chosen-dir &rest body)
  "Execute BODY form with CHOSEN-DIR as `default-directory'.
The form is not executed when no project root directory can be found."
  `(let ((dir ,chosen-dir))
     (if dir
         (let ((default-directory dir))
           ,@body)
       (error "Can't find project root or relevant directory"))))

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
         (package (android--flavor-appid module variant))
         (apk (android--apk-path)))
    (unless package (error "No applicationId for %s:%s" module variant))
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
        ;; If no launchable activity found, use monkey launcher as fallback
        (if activity
            (let* ((command (format "%s shell am start -n %s/%s"
                                    (android-tool-path "adb") package activity))
                   (output (shell-command-to-string command)))
              (message "Starting %s/%s" package activity)
              (when (string-match-p "^Error: " output)
                (error "Error starting app:\n%s" output)))
          ;; monkey fallback: launch default activity
          (let* ((command (format "%s shell monkey -p %s -c android.intent.category.LAUNCHER 1"
                                  (android-tool-path "adb") package))
                 (output (shell-command-to-string command)))
            (message "Starting %s via monkey launcher" package)
            (when (string-match-p "^Error\\|No activities found" output)
              (error "Error starting app:\n%s" output))))))))

;; --- Flavor data source (module / variant / appId) ---

(defcustom android-mode-cache-dir
  (concat user-emacs-directory ".cache/android/")
  "Directory for persisting android-mode caches."
  :type 'string
  :group 'android)

(defconst android--flavor-cache-version 7
  "Flavor cache schema version.")

(defvar android-project-model-updated-hook nil
  "Hook run after an Android project model refresh succeeds.")

(defvar android--project-refresh-processes (make-hash-table :test #'equal)
  "Active project model refresh processes keyed by project root.")

(defvar android--project-refresh-callbacks (make-hash-table :test #'equal)
  "Pending project model refresh callbacks keyed by project root.")

(defvar android--project-refresh-invalidated (make-hash-table :test #'equal)
  "Roots changed while their project model refresh was running.")

(defvar android--selection-loaded-roots nil
  "Project roots whose persisted target selection has been loaded.")

(defvar android--flavor-cache nil
  "Cached flavor data as plist entries.
Each entry contains :module-id, :build-root, :module-path, :module-name,
:module-root, :plugin-id, :variant, :application-id, :test-application-id,
:source-roots, :preview-task,
:build-type, :product-flavors, :preferred-build-type-p, and
:preferred-product-flavors.  Per-project, keyed by project root.")

(defvar android--flavor-cache-root nil
  "Project root for which `android--flavor-cache' is valid.")

(defvar android--flavor-cache-fingerprint nil
  "Input fingerprint for `android--flavor-cache'.")

(defvar android--flavor-cache-stale-p t
  "Non-nil when the in-memory project model needs refresh.")

(defvar android--project-watch-descriptors (make-hash-table :test #'equal)
  "File notification descriptors keyed by project root.")

(defvar android--project-watch-roots (make-hash-table :test #'equal)
  "Project roots keyed by file notification descriptor.")

(defvar android--project-watch-inputs (make-hash-table :test #'equal)
  "Tracked project model input files keyed by project root.")

(defvar android--project-watch-fingerprints (make-hash-table :test #'equal)
  "Last lightweight input signatures keyed by project root.")

(defvar android--project-watch-timer nil
  "Idle timer used when native file notifications are unavailable.")

(defun android--selection-file (root)
  "Return the target selection file path for project ROOT."
  (let ((key (md5 (directory-file-name (expand-file-name root)))))
    (expand-file-name (concat key "-selection.eld") android-mode-cache-dir)))

(defun android--file-signature (file)
  "Return a lightweight metadata signature for FILE."
  (if (file-directory-p file)
      (mapcar (lambda (entry)
                (cons (file-name-nondirectory entry)
                      (android--file-signature entry)))
              (directory-files file t "\\.toml\\'" t))
    (when-let* ((attributes (file-attributes file 'string)))
      (list (file-attribute-type attributes)
            (file-attribute-size attributes)
            (file-attribute-modification-time attributes)
            (file-attribute-status-change-time attributes)))))

(defun android--project-model-input-files (root &optional data)
  "Return model input files for ROOT and cached model DATA."
  (let* ((build-roots
          (delete-dups
           (cons root (delq nil (mapcar (lambda (entry)
                                         (plist-get entry :build-root))
                                       data)))))
         (module-roots
          (delete-dups (delq nil (mapcar (lambda (entry)
                                           (plist-get entry :module-root))
                                         data))))
         files)
    (dolist (dir (append build-roots module-roots))
      (dolist (name '("build.gradle" "build.gradle.kts" "gradle.properties"
                      "settings.gradle" "settings.gradle.kts"))
        (push (expand-file-name name dir) files)))
    (dolist (dir build-roots)
      (push (expand-file-name "gradle/wrapper/gradle-wrapper.properties" dir)
            files)
      (let ((catalog-dir (expand-file-name "gradle" dir)))
        (push catalog-dir files)
        (when (file-directory-p catalog-dir)
          (setq files (nconc (directory-files catalog-dir t "\\.toml\\'" t)
                             files)))))
    (sort (delete-dups files) #'string<)))

(defun android--project-model-fingerprint (root &optional data inputs)
  "Return a lightweight signature of project inputs for ROOT and DATA.
When INPUTS is non-nil, use that exact path list."
  (secure-hash
   'sha256
   (prin1-to-string
    (mapcar (lambda (file)
              (cons file (android--file-signature file)))
            (or inputs (android--project-model-input-files root data))))))

(defun android--flavor-cache-file (root)
  "Return the disk cache file path for project ROOT."
  (let ((key (md5 (directory-file-name (expand-file-name root)))))
    (expand-file-name (concat key ".eld") android-mode-cache-dir)))

(defun android--atomic-write (file value)
  "Write Lisp VALUE atomically to FILE without broad permissions."
  (make-directory (file-name-directory file) t)
  (let ((temporary (make-temp-file
                    (expand-file-name ".android-mode-" (file-name-directory file)))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (prin1 value (current-buffer)))
          (rename-file temporary file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun android--flavor-cache-save (root data)
  "Persist flavor DATA for project ROOT to disk."
  (let* ((file (android--flavor-cache-file root))
         (inputs (android--project-model-input-files root data))
         (fingerprint (android--project-model-fingerprint root data inputs)))
    (android--log "saving flavor cache for %s to %s" root file)
    (android--atomic-write
     file
     (list :version android--flavor-cache-version
           :root root :time (current-time)
           :inputs inputs :fingerprint fingerprint :data data))
    (setq android--flavor-cache-fingerprint fingerprint
          android--flavor-cache-stale-p nil)
    (android--watch-project-inputs root inputs)))

(defun android--flavor-cache-valid-p (data)
  "Return non-nil when DATA matches the current flavor cache schema."
  (and (listp data)
       (seq-every-p
        (lambda (entry)
          (and (keywordp (car-safe entry))
               (plist-get entry :module-id)
               (plist-get entry :build-root)
               (plist-get entry :module-path)
               (plist-get entry :module-root)
               (plist-get entry :plugin-id)
               (plist-get entry :variant)
               (plist-member entry :source-roots)
               (plist-member entry :preview-task)
               (plist-member entry :build-type)
               (plist-member entry :product-flavors)
               (plist-member entry :preferred-build-type-p)
               (plist-member entry :preferred-product-flavors)))
        data)))

(defun android--flavor-cache-load (root)
  "Load schema-valid cached flavor data for project ROOT.
Return a plist with :data and :fresh-p, or nil for an invalid cache."
  (let ((file (android--flavor-cache-file root)))
    (when (file-exists-p file)
      (android--log "loading flavor cache for %s from %s" root file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (let* ((plist (read (current-buffer)))
                 (data (plist-get plist :data))
                 (inputs (plist-get plist :inputs))
                 (fingerprint (plist-get plist :fingerprint))
                 (current-fingerprint
                  (when (and (listp inputs) (listp data))
                    (android--project-model-fingerprint
                     root data inputs))))
            (when (and (= (or (plist-get plist :version) 0)
                          android--flavor-cache-version)
                       (string= (plist-get plist :root) root)
                       (android--flavor-cache-valid-p data))
              (list :data data :inputs inputs
                    :fingerprint fingerprint
                    :current-fingerprint current-fingerprint
                    :fresh-p (equal fingerprint current-fingerprint)))))))))

(defun android--module-id-p (value)
  "Return non-nil when VALUE is a stable Android module ID."
  (and (consp value) (stringp (car value)) (stringp (cdr value))))

(defun android--selection-state-valid-p (state root)
  "Return non-nil when persisted selection STATE is valid for ROOT."
  (let ((module (plist-get state :module))
        (variants (plist-get state :variants)))
    (and (= (or (plist-get state :version) 0) 1)
         (string= (plist-get state :root) root)
         (or (null module) (android--module-id-p module))
         (listp variants)
         (seq-every-p
          (lambda (entry)
            (and (android--module-id-p (car entry))
                 (stringp (cdr entry))))
          variants))))

(defun android--selection-load (root)
  "Load persisted target selection for ROOT once."
  (unless (member root android--selection-loaded-roots)
    (push root android--selection-loaded-roots)
    (let ((file (android--selection-file root)))
      (when (file-readable-p file)
        (ignore-errors
          (with-temp-buffer
            (insert-file-contents file)
            (let ((state (read (current-buffer))))
              (when (android--selection-state-valid-p state root)
                (setf (alist-get root android--selected-modules
                                 nil nil #'string=)
                      (plist-get state :module))
                (setf (alist-get root android--selected-variants
                                 nil nil #'string=)
                      (plist-get state :variants))))))))))

(defun android--selection-save (root)
  "Persist the current target selection for ROOT."
  (android--atomic-write
   (android--selection-file root)
   (list :version 1 :root root
         :module (cdr (assoc root android--selected-modules))
         :variants (cdr (assoc root android--selected-variants)))))

(defun android--project-watch-event-relevant-p (root event)
  "Return non-nil when file notification EVENT affects model ROOT."
  (let ((inputs (gethash root android--project-watch-inputs)))
    (seq-some
     (lambda (file)
       (and file
            (or (member file inputs)
                (and (string-suffix-p ".toml" file)
                     (seq-some
                      (lambda (input)
                        (and (file-directory-p input)
                             (string= (file-name-directory file)
                                      (file-name-as-directory input))))
                      inputs)))))
     (cddr event))))

(defun android--mark-project-model-stale (root)
  "Mark ROOT stale and start one asynchronous refresh."
  (when (gethash root android--project-refresh-processes)
    (puthash root t android--project-refresh-invalidated))
  (when (equal root android--flavor-cache-root)
    (setq android--flavor-cache-stale-p t))
  (android-refresh-project-model root))

(defun android--project-watch-callback (event)
  "Mark a project model stale in response to file notification EVENT."
  (when-let* ((descriptor (car event))
              (root (gethash descriptor android--project-watch-roots))
              ((android--project-watch-event-relevant-p root event)))
    (android--mark-project-model-stale root)))

(defun android--check-project-watch-inputs ()
  "Refresh watched projects whose lightweight input signature changed."
  (maphash
   (lambda (root inputs)
     (let ((fingerprint (android--project-model-fingerprint root nil inputs)))
       (unless (equal fingerprint
                      (gethash root android--project-watch-fingerprints))
         (puthash root fingerprint android--project-watch-fingerprints)
         (android--mark-project-model-stale root))))
   android--project-watch-inputs))

(defun android--project-input-saved ()
  "Refresh a project when the saved buffer is a tracked model input."
  (when buffer-file-name
    (maphash
     (lambda (root inputs)
       (when (member buffer-file-name inputs)
         (android--mark-project-model-stale root)))
     android--project-watch-inputs)))

(defun android--watch-project-inputs (root inputs)
  "Watch model INPUTS for ROOT and install an idle fallback."
  (dolist (descriptor (gethash root android--project-watch-descriptors))
    (remhash descriptor android--project-watch-roots)
    (ignore-errors (file-notify-rm-watch descriptor)))
  (let (descriptors)
    (when (fboundp 'file-notify-add-watch)
      (dolist (file inputs)
        (let ((target (if (file-exists-p file)
                          file
                        (file-name-directory file))))
          (when (and target (file-exists-p target))
            (ignore-errors
              (let ((descriptor
                     (file-notify-add-watch
                      target '(change attribute-change)
                      #'android--project-watch-callback)))
                (puthash descriptor root android--project-watch-roots)
                (push descriptor descriptors)))))))
    (puthash root descriptors android--project-watch-descriptors)
    (puthash root inputs android--project-watch-inputs)
    (puthash root (android--project-model-fingerprint root nil inputs)
             android--project-watch-fingerprints)
    (unless (timerp android--project-watch-timer)
      (setq android--project-watch-timer
            (run-with-idle-timer 2 t #'android--check-project-watch-inputs)))))

(defun android--flavor-cache-current-p (root)
  "Return non-nil when the in-memory model for ROOT is not marked stale."
  (and android--flavor-cache
       (string= root android--flavor-cache-root)
       (not android--flavor-cache-stale-p)))

(defun android--gradle-model-command (root)
  "Return the Gradle project model command for ROOT."
  (list (expand-file-name "gradlew" root)
        "--no-configuration-cache" "-I" android-mode-flavor-script
        "help" "--quiet"))

(defun android--finish-project-refresh (root data error-data)
  "Finish the project model refresh for ROOT with DATA or ERROR-DATA."
  (let ((callbacks (prog1 (gethash root android--project-refresh-callbacks)
                     (remhash root android--project-refresh-callbacks))))
    (remhash root android--project-refresh-processes)
    (when data
      (setq android--flavor-cache data
            android--flavor-cache-root root)
      (android--flavor-cache-save root data)
      (run-hook-with-args 'android-project-model-updated-hook root data))
    (dolist (callback callbacks)
      (funcall callback data error-data))))

(defun android--project-refresh-stale-p (root start-fingerprint inputs)
  "Return non-nil if ROOT's INPUTS changed from START-FINGERPRINT."
  (or (gethash root android--project-refresh-invalidated)
      (not (equal start-fingerprint
                  (android--project-model-fingerprint root nil inputs)))))

(defun android--restart-project-refresh (root callbacks)
  "Restart a stale refresh for ROOT and preserve CALLBACKS."
  (remhash root android--project-refresh-processes)
  (puthash root callbacks android--project-refresh-callbacks)
  (android--log "project inputs changed during refresh; restarting %s" root)
  (android-refresh-project-model root))

(defun android--project-refresh-sentinel (process event)
  "Handle project model refresh PROCESS completion described by EVENT."
  (when (memq (process-status process) '(exit signal))
    (let* ((root (process-get process 'android-project-root))
           (buffer (process-buffer process))
           (current (gethash root android--project-refresh-processes))
           (output (when (buffer-live-p buffer)
                     (with-current-buffer buffer (buffer-string)))))
      (when (eq process current)
        (let ((start-fingerprint
               (process-get process 'android-project-input-fingerprint))
              (inputs (process-get process 'android-project-inputs)))
          (if (android--project-refresh-stale-p
               root start-fingerprint inputs)
              (progn
                (remhash root android--project-refresh-invalidated)
                (android--restart-project-refresh
                 root (gethash root android--project-refresh-callbacks)))
            (if (and (= (process-exit-status process) 0) output)
                (let ((data (android-parse-gradle-flavors output)))
                  (cond
                   ((android--project-refresh-stale-p
                     root start-fingerprint inputs)
                    (remhash root android--project-refresh-invalidated)
                    (android--restart-project-refresh
                     root (gethash root android--project-refresh-callbacks)))
                   (data
                    (android--log "refreshed %d flavor entries" (length data))
                    (android--finish-project-refresh root data nil))
                   (t
                    (android--finish-project-refresh
                     root nil "Gradle returned no Android project model"))))
              (android--finish-project-refresh
               root nil (string-trim (or output event)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun android-refresh-project-model (&optional project-root callback)
  "Refresh PROJECT-ROOT asynchronously and return its process.
CALLBACK, when non-nil, is called with two arguments DATA and ERROR.  Multiple
requests for the same root share one Gradle process."
  (when-let* ((root (android--project-root project-root)))
    (when callback
      (puthash root
               (append (gethash root android--project-refresh-callbacks)
                       (list callback))
               android--project-refresh-callbacks))
    (or (gethash root android--project-refresh-processes)
        (let* ((inputs (android--project-model-input-files
                        root (and (string= root android--flavor-cache-root)
                                  android--flavor-cache)))
               (fingerprint (android--project-model-fingerprint root nil inputs))
               (buffer (generate-new-buffer " *android-project-model*"))
               (default-directory root)
               (process
                (make-process
                 :name (format "android-project-model-%s"
                               (file-name-nondirectory
                                (directory-file-name root)))
                 :buffer buffer :command (android--gradle-model-command root)
                 :connection-type 'pipe :noquery t
                 :sentinel #'ignore)))
          (with-current-buffer buffer
            (setq-local default-directory root))
          (process-put process 'android-project-root root)
          (process-put process 'android-project-inputs inputs)
          (process-put process 'android-project-input-fingerprint fingerprint)
          (remhash root android--project-refresh-invalidated)
          (puthash root process android--project-refresh-processes)
          (set-process-sentinel process #'android--project-refresh-sentinel)
          (android--log "refreshing project model for %s asynchronously" root)
          process))))

(defun android--get-flavors (&optional refresh)
  "Return flavor data while refreshing stale metadata asynchronously.
With REFRESH non-nil, always request a refresh.  This function never waits for
Gradle and keeps returning an available last-known in-memory model."
  (when-let* ((root (android--project-root)))
    (android--selection-load root)
    (let ((memory (and android--flavor-cache
                       (string= root android--flavor-cache-root)
                       android--flavor-cache)))
      (cond
       ((and (not refresh) (android--flavor-cache-current-p root)) memory)
       ((and (not refresh)
             (let ((cache (android--flavor-cache-load root)))
               (when cache
                 (setq android--flavor-cache (plist-get cache :data)
                       android--flavor-cache-root root
                       android--flavor-cache-fingerprint
                       (plist-get cache :fingerprint)
                       android--flavor-cache-stale-p
                       (not (plist-get cache :fresh-p)))
                 (android--watch-project-inputs root (plist-get cache :inputs))
                 (when android--flavor-cache-stale-p
                   (android-refresh-project-model root))
                 t)))
        android--flavor-cache)
       (t
        (android-refresh-project-model root)
        memory)))))

(defun android-parse-gradle-flavors (gradle-output)
  "Parse GRADLE-OUTPUT and return Android module metadata plists.
Only considers lines between ===FLAVORS_START=== and ===FLAVORS_END===."
  (let ((in-flavors nil)
        (result '()))
    (dolist (line (split-string gradle-output "\n" t))
      (cond
       ((string-match-p "===FLAVORS_START===" line)
        (setq in-flavors t))
       ((string-match-p "===FLAVORS_END===" line)
        (setq in-flavors nil))
       (in-flavors
        (pcase-let ((`(,module-path ,module-root ,build-root ,variant ,appid
                         ,source-roots ,preview-task ,build-type
                         ,product-flavors ,preferred-build-type
                         ,preferred-product-flavors ,plugin-id
                         ,test-application-id)
                       (split-string line "|" nil)))
          (when (and module-path module-root variant)
            (push (list :module-id (cons build-root module-path)
                        :build-root build-root
                        :module-path module-path
                        :module-name (string-remove-prefix ":" module-path)
                        :module-root module-root
                        :plugin-id (or plugin-id "")
                        :variant variant
                        :application-id (or appid "")
                        :test-application-id (or test-application-id "")
                        :source-roots (split-string (or source-roots "") ";" t)
                        :preview-task (or preview-task "")
                        :build-type (or build-type "")
                        :product-flavors
                        (split-string (or product-flavors "") "," t)
                        :preferred-build-type-p
                        (equal preferred-build-type "true")
                        :preferred-product-flavors
                        (split-string (or preferred-product-flavors "") "," t))
                  result))))))
    (nreverse result)))

(defun android--flavor-field (entry index property)
  "Return ENTRY field from plist PROPERTY or legacy tuple INDEX."
  (if (keywordp (car-safe entry))
      (plist-get entry property)
    (nth index entry)))

(defun android--flavor-modules ()
  "Return deduplicated list of module names from flavor data."
  (delete-dups
   (mapcar (lambda (entry)
             (android--flavor-field entry 0 :module-name))
           (android--get-flavors))))

(defun android--flavor-variants (module)
  "Return list of variant names for MODULE."
  (mapcar (lambda (entry)
            (android--flavor-field entry 1 :variant))
          (seq-filter (lambda (entry)
                        (string= (android--flavor-field entry 0 :module-name)
                                 module))
                      (android--get-flavors))))

(defun android--flavor-appid (module variant)
  "Return applicationId for MODULE and VARIANT."
  (android--flavor-field
   (seq-find (lambda (entry)
               (and (string= (android--flavor-field entry 0 :module-name)
                             module)
                    (string= (android--flavor-field entry 1 :variant)
                             variant)))
             (android--get-flavors))
   2
   :application-id))

(defun android--file-in-directory-p (file directory)
  "Return non-nil when FILE is inside DIRECTORY."
  (let ((file (file-truename file))
        (directory (file-name-as-directory (file-truename directory))))
    (string-prefix-p directory file)))

(defun android--target-source-root-score (file module-root source-root)
  "Return match score when FILE is under SOURCE-ROOT in MODULE-ROOT."
  (let ((root (expand-file-name source-root
                                (file-name-as-directory module-root))))
    (when (android--file-in-directory-p file root)
      (length (file-truename root)))))

(defun android--target-score (file entry)
  "Return source-root match score for FILE and module metadata ENTRY."
  (let ((module-root (plist-get entry :module-root)))
    (when (and module-root (android--file-in-directory-p file module-root))
      (or (seq-max
           (delq nil
                 (mapcar (lambda (source-root)
                           (android--target-source-root-score
                            file module-root source-root))
                         (plist-get entry :source-roots))))
          (length (file-truename module-root))))))

(defun android--target-for-source-file (file project-root &optional entries)
  "Return best Android module metadata for FILE under PROJECT-ROOT.
ENTRIES defaults to `android--get-flavors'."
  (let* ((file (expand-file-name file))
         (entries (or entries
                      (let ((default-directory project-root))
                        (android--get-flavors))))
         best-entry
         best-score)
    (dolist (entry entries)
      (when (keywordp (car-safe entry))
        (let ((score (android--target-score file entry)))
          (when (and score (or (not best-score) (> score best-score)))
            (setq best-entry entry
                  best-score score)))))
    best-entry))

(defun android--root-for-file (file)
  "Return an Android project root for FILE, or nil."
  (ignore-errors
    (let ((default-directory (file-name-directory (expand-file-name file))))
      (android-root))))

(defun android--variant-sort-key (entry flavor-dimensions)
  "Return Studio-compatible key for ENTRY over FLAVOR-DIMENSIONS."
  (let* ((preferred-flavors (plist-get entry :preferred-product-flavors))
         (flavors (cl-subseq (plist-get entry :product-flavors)
                             0 flavor-dimensions)))
    (append
     (list (if (plist-get entry :preferred-build-type-p) 0 1))
     (mapcar (lambda (flavor)
               (if (member flavor preferred-flavors) 0 1))
             flavors)
     (list (if (equal (plist-get entry :build-type) "debug") 0 1))
     flavors
     (list (plist-get entry :build-type)))))

(defun android--variant-key-less-p (left right)
  "Return non-nil when variant key LEFT sorts before RIGHT."
  (catch 'result
    (while left
      (let ((left-value (pop left))
            (right-value (pop right)))
        (unless (equal left-value right-value)
          (throw 'result
                 (if (numberp left-value)
                     (< left-value right-value)
                   (string< left-value right-value))))))
    nil))

(defun android--default-module-target (entries)
  "Return Android Studio-compatible default target from ENTRIES."
  (when entries
    (let* ((flavor-dimensions
            (apply #'min
                   (mapcar (lambda (entry)
                             (length (plist-get entry :product-flavors)))
                           entries)))
           (best (car entries))
           (best-key (android--variant-sort-key best flavor-dimensions)))
      (dolist (entry (cdr entries))
        (let ((key (android--variant-sort-key entry flavor-dimensions)))
          (when (android--variant-key-less-p key best-key)
            (setq best entry
                  best-key key))))
      best)))

(defun android--project-root (&optional project-root)
  "Return normalized PROJECT-ROOT or the current Android project root."
  (when-let* ((root (or project-root (ignore-errors (android-root)))))
    (file-name-as-directory (expand-file-name root))))

(defun android-project-variants (&optional project-root refresh)
  "Return available Android variant metadata for PROJECT-ROOT.
Each entry is a plist describing one Gradle module variant.  PROJECT-ROOT
defaults to `android-root'.  Stale or missing metadata starts an asynchronous
refresh; a last-known in-memory model remains available during the refresh.
With REFRESH non-nil, always start a refresh."
  (when-let* ((root (android--project-root project-root)))
    (android--selection-load root)
    (let ((default-directory root))
      (android--mark-selected-variants
       root (copy-tree (android--get-flavors refresh))))))

(defun android--module-key (entry)
  "Return stable module identity for target ENTRY."
  (or (plist-get entry :module-id)
      (plist-get entry :module-name)))

(defun android--selected-module-variant (root module entries)
  "Return selected variant under ROOT for MODULE from ENTRIES.
MODULE is a stable module identity as returned by `android--module-key'."
  (let* ((module-selections (cdr (assoc root android--selected-variants)))
         (remembered (cdr (assoc module module-selections)))
         (variants (seq-filter
                    (lambda (entry)
                      (equal (android--module-key entry) module))
                    entries)))
    (or (and remembered
             (seq-find (lambda (entry)
                         (string= (plist-get entry :variant) remembered))
                       variants))
        (android--default-module-target variants))))

(defun android--mark-selected-variants (root entries)
  "Return copies of ENTRIES marked with selected state under ROOT."
  (let ((selected
         (mapcar
          (lambda (module)
            (android--selected-module-variant root module entries))
          (delete-dups (mapcar #'android--module-key entries)))))
    (mapcar
     (lambda (entry)
       (let ((copy (copy-tree entry)))
         (plist-put copy :selected-p
                    (and (memq entry selected) t))))
     entries)))

(defun android-project-targets (&optional project-root refresh)
  "Return the selected Android target for each module in PROJECT-ROOT.
This mirrors Android Studio's display modules and each module's selected
variant.  Use `android-project-variants' to inspect every available variant.
With REFRESH non-nil, refresh Gradle metadata."
  (when-let* ((root (android--project-root project-root))
              (entries (android-project-variants root refresh)))
    (seq-filter (lambda (entry) (plist-get entry :selected-p)) entries)))

(defun android-project-application-ids (&optional project-root refresh)
  "Return application and test IDs for all Android variants in PROJECT-ROOT.
The result mirrors Android Studio's project application-ID set: main IDs from
application, dynamic-feature, and standalone test modules, plus every available
instrumentation test ID.  Missing or stale metadata follows the asynchronous
refresh behavior of `android-project-variants'.  With REFRESH non-nil, always
start a refresh."
  (delete-dups
   (apply
    #'append
    (mapcar
     (lambda (target)
       (let ((plugin-id (plist-get target :plugin-id))
             (application-id (plist-get target :application-id))
             (test-application-id (plist-get target :test-application-id)))
         (delq
          nil
          (list
           (and (member plugin-id
                        '("com.android.application"
                          "com.android.dynamic-feature"
                          "com.android.test"))
                (stringp application-id)
                (not (string-empty-p application-id))
                application-id)
           (and (stringp test-application-id)
                (not (string-empty-p test-application-id))
                test-application-id)))))
     (android-project-variants project-root refresh)))))

(defun android-project-target (module &optional variant project-root refresh)
  "Return a target for MODULE under PROJECT-ROOT.
MODULE accepts a module ID, name, or Gradle path.  Without VARIANT, return the
module's selected target.  With VARIANT, return that exact candidate and mark
whether it is selected.  Ambiguous string module names return nil.  With
REFRESH non-nil, refresh Gradle metadata."
  (let* ((entries (android-project-variants project-root refresh))
         (matches
          (if (consp module)
              (seq-filter
               (lambda (entry)
                 (equal (plist-get entry :module-id) module))
               entries)
            (let ((name (string-remove-prefix ":" module)))
              (seq-filter
               (lambda (entry)
                 (or (string= (plist-get entry :module-name) name)
                     (string= (plist-get entry :module-path) module)))
               entries))))
         (module-ids (delete-dups (mapcar #'android--module-key matches))))
    (when (= (length module-ids) 1)
      (if variant
          (seq-find (lambda (entry)
                      (string= (plist-get entry :variant) variant))
                    matches)
        (seq-find (lambda (entry) (plist-get entry :selected-p)) matches)))))

(defun android-target-for-source-file (file &optional project-root refresh)
  "Return the selected Android target owning FILE under PROJECT-ROOT.
The file first resolves to a Gradle module, then to that module's selected
variant, matching Android Studio's build-target lookup.  With REFRESH non-nil,
refresh Gradle metadata."
  (let* ((file (expand-file-name file))
         (root (android--project-root
                (or project-root (android--root-for-file file))))
         (entries (and root (android-project-variants root refresh)))
         (owner (and entries
                     (android--target-for-source-file file root entries))))
    (when owner
      (let ((target
             (copy-tree
              (android--selected-module-variant
               root (android--module-key owner) entries))))
        (plist-put target :selected-p t)))))

;; --- Interactive selection ---

(defun android--module-display-name (target duplicates)
  "Return display name for TARGET, disambiguated by DUPLICATES."
  (let ((name (plist-get target :module-name)))
    (if (member name duplicates)
        (format "%s  [%s]" name (plist-get target :build-root))
      name)))

(defun android--select-module-target ()
  "Prompt for and return one selected module target."
  (let* ((targets (or (android-project-targets)
                      (user-error
                       "Android project model is loading; retry shortly")))
         (names (mapcar (lambda (entry) (plist-get entry :module-name)) targets))
         (duplicates
          (seq-filter
           (lambda (name) (> (seq-count (lambda (item) (string= item name)) names) 1))
           (delete-dups (copy-sequence names))))
         (choices
          (mapcar (lambda (target)
                    (cons (android--module-display-name target duplicates) target))
                  targets))
         (choice (if (= (length choices) 1)
                     (caar choices)
                   (completing-read "Module: " choices nil t))))
    (cdr (assoc choice choices))))

(defun android--select-module ()
  "Prompt user to select a module and return its module name string."
  (let* ((target (android--select-module-target))
         (module (plist-get target :module-name)))
    (android--log "selected module %s" module)
    module))

(defun android--select-target-variant (target)
  "Prompt for a variant of module TARGET and return its name."
  (let* ((module-id (android--module-key target))
         (module (plist-get target :module-name))
         (variants
          (mapcar
           (lambda (entry) (plist-get entry :variant))
           (seq-filter
            (lambda (entry)
              (equal (android--module-key entry) module-id))
            (android-project-variants))))
         (variant (if (= (length variants) 1)
                      (car variants)
                    (completing-read (format "Variant (%s): " module)
                                     variants nil t))))
    (android--log "selected variant %s for module %s" variant module)
    variant))

(defun android--select-variant (module)
  "Prompt for a variant of uniquely named MODULE and return its name."
  (when-let* ((target (android-project-target module)))
    (android--select-target-variant target)))

(defun android--remember-target (root module-id variant)
  "Remember and persist MODULE-ID and VARIANT as the target under ROOT."
  (setq root (android--project-root root))
  (android--selection-load root)
  (setf (alist-get root android--selected-modules nil nil #'string=) module-id)
  (let ((selections (copy-tree
                     (cdr (assoc root android--selected-variants)))))
    (setf (alist-get module-id selections nil nil #'equal) variant)
    (setf (alist-get root android--selected-variants nil nil #'string=)
          selections))
  (android--selection-save root))

(defun android--select-target (&optional prompt)
  "Return selected (MODULE . VARIANT) for the current project.
Reuse the current module's selected variant unless PROMPT is non-nil."
  (let* ((root (android--project-root))
         (targets (android-project-targets root))
         (current-module (cdr (assoc root android--selected-modules)))
         (current (and current-module
                       (seq-find
                        (lambda (entry)
                          (equal (android--module-key entry) current-module))
                        targets))))
    (if (and current (not prompt))
        (cons (plist-get current :module-name)
              (plist-get current :variant))
      (let* ((target (android--select-module-target))
             (module (plist-get target :module-name))
             (module-id (android--module-key target))
             (variant (android--select-target-variant target)))
        (android--log "selected module %s" module)
        (android--remember-target root module-id variant)
        (cons module variant)))))

(defun android-current-target (&optional prompt file project-root)
  "Return the current selected Android target metadata.
When PROMPT is non-nil, prompt for a module and variant and remember both.
Otherwise resolve FILE to its module and selected variant, then use the last
selected module, then the sole Android module.  FILE defaults to the variable
`buffer-file-name', and PROJECT-ROOT defaults to `android-root'."
  (let* ((file (or file buffer-file-name))
         (root (android--project-root
                (or project-root
                    (if file
                        (android--root-for-file file)
                      (ignore-errors (android-root)))))))
    (when root
      (if prompt
          (let ((default-directory root))
            (pcase-let ((`(,_module . ,variant) (android--select-target t)))
              (when-let* ((module-id
                           (cdr (assoc root android--selected-modules))))
                (android-project-target module-id variant root))))
        (or (and file (android-target-for-source-file file root))
            (when-let* ((module-id (cdr (assoc root android--selected-modules))))
              (seq-find
               (lambda (entry)
                 (equal (android--module-key entry) module-id))
               (android-project-targets root)))
            (let ((targets (android-project-targets root)))
              (and (= (length targets) 1) (car targets))))))))

(defun android-current-application-id (&optional prompt file project-root)
  "Return the current selected Android target's application ID.
Return nil when there is no unambiguous current target or its project model
does not expose an application ID.  PROMPT, FILE, and PROJECT-ROOT have the
same meaning as in `android-current-target'."
  (when-let* ((target (android-current-target prompt file project-root))
              (application-id (plist-get target :application-id))
              ((not (string-empty-p application-id))))
    application-id))

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
  (let* ((root (android--project-root))
         (variants (android-project-variants)))
    (if variants
        (android--log-variants variants)
      (android-refresh-project-model
       root
       (lambda (data error-data)
         (if error-data
             (android--log "project model refresh failed: %s" error-data)
           (android--log-variants
            (android--mark-selected-variants root (copy-tree data)))))))))

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

(defun android--list-devices ()
  "Return list of (SERIAL . DESCRIPTION) for connected Android devices.
Parses output of `adb devices -l'."
  (let* ((adb (android-tool-path "adb"))
         (output (shell-command-to-string (format "%s devices -l" adb)))
         devices)
    (dolist (line (split-string output "\n" t))
      (when (string-match "^\\([^ \t]+\\)[ \t]+device[ \t]+\\(.*\\)$" line)
        (let* ((serial (match-string 1 line))
               (info (match-string 2 line))
               (model (when (string-match "model:\\([^ ]+\\)" info)
                        (match-string 1 info)))
               (desc (or model serial)))
          (push (cons serial desc) devices))))
    (nreverse devices)))

(defun android--select-device ()
  "Prompt user to select a device when multiple are connected.
Returns the device serial string.  If only one device, return it directly."
  (let ((devices (android--list-devices)))
    (android--log "found %d connected device(s)" (length devices))
    (cond
     ((null devices) (error "No Android devices connected"))
     ((= (length devices) 1) (caar devices))
     (t (let* ((candidates (mapcar (lambda (d)
                                     (cons (format "%s (%s)" (cdr d) (car d))
                                           (car d)))
                                   devices))
               (choice (completing-read "Device: " (mapcar #'car candidates) nil t)))
          (cdr (assoc choice candidates)))))))

(defun android--install-apk (device apk &optional callback)
  "Install APK on DEVICE asynchronously.
When CALLBACK is non-nil, call it with no arguments on success."
  (let* ((adb (android-tool-path "adb"))
         (buf-name (format "*adb install %s*" (file-name-nondirectory apk)))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf (erase-buffer))
    (android--log "installing %s on %s" (file-name-nondirectory apk) device)
    (make-process
     :name "adb-install"
     :buffer buf
     :command (list adb "-s" device "install" "-r" apk)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((output (with-current-buffer (process-buffer proc)
                         (buffer-string))))
           (if (and (zerop (process-exit-status proc))
                    (string-match-p "Success" output))
               (progn
                 (android--log "installed %s on %s" (file-name-nondirectory apk) device)
                 (kill-buffer (process-buffer proc))
                 (when callback (funcall callback)))
             (pop-to-buffer (process-buffer proc))
             (error "Install failed on %s" device))))))))

(defun android--launch-app-on-device (device package &optional callback)
  "Launch PACKAGE on DEVICE asynchronously.
When CALLBACK is non-nil, call it with no arguments on success."
  (let* ((adb (android-tool-path "adb"))
         (buf-name (format "*adb launch %s*" package))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf (erase-buffer))
    (android--log "launching %s on %s" package device)
    (make-process
     :name "adb-launch"
     :buffer buf
     :command (list adb "-s" device "shell"
                    "monkey" "-p" package
                    "-c" "android.intent.category.LAUNCHER" "1")
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((output (with-current-buffer (process-buffer proc)
                         (buffer-string))))
           (if (and (zerop (process-exit-status proc))
                    (not (string-match-p "^Error\\|No activities found" output)))
               (progn
                 (android--log "launched %s on %s" package device)
                 (kill-buffer (process-buffer proc))
                 (when callback (funcall callback)))
             (pop-to-buffer (process-buffer proc))
             (error "Error launching %s on %s" package device))))))))

(defun android--launch-app (module variant)
  "Launch the app for MODULE and VARIANT on the connected device."
  (let ((package (android--flavor-appid module variant)))
    (unless package (error "No applicationId for %s:%s" module variant))
    (let* ((command (format "%s shell monkey -p %s -c android.intent.category.LAUNCHER 1"
                            (android-tool-path "adb") package))
           (output (shell-command-to-string command)))
      (android--log "launching %s" package)
      (when (string-match-p "^Error\\|No activities found" output)
        (error "Error launching app:\n%s" output)))))

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
         (device (android--select-device))
         (cap-variant (android--capitalize variant))
         (assemble-task (format ":%s:assemble%s" module cap-variant))
         (package (android--flavor-appid module variant)))
    (unless package (error "No applicationId for %s:%s" module variant))
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
(autoload 'android-scrcpy-start "android-mode-scrcpy"
  "Start scrcpy with the current transient arguments." t)
(autoload 'android-scrcpy "android-mode-scrcpy"
  "Configure, start, and manage scrcpy." t)
(define-obsolete-function-alias
  'android-start-emulator #'android-avd-start "0.8.0")

(defconst android-mode-keys
  '(("a" . android-start-app)
    ("r" . android-run)
    ("s" . android-scrcpy)
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

(add-hook 'after-save-hook #'android--project-input-saved)

(provide 'android-mode)

;;; android-mode.el ends here
