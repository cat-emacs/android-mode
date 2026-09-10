;;; android-mode-scrcpy.el --- Control scrcpy from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: R.W. van 't Veer
;; Keywords: tools processes android
;; Package-Requires: ((emacs "28.1") (transient "0.3.0"))
;; URL: https://github.com/cat-emacs/android-mode

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;;; Commentary:

;; Provides a Transient interface for starting and managing scrcpy
;; processes.  Common scrcpy options are exposed as infix arguments,
;; while `android-scrcpy-extra-arguments' supports less common options.

;;; Code:

(require 'comint)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'android-mode)

(defcustom android-scrcpy-program "scrcpy"
  "Executable used to run scrcpy.
This may be either an executable name found in variable `exec-path' or an
absolute path."
  :type 'string
  :group 'android)

(defcustom android-scrcpy-extra-arguments nil
  "Additional arguments appended to every scrcpy invocation.
Each list item must be one complete command-line argument."
  :type '(repeat string)
  :group 'android)

(defcustom android-scrcpy-display-buffer-on-start nil
  "Whether to display the scrcpy log buffer when starting scrcpy."
  :type 'boolean
  :group 'android)

(defvar android-scrcpy--processes nil
  "Scrcpy processes started by android-mode.")

(define-derived-mode android-scrcpy-output-mode comint-mode "scrcpy"
  "Major mode for scrcpy process output."
  (setq-local comint-process-echoes nil))

(defun android-scrcpy--program ()
  "Return the executable path for `android-scrcpy-program'."
  (or (and (file-name-absolute-p android-scrcpy-program)
           (file-executable-p android-scrcpy-program)
           android-scrcpy-program)
      (executable-find android-scrcpy-program)
      (user-error "Cannot find scrcpy executable: %s"
                  android-scrcpy-program)))

(defun android-scrcpy--device-candidates ()
  "Return completion candidates for connected Android devices."
  (mapcar (lambda (device)
            (cons (format "%s (%s)" (cdr device) (car device))
                  (car device)))
          (android--list-devices)))

(defun android-scrcpy--read-device (prompt initial-input _history)
  "Read a device serial using PROMPT and INITIAL-INPUT."
  (let* ((candidates (android-scrcpy--device-candidates))
         (display-values (mapcar #'car candidates))
         (initial
          (or (car (rassoc initial-input candidates))
              initial-input))
         (choice
          (completing-read prompt display-values nil nil initial)))
    (or (cdr (assoc choice candidates)) choice)))

(defun android-scrcpy--read-record-file (prompt initial-input _history)
  "Read a recording path using PROMPT and INITIAL-INPUT."
  (expand-file-name
   (read-file-name prompt nil initial-input nil initial-input)))

(defun android-scrcpy--argument-value (prefix args)
  "Return the value of the first argument beginning with PREFIX in ARGS."
  (when-let* ((argument
               (seq-find (lambda (arg) (string-prefix-p prefix arg)) args)))
    (string-remove-prefix prefix argument)))

(defun android-scrcpy--target-name (args)
  "Return a short target name inferred from scrcpy ARGS."
  (cond
   ((android-scrcpy--argument-value "--serial=" args))
   ((member "--select-usb" args) "usb")
   ((member "--select-tcpip" args) "tcpip")
   ((android-scrcpy--argument-value "--tcpip=" args)
    (concat "tcpip-"
            (android-scrcpy--argument-value "--tcpip=" args)))
   (t "default")))

(defun android-scrcpy--buffer-name (args)
  "Return a process buffer name for scrcpy ARGS."
  (format "*android-scrcpy:%s*"
          (replace-regexp-in-string
           "[^[:alnum:]._-]" "-"
           (android-scrcpy--target-name args))))

(defun android-scrcpy--command (args)
  "Return the complete scrcpy command for transient ARGS."
  (append (list (android-scrcpy--program))
          android-scrcpy-extra-arguments
          args))

(defun android-scrcpy--connection-arguments (args)
  "Return only device connection arguments from ARGS."
  (seq-filter
   (lambda (arg)
     (or (member arg '("--select-usb" "--select-tcpip"))
         (string-prefix-p "--serial=" arg)
         (string-prefix-p "--tcpip=" arg)))
   args))

(defun android-scrcpy--format-command (command)
  "Return shell-quoted display text for COMMAND."
  (mapconcat #'shell-quote-argument command " "))

(defun android-scrcpy--live-processes ()
  "Return live scrcpy processes and discard stale entries."
  (setq android-scrcpy--processes
        (seq-filter #'process-live-p android-scrcpy--processes)))

(defun android-scrcpy--read-process (&optional prompt)
  "Read a live scrcpy process using optional PROMPT."
  (let ((processes (android-scrcpy--live-processes)))
    (cond
     ((null processes)
      (user-error "No scrcpy process is running"))
     ((= (length processes) 1)
      (car processes))
     (t
      (let* ((candidates
              (mapcar
               (lambda (process)
                 (cons
                  (format "%s [%s]"
                          (process-get process 'android-scrcpy-target)
                          (process-name process))
                  process))
               processes))
             (choice
              (completing-read (or prompt "scrcpy process: ")
                               (mapcar #'car candidates) nil t)))
        (cdr (assoc choice candidates)))))))

(defun android-scrcpy--sentinel (process event)
  "Handle scrcpy PROCESS state change described by EVENT."
  (when (memq (process-status process) '(exit signal))
    (let ((expected-stop
           (process-get process 'android-scrcpy-expected-stop)))
      (setq android-scrcpy--processes
            (delq process android-scrcpy--processes))
      (when (buffer-live-p (process-buffer process))
        (with-current-buffer (process-buffer process)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\nProcess %s" (string-trim event))))))
      (if (or expected-stop (zerop (process-exit-status process)))
        (android--log "scrcpy stopped for %s"
                      (process-get process 'android-scrcpy-target))
        (when (buffer-live-p (process-buffer process))
          (pop-to-buffer (process-buffer process)))
        (android--log "scrcpy failed for %s (exit %d)"
                      (process-get process 'android-scrcpy-target)
                      (process-exit-status process))))))

(defun android-scrcpy--start (args)
  "Start scrcpy asynchronously with ARGS."
  (let* ((command (android-scrcpy--command args))
         (target (android-scrcpy--target-name args))
         (buffer (get-buffer-create (android-scrcpy--buffer-name args))))
    (when-let* ((existing (get-buffer-process buffer))
                ((process-live-p existing)))
      (user-error "Scrcpy is already running for %s" target))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "$ " (android-scrcpy--format-command command) "\n\n"))
      (android-scrcpy-output-mode))
    (let ((process
           (make-process
            :name (format "android-scrcpy-%s" target)
            :buffer buffer
            :command command
            :connection-type 'pipe
            :noquery t
            :sentinel #'android-scrcpy--sentinel)))
      (process-put process 'android-scrcpy-arguments args)
      (process-put process 'android-scrcpy-target target)
      (push process android-scrcpy--processes)
      (when android-scrcpy-display-buffer-on-start
        (display-buffer buffer))
      (android--log "started scrcpy for %s" target)
      process)))

;;;###autoload
(defun android-scrcpy-start (&optional args)
  "Start scrcpy using transient ARGS.
Interactively, use the current values from `android-scrcpy'."
  (interactive (list (transient-args 'android-scrcpy)))
  (android-scrcpy--start (or args nil)))

(defun android-scrcpy-stop (&optional process)
  "Stop a running scrcpy PROCESS."
  (interactive)
  (let ((process (or process (android-scrcpy--read-process))))
    (process-put process 'android-scrcpy-expected-stop t)
    (condition-case nil
        (interrupt-process process)
      (error (delete-process process)))
    (android--log "stopping scrcpy for %s"
                  (process-get process 'android-scrcpy-target))))

(defun android-scrcpy-restart (&optional process)
  "Restart a running scrcpy PROCESS with its original arguments."
  (interactive)
  (let* ((process (or process (android-scrcpy--read-process)))
         (args (process-get process 'android-scrcpy-arguments)))
    (process-put process 'android-scrcpy-expected-stop t)
    (delete-process process)
    (android-scrcpy--start args)))

(defun android-scrcpy-show-output (&optional process)
  "Display the output buffer for scrcpy PROCESS."
  (interactive)
  (pop-to-buffer
   (process-buffer (or process (android-scrcpy--read-process)))))

(defun android-scrcpy-copy-command ()
  "Copy the scrcpy command represented by the current transient values."
  (interactive)
  (let ((command
         (android-scrcpy--format-command
          (android-scrcpy--command (transient-args 'android-scrcpy)))))
    (kill-new command)
    (message "Copied: %s" command)))

(defun android-scrcpy--run-info (title &rest args)
  "Run scrcpy with ARGS and display the output in buffer TITLE."
  (let ((buffer (get-buffer-create title))
        status)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq status
              (apply #'call-process
                     (android-scrcpy--program) nil t nil args)))
      (special-mode))
    (pop-to-buffer buffer)
    (unless (zerop status)
      (user-error "Scrcpy exited with status %s" status))))

(defun android-scrcpy-version ()
  "Display the installed scrcpy version."
  (interactive)
  (android-scrcpy--run-info "*android-scrcpy-version*" "--version"))

(defun android-scrcpy-list-displays ()
  "List displays reported by the selected Android device."
  (interactive)
  (apply #'android-scrcpy--run-info
         "*android-scrcpy-displays*"
         (append
          (android-scrcpy--connection-arguments
           (transient-args 'android-scrcpy))
          '("--list-displays"))))

(defun android-scrcpy-list-encoders ()
  "List encoders reported by the selected Android device."
  (interactive)
  (apply #'android-scrcpy--run-info
         "*android-scrcpy-encoders*"
         (append
          (android-scrcpy--connection-arguments
           (transient-args 'android-scrcpy))
          '("--list-encoders"))))

(defun android-scrcpy-list-cameras ()
  "List cameras reported by the selected Android device."
  (interactive)
  (apply #'android-scrcpy--run-info
         "*android-scrcpy-cameras*"
         (append
          (android-scrcpy--connection-arguments
           (transient-args 'android-scrcpy))
          '("--list-cameras"))))

;;;###autoload
(transient-define-prefix android-scrcpy ()
  "Configure, start, and manage scrcpy."
  [["Connection"
    ("s" "Device serial" "--serial="
     :reader android-scrcpy--read-device)
    ("u" "Select USB device" "--select-usb")
    ("e" "Select TCP/IP device" "--select-tcpip")
    ("t" "Connect over TCP/IP" "--tcpip=")
    ("i" "Display id" "--display-id=")]
   ["Video"
    ("m" "Maximum size" "--max-size=")
    ("f" "Maximum FPS" "--max-fps=")
    ("b" "Video bit rate" "--video-bit-rate=")
    ("v" "Video codec" "--video-codec="
     :choices ("h264" "h265" "av1" "raw"))
    ("c" "Crop" "--crop=")
    ("o" "Capture orientation" "--capture-orientation="
     :choices ("0" "90" "180" "270"
               "flip0" "flip90" "flip180" "flip270"))]
   ["Window"
    ("F" "Fullscreen" "--fullscreen")
    ("a" "Always on top" "--always-on-top")
    ("B" "Borderless" "--window-borderless")
    ("d" "Disable screensaver" "--disable-screensaver")
    ("W" "No window" "--no-window")
    ("l" "Window title" "--window-title=")]]
  [["Control and input"
    ("C" "No control" "--no-control")
    ("S" "Turn screen off" "--turn-screen-off")
    ("k" "Stay awake" "--stay-awake")
    ("K" "Keep active" "--keep-active")
    ("p" "Power off on close" "--power-off-on-close")
    ("h" "Show touches" "--show-touches")
    ("q" "Keyboard mode" "--keyboard="
     :choices ("disabled" "sdk" "uhid" "aoa"))
    ("M" "Mouse mode" "--mouse="
     :choices ("disabled" "sdk" "uhid" "aoa"))]
   ["Audio"
    ("A" "Disable audio" "--no-audio")
    ("j" "Audio source" "--audio-source="
     :choices ("output" "playback" "mic" "mic-unprocessed"
               "mic-camcorder" "mic-voice-recognition"
               "mic-voice-communication" "voice-call"
               "voice-call-uplink" "voice-call-downlink"
               "voice-performance"))
    ("J" "Audio codec" "--audio-codec="
     :choices ("opus" "aac" "flac" "raw"))
    ("g" "Audio bit rate" "--audio-bit-rate=")
    ("y" "Duplicate audio" "--audio-dup")]
   ["Recording"
    ("r" "Record to file" "--record="
     :reader android-scrcpy--read-record-file)
    ("R" "Record format" "--record-format="
     :choices ("mp4" "mkv" "m4a" "mka" "opus" "aac" "flac" "wav"))
    ("N" "No playback" "--no-playback")
    ("V" "No video playback" "--no-video-playback")
    ("O" "No audio playback" "--no-audio-playback")
    ("L" "Time limit" "--time-limit=")]]
  [["Actions"
    ("RET" "Start" android-scrcpy-start)
    ("x" "Stop" android-scrcpy-stop)
    ("X" "Restart" android-scrcpy-restart)
    ("z" "Show output" android-scrcpy-show-output)
    ("w" "Copy command" android-scrcpy-copy-command)]
   ["Inspect"
    ("?" "Version" android-scrcpy-version)
    ("D" "List displays" android-scrcpy-list-displays)
    ("E" "List encoders" android-scrcpy-list-encoders)
    ("I" "List cameras" android-scrcpy-list-cameras)]])

(provide 'android-mode-scrcpy)

;;; android-mode-scrcpy.el ends here
