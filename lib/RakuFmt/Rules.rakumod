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

package RakuFmt::Rules {
    my @builtin-rules = (
        RakuFmt::Rule::TrailingWhitespace,
    ).map(*.new);

    #| The rules that come with rakufmt, in the order they run.
    our sub builtin-rules(--> List:D) { @builtin-rules.List }
}
