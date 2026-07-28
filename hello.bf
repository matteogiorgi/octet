[
  Prints "Hello World!" followed by a newline.

  This whole bracketed block is a no-op: cell #0 starts at zero, so the
  loop guard below is false immediately and the loop body -- including
  every character in this comment -- is skipped without ever running.
  Anything that isn't one of ><+-.,[] is simply ignored by the parser
  wherever it appears, but wrapping it in a loop like this means it is
  never even reached, which is the idiomatic way to write a Brainfuck
  comment block.

  Six cells are used as scratch space. Right before the first '.' runs,
  they hold 72, 104, 88, 32, 8 -- the first one (72) is 'H', printed as
  is. The '.' commands below revisit the others more than once, adding
  to or subtracting from each cell to reach the exact byte needed for
  every remaining letter, rather than computing each letter from scratch.
]
++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.
>>.<-.<.+++.------.--------.>>+.>++.
