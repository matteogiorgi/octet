#!/bin/sh
# -*- scheme -*-
exec guile -e main -s "$0" "$@"
!#
;;; octet.scm --- A Brainfuck interpreter in Guile.
;;;
;;; The pipeline has three stages:
;;;   1. parse   : string -> AST.  The six primitive commands become
;;;      symbols, and [...] loops become nested (loop . body) nodes.  The
;;;      parser also validates bracket matching (see parse-instrs below).
;;;   2. compile : AST -> closures.  Each node is turned into a single
;;;      tape -> tape function once, so the match-based dispatch on the
;;;      node's shape happens at compile time, not on every execution.
;;;   3. run     : just calling the compiled top-level closure on a fresh
;;;      tape.  All "execution" is function application; the only
;;;      remaining state is the tape value threaded from call to call.
;;;
;;; The tape is a list (left cur right) -- a Huet-style zipper:
;;;   - cur   : the cell currently under the pointer
;;;   - left  : cells to the left of the pointer, closest one at the head
;;;             (i.e. stored in reverse order, since that's the end the
;;;             pointer moves through)
;;;   - right : cells to the right of the pointer, closest one at the head
;;; Moving the pointer is therefore plain cons/uncons: O(1) and purely
;;; functional -- no cell array is ever mutated in place.

(use-modules (ice-9 match)
             (ice-9 textual-ports)        ; get-string-all
             (ice-9 binary-ports))        ; put-u8, get-u8: raw byte I/O (see write-output-byte below)

;;; ----------------------------------------------------------------- The tape

(define (make-tape) (list '() 0 '()))

(define (tape-ref t)
  (match t ((_ cur _) cur)))

(define (tape-set t v)
  (match t ((left _ right) (list left v right))))

(define (tape-update t f)
  (match t ((left cur right) (list left (f cur) right))))

;; Move right: the old cur is pushed onto the head of left; the new cur
;; is the head of right (or 0 if the tape hasn't been extended that far
;; yet, i.e. this cell has never been visited before).
(define (tape-right t)
  (match t
         ((left cur '())        (list (cons cur left) 0 '()))
         ((left cur (r . rs))   (list (cons cur left) r rs))))

