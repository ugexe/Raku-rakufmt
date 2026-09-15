use v6.e.PREVIEW;
use experimental :rakuast;
use RakuFmt::Source;

# RakuFmt::Edit and RakuFmt::Rule depend on each other, so predeclare one.
role RakuFmt::Rule { ... }

#| A replacement of the text in from..^to, and the rule that asked for it.
class RakuFmt::Edit {
    #| Where the replaced text starts, as an offset into the source text.
    has Int:D $.from is required;
    #| Where the replaced text ends. An edit whose `to` is its `from` inserts
    #| text.
    has Int:D $.to is required;
    #| The text that takes the place of from..^to.
    has Str:D $.text is required;
    #| The rule that made the edit.
    has RakuFmt::Rule:D $.rule is required;
    #| Why the rule made the edit, as `--explain` shows it.
    has Str:D $.why is required;
}

#| A formatting rule. It looks at a parsed source and returns edits. Rules
#| never see each other's edits. The formatter reparses between rules.
role RakuFmt::Rule {
    #| The name the rule is chosen by, as in `--enable-rule=indent`.
    method name(--> Str:D) { ... }
    #| A short summary for `--list-rules`.
    method description(--> Str:D) { ... }
    #| True if the rule runs without being asked for by name.
    method default(--> Bool:D) { True }
    #| The edits the rule makes to `$src`. Positions are offsets into
    #| `$src.text`. `%options` holds options such as `indent` and `width`.
    #| An edit that overlaps an earlier one is dropped.
    method edits(RakuFmt::Source:D $src, %options --> Iterable:D) { ... }

    #| An edit that replaces the text in from..^to with `$text`. `$why` is
    #| what `--explain` shows for it.
    method edit(Int:D $from, Int:D $to, Str:D $text, Str:D $why --> RakuFmt::Edit:D) {
        RakuFmt::Edit.new(:$from, :$to, :$text, :rule(self), :$why)
    }
}

#| Strip spaces at the end of lines, and end the file with one newline.
class RakuFmt::Rule::TrailingWhitespace does RakuFmt::Rule {
    method name(--> Str:D) { 'trailing-whitespace' }
    method description(--> Str:D) { 'strip spaces at the end of lines, except inside strings and heredocs' }

    method edits($src, % --> Iterable:D) {
        my $text = $src.text;
        gather {
            for ^$src.line-count -> $line {
                my $end = $src.line-end($line);
                my $start = $end;
                $start-- while $start > $src.line-start($line)
                  && $text.substr($start - 1, 1) eq ' ' | "\t";
                # Trailing spaces in a heredoc body or a multi-line string
                # are part of the string.
                take self.edit($start, $end, '', 'trailing spaces')
                  if $start < $end && !$src.has-literal($start, $end);
            }
            with $text.match(/ \s* $ /) -> $m {
                take self.edit($m.from, $m.to, "\n", 'end with one newline')
                  if $m.Str ne "\n" && !$src.has-literal($m.from, $m.to);
            }
        }
    }
}

#| One space on each side of an infix operator.
class RakuFmt::Rule::InfixSpacing does RakuFmt::Rule {
    method name(--> Str:D) { 'infix-spacing' }
    method description(--> Str:D) { 'one space around infix operators, `=` in declarations and defaults, and `=>` (ranges stay tight)' }

    my constant @tight = '..', '^..', '..^', '^..^';

