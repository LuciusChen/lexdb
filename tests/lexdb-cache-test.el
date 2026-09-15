;;; lexdb-cache-test.el --- Cache and prefetch tests -*- lexical-binding: t -*-

;;; Commentary:

;; Exercise real SQLite reads, cache lifecycle, and adapter isolation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lexdb-ui)
(require 'lexdb-ldoce)
(require 'lexdb-oald)
(require 'lexdb-ode)

(defmacro lexdb-cache-test--with-db (&rest body)
  "Run BODY with an isolated dictionary database and registries."
  (declare (indent 0) (debug t))
  `(let* ((db-file (make-temp-file "lexdb-cache-test-" nil ".db"))
          (lexdb--database-connections (make-hash-table :test 'eq))
          (lexdb--query-caches (make-hash-table :test 'eq))
          (lexdb-adapters (make-hash-table :test 'eq))
          (lexdb-default-adapter nil)
          (lexdb-current-adapter nil)
          (lexdb--active-adapter nil)
          (lexdb-ldoce-db-file db-file)
          (lexdb-oald-db-file db-file)
          (lexdb-ode-db-file db-file)
          (db (lexdb-db-ensure 'ldoce db-file)))
     (unwind-protect
         (progn
           (dolist (sql
                    '("CREATE TABLE collocations (id INTEGER PRIMARY KEY, entry_id INTEGER, category TEXT, text TEXT, gloss TEXT, sort_order INTEGER)"
                      "CREATE TABLE collocation_examples (id INTEGER PRIMARY KEY, collocation_id INTEGER, text TEXT, sort_order INTEGER)"
                      "CREATE TABLE entry_attributes (entry_id INTEGER, attr_key TEXT, attr_value TEXT, attr_type TEXT)"
                      "INSERT INTO collocations VALUES (10, 1, 'verb', 'second', 'later', 2), (20, 1, 'noun', 'first', 'earlier', 1), (30, 2, 'adjective', 'other entry', NULL, 1), (40, 1, 'verb', 'no examples', NULL, 3), (50, 4, 'noun', 'unrequested', NULL, 1)"
                      "INSERT INTO collocation_examples VALUES (1, 20, 'example B', 2), (2, 20, 'example A', 1), (3, 10, 'second example', 1), (4, 30, 'other example', 1), (5, 50, 'unrequested example', 1)"
                      "INSERT INTO entry_attributes VALUES (1, 'oald/idioms', '[{\"text\":\"test idiom\"}]', 'json'), (1, 'ode/phrases', '[{\"text\":\"test phrase\"}]', 'json'), (1, 'ode/origin', 'Old English', 'text')"))
             (sqlite-execute db sql))
           ,@body)
       (dolist (id (hash-table-keys lexdb--database-connections))
         (lexdb-db-close id))
       (delete-file db-file))))

(defun lexdb-cache-test--query-count (function)
  "Run FUNCTION and return the number of SQLite select calls it makes."
  (let ((select (symbol-function 'sqlite-select))
        (count 0))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (&rest args)
                 (cl-incf count)
                 (apply select args))))
      (funcall function))
    count))

(ert-deftest lexdb-cache-composite-keys ()
  "Equivalent keys hit caches created both before and after connecting."
  (lexdb-cache-test--with-db
    (dolist (id '(ldoce disconnected))
      (lexdb-db-cache-put id (list 7 'collocations) '("saved"))
      (should (equal (lexdb-db-cache-get id (list 7 'collocations))
                     '("saved")))
      (should-not (lexdb-db-cache-get id (list 7 'idioms))))))

(ert-deftest lexdb-cache-empty-values-and-close ()
  "Cached nil differs from a miss, and closing invalidates cached data."
  (lexdb-cache-test--with-db
    (should (eq (lexdb-db-cache-get 'unknown '(1 . empty) 'missing) 'missing))
    (lexdb-db-cache-put 'ldoce (cons 1 'empty) nil)
    (should-not (lexdb-db-cache-get 'ldoce (cons 1 'empty) 'missing))
    (lexdb-db-close 'ldoce)
    (should (eq (lexdb-db-cache-get 'ldoce (cons 1 'empty) 'missing) 'missing))
    (lexdb-db-ensure 'ldoce db-file)
    (should (eq (lexdb-db-cache-get 'ldoce (cons 1 'empty) 'missing) 'missing))))

(ert-deftest lexdb-ldoce-prefetch-batches-and-preserves-data ()
  "Prefetch uses two reads and preserves order and entries without examples."
  (lexdb-cache-test--with-db
    (should (= 2 (lexdb-cache-test--query-count
                  (lambda () (lexdb-ldoce--prefetch '(2 1 3 1))))))
    (should (= 0 (lexdb-cache-test--query-count
                  (lambda ()
                    (let ((colls (lexdb-ldoce--get-collocations 1)))
                      (should (equal (mapcar #'lexdb-collocation-text colls)
                                     '("first" "second" "no examples")))
                      (should (equal (mapcar #'lexdb-collocation-category colls)
                                     '("noun" "verb" "verb")))
                      (should (equal (mapcar #'lexdb-collocation-gloss colls)
                                     '("earlier" "later" nil)))
                      (should (equal (mapcar #'lexdb-collocation-examples colls)
                                     '(("example A" "example B") ("second example") nil))))
                    (should (equal (mapcar #'lexdb-collocation-text
                                          (lexdb-ldoce--get-collocations 2))
                                   '("other entry")))
                    (should-not (lexdb-ldoce--get-collocations 3))
                    (lexdb-ldoce--prefetch '(1 2 3))))))
    (should (eq (lexdb-db-cache-get 'ldoce '(4 . collocations) 'missing) 'missing))
    (should (= 2 (lexdb-cache-test--query-count
                  (lambda () (lexdb-ldoce--prefetch '(1 4))))))
    (should (equal (lexdb-collocation-examples
                    (car (lexdb-ldoce--get-collocations 4)))
                   '("unrequested example")))))

(ert-deftest lexdb-ldoce-empty-prefetch-is-cached ()
  "Empty batches do no work and entries without collocations stay cached."
  (lexdb-cache-test--with-db
    (should (= 0 (lexdb-cache-test--query-count
                  (lambda () (lexdb-ldoce--prefetch nil)))))
    (should (= 1 (lexdb-cache-test--query-count
                  (lambda () (lexdb-ldoce--prefetch '(3))))))
    (should (= 0 (lexdb-cache-test--query-count
                  (lambda ()
                    (lexdb-ldoce--prefetch '(3))
                    (should-not (lexdb-ldoce--get-collocations 3))))))))

(ert-deftest lexdb-ldoce-direct-get-reuses-prefetch ()
  "A direct get batches examples and shares results with later prefetches."
  (lexdb-cache-test--with-db
    (should (= 2 (lexdb-cache-test--query-count
                  (lambda ()
                    (should (= 3 (length (lexdb-ldoce--get-collocations 1))))))))
    (should (= 0 (lexdb-cache-test--query-count
                  (lambda ()
                    (lexdb-ldoce--prefetch '(1))
                    (should (= 3 (length (lexdb-ldoce--get-collocations 1))))))))))

(ert-deftest lexdb-attribute-caches-reuse-present-and-empty-values ()
  "OALD and ODE avoid re-reading both populated and absent attributes."
  (lexdb-cache-test--with-db
    (dolist (getter '(lexdb-oald--get-idioms lexdb-ode--get-phrases
                     lexdb-ode--get-origin))
      (let ((value nil))
        (should (= 1 (lexdb-cache-test--query-count
                      (lambda () (setq value (funcall getter 1))))))
        (should value)
        (should (= 0 (lexdb-cache-test--query-count
                      (lambda () (should (equal (funcall getter 1) value))))))
        (should (= 1 (lexdb-cache-test--query-count
                      (lambda () (should-not (funcall getter 99))))))
        (should (= 0 (lexdb-cache-test--query-count
                      (lambda () (should-not (funcall getter 99))))))))))

(ert-deftest lexdb-ldoce-cache-invalidated-on-close ()
  "Closing a connection lets subsequent reads see updated data."
  (lexdb-cache-test--with-db
    (should-not (lexdb-ldoce--get-collocations 3))
    (sqlite-execute db "INSERT INTO collocations VALUES (60, 3, 'verb', 'new', NULL, 1)")
    (should-not (lexdb-ldoce--get-collocations 3))
    (lexdb-db-close 'ldoce)
    (should (equal (mapcar #'lexdb-collocation-text
                          (lexdb-ldoce--get-collocations 3))
                   '("new")))))

(ert-deftest lexdb-ldoce-failed-prefetch-does-not-cache-partial-results ()
  "An example query failure remains visible and a retry can load all data."
  (lexdb-cache-test--with-db
    (let ((select (symbol-function 'sqlite-select)))
      (cl-letf (((symbol-function 'sqlite-select)
                 (lambda (connection sql &rest args)
                   (if (string-match-p "collocation_examples" sql)
                       (error "Example query failed")
                     (apply select connection sql args)))))
        (should-error (lexdb-ldoce--prefetch '(1 3)))))
    (dolist (id '(1 3))
      (should (eq (lexdb-db-cache-get 'ldoce (cons id 'collocations) 'missing)
                  'missing)))
    (should (equal (lexdb-collocation-examples
                    (car (lexdb-ldoce--get-collocations 1)))
                   '("example A" "example B")))))

(ert-deftest lexdb-ldoce-legacy-registration-uses-cache ()
  "Legacy registration still shares caches across public adapter callbacks."
  (lexdb-cache-test--with-db
    (lexdb-ldoce-register)
    (lexdb-prefetch '(1 3) 'ldoce)
    (should (= 0 (lexdb-cache-test--query-count
                  (lambda ()
                    (should (= 3 (length (lexdb-get-collocations 1 'ldoce))))))))))

(ert-deftest lexdb-ldoce-prefetch-keeps-adapter-caches-isolated ()
  "Unified registration and UI rendering preserve same-type adapter isolation."
  (lexdb-cache-test--with-db
    (let ((lexdb-dictionaries
           `((:id first :type ldoce :db-file ,db-file)
             (:id second :type ldoce :db-file ,db-file))))
      (lexdb-init))
    (lexdb-prefetch '(1 3) 'first)
    (should (= 2 (lexdb-cache-test--query-count
                  (lambda () (lexdb-prefetch '(1) 'second)))))
    (should-not (eq (lexdb-get-collocations 1 'first)
                    (lexdb-get-collocations 1 'second)))
    (let ((entries (list (lexdb-entry-create :id 1 :headword "example")
                         (lexdb-entry-create :id 3 :headword "empty"))))
      (should (= 0 (lexdb-cache-test--query-count
                    (lambda ()
                      (with-temp-buffer
                        (lexdb-ui-render-entries entries (lexdb-get-adapter 'first))
                        (should (string-match-p "COLLOCATIONS" (buffer-string)))))))))
    (lexdb-unregister-adapter 'first)
    (should (= 0 (lexdb-cache-test--query-count
                  (lambda ()
                    (should (= 3 (length (lexdb-get-collocations 1 'second))))))))))

(provide 'lexdb-cache-test)
;;; lexdb-cache-test.el ends here
