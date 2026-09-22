;;; android-mode-tests.el --- Tests for android-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for android-mode helpers.

;;; Code:

(require 'ert)
(require 'android-mode)
(ert-deftest android-mode-parse-gradle-flavors ()
  "Gradle flavor output is parsed between marker lines."
  (should
   (equal
    (android-parse-gradle-flavors
     "ignored\n===FLAVORS_START===\n:app|/tmp/project/app|debug|com.example|src/main/kotlin;src/debug/kotlin|testDebugUnitTest\n:feature|/tmp/project/feature|release|com.example.feature|src/main/kotlin|assembleRelease\n===FLAVORS_END===\nignored\n")
    '((:module-path ":app"
       :module-name "app"
       :module-root "/tmp/project/app"
       :variant "debug"
       :application-id "com.example"
       :source-roots ("src/main/kotlin" "src/debug/kotlin")
       :preview-task "testDebugUnitTest")
      (:module-path ":feature"
       :module-name "feature"
       :module-root "/tmp/project/feature"
       :variant "release"
       :application-id "com.example.feature"
       :source-roots ("src/main/kotlin")
       :preview-task "assembleRelease")))))

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

(ert-deftest android-mode-public-target-api-resolves-source-and-selection ()
  "Public target APIs expose source and remembered project metadata."
  (let* ((root "/tmp/project/")
         (app (list :module-path ":app" :module-name "app"
                    :module-root "/tmp/project/app" :variant "debug"
                    :application-id "com.example" :source-roots '("src/main")))
         (feature (list :module-path ":feature" :module-name "feature"
                        :module-root "/tmp/project/feature" :variant "release"
                        :application-id "com.feature" :source-roots '("src/main")))
         (android--selected-targets nil))
    (cl-letf (((symbol-function 'android-project-targets)
               (lambda (&optional _root _refresh) (list app feature))))
      (should (equal (android-target-for-source-file
                      "/tmp/project/feature/src/main/Foo.kt" root)
                     feature))
      (setf (alist-get root android--selected-targets nil nil #'string=)
            '("app" . "debug"))
      (should (equal (android-current-target nil nil root) app))
      (should (equal (android-current-application-id nil nil root)
                     "com.example")))))

(ert-deftest android-mode-current-application-id-handles-ambiguity ()
  "Application ID resolution accepts one ID and rejects ambiguous IDs."
  (let ((android--selected-targets nil))
    (cl-letf (((symbol-function 'android-root) (lambda () "/tmp/project/"))
              ((symbol-function 'android-project-targets)
               (lambda (&optional _root _refresh)
                 (list (list :module-name "app" :variant "debug"
                             :application-id "com.example")
                       (list :module-name "app" :variant "release"
                             :application-id "com.example")))))
      (should (equal (android-current-application-id) "com.example")))
    (cl-letf (((symbol-function 'android-root) (lambda () "/tmp/project/"))
              ((symbol-function 'android-project-targets)
               (lambda (&optional _root _refresh)
                 (list (list :module-name "app" :variant "debug"
                             :application-id "com.debug")
                       (list :module-name "app" :variant "release"
                             :application-id "com.release")))))
      (should-not (android-current-application-id)))))

(ert-deftest android-mode-project-targets-forwards-refresh ()
  "Public project metadata forwards its root and refresh request."
  (let (seen-root seen-refresh)
    (cl-letf (((symbol-function 'android--get-flavors)
               (lambda (&optional refresh)
                 (setq seen-root default-directory seen-refresh refresh)
                 (list (list :module-name "app" :variant "debug")))))
      (should (android-project-targets "/tmp/project" t))
      (should (equal seen-root "/tmp/project/"))
      (should seen-refresh))))

(ert-deftest android-mode-public-target-api-ignores-non-project-files ()
  "Public target APIs return nil outside an Android project."
  (let ((android--selected-targets nil))
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
  (let ((android--selected-targets nil)
        (answers '("app" "debug"))
        gradle-tasks)
    (cl-letf (((symbol-function 'android-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android--flavor-modules)
               (lambda () '("app" "demo")))
              ((symbol-function 'android--flavor-variants)
               (lambda (module)
                 (if (string= module "app")
                     '("debug" "release")
                   '("staging"))))
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
  (let ((android--selected-targets nil)
        (answers '("app" "debug" "demo" "staging"))
        gradle-tasks)
    (cl-letf (((symbol-function 'android-root)
               (lambda () "/tmp/project/"))
              ((symbol-function 'android--flavor-modules)
               (lambda () '("app" "demo")))
              ((symbol-function 'android--flavor-variants)
               (lambda (module)
                 (if (string= module "app")
                     '("debug" "release")
                   '("staging" "qa"))))
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
