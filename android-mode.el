;;; android-mode.el --- Minor mode for Android application development -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2018 R.W van 't Veer
;; Copyright (C) 2025 Gemini (Code optimizations and warning fixes)

;; Author: R.W. van 't Veer
;; Created: 20 Feb 2009
;; Keywords: tools processes
;; Version: 0.7.0
;; Package-Requires: ((emacs "28.1"))
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

(defcustom android-mode-sdk-tool-subdirs '("emulator" "tools" "platform-tools")
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

(defvar android-mode-gradle-log-buffer-name "*android-gradle-log*"
  "Buffer name used for synchronous android-mode Gradle output.")

(defun android--log (format-string &rest args)
  "Log android-mode message FORMAT-STRING with ARGS."
  (apply #'message (concat "android-mode: " format-string) args))

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
  (or (cl-loop for subdir in android-mode-sdk-tool-subdirs
               thereis (cl-loop for ext in android-mode-sdk-tool-extensions
                                for path = (expand-file-name (concat name ext)
                                                             (expand-file-name subdir (android-local-sdk-dir)))
                                when (file-exists-p path)
                                return path))
      (error "Can't find SDK tool: %s in SDK path %s" name (android-local-sdk-dir))))

(defvar android-exclusive-processes ()
  "A list of symbols representing running exclusive processes.")

(defun android-start-exclusive-command (name command &rest args)
  "Run COMMAND named NAME with ARGS unless it's already running."
  (let ((proc-name (intern name)))
    (when (not (cl-member proc-name android-exclusive-processes))
      (let* ((full-command (format "%s %s" command (mapconcat #'shell-quote-argument args " ")))
             (process (start-process-shell-command name name full-command)))
        (set-process-sentinel process
                              (lambda (proc _msg)
                                (when (memq (process-status proc) '(exit signal))
                                  (setq android-exclusive-processes
                                        (cl-remove (intern (process-name proc))
                                                   android-exclusive-processes)))))
        (push proc-name android-exclusive-processes)
        process))))

(defun android-list-avd ()
  "List of Android Virtual Devices installed on local machine.
Uses the modern `emulator -list-avds` command."
  (let* ((command (format "%s -list-avds" (android-tool-path "emulator")))
         (output (shell-command-to-string command))
         (result (split-string output "\n" t)))
    (if result
        (nreverse result)
      (error "No Android Virtual Devices found"))))

(defun android-start-emulator ()
  "Launch Android emulator."
  (interactive)
  (let ((avd (or (and (not (string-blank-p android-mode-avd)) android-mode-avd)
                 (completing-read "Android Virtual Device: " (android-list-avd)))))
    (android--log "starting emulator %s" avd)
    (unless (android-start-exclusive-command (format "*android-emulator-%s*" avd)
                                             (android-tool-path "emulator")
                                             "-avd"
                                             avd)
      (android--log "emulator for %s is already running or being started" avd))))

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
  (when-let ((dir (file-name-as-directory (expand-file-name dir))))
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
  (when-let ((apk (android--apk-path)))
    (let ((output (android--aapt2-dump apk)))
      (when (string-match "^package: name='\\([^']+\\)'" output)
        (match-string 1 output)))))

(defun android-project-main-activities (&optional _category)
  "Return list of main activity class names.
Parses the built APK via aapt2."
  (when-let ((apk (android--apk-path)))
    (let ((output (android--aapt2-dump apk))
          activities)
      (with-temp-buffer
        (insert output)
        (goto-char (point-min))
        (while (re-search-forward "^launchable-activity: name='\\([^']+\\)'" nil t)
          (push (match-string 1) activities)))
      (nreverse activities))))

(defun android-start-app ()
  "Start an application on the connected device.
Interactively select module and variant, then launch via adb.
Uses aapt2 to find the launchable activity from the built APK."
  (interactive)
  (let* ((module (android--select-module))
         (variant (android--select-variant module))
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

(defconst android--flavor-cache-version 2
  "Flavor cache schema version.")

(defvar android--flavor-cache nil
  "Cached flavor data as plist entries.
Each entry contains :module-path, :module-name, :module-root, :variant,
:application-id, :source-roots, and :preview-task.
Per-project, keyed by project root.")

(defvar android--flavor-cache-root nil
  "Project root for which `android--flavor-cache' is valid.")

(defun android--flavor-cache-file (root)
  "Return the disk cache file path for project ROOT."
  (let ((key (md5 (directory-file-name (expand-file-name root)))))
    (expand-file-name (concat key ".eld") android-mode-cache-dir)))

(defun android--flavor-cache-save (root data)
  "Persist flavor DATA for project ROOT to disk."
  (let ((file (android--flavor-cache-file root)))
    (android--log "saving flavor cache for %s to %s" root file)
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 (list :version android--flavor-cache-version
                   :root root
                   :time (current-time)
                   :data data)
             (current-buffer)))))

(defun android--flavor-cache-valid-p (data)
  "Return non-nil when DATA matches the current flavor cache schema."
  (and (listp data)
       (seq-every-p
        (lambda (entry)
          (and (keywordp (car-safe entry))
               (plist-get entry :module-path)
               (plist-get entry :module-root)
               (plist-get entry :variant)
               (plist-member entry :source-roots)
               (plist-member entry :preview-task)))
        data)))

(defun android--flavor-cache-load (root)
  "Load cached flavor data for project ROOT from disk.
Returns the data list, or nil if no valid cache exists."
  (let ((file (android--flavor-cache-file root)))
    (when (file-exists-p file)
      (android--log "loading flavor cache for %s from %s" root file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (let ((plist (read (current-buffer))))
            (when (and (= (or (plist-get plist :version) 0)
                          android--flavor-cache-version)
                       (string= (plist-get plist :root) root)
                       (android--flavor-cache-valid-p
                        (plist-get plist :data)))
              (plist-get plist :data))))))))

(defun android--run-gradle-for-output (root command)
  "Run Gradle COMMAND in ROOT, write logs, and return its output."
  (android-in-directory
   root
   (let ((buffer (get-buffer-create android-mode-gradle-log-buffer-name)))
     (android--log "running Gradle in %s: %s" root command)
     (with-current-buffer buffer
       (let ((inhibit-read-only t))
         (erase-buffer)
         (insert (format "$ %s\n\n" command)))
       (setq-local default-directory root)
       (let ((exit-code (call-process-shell-command command nil buffer t)))
         (android--log "Gradle command exited with code %s" exit-code)
         (buffer-string))))))

(defun android--get-flavors (&optional refresh)
  "Return flavor data as list of (MODULE VARIANT APPID).
Caches in memory and on disk under `android-mode-cache-dir'.
With REFRESH non-nil, re-fetch from gradle."
  (let ((root (android-root)))
    (android--log "resolving flavors for %s%s"
                  root
                  (if refresh " with refresh" ""))
    (when (or refresh
              (not android--flavor-cache)
              (not (string= root android--flavor-cache-root)))
      ;; try disk cache first
      (let ((disk (unless refresh (android--flavor-cache-load root))))
        (if disk
            (setq android--flavor-cache disk
                  android--flavor-cache-root root)
          ;; fetch from gradle
          (android-in-directory
           root
           (let* ((script android-mode-flavor-script)
                  (command (format "./gradlew --no-configuration-cache -I %s help --quiet"
                                   (shell-quote-argument script)))
                  (output (android--run-gradle-for-output root command))
                  (data (android-parse-gradle-flavors output)))
             (android--log "parsed %d flavor entries" (length data))
             (setq android--flavor-cache data
                   android--flavor-cache-root root)
             (android--flavor-cache-save root data))))))
    android--flavor-cache))

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
        (pcase-let ((`(,module-path ,module-root ,variant ,appid ,source-roots ,preview-task)
                     (split-string line "|" nil)))
          (when (and module-path module-root variant)
            (push (list :module-path module-path
                        :module-name (string-remove-prefix ":" module-path)
                        :module-root module-root
                        :variant variant
                        :application-id (or appid "")
                        :source-roots (split-string (or source-roots "") ";" t)
                        :preview-task (or preview-task ""))
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

;; --- Interactive selection ---

(defun android--select-module ()
  "Prompt user to select a module and return the module name string."
  (let ((modules (android--flavor-modules)))
    (let ((module (if (= (length modules) 1)
                      (car modules)
                    (completing-read "Module: " modules nil t))))
      (android--log "selected module %s" module)
      module)))

(defun android--select-variant (module)
  "Prompt user to select a variant for MODULE and return its name."
  (let ((variants (android--flavor-variants module)))
    (let ((variant (if (= (length variants) 1)
                       (car variants)
                     (completing-read (format "Variant (%s): " module) variants nil t))))
      (android--log "selected variant %s for module %s" variant module)
      variant)))

(defun android--capitalize (s)
  "Capitalize first letter of S."
  (if (string-empty-p s) s
    (concat (upcase (substring s 0 1)) (substring s 1))))

;; --- Commands ---

(defun android-print-flavor ()
  "Print the project's flavors, variants and application IDs."
  (interactive)
  (android--log "printing flavor data")
  (let ((flavors (android--get-flavors t)))
    (if flavors
        (dolist (f flavors)
          (android--log "module=%s variant=%s appId=%s"
                        (nth 0 f) (nth 1 f) (nth 2 f)))
      (android--log "no application flavors found"))))

(defun android-refresh-flavors ()
  "Force refresh the cached flavor data."
  (interactive)
  (android--log "refreshing flavor cache")
  (android--get-flavors t)
  (android--log "refreshed %d flavors" (length android--flavor-cache)))

(defun android-gradle (tasks-or-goals)
  "Run gradle TASKS-OR-GOALS in the project root directory."
  (interactive "sTasks or Goals: ")
  (android-in-directory
   (android-root)
   (android--log "running Gradle in %s: ./gradlew %s" default-directory tasks-or-goals)
   (compile (format "./gradlew %s" tasks-or-goals))))

(defun android-gradle-build ()
  "Interactively select module and variant, then run assemble task."
  (interactive)
  (let* ((module (android--select-module))
         (variant (android--select-variant module))
         (task (format ":%s:assemble%s" module (android--capitalize variant))))
    (android--log "build task %s" task)
    (android-gradle task)))

(defun android-gradle-install ()
  "Interactively select module and variant, then run install task."
  (interactive)
  (let* ((module (android--select-module))
         (variant (android--select-variant module))
         (task (format ":%s:install%s" module (android--capitalize variant))))
    (android--log "install task %s" task)
    (android-gradle task)))

(defun android-gradle-uninstall ()
  "Interactively select module and variant, then run uninstall task."
  (interactive)
  (let* ((module (android--select-module))
         (variant (android--select-variant module))
         (task (format ":%s:uninstall%s" module (android--capitalize variant))))
    (android--log "uninstall task %s" task)
    (android-gradle task)))

(defun android-gradle-test ()
  "Interactively select module and variant, then run test task."
  (interactive)
  (let* ((module (android--select-module))
         (variant (android--select-variant module))
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

(defun android-run ()
  "Build, install and launch the app.
Interactively select module, variant and target device, then chain:
  gradle assemble → adb install → adb start.
All adb steps run asynchronously without blocking Emacs.
When only one device is connected, it is used automatically."
  (interactive)
  (let* ((module (android--select-module))
         (variant (android--select-variant module))
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

(defconst android-mode-keys
  '(("a" . android-start-app)
    ("r" . android-run)
    ("e" . android-start-emulator)
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

(when-let ((subdir (ignore-errors (android--latest-build-tools-subdir))))
  (cl-pushnew subdir android-mode-sdk-tool-subdirs :test #'string=))

(provide 'android-mode)

;;; android-mode.el ends here
