use v6.e.PREVIEW;
use RakuFmt::Source;
use RakuFmt::Rules;

#| The text one rule saw and the edits it made to it.
class RakuFmt::Step {
    has RakuFmt::Source:D $.source is required;
    has RakuFmt::Edit:D @.edits;
}

#| The formatted text and the edits that produced it, per rule.
class RakuFmt::Result {
    has Str:D $.original is required;
    has Str:D $.formatted is required;
    #| A step for each rule that changed something, in the order they ran.
    has RakuFmt::Step:D @.steps;
    method changed(--> Bool:D) { $!original ne $!formatted }
}

class X::RakuFmt::MeaningChanged is Exception {
    has Str:D $.name is required;
    has RakuFmt::Rule:D $.rule is required;
    method message(--> Str:D) {
        "rakufmt: rule '{$!rule.name}' would change what $!name means, nothing was written"
    }
}

class RakuFmt {
    #| Rules to run, in the order they run.
    has RakuFmt::Rule:D @.rules = RakuFmt::Rules::builtin-rules().grep(*.default);
    has %.options = :indent(4), :width(80);

    method rule-names(--> List:D) { RakuFmt::Rules::builtin-rules().map(*.name).List }

    method format(Str:D $text, Str:D :$name = '<input>' --> RakuFmt::Result:D) {
        my $src = RakuFmt::Source.new(:$text, :$name);
        my $meaning = $src.ast.DEPARSE;
        my @steps;
        for @!rules -> $rule {
            my @edits = non-overlapping($rule.edits($src, %!options));
            next unless @edits;
            my $next = RakuFmt::Source.new(:text(apply($src.text, @edits)), :$name);

            # The reformatted file must parse to a tree that deparses exactly
            # like the original.
            X::RakuFmt::MeaningChanged.new(:$name, :$rule).throw
              unless $next.ast.DEPARSE eq $meaning;

            @steps.push: RakuFmt::Step.new(:source($src), :@edits);
            $src = $next;
        }
        RakuFmt::Result.new(:original($text), :formatted($src.text), :@steps)
    }

    sub non-overlapping(@edits --> Seq:D) {
        my $end = -1;
        gather for @edits.sort({ .from, .to }) {
            next if .from < $end || (.from == .to && .from == $end);
            take $_;
            $end = .to;
        }
    }

    sub apply(Str:D $text, @edits --> Str:D) {
        my $out = $text;
        for @edits.sort(-*.from) {
            $out = $out.substr(0, .from) ~ .text ~ $out.substr(.to);
        }
        $out
    }
}