    method edits($src, % --> Iterable:D) {
        my $text = $src.text;
        # One space between from and the operator at op-from, and between
        # the end of the operator and to, when only horizontal space is
        # there now. A line break next to an operator is the author's layout.
        sub around(Int:D $from, Int:D $op-from, Str:D $op, Int:D $to --> Seq:D) {
            gather for ($from, $op-from), ($op-from + $op.chars, $to) -> ($a, $b) {
                next unless $a <= $b;
                my $gap = $text.substr($a, $b - $a);
                next unless $gap ~~ / ^ \h* $ /;
                # Padding that lines the operator up with the one on the
                # line above or below is kept.
                next if $b == $op-from && $gap.chars > 1 && aligned($src, $op-from, $op);
                take self.edit($a, $b, ' ', "around `$op`") if $gap ne ' ';
            }
        }

        gather {
            for $src.nodes-of(RakuAST::ApplyInfix) -> $apply {
                my $infix = $apply.infix;
                my $left  = $apply.left;
                my $right = $apply.right;
                next unless $infix.origin && $left.origin && $right.origin;
                my $op = $src.text-of($infix);
                next if $op eq any @tight;
                take $_ for around($left.origin.to, $infix.origin.from, $op, $right.origin.from);
            }

            # `my $x=1` and `has $.x=1`. The initializer's span starts at
            # its operator.
            for $src.nodes-of(RakuAST::Initializer::Assign, RakuAST::Initializer::Bind) -> $init {
                my $expression = $init.expression;
                next unless $expression && $expression.origin;
                my $op-from = $init.origin.from;
                my $op = $text.substr($op-from, 2) eq ':=' ?? ':=' !! '=';
                my $from = $op-from;
                $from-- while $from > 0 && $text.substr($from - 1, 1) eq ' ' | "\t";
                take $_ for around($from, $op-from, $op, $expression.origin.from);
            }

            # `:$precision=2` in a signature.
            for $src.nodes-of(RakuAST::Parameter) -> $param {
                my $default = $param.default;
                my $target  = $param.target;
                next unless $default && $default.origin && $target && $target.origin;
                my $gap = $text.substr($target.origin.to, $default.origin.from - $target.origin.to);
                next unless $gap ~~ / ^ \h* '=' \h* $ /;
                my $op-from = $target.origin.to + $gap.index('=');
                take $_ for around($target.origin.to, $op-from, '=', $default.origin.from);
            }

            # `name=>'square'`. The key of a pair is a Str, not a node, so
            # the arrow is found after the key at the start of the span.
            for $src.nodes-of(RakuAST::FatArrow) -> $pair {
                my $value = $pair.value;
                next unless $value && $value.origin;
                my $key-end = $pair.origin.from + $pair.key.chars;
                next unless $text.substr($pair.origin.from, $pair.key.chars) eq $pair.key;
                my $gap = $text.substr($key-end, $value.origin.from - $key-end);
                next unless $gap ~~ / ^ \h* '=>' \h* $ /;
                take $_ for around($key-end, $key-end + $gap.index('=>'), '=>', $value.origin.from);
            }
        }
    }
}

# True if the same operator, after a space, is at the same column on a
# nearby line of the same paragraph.
sub aligned($src, Int:D $op-from, Str:D $op --> Bool:D) {
    my $text   = $src.text;
    my $line   = $src.line-of($op-from);
    my $column = $src.column-of($op-from);
    for -1, 1 -> $direction {
        for 1..3 -> $distance {
            my $l = $line + $direction * $distance;
            last unless 0 <= $l < $src.line-count;
            last unless $text.substr($src.line-start($l), $src.line-end($l) - $src.line-start($l)).trim;
            my $at = $src.line-start($l) + $column;
            return True if $at < $src.line-end($l) && $text.substr($at - 1, $op.chars + 2) eq " $op ";
        }
    }
    False
}

#| No space before a comma, one space after it.
class RakuFmt::Rule::CommaSpacing does RakuFmt::Rule {
    method name(--> Str:D) { 'comma-spacing' }
    method description(--> Str:D) { 'no space before a comma and one after it, in lists, arguments and signatures' }

    method edits($src, % --> Iterable:D) {
        my $text = $src.text;
        gather {
            my @lists;
            @lists.push: $(.operands) for $src.nodes-of(RakuAST::ApplyListInfix)
              .grep({ .infix.origin && $src.text-of(.infix) eq ',' });
            @lists.push: $(.args) for $src.nodes-of(RakuAST::ArgList);
            @lists.push: $(.parameters) for $src.nodes-of(RakuAST::Signature);
            my %seen;
            for @lists -> @items {
                # Implicit parameters such as the invocant have no origin.
                my @real = @items.grep(*.origin);
                for @real.rotor(2 => -1) -> ($a, $b) {
                    my ($from, $to) = $a.origin.to, $b.origin.from;
                    next unless $from < $to && !%seen{$from}++;
                    my $gap = $text.substr($from, $to - $from);
                    if $gap ~~ / ^ \h* ',' \h* $ / {
                        take self.edit($from, $to, ', ', 'comma') if $gap ne ', ';
                    }
                    elsif $gap ~~ / ^ (\h+) ',' / {
                        take self.edit($from, $from + $0.chars, '', 'space before comma');
                    }
                }
            }
        }
    }
}

