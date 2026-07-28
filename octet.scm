#!/bin/sh
# -*- scheme -*-
exec guile -e main -s "$0" "$@"
!#
;;; bf.scm --- Un interprete Brainfuck in Guile.
;;;
;;; Design in due fasi:
;;;   1. parse : stringa -> AST.  I sei comandi semplici diventano simboli,
;;;      i cicli [...] diventano nodi (loop . corpo) annidati.
;;;   2. run   : esegue l'AST su un "nastro" rappresentato come zipper.
;;;
;;; Il nastro e' una lista (left cur right):
;;;   - cur   : la cella sotto il puntatore
;;;   - left  : celle a sinistra, la piu' vicina in testa (ordine invertito)
;;;   - right : celle a destra, la piu' vicina in testa
;;; Muovere il puntatore e' quindi solo cons/uncons: O(1), nessuna mutazione.

(use-modules (ice-9 match)
             (ice-9 textual-ports)        ; get-string-all
             (ice-9 binary-ports))        ; put-u8, get-u8: I/O a byte grezzi,
; indipendente dall'encoding del
; terminale (serve con celle > 8 bit)

;;; ---------------------------------------------------------------- Il nastro

(define (make-tape) (list '() 0 '()))

(define (tape-ref t)
  (match t ((_ cur _) cur)))

(define (tape-set t v)
  (match t ((left _ right) (list left v right))))

(define (tape-update t f)
  (match t ((left cur right) (list left (f cur) right))))

;; Muovi a destra: la vecchia cur va in testa a left; la nuova cur e' la
;; prima di right (o 0 se il nastro non e' ancora stato esteso li').
(define (tape-right t)
  (match t
         ((left cur '())        (list (cons cur left) 0 '()))
         ((left cur (r . rs))   (list (cons cur left) r rs))))

(define (tape-left t)
  (match t
         ((()       cur right)  (list '() 0 (cons cur right)))
         (((l . ls) cur right)  (list ls  l (cons cur right)))))

;;; ------------------------------------------------------------------ Il parser

;; Annota ogni carattere con la sua posizione (riga, colonna), 1-based,
;; cosi' il parser puo' segnalare le parentesi sbilanciate con precisione.
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

;; Legge una sequenza di istruzioni finche' non trova ] o la fine.
;; Ritorna (values istruzioni resto), dove `resto` sono i caratteri dopo
;; il ] che chiude (o '() a fine input).
;;
;; `open-pos` e' #f al livello piu' esterno, oppure (line . col) della '['
;; che ha aperto questo livello: serve per segnalare un ciclo non chiuso
;; con la posizione di apertura, non quella (inesistente) di chiusura.
(define (parse-instrs chars open-pos)
  (let loop ((chars chars) (acc '()))
    (if (null? chars)
      (if open-pos
        (parse-error (car open-pos) (cdr open-pos) "'[' non chiuso")
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
                     (parse-error line col "']' senza '[' corrispondente")))
                  (else (loop rest acc)))))))))     ; ogni altro carattere: commento

(define (parse str)
  (call-with-values
    (lambda () (parse-instrs (annotate str) #f))
    (lambda (instrs _rest) instrs)))

;;; ------------------------------------------------------------ Il compilatore

;; Ogni nodo dell'AST diventa una closure tape -> tape: il dispatch con
;; match avviene una sola volta, in fase di compilazione, non ad ogni
;; iterazione di un loop.

;; Due convenzioni che il Brainfuck "classico" fissa arbitrariamente, e che
;; qui sono parametri dinamici anziche' costanti — main le imposta da riga
;; di comando, il default riproduce il comportamento originale (celle a 8
;; bit, EOF -> 0).
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

;; L'output resta sempre un byte (0-255): la cella puo' essere piu' larga
;; di 8 bit, ma "un carattere in output" e' per convenzione il suo byte
;; basso — coerente con le altre implementazioni Brainfuck a celle larghe.
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
              ;; ripeti il corpo finche' la cella corrente non e' zero
              (let iterate ((tape tape))
                (if (zero? (tape-ref tape))
                  tape
                  (iterate (run-body tape)))))))))

;; Compila una lista di istruzioni in un'unica closure che le fila in
;; sequenza sul nastro.
(define (compile-seq instrs)
  (let ((fns (map compile-instr instrs)))
    (lambda (tape)
      (let run ((fns fns) (tape tape))
        (if (null? fns)
          tape
          (run (cdr fns) ((car fns) tape)))))))

;;; ---------------------------------------------------------- Interfaccia utente

(define (run-string src)
  ((compile-seq (parse src)) (make-tape))
  (force-output))

(define (run-file path)
  (run-string (call-with-input-file path get-string-all)))

(define (usage-error)
  (format (current-error-port)
          "uso: bf.scm [--cell-bits=N] [--eof=zero|minus-one|unchanged] PROGRAMMA.bf~%")
  (exit 2))

;; Se arg inizia per prefix ritorna il resto della stringa, altrimenti #f.
(define (flag-value prefix arg)
  (let ((plen (string-length prefix)))
    (and (>= (string-length arg) plen)
         (string=? (substring arg 0 plen) prefix)
         (substring arg plen))))

(define (parse-cell-bits s)
  (let ((n (string->number s)))
    (if (and n (integer? n) (positive? n))
      n
      (begin
        (format (current-error-port) "--cell-bits non valido: ~a~%" s)
        (exit 2)))))

(define (parse-eof-mode s)
  (match s
         ("zero"      'zero)
         ("minus-one" 'minus-one)
         ("unchanged" 'unchanged)
         (_ (format (current-error-port)
                    "--eof non valido: ~a (usa zero, minus-one o unchanged)~%" s)
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
                            "~a: errore di sintassi (riga ~a, colonna ~a): ~a~%"
                            path line col msg)
                    (exit 1))))))
      ((flag-value "--cell-bits=" (car args))
       => (lambda (v) (loop (cdr args) (parse-cell-bits v) eof path)))
      ((flag-value "--eof=" (car args))
       => (lambda (v) (loop (cdr args) bits (parse-eof-mode v) path)))
      (path (usage-error))
      (else (loop (cdr args) bits eof (car args))))))
