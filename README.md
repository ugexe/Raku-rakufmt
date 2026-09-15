# rakufmt

A small demonstration of a Raku code formatter built on RakuAST.

It is not meant to be a real formatter. It has a handful of rules, a few
options, and no configuration file. It exists to show what RakuAST makes
possible.

## Rules

| Rule | What it does |
|---|---|
| `trailing-whitespace` | strips spaces at the end of lines and ends the file with one newline, except inside strings and heredoc bodies |

## How it works

1. **Parse.** The file is compiled to a RakuAST tree by Rakudo's own compiler,
   as a compilation unit of its own, so `use v6.e` works.
2. **Find the comments.** [RakuFmt::Source](lib/RakuFmt/Source.rakumod) walks
   the tree and marks the characters that belong to literal text: string
   literals, regex literals and character class elements, Pod and declarator
   docs. Any other `#` starts a comment.
3. **Collect edits.** Each rule in [RakuFmt::Rules](lib/RakuFmt/Rules.rakumod)
   looks at node spans and returns replacements of source ranges.
4. **Apply, reparse, compare.** The edits are applied and the result is parsed
   again. Its `.DEPARSE` output must be identical to the original's, or the
   rule is refused and nothing is written. The next rule works on the new tree.

## Tests

```
zef test .
```