#| Put each parameter of a signature that makes its line too long on a line
#| of its own.
class RakuFmt::Rule::SignatureWrap does RakuFmt::Rule {
    method name(--> Str:D) { 'signature-wrap' }
    method description(--> Str:D) { 'wrap a routine signature that is too long, one parameter per line' }

    method edits($src, %options --> Iterable:D) {
        my $text  = $src.text;
        my $width = %options<width> // 80;
        my $step  = %options<indent> // 4;
        gather for $src.nodes-of(RakuAST::Routine) -> $routine {
            my $sig = $routine.signature;
            next unless $sig && $sig.origin;
            my ($from, $to) = $sig.origin.from, $sig.origin.to;
            next unless $text.substr($from - 1, 1) eq '(' && $text.substr($to, 1) eq ')';

            my $line = $src.line-of($from);
            next unless $src.line-of($to) == $line;
            next unless $src.line-end($line) - $src.line-start($line) > $width;
            next if $src.has-comment($from, $to);

            my @params = $sig.parameters.grep(*.origin);
            next unless @params >= 2;
            # Only plain comma separated parameters.
            next unless all(@params.rotor(2 => -1).map(-> ($a, $b) {
                $text.substr($a.origin.to, $b.origin.from - $a.origin.to) ~~ / ^ \h* ',' \h* $ /
            }));
            my $returns = $text.substr(@params.tail.origin.to, $to - @params.tail.origin.to).trim;
            next unless $returns eq '' || $returns.starts-with('-->');

            my $base = $text.substr($src.line-start($line)).match(/ ^ \h* /).Str;
            my $pad  = $base ~ ' ' x $step;
            my $new  = "(\n"
              ~ @params.map({ $pad ~ $src.text-of($_) ~ ",\n" }).join
              ~ ($returns ?? "$pad$returns\n" !! '')
              ~ "$base)";
            take self.edit($from - 1, $to + 1, $new,
              "signature of `{$routine.name ?? $src.text-of($routine.name) !! 'anon'}` is longer than $width columns");
        }
    }
}

#| Indent every line by the blocks and brackets it is in.
class RakuFmt::Rule::Indent does RakuFmt::Rule {
    method name(--> Str:D) { 'indent' }
    method description(--> Str:D) { 'indent by nesting depth; continuation lines keep their offset; heredocs, strings and Pod are left alone' }

