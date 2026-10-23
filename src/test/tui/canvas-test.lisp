;;;; canvas-test.lisp --- what a ground fades into and a word comes up out of.
;;;;
;;;; SPDX-License-Identifier: MIT
;;;;
;;;; A transparent theme's canvas is the terminal's own background: a band's
;;;; fade goes out into it and a fading word comes up out of it, never the
;;;; theme's nominal canvas, and while the terminal has not said what it is
;;;; neither guesses.

(in-package #:nodecode.test)

(defun painted-grounds (row width)
  "The (COLUMN . RGB) of each cell of ROW, one painted row WIDTH wide, that
stands on a ground of its own."
  (let ((buffer (nlt:parse-styled-string (list row) width 1)))
    (loop for x below width
          for rgb = (nle::sgr-rgb (nlt:cell-bg (nlt:screen-buffer-ref buffer x 0)))
          when rgb collect (cons x rgb))))

(defun heading-grounds (text width)
  "The painted grounds of each row TEXT, a markdown answer, lays at WIDTH."
  (mapcar (lambda (row) (painted-grounds row width))
          (nle::llines-rows (nle::markdown-llines text :width width) width)))

(deftest a-band-fades-out-into-the-canvas-the-terminal-shows ()
  (let* ((nle:*color-profile* :truecolor)
         (nle::*terminal-canvas* '(19 19 19))
         (nle:*palette* (theme-palette "Tungstene" :user nil))
         (fill (nle::visual-style-bg (nle::style-for-tone :heading-band)))
         (grounds (first (heading-grounds "## The verdict" 100))))
    (is (equal fill (cdr (first grounds))) "the band opens solid")
    (is (<= (reduce #'max (mapcar (lambda (a b) (abs (- a b))) (cdr (car (last grounds))) '(19 19 19))) 2) "and goes out on the terminal's own background")
    (is (every (lambda (ground) (every #'>= (cdr ground) '(19 19 19))) grounds) "no cell of it darker than the terminal")))

(deftest a-band-over-a-canvas-the-terminal-has-not-said-stands-solid ()
  (let* ((nle:*color-profile* :truecolor)
         (nle::*terminal-canvas* nil)
         (nle:*palette* (theme-palette "Tungstene" :user nil))
         (fill (nle::visual-style-bg (nle::style-for-tone :heading-band)))
         (grounds (first (heading-grounds "## The verdict" 100))))
    (is (and grounds (every (lambda (ground) (equal fill (cdr ground))) grounds)) "its own fill alone, no fade toward a guessed canvas")
    (is (< (car (car (last grounds))) 20) "ending two past its words")))

(deftest a-band-never-runs-past-the-rows-edge ()
  (let ((nle:*color-profile* :truecolor)
        (nle::*terminal-canvas* '(19 19 19))
        (edge (- 40 nle::*transcript-right-padding*)))
    (let ((nle:*palette* (theme-palette "Tungstene" :user nil)))
      (dolist (row (heading-grounds "## A heading long enough to fill the row it stands on" 40))
        (is (< (car (car (last row))) edge) "no wrapped row's band crosses into the right padding")
        (is (<= (reduce #'max (mapcar (lambda (a b) (abs (- a b))) (cdr (car (last row))) '(19 19 19))) 12) "a row with little room fades out in what room it has")))))

(deftest words-come-up-out-of-the-canvas-the-terminal-shows ()
  (loop for (canvas lit) in '(((19 19 19) "38;2;19;19;19") (nil nil))
        do (let ((nle:*color-profile* :truecolor)
                 (nle::*terminal-canvas* canvas))
             (let ((nle:*palette* (theme-palette "Tungstene" :user nil)))
               (with-frame-model (model 100 30 :session-id "words-canvas" :tool-detail :standard)
                 (let ((nle::*turn-words* (make-hash-table :test 'equal)))
                   (setf (nle::chat-model-program model) :terminal)
                   (fold-model model
                     (exchange "check the sum" "Looking at the file." :turn-id "t1"))
                   (mark-turn-in-flight model)
                   (nle::render-state model)
                   (let* ((rows (nle::compose-frame model))
                          (y (1- (frame-row-carrying model "Looking at the file.")))
                          (row (find y (nle::fade-rows model) :key #'first))
                          (screen (nlt:parse-styled-string rows 100 30))
                          (cell (nlt:screen-buffer-ref screen (second row) y))
                          (painted (nlt:cell-fg cell)))
                     (is row "the words fade in their place")
                     (funcall (nle::frame-overlay model) screen)
                     (if lit
                         (is (equal lit (nlt:cell-fg cell)) "coming up out of the terminal's own background")
                         (is (equal painted (nlt:cell-fg cell)) "over a canvas not yet known, standing as painted")))))))))

(deftest a-band-is-as-long-as-its-words ()
  (let ((nle:*color-profile* :truecolor)
        (nle::*terminal-canvas* '(19 19 19)))
    (let ((nle:*palette* (theme-palette "Tungstene" :user nil)))
      (flet ((band-end (text) (car (car (last (first (heading-grounds text 100))))))
             (words-end (text) (nle::text-display-width (first (nth-value 1 (nle::llines-rows (nle::markdown-llines text :width 100) 100))))))
        (let ((short (words-end "## The verdict"))
              (long (words-end "## The verdict on the whole table and its client adapter")))
          (is (= (1+ short) (band-end "## The verdict")) "a heading's band ends two past its words")
          (is (= (1+ long) (band-end "## The verdict on the whole table and its client adapter")) "a longer sentence's band is that much longer")
          (is (= (1+ short) (band-end "**The verdict** and the prose that follows it")) "a lead run's band is its run's, never under the prose after it"))))))
