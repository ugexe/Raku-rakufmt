# rakufmt

A small demonstration of a Raku code formatter built on RakuAST.

It is not meant to be a real formatter. It has a handful of rules, a few
options, and no configuration file. It exists to show what RakuAST makes
possible.

## Trying it

```
raku -I. bin/rakufmt examples/messy.raku            # print the formatted file
raku -I. bin/rakufmt --check examples/              # exit 1 if anything would change
raku -I. bin/rakufmt -w some-file.raku              # rewrite in place
raku -I. bin/rakufmt --list-rules
raku -I. bin/rakufmt --help
```

[examples/messy.raku](examples/messy.raku) goes in, and
[examples/tidy.raku](examples/tidy.raku) comes out. An excerpt:

```raku
class Shape {
  has Str $.name;
      has Int $.sides=0;   # how many
  has @.points;  # the corners

    method describe(Str $prefix,Int :$precision=2,Bool :$verbose=False,Str :$unit="cm" --> Str) {
      my $area=self.area.round(10**-$precision);
        my $text = qq:to/END/;
            $prefix $!name
              # not a comment, heredoc text
            area: {$area # a comment inside interpolated code
            } $unit
            END
```

becomes

```raku
class Shape {
    has Str $.name;
    has Int $.sides = 0;  # how many
    has @.points;         # the corners

    method describe(
        Str $prefix,
        Int :$precision = 2,
        Bool :$verbose = False,
        Str :$unit = "cm",
        --> Str
    ) {
        my $area = self.area.round(10 ** -$precision);
        my $text = qq:to/END/;
            $prefix $!name
              # not a comment, heredoc text
            area: {$area # a comment inside interpolated code
            } $unit
            END
```

## Rules

| Rule | What it does |
|---|---|
| `trailing-whitespace` | strips spaces at the end of lines and ends the file with one newline, except inside strings and heredoc bodies |
| `infix-spacing` | one space around infix operators, `=` in declarations and parameter defaults, and `=>`. Ranges stay tight, a line break next to an operator stays, and padding that lines an operator up with a nearby line stays |
| `comma-spacing` | no space before a comma and one after it, in lists, arguments and signatures |
| `signature-wrap` | a routine signature that makes its line longer than `--width` gets one parameter per line |
| `indent` | indents by the blocks and brackets a line is in. A continuation line keeps its offset from the start of its statement. Heredoc bodies, multi-line strings, comments and Pod keep their own indentation |
| `align-comments` | lines up trailing comments on consecutive lines |
| `single-quotes` | off by default: `"..."` with nothing to interpolate or escape becomes `'...'` |

Turn rules on and off with `--enable-rule=single-quotes` and `--disable-rule=indent --disable-rule=align-comments`.

## How it works

1. **Parse.** The file is compiled to a RakuAST tree by Rakudo's own compiler,
   as a compilation unit of its own, so `use v6.e` works.
2. **Find the comments.** [RakuFmt::Source](lib/RakuFmt/Source.rakumod) walks
   the tree and marks the characters that belong to literal text: string
   literals, regex literals and character class elements, Pod and declarator
   docs. Any other `#` starts a comment.
3. **Collect edits.** Each rule in [RakuFmt::Rules](lib/RakuFmt/Rules.rakumod)
   looks at node spans and returns replacements of source ranges. The
   infix rule, for example, replaces the text between the end of an operator's
   left operand and the start of the operator.
4. **Apply, reparse, compare.** The edits are applied and the result is parsed
   again. Its `.DEPARSE` output must be identical to the original's, or the
   rule is refused and nothing is written. The next rule works on the new tree.

## Limitations

- **Parsing runs code.** Compiling a file runs its `BEGIN` blocks and loads the
  modules it `use`s. Point rakufmt at them with `-I lib`. Do not run it on code
  you would not run. Packages a parse leaves behind in loaded modules are
  cleaned up so the file can be parsed again, but a file whose classes are
  already loaded in the rakufmt process, such as rakufmt's own
  `lib/RakuFmt/Rules.rakumod`, cannot be parsed.
- **The file has to compile.** An undeclared variable is a parse error, as it is
  for Rakudo.
- **It is slow on big files.** Every rule that changes something causes a
  reparse. Formatting Rakudo's `lib/Test.rakumod` takes about seven seconds.
- The rules are a sample, not a style guide.

## Tests

```
zef test .
```