    method edits($src, %options --> Iterable:D) {
        my $text = $src.text;
        my $step = %options<indent> // 4;

        my @containers = $src.nodes-of(
          RakuAST::Blockoid,
          RakuAST::Circumfix::Parentheses,
          RakuAST::Circumfix::ArrayComposer,
          RakuAST::Circumfix::HashComposer,
        ).grep({
            # A `unit` package has a block with no braces.
            $text.substr(.origin.from, 1) eq any(<{ ( [>)
              && $src.line-of(.origin.from) != $src.line-of(.origin.to - 1)
        });
        my @statements = $src.nodes-of(RakuAST::Statement)
          .grep({ $src.line-of(.origin.from) != $src.line-of(.origin.to - 1) });

        my %delta;
        my %new;
        gather for ^$src.line-count -> $line {
            my $start = $src.line-start($line);
            my $end   = $src.line-end($line);
            my $p = $start;
            $p++ while $p < $end && $text.substr($p, 1) eq ' ' | "\t";
            next if $p == $end;
            %delta{$line} = 0;
            # Heredoc bodies and multi-line strings keep their own
            # indentation.
            next if $src.is-verbatim($start) || $src.is-verbatim($p);

            my $old = $p - $start;
            my @around = @containers.grep({ .origin.from < $p < .origin.to - 1 });
            my $depth = +@around;
            my $closing = so @containers.first({ .origin.to - 1 == $p });

            # The innermost statement that began on an earlier line, unless
            # a block or bracket inside of it holds this line.
            my $statement = @statements
              .grep({ .origin.from < $p < .origin.to })
              .sort({ .origin.to - .origin.from }).head;
            my $inner = @around.sort({ .origin.to - .origin.from }).head;
            my $continuation = !$closing && $statement
              && (!$inner || $inner.origin.from < $statement.origin.from);

            my $first-line = $continuation ?? $src.line-of($statement.origin.from) !! $line;
            my $new = do if !$continuation {
                $depth * $step
            }
            # One element per line in a bracketed list: line up with the
            # first element.
            elsif $inner && $statement.origin.from > $inner.origin.from
              && $statement ~~ RakuAST::Statement::Expression
              && $statement.expression ~~ RakuAST::ApplyListInfix
              && $statement.expression.operands.first({ .origin && .origin.from == $p })
              && $text.substr($src.line-start($first-line), $statement.origin.from - $src.line-start($first-line)).trim eq '' {
                %new{$first-line}
            }
            else {
                max(0, $old + (%delta{$first-line} // 0))
            }
            %delta{$line} = $new - $old;
            %new{$line} = $new;
            take self.edit($start, $p, ' ' x $new,
              $continuation ?? 'continuation line keeps its offset' !! "nesting depth $depth")
              if $new != $old || $text.substr($start, $p - $start).contains("\t");
        }
    }
}

#| Line up the trailing comments of consecutive lines.
class RakuFmt::Rule::AlignComments does RakuFmt::Rule {
    method name(--> Str:D) { 'align-comments' }
    method description(--> Str:D) { 'line up trailing comments on consecutive lines' }

    method edits($src, %options --> Iterable:D) {
        my $text  = $src.text;
        my $width = %options<width> // 80;
        my @trailing = $src.comments.grep(!*.own-line).map(-> $c {
            my $code-end = $c.from;
            $code-end-- while $text.substr($code-end - 1, 1) eq ' ' | "\t";
            %( :comment($c), :$code-end, :line($src.line-of($c.from)),
               :column($src.column-of($code-end)) )
        });
        my @groups;
        for @trailing -> $t {
            if @groups && @groups.tail.tail<line> == $t<line> - 1 {
                @groups.tail.push($t);
            }
            else {
                @groups.push([$t]);
            }
        }
        gather for @groups.grep(* > 1) -> @group {
            my $target = @group.map(*<column>).max + 2;
            # Lining up far to the right is worse than not lining up.
            next if $target > $width;
            for @group -> %t {
                my $spaces = $target - %t<column>;
                my $gap = $text.substr(%t<code-end>, %t<comment>.from - %t<code-end>);
                take self.edit(%t<code-end>, %t<comment>.from, ' ' x $spaces,
                  "align with the comments on lines {@group.head<line> + 1}..{@group.tail<line> + 1}")
                  if $gap ne ' ' x $spaces;
            }
        }
    }
}

#| Use single quotes for a string that interpolates nothing.
class RakuFmt::Rule::SingleQuotes does RakuFmt::Rule {
    method name(--> Str:D) { 'single-quotes' }
    method description(--> Str:D) { q|use '...' for a "..." string with nothing to interpolate or escape| }
    method default(--> Bool:D) { False }

    method edits($src, % --> Iterable:D) {
        gather for $src.nodes-of(RakuAST::QuotedString) -> $q {
            my $literal = $src.text-of($q);
            next unless $literal.starts-with('"') && $literal.ends-with('"') && $literal.chars >= 2;
            my @segments = $q.segments;
            next unless @segments == 1 && @segments[0] ~~ RakuAST::StrLiteral;
            my $inner = @segments[0].origin ?? $src.text-of(@segments[0]) !! next;
            next if $inner ~~ / <[ \\ $ @ % & { } ' " ]> /;
            take self.edit($q.origin.from, $q.origin.to, "'$inner'", 'nothing to interpolate');
        }
    }
}

package RakuFmt::Rules {
    my @builtin-rules = (
        RakuFmt::Rule::TrailingWhitespace,
        RakuFmt::Rule::SingleQuotes,
        RakuFmt::Rule::InfixSpacing,
        RakuFmt::Rule::CommaSpacing,
        RakuFmt::Rule::SignatureWrap,
        RakuFmt::Rule::Indent,
        RakuFmt::Rule::AlignComments,
    ).map(*.new);

    #| The rules that come with rakufmt, in the order they run.
    our sub builtin-rules(--> List:D) { @builtin-rules.List }
}
