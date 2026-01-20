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

(defvar lexdb-oald--db nil
  "Database connection for OALD.")

(defvar lexdb-oald--cache (make-hash-table :test 'eql)
  "Cache for prefetched data.")

(defun lexdb-oald--ensure-db ()
  "Ensure database connection is open."
  (unless lexdb-oald-db-file
    (error "Please set `lexdb-oald-db-file'"))
  (unless (file-exists-p lexdb-oald-db-file)
    (error "Database file not found: %s" lexdb-oald-db-file))
  (unless (and lexdb-oald--db (sqlitep lexdb-oald--db))
    (setq lexdb-oald--db (sqlite-open lexdb-oald-db-file)))
  lexdb-oald--db)

(defun lexdb-oald--close ()
  "Close database connection and clear cache."
  (when (and lexdb-oald--db (sqlitep lexdb-oald--db))
    (sqlite-close lexdb-oald--db)
    (setq lexdb-oald--db nil))
  (clrhash lexdb-oald--cache))

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

(defun lexdb-oald--build-pronunciations (entry-id db)
  "Build pronunciations for ENTRY-ID from DB."
  (let ((rows (sqlite-select db
               "SELECT variant, ipa, audio_path FROM pronunciations WHERE entry_id = ? ORDER BY sort_order"
               (list entry-id))))
    (delq nil
          (mapcar (lambda (row)
                    (pcase-let ((`(,variant ,ipa ,audio) row))
                      (when (lexdb--non-empty-string-p ipa)
                        (lexdb-pronunciation-create
                         :ipa ipa
                         :variant (when variant (intern variant))
                         :audio (when (lexdb--non-empty-string-p audio) audio)))))
                  rows))))

(defun lexdb-oald--decompress-json (compressed-data)
  "Decompress COMPRESSED-DATA and parse as JSON."
  (when (and compressed-data (not (string-empty-p compressed-data)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert compressed-data)
      (zlib-decompress-region (point-min) (point-max))
      (decode-coding-region (point-min) (point-max) 'utf-8)
      (goto-char (point-min))
      (json-parse-buffer :object-type 'alist))))

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
  (or (gethash (cons entry-id 'idioms) lexdb-oald--cache)
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
        (puthash (cons entry-id 'idioms) idioms lexdb-oald--cache)
        idioms)))

;;;; ============================================================
;;;; Lemmatization
;;;; ============================================================

(defun lexdb-oald--try-lemma (word suffix replacement)
  "Try removing SUFFIX from WORD and adding REPLACEMENT."
  (when (and (> (length word) (length suffix)) (string-suffix-p suffix word))
    (let ((candidate (concat (substring word 0 (- (length word) (length suffix))) replacement)))
      (when (and (> (length candidate) 1) (lexdb-oald--lookup candidate)) candidate))))

(defun lexdb-oald--find-lemma (word)
  "Find base form of WORD."
  (let ((w (downcase word)))
    (if (lexdb-oald--lookup w) w
      (or (lexdb-oald--try-lemma w "ing" "") (lexdb-oald--try-lemma w "ing" "e")
          (lexdb-oald--try-lemma w "ning" "n") (lexdb-oald--try-lemma w "ting" "t")
          (lexdb-oald--try-lemma w "ping" "p") (lexdb-oald--try-lemma w "bing" "b")
          (lexdb-oald--try-lemma w "ging" "g") (lexdb-oald--try-lemma w "ming" "m")
          (lexdb-oald--try-lemma w "ding" "d") (lexdb-oald--try-lemma w "ed" "")
          (lexdb-oald--try-lemma w "ed" "e") (lexdb-oald--try-lemma w "ied" "y")
          (lexdb-oald--try-lemma w "ned" "n") (lexdb-oald--try-lemma w "ted" "t")
          (lexdb-oald--try-lemma w "ped" "p") (lexdb-oald--try-lemma w "bed" "b")
          (lexdb-oald--try-lemma w "ged" "g") (lexdb-oald--try-lemma w "med" "m")
          (lexdb-oald--try-lemma w "ded" "d") (lexdb-oald--try-lemma w "s" "")
          (lexdb-oald--try-lemma w "es" "") (lexdb-oald--try-lemma w "ies" "y")
          (lexdb-oald--try-lemma w "er" "") (lexdb-oald--try-lemma w "er" "e")
          (lexdb-oald--try-lemma w "ier" "y") (lexdb-oald--try-lemma w "est" "")
          (lexdb-oald--try-lemma w "est" "e") (lexdb-oald--try-lemma w "iest" "y")
          (lexdb-oald--try-lemma w "ly" "") (lexdb-oald--try-lemma w "ily" "y")
          (lexdb-oald--try-lemma w "'s" "") w))))

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