(define (tape-left t)
  (match t
         ((()       cur right)  (list '() 0 (cons cur right)))
         (((l . ls) cur right)  (list ls  l (cons cur right)))))

;;; --------------------------------------------------------------- The parser

;; Annotates each character with its position (line, column), 1-based, so
;; the parser can report unbalanced brackets precisely rather than just
;; pointing at "somewhere in the file".
(define (annotate str)
  (let loop ((chars (string->list str)) (line 1) (col 1) (acc '()))
    (if (null? chars)
      (reverse acc)
      (let* ((c (car chars)) (entry (list c line col)))
        (if (char=? c #\newline)
          (loop (cdr chars) (+ line 1) 1 (cons entry acc))
          (loop (cdr chars) line (+ col 1) (cons entry acc)))))))

(define (parse-error line col msg)
  (throw 'bf-parse-error line col msg))

;; Reads a sequence of instructions until it hits ] or runs out of input.
;; Returns (values instructions rest), where `rest` is the characters
;; remaining after the closing ] (or '() at end of input).
;;
;; `open-pos` is #f at the outermost level, or the (line . col) of the '['
;; that opened the current level.  This is what lets an unclosed loop be
;; reported at the position where it was *opened* -- there is no closing
;; position to point to, since the file simply ends.
(define (parse-instrs chars open-pos)
  (let loop ((chars chars) (acc '()))
    (if (null? chars)
      (if open-pos
        (parse-error (car open-pos) (cdr open-pos) "unclosed '['")
        (values (reverse acc) '()))
      (match (car chars)
             ((c line col)
              (let ((rest (cdr chars)))
                (case c
                  ((#\>) (loop rest (cons 'inc-ptr acc)))
                  ((#\<) (loop rest (cons 'dec-ptr acc)))
                  ((#\+) (loop rest (cons 'inc     acc)))
                  ((#\-) (loop rest (cons 'dec     acc)))
                  ((#\.) (loop rest (cons 'output  acc)))
                  ((#\,) (loop rest (cons 'input   acc)))
                  ((#\[)
                   (call-with-values
                     (lambda () (parse-instrs rest (cons line col)))
                     (lambda (body remaining)
                       (loop remaining (cons (cons 'loop body) acc)))))
                  ((#\])
                   (if open-pos
                     (values (reverse acc) rest)
                     (parse-error line col "']' without a matching '['")))
                  ;; any other character is a Brainfuck comment: ignore it
                  (else (loop rest acc)))))))))

(define (parse str)
  (call-with-values
    (lambda () (parse-instrs (annotate str) #f))
    (lambda (instrs _rest) instrs)))

;;; ------------------------------------------------------------- The compiler

;; Each AST node is turned into a tape -> tape closure: the match-based
;; dispatch on the node's shape happens once, at compile time, instead of
;; being redone on every single iteration of a loop's body.

;; Two conventions that "classic" Brainfuck fixes arbitrarily are modeled
;; here as dynamic parameters rather than constants -- main sets them from
;; the command line (--cell-bits, --eof), and their defaults reproduce the
;; original, non-configurable behavior: 8-bit cells, EOF reads as 0.
(define cell-bits (make-parameter 8))
(define eof-mode  (make-parameter 'zero))  ; 'zero | 'minus-one | 'unchanged

(define (wrap n) (modulo n (expt 2 (cell-bits))))

(define (read-input-byte tape)
  (let ((b (get-u8 (current-input-port))))
    (if (eof-object? b)
      (case (eof-mode)
        ((zero)      (tape-set tape 0))
        ((minus-one) (tape-set tape (wrap -1)))
        ((unchanged) tape))
      (tape-set tape (wrap b)))))

;; Output is always a single byte (0-255): a cell may be wider than 8
;; bits when --cell-bits is used, but "a character of output" is by
;; convention its low byte -- this matches how other Brainfuck
;; implementations with wide cells behave, and keeps the output stream
;; byte-oriented regardless of the configured cell width.
(define (write-output-byte tape)
  (put-u8 (current-output-port) (modulo (tape-ref tape) 256))
  tape)

(define (compile-instr instr)
  (match instr
         ('inc-ptr tape-right)
         ('dec-ptr tape-left)
         ('inc     (lambda (tape) (tape-update tape (lambda (b) (wrap (+ b 1))))))
         ('dec     (lambda (tape) (tape-update tape (lambda (b) (wrap (- b 1))))))
         ('output  write-output-byte)
         ('input   read-input-byte)
         (('loop . body)
          (let ((run-body (compile-seq body)))
            (lambda (tape)
              ;; Repeat the body while the current cell is non-zero.  The
              ;; body was compiled once, above, outside this loop -- each
              ;; iteration just applies the resulting closure.
              (let iterate ((tape tape))
                (if (zero? (tape-ref tape))
                  tape
                  (iterate (run-body tape)))))))))

;; Compiles a list of instructions into a single closure that threads the
;; tape through each of them in sequence.
(define (compile-seq instrs)
  (let ((fns (map compile-instr instrs)))
    (lambda (tape)
      (let run ((fns fns) (tape tape))
        (if (null? fns)
          tape
          (run (cdr fns) ((car fns) tape)))))))

;;; --------------------------------------------------- Command-line interface

(define (run-string src)
  ((compile-seq (parse src)) (make-tape))
  (force-output))

(define (run-file path)
  (run-string (call-with-input-file path get-string-all)))

(define (usage-error)
  (format (current-error-port)
          "usage: octet.scm [--cell-bits=N] [--eof=zero|minus-one|unchanged] PROGRAM.bf~%")
  (exit 2))

;; If arg starts with prefix, returns the rest of the string; #f otherwise.
(define (flag-value prefix arg)
  (let ((plen (string-length prefix)))
    (and (>= (string-length arg) plen)
         (string=? (substring arg 0 plen) prefix)
         (substring arg plen))))

(define (parse-cell-bits s)
  (let ((n (string->number s)))
    (if (and n (exact-integer? n) (positive? n))
      n
      (begin
        (format (current-error-port) "invalid --cell-bits: ~a~%" s)
        (exit 2)))))

(define (parse-eof-mode s)
  (match s
         ("zero"      'zero)
         ("minus-one" 'minus-one)
         ("unchanged" 'unchanged)
         (_ (format (current-error-port)
                    "invalid --eof: ~a (use zero, minus-one or unchanged)~%" s)
            (exit 2))))

(define (main args)
  (let loop ((args (cdr args)) (bits 8) (eof 'zero) (path #f))
    (cond
      ((null? args)
       (if (not path)
         (usage-error)
         (parameterize ((cell-bits bits) (eof-mode eof))
           (catch 'bf-parse-error
                  (lambda () (run-file path))
                  (lambda (key line col msg)
                    (format (current-error-port)
                            "~a: syntax error (line ~a, column ~a): ~a~%"
                            path line col msg)
                    (exit 1))))))
      ((flag-value "--cell-bits=" (car args))
       => (lambda (v) (loop (cdr args) (parse-cell-bits v) eof path)))
      ((flag-value "--eof=" (car args))
       => (lambda (v) (loop (cdr args) bits (parse-eof-mode v) path)))
      (path (usage-error))
      (else (loop (cdr args) bits eof (car args))))))

; vim: ft=scheme
