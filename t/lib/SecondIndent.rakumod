use v6.e.PREVIEW;
use RakuFmt::Rules;

unit module SecondIndent;

class Indent does RakuFmt::Rule is export {
    method name(--> Str:D) { 'indent' }
    method description(--> Str:D) { 'a second rule named indent' }
    method edits($, % --> Iterable:D) { () }
}
