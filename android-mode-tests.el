;;; android-mode-tests.el --- Tests for android-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for android-mode helpers.

;;; Code:

(require 'ert)
(require 'android-mode)

(defun android-mode-tests--target (module variant &rest properties)
  "Return target metadata for MODULE, VARIANT, and PROPERTIES."
  (let* ((root (format "/tmp/project/%s" module))
         (target
          (list :module-id (cons "/tmp/project" (concat ":" module))
                :build-root "/tmp/project"
                :module-path (concat ":" module)
                :module-name module
                :module-root root
                :plugin-id "com.android.application"
                :variant variant
                :application-id (format "com.example.%s" module)
                :source-roots '("src/main/kotlin")
                :preview-task (format "assemble%s" (capitalize variant))
                :build-type variant
                :product-flavors nil
                :preferred-build-type-p nil
                :preferred-product-flavors nil)))
    (while properties
      (setq target (plist-put target (pop properties) (pop properties))))
    target))

(ert-deftest android-mode-parse-gradle-flavors ()
  "Gradle flavor output is parsed between marker lines."
  (should
   (equal
    (android-parse-gradle-flavors
     "ignored\n===FLAVORS_START===\n:app|/tmp/project/app|/tmp/project|demoDebug|com.example|src/main/kotlin;src/demo/kotlin|testDemoDebugUnitTest|debug|demo|true|demo|com.android.application\n===FLAVORS_END===\nignored\n")
    '((:module-id ("/tmp/project" . ":app")
       :build-root "/tmp/project"
       :module-path ":app"
       :module-name "app"
       :module-root "/tmp/project/app"
       :plugin-id "com.android.application"
       :variant "demoDebug"
       :application-id "com.example"
       :source-roots ("src/main/kotlin" "src/demo/kotlin")
       :preview-task "testDemoDebugUnitTest"
       :build-type "debug"
       :product-flavors ("demo")
       :preferred-build-type-p t
       :preferred-product-flavors ("demo"))))))

