;;; lexdb-oald.el --- OALD adapter for lexdb -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lexdb "0.1.0"))

;;; Commentary:

;; Adapter for Oxford Advanced Learner's Dictionary (OALD).
;; Supports OALD4 (4th Edition) with Chinese translations.
;;
;; Usage (recommended - unified config):
;;   (require 'lexdb-oald)
;;   (setq lexdb-dictionaries
;;         '((:id oald
;;            :type oald
;;            :name "Oxford Advanced Learner's"
;;            :db-file "~/dicts/OALD4_EC.db"
;;            :priority 2)))
;;   (lexdb-init)
;;
;; Usage (legacy - still supported):
;;   (require 'lexdb-oald)
;;   (setq lexdb-oald-db-file "~/path/to/OALD4_EC.db")
;;   (lexdb-oald-register)

;;; Code:

(require 'lexdb)
(require 'sqlite)

;;;; ============================================================
;;;; Utility Functions
;;;; ============================================================

;; Note: Uses lexdb--non-empty-string-p from lexdb.el

;;;; ============================================================
;;;; Configuration
;;;; ============================================================

(defgroup lexdb-oald nil
  "OALD adapter settings."
  :prefix "lexdb-oald-"
  :group 'lexdb)

(defcustom lexdb-oald-db-file nil
  "Path to OALD SQLite database."
  :type '(choice (const nil) file)
  :group 'lexdb-oald)

(defcustom lexdb-oald-show-chinese t
  "Whether to show Chinese translations."
  :type 'boolean
  :group 'lexdb-oald)

;;;; ============================================================
;;;; Database Connection
;;;; ============================================================

(defun lexdb-oald--ensure-db ()
  "Ensure database connection is open."
  (lexdb-db-ensure 'oald lexdb-oald-db-file))

(defun lexdb-oald--close ()
  "Close database connection and clear cache."
  (lexdb-db-close 'oald))

;;;; ============================================================
;;;; Schema Queries
;;;; ============================================================

(defun lexdb-oald--row-to-sense (sense-row db)
  "Convert SENSE-ROW to lexdb-sense using DB connection."
  (pcase-let ((`(,id ,sense-num ,signpost ,plural ,definition ,definition-zh ,_sort) sense-row))
    (let* ((ex-rows (sqlite-select db
                     "SELECT text, text_zh FROM examples WHERE sense_id = ? ORDER BY sort_order"
                     (list id)))
           (examples (mapcar (lambda (ex)
                               (let ((text (nth 0 ex))
                                     (text-zh (nth 1 ex)))
                                 (lexdb-example-create
                                  :text text
                                  ;; Store Chinese in metadata
                                  :metadata (when (and lexdb-oald-show-chinese
                                                       (lexdb--non-empty-string-p text-zh))
                                              (list (cons 'oald/text-zh text-zh))))))
                             ex-rows))
           (gram-rows (sqlite-select db
                       "SELECT pattern FROM grammar_patterns WHERE sense_id = ? ORDER BY sort_order"
                       (list id)))
           (gram-patterns (mapcar (lambda (g)
                                    (lexdb-grammar-pattern-create :pattern (car g)))
                                  gram-rows))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE sense_id = ? ORDER BY sort_order"
                        (list id)))
           (labels (mapcar (lambda (l)
                             (lexdb-label-create :type (intern (nth 0 l)) :value (nth 1 l)))
                           label-rows)))
      (let ((meta nil))
        ;; Store Chinese definition in metadata
        (when (and lexdb-oald-show-chinese
                   (lexdb--non-empty-string-p definition-zh))
          (push (cons 'oald/definition-zh definition-zh) meta))
        ;; Store plural forms in metadata
        (when (lexdb--non-empty-string-p plural)
          (push (cons 'oald/plural plural) meta))
        (lexdb-sense-create
         :id id
         :number (when (lexdb--non-empty-string-p sense-num) sense-num)
         :signpost (when (lexdb--non-empty-string-p signpost) signpost)
         :definition definition
         :examples examples
         :grammar-patterns gram-patterns
         :labels labels
         :metadata meta)))))

(defalias 'lexdb-oald--build-pronunciations #'lexdb--build-pronunciations-from-db
  "Build pronunciations for ENTRY-ID from DB.")

(defalias 'lexdb-oald--decompress-json #'lexdb--decompress-json-value
  "Decompress COMPRESSED-DATA and parse as JSON.")

(defun lexdb-oald--row-to-entry (row)
  "Convert database ROW to lexdb-entry."
  (pcase-let ((`(,id ,_dict-id ,word ,_word-lower ,hyph) row))
    (let* ((db (lexdb-oald--ensure-db))
           (sense-rows (sqlite-select db
                        "SELECT id, sense_number, signpost, plural, definition, definition_zh, sort_order
                         FROM senses WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (prons (lexdb-oald--build-pronunciations id db))
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (metadata nil)
           (subsenses-map nil))  ;; Will hold subsenses by sense number
      ;; Add pos from labels
      (dolist (label label-rows)
        (pcase-let ((`(,ltype ,lvalue) label))
          (when (and (equal ltype "pos") (not (assq 'oald/pos metadata)))
            (push (cons 'oald/pos lvalue) metadata))))
      ;; Fetch entry attributes (idioms, derivatives, subsenses, etc.)
      (let ((attr-rows (sqlite-select db
                        "SELECT attr_key, attr_value, attr_type FROM entry_attributes WHERE entry_id = ?"
                        (list id))))
        (dolist (attr attr-rows)
          (pcase-let ((`(,key ,value ,type) attr))
            (when (lexdb--non-empty-string-p value)
              (let ((parsed-value (if (equal type "json_compressed")
                                      (lexdb-oald--decompress-json value)
                                    value)))
                ;; Extract subsenses map for sense-level distribution
                (if (equal key "oald/subsenses")
                    (setq subsenses-map parsed-value)
                  (push (cons (intern key) parsed-value) metadata)))))))
      ;; Convert sense rows, attaching subsenses from map
      (let ((senses (mapcar (lambda (sr)
                              (let* ((sense (lexdb-oald--row-to-sense sr db))
                                     (sense-num (lexdb-sense-number sense))
                                     (sense-subsenses (when (and subsenses-map sense-num)
                                                        (cdr (assoc sense-num subsenses-map #'string=)))))
                                ;; Attach subsenses to sense metadata if present
                                (when sense-subsenses
                                  (let ((meta (lexdb-sense-metadata sense)))
                                    (setf (lexdb-sense-metadata sense)
                                          (cons (cons 'oald/subsenses sense-subsenses) meta))))
                                sense))
                            sense-rows)))
        (lexdb-entry-create
         :id id :headword word
         :headword-display (when (lexdb--non-empty-string-p hyph) hyph)
         :senses senses :pronunciations prons :metadata metadata)))))

;;;; ============================================================
;;;; Adapter Functions
;;;; ============================================================

(defun lexdb-oald--lookup (word)
  "Look up WORD in OALD database."
  (let* ((db (lexdb-oald--ensure-db))
         (word-lower (downcase word))
         ;; First try exact match
         (rows (sqlite-select db
                "SELECT id, dict_id, headword, headword_lower, headword_display
                 FROM entries WHERE headword_lower = ? AND dict_id = 'oald'"
                (list word-lower))))
    ;; If no results, try fuzzy match
    (unless rows
      (setq rows (sqlite-select db
                  "SELECT id, dict_id, headword, headword_lower, headword_display
                   FROM entries WHERE headword_lower LIKE ? AND dict_id = 'oald' LIMIT 20"
                  (list (concat word-lower "%")))))
    (mapcar #'lexdb-oald--row-to-entry rows)))

(defun lexdb-oald--get-idioms (entry-id)
  "Get idioms for ENTRY-ID."
  (or (lexdb-db-cache-get 'oald (cons entry-id 'idioms))
      (let* ((db (lexdb-oald--ensure-db))
             (attr-row (sqlite-select db
                        "SELECT attr_value, attr_type FROM entry_attributes
                         WHERE entry_id = ? AND attr_key = 'oald/idioms'"
                        (list entry-id)))
             (idioms (when attr-row
                       (let ((value (caar attr-row))
                             (type (cadar attr-row)))
                         (when (lexdb--non-empty-string-p value)
                           (if (equal type "json_compressed")
                               (lexdb-oald--decompress-json value)
                             (json-parse-string value :object-type 'alist)))))))
        (lexdb-db-cache-put 'oald (cons entry-id 'idioms) idioms))))

;;;; ============================================================
;;;; Lemmatization
;;;; ============================================================

(defun lexdb-oald--find-lemma (word)
  "Find base form of WORD using common lemmatization rules."
  (lexdb--find-lemma-with-lookup word #'lexdb-oald--lookup))

;;;; ============================================================
;;;; Registration
;;;; ============================================================

(defun lexdb-oald--register-from-config (config)
  "Register OALD adapter from CONFIG plist.
Called by `lexdb-init' for unified configuration."
  (let ((id (plist-get config :id))
        (name (or (plist-get config :name)
                  "Oxford Advanced Learner's Dictionary"))
        (db-file (plist-get config :db-file)))
    (unless db-file
      (error "OALD config missing :db-file"))
    ;; Set legacy variable for compatibility
    (setq lexdb-oald-db-file (expand-file-name db-file))
    ;; Register adapter
    (lexdb-register-adapter
     (lexdb-adapter-create
      :id id
      :name name
      :version "4th Edition (双解)"
      :capabilities '(lookup definition pronunciation
                      pos grammar examples idioms lemmatization
                      chinese-definition chinese-example)
      :db-file lexdb-oald-db-file
      :lookup-fn #'lexdb-oald--lookup
      :close-fn #'lexdb-oald--close
      :lemma-fn #'lexdb-oald--find-lemma))))

;;;###autoload
(defun lexdb-oald-register ()
  "Register OALD adapter using legacy configuration variables.
For new setups, prefer using `lexdb-dictionaries' and `lexdb-init'."
  (interactive)
  (lexdb-oald--register-from-config
   (list :id 'oald
         :name "Oxford Advanced Learner's Dictionary"
         :db-file lexdb-oald-db-file)))

;; Register adapter type for unified config system
(lexdb-register-adapter-type 'oald #'lexdb-oald--register-from-config)

(provide 'lexdb-oald)
;;; lexdb-oald.el ends here
