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
     "ignored\n===FLAVORS_START===\n:app|/tmp/project/app|/tmp/project|demoDebug|com.example|src/main/kotlin;src/demo/kotlin|testDemoDebugUnitTest|debug|demo|true|demo\n===FLAVORS_END===\nignored\n")
    '((:module-id ("/tmp/project" . ":app")
       :build-root "/tmp/project"
       :module-path ":app"
       :module-name "app"
       :module-root "/tmp/project/app"
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
          (android--flavor-cache-root default-directory))
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

(provide 'android-mode-tests)

;;; android-mode-tests.el ends here