(ert-deftest android-mode-flavor-helpers-use-cache ()
  "Flavor helper functions read module, variant and applicationId from cache."
  (cl-letf (((symbol-function 'android-root)
             (lambda () default-directory)))
    (let ((android--flavor-cache '(("app" "debug" "com.example")
                                    ("app" "release" "com.example.release")))
          (android--flavor-cache-root
           (file-name-as-directory (expand-file-name default-directory)))
          (android--flavor-cache-fingerprint nil))
      (should (equal (android--flavor-modules) '("app")))
      (should (equal (android--flavor-variants "app") '("debug" "release")))
      (should (equal (android--flavor-appid "app" "release")
                     "com.example.release")))))

(ert-deftest android-mode-public-target-api-mirrors-selected-variants ()
  "Public targets expose one selected variant per Android module."
  (let* ((root "/tmp/project/")
         (app-debug (android-mode-tests--target "app" "debug"))
         (app-release (android-mode-tests--target "app" "release"))
         (feature (android-mode-tests--target "feature" "release"))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--selection-loaded-roots nil)
         (android--selected-modules nil)
         (android--selected-variants nil))
    (cl-letf (((symbol-function 'android--get-flavors)
               (lambda (&optional _refresh)
                 (list app-release app-debug feature))))
      (let ((targets (android-project-targets root)))
        (should (= (length targets) 2))
        (should (equal (mapcar (lambda (entry)
                                (cons (plist-get entry :module-name)
                                      (plist-get entry :variant)))
                              targets)
                       '(("app" . "debug") ("feature" . "release"))))
        (should (seq-every-p (lambda (entry)
                               (plist-get entry :selected-p))
                             targets)))
      (android--remember-target root (plist-get app-debug :module-id) "release")
      (should (equal (plist-get
                      (android-target-for-source-file
                       "/tmp/project/app/src/main/kotlin/Foo.kt" root)
                      :variant)
                     "release"))
      (should-not (plist-get (android-project-target "app" "debug" root)
                             :selected-p))
      (should (plist-get (android-project-target "app" nil root)
                         :selected-p)))))

(ert-deftest android-mode-current-target-follows-file-module ()
  "Current target resolves a file's module before its selected variant."
  (let* ((root "/tmp/project/")
         (app (android-mode-tests--target "app" "debug"
                                         :application-id "com.example.app"))
         (feature (android-mode-tests--target
                   "feature" "release" :application-id "com.example.feature"))
         (android--selected-modules
          (list (cons root (plist-get app :module-id))))
         (android--selected-variants nil))
    (cl-letf (((symbol-function 'android--get-flavors)
               (lambda (&optional _refresh) (list app feature))))
      (should (equal
               (plist-get
                (android-current-target
                 nil "/tmp/project/feature/src/main/kotlin/Foo.kt" root)
                :module-name)
               "feature"))
      (should (equal
               (android-current-application-id
                nil "/tmp/project/feature/src/main/kotlin/Foo.kt" root)
               "com.example.feature")))))

(ert-deftest android-mode-current-application-id-requires-current-module ()
  "Application ID resolution does not guess across multiple modules."
  (let ((android--selected-modules nil)
        (android--selected-variants nil))
    (cl-letf (((symbol-function 'android--get-flavors)
               (lambda (&optional _refresh)
                 (list (android-mode-tests--target "app" "debug"
                                                   :application-id "com.example")
                       (android-mode-tests--target "feature" "debug"
                                                   :application-id "com.example")))))
      (should-not (android-current-application-id nil nil "/tmp/project/")))))

(ert-deftest android-mode-project-targets-forwards-refresh ()
  "Public project metadata forwards its root and refresh request."
  (let (seen-root seen-refresh)
    (cl-letf (((symbol-function 'android--get-flavors)
               (lambda (&optional refresh)
                 (setq seen-root default-directory seen-refresh refresh)
                 (list (android-mode-tests--target "app" "debug")))))
      (should (android-project-targets "/tmp/project" t))
      (should (equal seen-root "/tmp/project/"))
      (should seen-refresh))))

(ert-deftest android-mode-default-variant-matches-studio-ordering ()
  "Default variants follow Studio preferences and common flavor dimensions."
  (let ((release (android-mode-tests--target "app" "release"))
        (debug (android-mode-tests--target "app" "debug"))
        (demo (android-mode-tests--target
               "app" "demoRelease" :build-type "release"
               :product-flavors '("demo")
               :preferred-product-flavors '("demo")))
        (production-debug (android-mode-tests--target
                           "app" "productionDebug" :build-type "debug"
                           :product-flavors '("production")
                           :preferred-product-flavors '("demo")))
        (longer (android-mode-tests--target
                 "app" "demoZetaRelease" :build-type "release"
                 :product-flavors '("demo" "zeta")))
        (shorter (android-mode-tests--target
                  "app" "demoRelease" :build-type "release"
                  :product-flavors '("demo"))))
    (should (eq (android--default-module-target (list release debug)) debug))
    ;; With no dimension shared by every candidate, Studio skips flavors.
    (should (eq (android--default-module-target (list debug demo)) debug))
    (should (eq (android--default-module-target
                 (list production-debug demo))
                demo))
    ;; Studio compares only the number of flavor dimensions shared by all
    ;; candidates, so these tie and retain the first model entry.
    (should (eq (android--default-module-target (list longer shorter))
                longer))))

(ert-deftest android-mode-project-target-rejects-ambiguous-module-path ()
  "String module paths do not cross composite-build identities."
  (let* ((first (android-mode-tests--target "app" "debug"))
         (second (copy-tree first))
         (android--selected-modules nil)
         (android--selected-variants nil))
    (plist-put second :module-id '("/tmp/included" . ":app"))
    (plist-put second :build-root "/tmp/included")
    (cl-letf (((symbol-function 'android--get-flavors)
               (lambda (&optional _refresh) (list first second))))
      (should-not (android-project-target ":app" nil "/tmp/project/"))
      (should (equal
               (plist-get
                (android-project-target
                 '("/tmp/included" . ":app") nil "/tmp/project/")
                :build-root)
               "/tmp/included")))))

(ert-deftest android-mode-public-target-api-ignores-non-project-files ()
  "Public target APIs return nil outside an Android project."
  (let ((android--selected-modules nil)
        (android--selected-variants nil))
    (cl-letf (((symbol-function 'android-root)
               (lambda () (error "No Android project"))))
      (should-not (android-project-targets))
      (should-not (android-target-for-source-file "/missing/Foo.kt"))
      (should-not (android-current-target nil "/missing/Foo.kt"))
      (should-not (android-current-application-id nil "/missing/Foo.kt")))))

(ert-deftest android-mode-flavor-cache-rejects-old-schema ()
  "Flavor cache entries without the current schema are ignored."
  (let* ((root "/tmp/project/")
         (android-mode-cache-dir (make-temp-file "android-mode-cache" t))
         (file (android--flavor-cache-file root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 (list :root root :time (current-time) :data '(("app" "debug" "com.example")))
             (current-buffer)))
    (should-not (android--flavor-cache-load root))))

(ert-deftest android-mode-flavor-cache-rejects-stale-preview-task-schema ()
  "Flavor caches created before JVM preview discovery are ignored."
  (let* ((root "/tmp/project/")
         (android-mode-cache-dir (make-temp-file "android-mode-cache" t))
         (file (android--flavor-cache-file root))
         (entry (list :module-path ":composeApp"
                      :module-root "/tmp/project/composeApp"
                      :variant "androidMain"
                      :source-roots '("src/commonMain/kotlin")
                      :preview-task "assembleAndroidMain")))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 (list :version 2 :root root :time (current-time) :data (list entry))
             (current-buffer)))
    (should-not (android--flavor-cache-load root))))

(ert-deftest android-mode-target-for-source-file-prefers-kmp-source-set ()
  "Target lookup maps KMP source-set files to their owning Gradle module."
  (let* ((project-root "/tmp/project/")
         (entry (list :module-path ":composeApp"
                      :module-name "composeApp"
                      :module-root "/tmp/project/composeApp"
                      :variant "debug"
                      :application-id "com.example"
                      :source-roots '("src/commonMain/kotlin"
                                      "src/androidMain/kotlin"))))
    (should
     (equal
      (android--target-for-source-file
       "/tmp/project/composeApp/src/commonMain/kotlin/example/Foo.kt"
       project-root
       (list entry))
      entry))))

(ert-deftest android-mode-flavor-script-uses-plugin-models-for-kmp ()
  "Flavor script should use AGP/KGP models instead of hard-coded KMP paths."
  (with-temp-buffer
    (insert-file-contents android-mode-flavor-script)
    (let ((script (buffer-string)))
      (should (string-match-p "androidComponents" script))
      (should (string-match-p "extensions.findByName(\"kotlin\")" script))
      (should (string-match-p "compilations" script))
      (should (string-match-p "platformType == \"jvm\"" script))
      (should (string-match-p "desktopTest" script))
      (should-not (string-match-p "src/commonMain/kotlin" script))
      (should-not (string-match-p "src/androidMain/kotlin" script)))))

(ert-deftest android-mode-gradle-install-reuses-current-project-selection ()
  "Install reuses a previous module and variant selection for the project."
  (let ((android--selected-modules nil)
        (android--selected-variants nil)
        (answers '("app" "debug"))
        (variants (list (android-mode-tests--target "app" "debug")
                        (android-mode-tests--target "app" "release")
                        (android-mode-tests--target "demo" "staging")))
        gradle-tasks)
    (cl-letf (((symbol-function 'android-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android--get-flavors)
               (lambda (&optional _refresh) variants))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 (pop answers)))
              ((symbol-function 'android-gradle)
               (lambda (task)
                 (push task gradle-tasks))))
      (android-gradle-install)
      (android-gradle-install)
      (should (equal (nreverse gradle-tasks)
                     '(":app:installDebug" ":app:installDebug")))
      (should-not answers))))

(ert-deftest android-mode-gradle-install-prefix-prompts-again ()
  "A prefix argument forces module and variant prompting again."
  (let ((android--selected-modules nil)
        (android--selected-variants nil)
        (answers '("app" "debug" "demo" "staging"))
        (variants (list (android-mode-tests--target "app" "debug")
                        (android-mode-tests--target "app" "release")
                        (android-mode-tests--target "demo" "staging")
                        (android-mode-tests--target "demo" "qa")))
        gradle-tasks)
    (cl-letf (((symbol-function 'android-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android--get-flavors)
               (lambda (&optional _refresh) variants))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 (pop answers)))
              ((symbol-function 'android-gradle)
               (lambda (task)
                 (push task gradle-tasks))))
      (android-gradle-install)
      (android-gradle-install t)
      (android-gradle-install)
      (should (equal (nreverse gradle-tasks)
                     '(":app:installDebug"
                       ":demo:installStaging"
                       ":demo:installStaging")))
      (should-not answers))))

(ert-deftest android-mode-hot-model-read-does-not-stat-project-inputs ()
  "A normal read of a fresh in-memory model performs no filesystem scan."
  (let* ((root "/tmp/project/")
         (entry (android-mode-tests--target "app" "debug"))
         (android--flavor-cache (list entry))
         (android--flavor-cache-root root)
         (android--flavor-cache-stale-p nil))
    (let ((default-directory root))
      (cl-letf (((symbol-function 'android-root) (lambda () root))
                ((symbol-function 'android--project-model-fingerprint)
                 (lambda (&rest _args)
                   (ert-fail "hot read fingerprinted project inputs")))
                ((symbol-function 'android--selection-load) #'ignore))
        (should (equal (android--get-flavors) (list entry)))))))

(ert-deftest android-mode-stale-disk-model-remains-available ()
  "A stale schema-valid disk model is returned while refresh starts."
  (let* ((root (file-name-as-directory (make-temp-file "android-project" t)))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--flavor-cache nil)
         (android--flavor-cache-root nil)
         (android--flavor-cache-fingerprint nil)
         (android--flavor-cache-stale-p t)
         (entry (android-mode-tests--target "app" "debug"))
         (settings (expand-file-name "settings.gradle.kts" root))
         refreshed)
    (plist-put entry :build-root (directory-file-name root))
    (plist-put entry :module-root (expand-file-name "app" root))
    (make-directory (plist-get entry :module-root) t)
    (with-temp-file settings (insert "include(\":app\")\n"))
    (android--flavor-cache-save root (list entry))
    (setq android--flavor-cache nil
          android--flavor-cache-root nil
          android--flavor-cache-fingerprint nil
          android--flavor-cache-stale-p t)
    (with-temp-file settings (insert "include(\":app\", \":feature\")\n"))
    (let ((default-directory root))
      (cl-letf (((symbol-function 'android-root) (lambda () root))
                ((symbol-function 'android-refresh-project-model)
                 (lambda (&optional _root _callback)
                   (setq refreshed t))))
        (should (equal (android--get-flavors) (list entry)))
        (should refreshed)
        (should android--flavor-cache-stale-p)))))

(ert-deftest android-mode-cache-read-disables-read-time-evaluation ()
  "Persisted state cannot execute read-time Lisp forms."
  (let* ((root "/tmp/project/")
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android-mode-tests--read-evaluated nil)
         (selection (android--selection-file root)))
    (make-directory (file-name-directory selection) t)
    (with-temp-file selection
      (insert "#.(setq android-mode-tests--read-evaluated t)"))
    (let ((android--selection-loaded-roots nil))
      (android--selection-load root))
    (should-not android-mode-tests--read-evaluated)))

(ert-deftest android-mode-selection-reports-loading-model ()
  "Interactive target selection does not open an empty completion UI."
  (cl-letf (((symbol-function 'android-project-targets) #'ignore))
    (should-error (android--select-module-target)
                  :type 'user-error)))

(ert-deftest android-mode-project-model-fingerprint-detects-input-changes ()
  "Project model fingerprints cover settings, module builds, and catalogs."
  (let* ((root (file-name-as-directory (make-temp-file "android-project" t)))
         (module-root (expand-file-name "app" root))
         (catalog (expand-file-name "gradle/libs.versions.toml" root))
         (entry (android-mode-tests--target "app" "debug")))
    (make-directory module-root t)
    (make-directory (file-name-directory catalog) t)
    (plist-put entry :build-root (directory-file-name root))
    (plist-put entry :module-root module-root)
    (with-temp-file (expand-file-name "settings.gradle.kts" root)
      (insert "include(\":app\")\n"))
    (with-temp-file (expand-file-name "build.gradle.kts" module-root)
      (insert "plugins {}\n"))
    (with-temp-file catalog (insert "[versions]\nagp = \"9.3.0\"\n"))
    (let ((before (android--project-model-fingerprint root (list entry))))
      (with-temp-file catalog (insert "[versions]\nagp = \"9.3.1\"\n"))
      (should-not
       (equal before
              (android--project-model-fingerprint root (list entry)))))))

(ert-deftest android-mode-flavor-cache-rejects-changed-project-inputs ()
  "A disk model is invalidated when a tracked Gradle input changes."
  (let* ((root (file-name-as-directory (make-temp-file "android-project" t)))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--flavor-cache-fingerprint nil)
         (entry (android-mode-tests--target "app" "debug"))
         (settings (expand-file-name "settings.gradle.kts" root)))
    (plist-put entry :build-root (directory-file-name root))
    (plist-put entry :module-root (expand-file-name "app" root))
    (make-directory (plist-get entry :module-root) t)
    (with-temp-file settings (insert "include(\":app\")\n"))
    (android--flavor-cache-save root (list entry))
    (should (plist-get (android--flavor-cache-load root) :fresh-p))
    (with-temp-file settings (insert "include(\":app\", \":feature\")\n"))
    (let ((cache (android--flavor-cache-load root)))
      (should cache)
      (should-not (plist-get cache :fresh-p)))))

(ert-deftest android-mode-target-selection-persists-by-module-id ()
  "Selected modules and variants survive a fresh in-memory session."
  (let* ((root "/tmp/project/")
         (module-id '("/tmp/project" . ":app"))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--selected-modules nil)
         (android--selected-variants nil)
         (android--selection-loaded-roots nil))
    (android--remember-target root module-id "release")
    (setq android--selected-modules nil
          android--selected-variants nil
          android--selection-loaded-roots nil)
    (android--selection-load root)
    (should (equal (cdr (assoc root android--selected-modules)) module-id))
    (should (equal (cdr (assoc module-id
                               (cdr (assoc root android--selected-variants))))
                   "release"))))

(ert-deftest android-mode-project-application-ids-use-all-runnable-variants ()
  "Project application IDs include every runnable variant exactly once."
  (let ((targets (list (android-mode-tests--target "app" "debug")
                       (android-mode-tests--target "demo" "debug")
                       (android-mode-tests--target
                        "feature" "debug"
                        :plugin-id "com.android.dynamic-feature")
                       (android-mode-tests--target
                        "library" "debug"
                        :plugin-id "com.android.library"))))
    (cl-letf (((symbol-function 'android-project-variants)
               (lambda (&optional _root _refresh) targets)))
      (should (equal (android-project-application-ids "/tmp/project/")
                     '("com.example.app" "com.example.demo"
                       "com.example.feature"))))))

(ert-deftest android-mode-project-refresh-is-asynchronous-and-shared ()
  "Concurrent model refresh requests share a process and notify all callers."
  (let* ((root (file-name-as-directory (make-temp-file "android-project" t)))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--project-refresh-processes (make-hash-table :test #'equal))
         (android--project-refresh-callbacks (make-hash-table :test #'equal))
         (android--flavor-cache nil)
         (android--flavor-cache-root nil)
         callbacks)
    (cl-letf (((symbol-function 'android--gradle-model-command)
               (lambda (_root)
                 (list shell-file-name shell-command-switch
                       "printf '===FLAVORS_START===\\n:app|/tmp/app|/tmp|debug|com.example|src/main/kotlin|assembleDebug|debug||false||com.android.application\\n===FLAVORS_END===\\n'"))))
      (let ((first (android-refresh-project-model
                    root (lambda (data error-data)
                           (push (list data error-data) callbacks))))
            second)
        (setq second
              (android-refresh-project-model
               root (lambda (data error-data)
                      (push (list data error-data) callbacks))))
        (should (eq first second))
        (while (and (< (length callbacks) 2)
                    (or (process-live-p first)
                        (gethash root android--project-refresh-processes)))
          (accept-process-output nil 0.1))
        (should (= (length callbacks) 2))
        (should (seq-every-p (lambda (result)
                               (and (car result) (null (cadr result))))
                             callbacks))
        (should-not (gethash root android--project-refresh-processes))))))

(ert-deftest android-mode-project-refresh-restarts-after-input-change ()
  "A refresh whose inputs change is discarded and restarted."
  (let* ((root (file-name-as-directory (make-temp-file "android-project" t)))
         (settings (expand-file-name "settings.gradle.kts" root))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--project-refresh-processes (make-hash-table :test #'equal))
         (android--project-refresh-callbacks (make-hash-table :test #'equal))
         launches done result failure)
    (with-temp-file settings (insert "include(\":app\")\n"))
    (cl-letf (((symbol-function 'android--gradle-model-command)
               (lambda (_root)
                 (setq launches (1+ (or launches 0)))
                 (list shell-file-name shell-command-switch
                       "sleep 0.1; printf '===FLAVORS_START===\\n:app|/tmp/app|/tmp|debug|com.example|src/main/kotlin|assembleDebug|debug||false||com.android.application\\n===FLAVORS_END===\\n'"))))
      (android-refresh-project-model
       root (lambda (data error-data)
              (setq result data failure error-data done t)))
      (with-temp-file settings (insert "include(\":app\", \":feature\")\n"))
      (while (and (not done) (< launches 3))
        (accept-process-output nil 0.2))
      (should done)
      (should (= launches 2))
      (should result)
      (should-not failure))))

(ert-deftest android-mode-project-refresh-rechecks-after-parsing ()
  "Inputs changed during parsing prevent stale model publication."
  (let* ((root (file-name-as-directory (make-temp-file "android-project" t)))
         (settings (expand-file-name "settings.gradle.kts" root))
         (android-mode-cache-dir (make-temp-file "android-cache" t))
         (android--project-refresh-processes (make-hash-table :test #'equal))
         (android--project-refresh-callbacks (make-hash-table :test #'equal))
         (android--project-refresh-invalidated (make-hash-table :test #'equal))
         (real-parser (symbol-function 'android-parse-gradle-flavors))
         parsed launches done result)
    (with-temp-file settings (insert "include(\":app\")\n"))
    (cl-letf (((symbol-function 'android--gradle-model-command)
               (lambda (_root)
                 (setq launches (1+ (or launches 0)))
                 (list shell-file-name shell-command-switch
                       "printf '===FLAVORS_START===\\n:app|/tmp/app|/tmp|debug|com.example|src/main/kotlin|assembleDebug|debug||false||com.android.application\\n===FLAVORS_END===\\n'")))
              ((symbol-function 'android-parse-gradle-flavors)
               (lambda (output)
                 (unless parsed
                   (setq parsed t)
                   (with-temp-file settings
                     (insert "include(\":app\", \":feature\")\n")))
                 (funcall real-parser output))))
      (android-refresh-project-model
       root (lambda (data _error-data) (setq result data done t)))
      (while (and (not done) (< launches 3))
        (accept-process-output nil 0.2))
      (should done)
      (should (= launches 2))
      (should result))))

(provide 'android-mode-tests)

;;; android-mode-tests.el ends here
