use v6.e.PREVIEW;
use nqp;
use experimental :rakuast;

#| A comment found in the source: plain `#` to the end of the line, or an
#| embedded `#`(...)` comment.
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
    has Int:D @!line-starts;

    submethod TWEAK(--> Nil) {
        $!ast := parse-ast($!text, $!name);
        @!line-starts = 0, |$!text.indices("\n").map(* + 1);
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
              | RakuAST::Regex::Literal
              | RakuAST::Doc::Block
              | RakuAST::Doc::Declarator {
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
            my $to = embedded-comment-end($text, $at)
              // ($text.index("\n", $at) // $text.chars);
            @!comments.push: RakuFmt::Comment.new(:from($at), :$to);
            $pos = $to;
        }
    }

    # `#`(...)`, `#`[[...]]` and friends: the opener may be repeated, and
    # the comment ends at the same number of closers.
    sub embedded-comment-end(Str:D $text, Int:D $at --> Int) {
        return Nil unless $text.substr($at + 1, 1) eq '`';
        my constant %pairs = '(' => ')', '[' => ']', '{' => '}', '<' => '>',
          '«' => '»', '「' => '」';
        my $open = $text.substr($at + 2, 1);
        my $close = %pairs{$open} // return Nil;
        my $count = 1;
        $count++ while $text.substr($at + 2 + $count, 1) eq $open;
        my $opener = $open x $count;
        my $closer = $close x $count;
        my int $depth = 1;
        my int $pos = $at + 2 + $count;
        while $pos < $text.chars {
            if $text.substr($pos, $count) eq $opener { ++$depth; $pos += $count }
            elsif $text.substr($pos, $count) eq $closer {
                return $pos + $count unless --$depth;
                $pos += $count;
            }
            else { ++$pos }
        }
        $text.chars
    }

    #| The source text of a node.
    method text-of(RakuAST::Node:D $node --> Str:D) {
        my $o = $node.origin;
        $!text.substr($o.from, $o.to - $o.from)
    }

    #| True if any character in from..^to is literal text.
    method has-literal(Int:D $from, Int:D $to --> Bool:D) {
        ($from ..^ $to).first({ $!literal[$_] }).defined
    }

    method line-count(--> Int:D) { +@!line-starts }

    method line-start(Int:D $line --> Int:D) { @!line-starts[$line] }

    #| Position of the newline ending a line, or the end of the text.
    method line-end(Int:D $line --> Int:D) {
        $line < @!line-starts.end ?? @!line-starts[$line + 1] - 1 !! $!text.chars
    }

    #| Nodes of any of the given types.
    method nodes-of(*@types --> Seq:D) {
        @!nodes.grep(-> $n { @types.first({ $n ~~ $_ }, :k).defined })
    }
}
