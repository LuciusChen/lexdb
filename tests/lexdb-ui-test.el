;;; lexdb-ui-test.el --- Tests for LexDB UI -*- lexical-binding: t -*-

;;; Commentary:

;; Focused UI regression tests.

;;; Code:

(require 'ert)
(require 'lexdb-ui)

(defun lexdb-ui-test--entry (headword pos senses)
  "Build a test entry with HEADWORD, POS, and SENSES."
  (lexdb-entry-create
   :id 1
   :headword headword
   :headword-display headword
   :metadata `((ldoce/pos . ,pos))
   :senses (mapcar (lambda (sense)
                     (pcase-let ((`(,num ,signpost ,definition) sense))
                       (lexdb-sense-create
                        :number num
                        :signpost signpost
                        :definition definition)))
                   senses)))

(ert-deftest lexdb-ui-imenu-uses-entry-pos-properties ()
  "Imenu uses rendered entry properties for homographs without IPA."
  (let ((adapter (lexdb-adapter-create
                  :id 'ldoce
                  :name "Test LDOCE"
                  :capabilities '(pos)))
        (entries (list
                  (lexdb-ui-test--entry
                   "good1" "adjective"
                   '(("1" "of a high standard" "of a high standard or quality")))
                  (lexdb-ui-test--entry
                   "good2" "noun"
                   '(("1" nil "no good/not much good/not any good")
                     ("2" nil "used to say that an action will not work"))))))
    (with-temp-buffer
      (lexdb-ui-render-entries entries adapter)
      (should (equal (mapcar #'substring-no-properties
                             (mapcar #'car (lexdb-imenu-create-index)))
                     '("adj. 1 OF A HIGH STANDARD of a high standard or quality (good¹)"
                       "n. 1 no good/not much good/not any good (good²)"
                       "n. 2 used to say that an action will not work (good²)"))))))

(ert-deftest lexdb-ui-custom-id-jumps-to-rendered-sense ()
  "Follow a numbered homograph link in both dictionary display modes."
  (let* ((lexdb-adapters (make-hash-table :test 'eq))
         (lexdb-dictionaries '((:id longman :type ldoce)))
         (lexdb-enabled-adapters '(longman))
         (lexdb--history nil)
         (lexdb--history-position -1)
         (source (lexdb-ui-test--entry "abet" "verb" '(("1" nil "help"))))
         (targets (list (lexdb-ui-test--entry "aid1" "noun" '(("3" nil "charity")))
                        (lexdb-ui-test--entry "aid2" "verb" '(("3" nil "illegal")))))
         (adapter (lexdb-adapter-create
                   :id 'longman :name "Longman" :capabilities '(pos cross-refs)
                   :lookup-fn (lambda (word)
                                (pcase word ("abet" (list source)) ("aid" targets))))))
    (lexdb-register-adapter adapter)
    (let ((ref (lexdb-relation-create :type 'cross_ref :clickable "at aid2"
                                      :suffix "(3)" :target-word "aid" :target-sense "3"
                                      :metadata '((target-headword . "aid2")))))
      (save-window-excursion
        (dolist (multi '(nil t))
          (let ((lexdb-multi-dict-mode multi))
            (dolist (level '(entry sense))
              (setf (lexdb-entry-relations source) (and (eq level 'entry) (list ref))
                    (lexdb-sense-relations (car (lexdb-entry-senses source)))
                    (and (eq level 'sense) (list ref)))
              (if multi (lexdb-ui-display-multi "abet")
                (lexdb-ui-display "abet" (list source) adapter))
              (goto-char (point-min))
              (search-forward "at aid²")
              (button-activate (button-at (1- (point))))
              (should (looking-at "3 illegal"))
              (goto-char (point-min))
              (should (search-forward "noun" nil t)))))))))

(ert-deftest lexdb-resolve-word-reuses-matching-entries ()
  (let* ((lexdb-adapters (make-hash-table :test 'eq))
         calls
         (adapter (lexdb-adapter-create
                   :id 'test :name "Test" :capabilities '(lemmatization)
                   :lookup-fn (lambda (word)
                                (push word calls)
                                (when (equal word "run") '(found))))))
    (lexdb-register-adapter adapter)
    (should (equal (lexdb--resolve-word "runs" adapter) '("run" found)))
    (should (equal (nreverse calls) '("runs" "run")))))

(provide 'lexdb-ui-test)
;;; lexdb-ui-test.el ends here
