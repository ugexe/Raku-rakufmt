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

package RakuFmt::Rules {
    my @builtin-rules = (
        RakuFmt::Rule::TrailingWhitespace,
        RakuFmt::Rule::InfixSpacing,
        RakuFmt::Rule::CommaSpacing,
        RakuFmt::Rule::SignatureWrap,
    ).map(*.new);

    #| The rules that come with rakufmt, in the order they run.
    our sub builtin-rules(--> List:D) { @builtin-rules.List }
}
