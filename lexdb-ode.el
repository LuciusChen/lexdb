;;; lexdb-ode.el --- ODE adapter for lexdb -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lexdb "0.1.0"))

;;; Commentary:

;; Adapter for Oxford Dictionary of English (ODE) / Oxford English Living Dictionary (OELD).
;; Supports ODE Living Online edition.
;;
;; Usage (recommended - unified config):
;;   (require 'lexdb-ode)
;;   (setq lexdb-dictionaries
;;         '((:id ode
;;            :type ode
;;            :name "Oxford Dictionary of English"
;;            :db-file "~/dicts/ODE_Living_Online.db"
;;            :priority 3)))
;;   (lexdb-init)
;;
;; Usage (legacy - still supported):
;;   (require 'lexdb-ode)
;;   (setq lexdb-ode-db-file "~/path/to/ODE_Living_Online.db")
;;   (lexdb-ode-register)

;;; Code:

(require 'lexdb)
(require 'sqlite)
(require 'json)

;;;; ============================================================
;;;; Configuration
;;;; ============================================================

(defgroup lexdb-ode nil
  "ODE adapter settings."
  :prefix "lexdb-ode-"
  :group 'lexdb)

(defcustom lexdb-ode-db-file nil
  "Path to ODE SQLite database."
  :type '(choice (const nil) file)
  :group 'lexdb-ode)

;;;; ============================================================
;;;; Database Connection
;;;; ============================================================

(defun lexdb-ode--ensure-db ()
  "Ensure database connection is open."
  (lexdb-db-ensure (lexdb--active-adapter-id 'ode)
                   (lexdb--active-adapter-db-file lexdb-ode-db-file)))

(defun lexdb-ode--close ()
  "Close database connection and clear cache."
  (lexdb-db-close (lexdb--active-adapter-id 'ode)))

;;;; ============================================================
;;;; Schema Queries
;;;; ============================================================

(defalias 'lexdb-ode--decompress-json #'lexdb--decompress-json-value
  "Decompress COMPRESSED-DATA and parse as JSON.")

(defun lexdb-ode--row-to-sense (sense-row db)
  "Convert SENSE-ROW to lexdb-sense using DB connection."
  (pcase-let ((`(,id ,sense-num ,signpost ,definition ,_sort) sense-row))
    (let* ((ex-rows (sqlite-select db
                     "SELECT text FROM examples WHERE sense_id = ? ORDER BY sort_order"
                     (list id)))
           (examples (mapcar (lambda (ex)
                               (lexdb-example-create :text (nth 0 ex)))
                             ex-rows))
           (gram-rows (sqlite-select db
                       "SELECT pattern, gloss FROM grammar_patterns WHERE sense_id = ? ORDER BY sort_order"
                       (list id)))
           (gram-patterns (mapcar (lambda (g)
                                    (lexdb-grammar-pattern-create
                                     :pattern (car g)
                                     :gloss (cadr g)))
                                  gram-rows))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE sense_id = ? ORDER BY sort_order"
                        (list id)))
           (labels (mapcar (lambda (l)
                             (lexdb-label-create :type (intern (nth 0 l)) :value (nth 1 l)))
                           label-rows))
           ;; Fetch sense-level relations (cross-references)
           (rel-rows (sqlite-select db
                      "SELECT relation_type, prefix, clickable, suffix, target_word, target_sense
                       FROM relations WHERE sense_id = ? ORDER BY sort_order"
                      (list id)))
           (relations (delq nil
                            (mapcar (lambda (row)
                                      (pcase-let ((`(,rel-type ,prefix ,clickable ,suffix ,target-word ,target-sense) row))
                                        (when (or (lexdb--non-empty-string-p clickable)
                                                  (lexdb--non-empty-string-p prefix))
                                          (lexdb-relation-create
                                           :type (intern rel-type)
                                           :prefix prefix
                                           :clickable clickable
                                           :suffix suffix
                                           :target-word target-word
                                           :target-sense target-sense
                                           :target (concat (or prefix "") (or clickable "") (or suffix ""))))))
                                    rel-rows))))
      (lexdb-sense-create
       :id id
       :number (when (lexdb--non-empty-string-p sense-num) sense-num)
       :signpost (when (lexdb--non-empty-string-p signpost) signpost)
       :definition definition
       :examples examples
       :grammar-patterns gram-patterns
       :labels labels
       :relations relations))))

(defalias 'lexdb-ode--build-pronunciations #'lexdb--build-pronunciations-from-db
  "Build pronunciations for ENTRY-ID from DB.")

(defun lexdb-ode--row-to-entry (row)
  "Convert database ROW to lexdb-entry."
  (pcase-let ((`(,id ,_dict-id ,word ,_word-lower ,hyph) row))
    (let* ((db (lexdb-ode--ensure-db))
           (sense-rows (sqlite-select db
                        "SELECT id, sense_number, signpost, definition, sort_order
                         FROM senses WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (prons (lexdb-ode--build-pronunciations id db))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (metadata nil))
      ;; Add pos from labels
      (dolist (label label-rows)
        (pcase-let ((`(,ltype ,lvalue) label))
          (when (and (equal ltype "pos") (not (assq 'ode/pos metadata)))
            (push (cons 'ode/pos lvalue) metadata))))
      ;; Add audio paths to metadata
      (dolist (pron prons)
        (when-let* ((audio (lexdb-pronunciation-audio pron)))
          (pcase (lexdb-pronunciation-variant pron)
            ('uk (unless (assq 'ode/audio-uk metadata)
                   (push (cons 'ode/audio-uk audio) metadata)))
            ('us (unless (assq 'ode/audio-us metadata)
                   (push (cons 'ode/audio-us audio) metadata))))))
      ;; Fetch entry attributes (phrases, origin, frequency, etc.)
      (let ((attr-rows (sqlite-select db
                        "SELECT attr_key, attr_value, attr_type FROM entry_attributes WHERE entry_id = ?"
                        (list id))))
        (dolist (attr attr-rows)
          (pcase-let ((`(,key ,value ,type) attr))
            (when (lexdb--non-empty-string-p value)
              (let ((parsed-value (cond
                                   ((equal type "json.gz")
                                    (lexdb-ode--decompress-json value))
                                   ((equal type "json")
                                    (condition-case nil
                                        ;; Use json-read-from-string for symbol keys
                                        (json-read-from-string value)
                                      (error value)))
                                   ((equal type "integer")
                                    (string-to-number value))
                                   (t value))))
                (push (cons (intern key) parsed-value) metadata))))))
      ;; Convert sense rows
      (let ((senses (mapcar (lambda (sr)
                              (lexdb-ode--row-to-sense sr db))
                            sense-rows)))
        (lexdb-entry-create
         :id id :headword word
         :headword-display (when (lexdb--non-empty-string-p hyph) hyph)
         :senses senses :pronunciations prons :metadata metadata)))))

;;;; ============================================================
;;;; Adapter Functions
;;;; ============================================================

(defun lexdb-ode--lookup (word)
  "Look up WORD in ODE database.
Uses exact match, suffix match (with hyphen prefix), and @@@LINK= aliases."
  (let* ((db (lexdb-ode--ensure-db))
         (word-lower (downcase word))
         ;; Also try with hyphen prefix for suffix entries (e.g., "ious" -> "-ious")
         (suffix-word (unless (string-prefix-p "-" word-lower)
                        (concat "-" word-lower)))
         ;; Direct entry matches (exact match only)
         (direct-rows (sqlite-select db
                       "SELECT id, dict_id, headword, headword_lower, headword_display
                        FROM entries WHERE dict_id = 'ode' AND headword_lower = ?
                        ORDER BY headword_lower"
                       (list word-lower)))
         ;; Suffix entry matches (e.g., "-ious" for "ious")
         (suffix-rows (when suffix-word
                        (sqlite-select db
                         "SELECT id, dict_id, headword, headword_lower, headword_display
                          FROM entries WHERE dict_id = 'ode' AND headword_lower = ?
                          ORDER BY headword_lower"
                         (list suffix-word))))
         ;; Find alias targets and look up those entries
         (alias-targets (sqlite-select db
                         "SELECT target FROM aliases
                          WHERE dict_id = 'ode' AND alias_lower = ?"
                         (list word-lower)))
         (alias-rows (when alias-targets
                       (let ((targets (mapcar #'car alias-targets)))
                         (sqlite-select db
                          (format "SELECT id, dict_id, headword, headword_lower, headword_display
                                   FROM entries WHERE dict_id = 'ode' AND headword_lower IN (%s)
                                   ORDER BY headword_lower"
                                  (mapconcat (lambda (_) "?") targets ","))
                          (mapcar #'downcase targets)))))
         ;; Combine and deduplicate by entry id
         (all-rows (append direct-rows suffix-rows alias-rows))
         (seen-ids (make-hash-table :test 'eq))
         (unique-rows (seq-filter (lambda (row)
                                    (let ((id (car row)))
                                      (unless (gethash id seen-ids)
                                        (puthash id t seen-ids)
                                        t)))
                                  all-rows)))
    (mapcar #'lexdb-ode--row-to-entry unique-rows)))

(defun lexdb-ode--get-phrases (entry-id)
  "Get phrases for ENTRY-ID."
  (let ((adapter-id (lexdb--active-adapter-id 'ode)))
    (or (lexdb-db-cache-get adapter-id (cons entry-id 'phrases))
      (let* ((db (lexdb-ode--ensure-db))
             (attr-row (sqlite-select db
                        "SELECT attr_value, attr_type FROM entry_attributes
                         WHERE entry_id = ? AND attr_key = 'ode/phrases'"
                        (list entry-id)))
             (phrases (when attr-row
                        (let ((value (caar attr-row))
                              (type (cadar attr-row)))
                          (when (lexdb--non-empty-string-p value)
                            (cond
                             ((equal type "json.gz")
                              (lexdb-ode--decompress-json value))
                             ((equal type "json")
                              (condition-case nil
                                  (json-parse-string value :object-type 'alist)
                                (error nil)))
                             (t nil)))))))
        (lexdb-db-cache-put adapter-id (cons entry-id 'phrases) phrases)))))

(defun lexdb-ode--get-origin (entry-id)
  "Get etymology/origin for ENTRY-ID."
  (let ((adapter-id (lexdb--active-adapter-id 'ode)))
    (or (lexdb-db-cache-get adapter-id (cons entry-id 'origin))
      (let* ((db (lexdb-ode--ensure-db))
             (attr-row (sqlite-select db
                        "SELECT attr_value, attr_type FROM entry_attributes
                         WHERE entry_id = ? AND attr_key = 'ode/origin'"
                        (list entry-id)))
             (origin (when attr-row
                       (let ((value (caar attr-row))
                             (type (cadar attr-row)))
                         (when (lexdb--non-empty-string-p value)
                           (cond
                            ((equal type "json.gz")
                             (lexdb-ode--decompress-json value))
                            ((equal type "json")
                             (condition-case nil
                                 (json-parse-string value :object-type 'alist)
                               (error nil)))
                            (t value)))))))
        (lexdb-db-cache-put adapter-id (cons entry-id 'origin) origin)))))

;;;; ============================================================
;;;; Lemmatization
;;;; ============================================================

(defun lexdb-ode--find-lemma (word)
  "Find base form of WORD using common lemmatization rules."
  (lexdb--find-lemma-with-lookup word #'lexdb-ode--lookup))

;;;; ============================================================
;;;; Registration
;;;; ============================================================

(defun lexdb-ode--register-from-config (config)
  "Register ODE adapter from CONFIG plist.
Called by `lexdb-init' for unified configuration."
  (let* ((id (plist-get config :id))
         (name (or (plist-get config :name)
                   "Oxford Dictionary of English"))
         (db-file (plist-get config :db-file))
         (expanded-db-file (and db-file (expand-file-name db-file))))
    (unless db-file
      (error "ODE config missing :db-file"))
    ;; Register adapter
    (lexdb-register-adapter
     (lexdb-adapter-create
      :id id
      :name name
      :version "Living Online"
      :capabilities '(lookup definition pronunciation
                      pos grammar register domain examples
                      phrases origin lemmatization
                      audio-uk audio-us)
      :db-file expanded-db-file
      :lookup-fn #'lexdb-ode--lookup
      :close-fn #'lexdb-ode--close
      :lemma-fn #'lexdb-ode--find-lemma))))

;;;###autoload
(defun lexdb-ode-register ()
  "Register ODE adapter using legacy configuration variables.
For new setups, prefer using `lexdb-dictionaries' and `lexdb-init'."
  (interactive)
  (lexdb-ode--register-from-config
   (list :id 'ode
         :name "Oxford Dictionary of English"
         :db-file lexdb-ode-db-file)))

;; Register adapter type for unified config system
(lexdb-register-adapter-type 'ode #'lexdb-ode--register-from-config)

(provide 'lexdb-ode)
;;; lexdb-ode.el ends here
