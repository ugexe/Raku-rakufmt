use v6.e.PREVIEW;
use nqp;
use experimental :rakuast;

#| A comment found in the source: a `#` and the rest of its line.
class RakuFmt::Comment {
    has Int:D $.from is required;
    has Int:D $.to   is required;
}

#| A source file parsed into a RakuAST tree, with the lookups rules need to
#| relate nodes back to the text they came from. Rules receive one in
#| `edits`, and the formatter parses a new one after each rule that changes
#| the text.
class RakuFmt::Source {
    has Str:D $.text is required;
    has Str:D $.name = '<input>';
    has RakuAST::CompUnit $.ast;
    #| Every node with an origin, parents before children, each node once.
    has RakuAST::Node:D @.nodes;
    has RakuFmt::Comment:D @.comments;
    #| One byte per character of the text, set where the character is literal
    #| text. A `#` there does not start a comment.
    has buf8 $!literal;

    submethod TWEAK(--> Nil) {
        $!ast := parse-ast($!text, $!name);
        $!literal = buf8.allocate($!text.chars);
        self!walk($!ast, my %seen);
        self!scan-comments;
    }

    # A standalone compilation unit rather than Str.AST, which is an EVAL
    # and so refuses a `use v6.e` at the top of the file.
    sub parse-ast(Str:D $text, Str:D $name --> RakuAST::CompUnit:D) {
        # A CATCH block would run while the silenced $*ERR is still in
        # effect, so report the failure after leaving its scope.
        my $ast = try compile-quietly($text);
        my $error = $!;
        die "Could not parse $name:\n" ~ $error.message.indent(4) unless $ast;
        $ast
    }

    sub compile-quietly(Str:D $text --> RakuAST::CompUnit:D) {
        # Compile-time worries (e.g. "useless use") are the compiler's
        # business, not the formatter's.
        my $null = open($*SPEC.devnull, :w);
        LEAVE $null.close;
        my $*ERR = $null;
        temp $PROCESS::ERR = $null;
        nqp::getcomp('Raku').compile(
          $text,
          :target<ast>,
          :compunit_ok(1),
          :grammar(nqp::gethllsym('Raku', 'Grammar')),
          :actions(nqp::gethllsym('Raku', 'Actions')),
        )
    }

    method !walk(RakuAST::Node:D $node, %seen --> Nil) {
        return if %seen{$node.WHICH}++;
        my $origin = $node.origin;
        @!nodes.push($node) if $origin;

        given $node {
            # Text the author typed as data. A `#` in here never starts a
            # comment.
            when RakuAST::StrLiteral
              | RakuAST::Regex::Literal {
                self!mark($origin, 1) if $origin;
            }
            when .^name.starts-with('RakuAST::Regex::CharClassEnumerationElement') {
                self!mark($origin, 1) if $origin;
            }
        }

        $node.visit-children(-> $child { self!walk($child, %seen) });
    }

    method !mark(RakuAST::Origin:D $origin, Int:D $value --> Nil) {
        $!literal[$_] = $value for $origin.from ..^ $origin.to;
    }

    method !scan-comments(--> Nil) {
        my $text := $!text;
        my int $pos = 0;
        loop {
            my $at = $text.index('#', $pos) // last;
            if $!literal[$at] {
                $pos = $at + 1;
                next;
            }
            my $to = $text.index("\n", $at) // $text.chars;
            @!comments.push: RakuFmt::Comment.new(:from($at), :$to);
            $pos = $to;
        }
    }
}
