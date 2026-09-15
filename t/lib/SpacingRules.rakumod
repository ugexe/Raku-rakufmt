use v6.e.PREVIEW;
use RakuFmt::Rules;

unit module SpacingRules;

sub outside-comments($src, @matches --> Seq:D) {
    @matches.grep: -> $m { !$src.has-literal($m.from, $m.to) && !$src.comments.first({ .from <= $m.from < .to }) }
}

class SemicolonSpacing does RakuFmt::Rule is export {
    method name(--> Str:D) { 'semicolon-spacing' }
    method description(--> Str:D) { 'no space before a semicolon' }
    method default(--> Bool:D) { False }

    method edits($src, % --> Iterable:D) {
        outside-comments($src, $src.text.match(/ \h+ <?before ';'> /, :g))
          .map({ self.edit(.from, .to, '', 'space before a semicolon') })
    }
}

class ParenSpacing does RakuFmt::Rule is export {
    method name(--> Str:D) { 'paren-spacing' }
    method description(--> Str:D) { 'no space just inside parentheses' }

    method edits($src, % --> Iterable:D) {
        outside-comments($src, $src.text.match(/ <?after '('> \h+ | \h+ <?before ')'> /, :g))
          .map({ self.edit(.from, .to, '', 'space inside parentheses') })
    }
}

class NotExported does RakuFmt::Rule {
    method name(--> Str:D) { 'not-exported' }
    method description(--> Str:D) { 'a rule the module does not export' }
    method edits($, % --> Iterable:D) { () }
}
