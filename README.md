# Eight-bit-cell Brainfuck interpreter

Octet is a small interpreter written in [GNU Guile](https://www.gnu.org/software/guile/) Scheme for [Brainfuck](https://esolangs.org/wiki/Brainfuck), an esoteric, minimalist language. A Brainfuck program is a string over just eight one-character commands, operating on an array of memory cells and a single movable pointer:

| Command | Meaning                                                      |
|---------|--------------------------------------------------------------|
| `>`     | move the pointer right                                       |
| `<`     | move the pointer left                                        |
| `+`     | increment the current cell                                   |
| `-`     | decrement the current cell                                   |
| `.`     | output the current cell as a byte                            |
| `,`     | read one byte of input into the current cell                 |
| `[`     | jump past the matching `]` if the current cell is zero       |
| `]`     | jump back to the matching `[` if the current cell is nonzero |

There is nothing else -- no variables, no named functions, no types. All control flow is `[...]` looping over a cell's value, so even simple arithmetic has to be built out of loops. For example, `++++++++[>++++++++<-]>+.` sets the first cell to 8, then loops that 8 times to add 8 to the second cell each time (8 x 8 = 64), moves onto it, adds one more, and prints the result -- 65 is the ASCII code for `A`, so the program outputs `A`.

A few more idioms that show up in most Brainfuck programs:

- `[-]` clears the current cell -- decrementing in a loop until it hits zero, regardless of the starting value, is the idiomatic way to zero a cell without a dedicated "set to zero" command.
- `,.` echoes one byte of input straight back out -- read into the current cell, then print it.
- `[->+<]` moves the current cell's value into the next cell, adding it there and leaving the source at zero -- the building block every larger loop-based arithmetic idiom is assembled from.




## Design

[`octet.scm`](https://github.com/matteogiorgi/octet/blob/main/octet.scm) runs a program in three stages:

1. **parse** -- the source string is turned into an AST. The six primitive commands become symbols, `[...]` loops become nested `(loop . body)` nodes, and unbalanced brackets are rejected with a line/column error instead of being silently tolerated.
2. **compile** -- every AST node is turned into a `tape -> tape` closure once, so instruction dispatch happens at compile time, not on every iteration of a loop.
3. **run** -- the compiled closure is applied to a fresh tape.

The tape (the cell array Brainfuck's `<`/`>` move across) is represented as a Huet-style zipper -- a triple of `(left cur right)` lists -- so moving the pointer is a plain, purely functional `cons`/`uncons`, with no mutable array underneath.

See the comments in `octet.scm` for the details; each section of the file documents the reasoning behind its own design choices.




## Requirements

GNU Guile (tested with 3.0). No third-party dependencies -- only `(ice-9 match)`, `(ice-9 textual-ports)` and `(ice-9 binary-ports)` from Guile's own standard library.




## Usage

The script is directly executable:

```bash
./octet.scm PROGRAM.bf
```

It can also be run explicitly through Guile, telling it to call `main` after loading the file:

```bash
guile -e main -s octet.scm PROGRAM.bf
```

Loading the file into a REPL (`guile -l octet.scm`, or plain `guile octet.scm`) does **not** run `main` -- it only defines everything, so `parse`, `compile-seq` and `run-string` remain usable interactively without side effects.


### Options

| Flag            | Default | Description                                                           |
|-----------------|---------|-------------------------------------------------------------------------|
| `--cell-bits=N` | `8`     | Cell width in bits; cells wrap modulo 2^N.                              |
| `--eof=MODE`    | `zero`  | Behavior of `,` on end-of-input: `zero`, `minus-one`, or `unchanged`.   |

```bash
./octet.scm --cell-bits=16 --eof=unchanged PROGRAM.bf
```

Output (`.`) is always emitted as a single raw byte, regardless of `--cell-bits` -- a wide cell's low byte is what gets printed, matching the convention used by other Brainfuck implementations with cells wider than 8 bits.


### Exit codes

- `0` -- the program ran to completion.
- `1` -- syntax error (unbalanced brackets); reported with the line and column of the offending `[` or `]`.
- `2` -- usage error: missing program file, or an invalid flag value.




## Example

[`hello.bf`](https://github.com/matteogiorgi/octet/blob/main/hello.bf) is a classic Brainfuck "Hello World!" program, included as a smoke test:

```bash
$ ./octet.scm hello.bf
Hello World!
```
