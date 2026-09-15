use v6.e.PREVIEW;
use RakuFmt;
use RakuFmt::Rules;

#| The name of a rule, as --list-rules shows it.
my subset RuleName of Str where * eq any RakuFmt::Rules::builtin-rules().map(*.name);

#| The names given by the repeated uses of an option such as --enable-rule.
#| An option that is not given binds the type object, which has no names to
#| check.
my subset RuleNames of Positional where { !.defined || .all ~~ RuleName };

#| A number of columns, as `val` makes it from the command line. `UInt`
#| would accept `True`, which makes `--indent 2` set `--indent` to `True`
#| and take the 2 as a path.
my subset Columns of IntStr where * >= 0;

#| What is done with a file once it is formatted.
my enum Mode <Print Check Write Explain>;

#| A file to format, or standard input.
my subset Input where IO::Path:D | IO::Handle:D;

proto sub MAIN(|args --> Nil) is export {
    my $*MAIN-ARGS = args;
    {*}
}

#| Print the formatted files
multi sub MAIN(
    *@paths,                    #= files or directories, none or - reads stdin
    RuleNames :$enable-rule,    #= also run this rule, see --list-rules
    RuleNames :$disable-rule,   #= do not run this rule
    Columns :$indent = <4>,     #= spaces per indentation level
    Columns :$width = <80>,     #= line width for signature-wrap and align-comments
    :I(:@include),              #= where the modules the files use can be found
    --> Nil
) {
    format-paths @paths, Print, :$enable-rule, :$disable-rule, :$indent, :$width, :@include;
}

#| List the files that would change, exit 1 if any
multi sub MAIN(
    *@paths,
    Bool :$check! where .so,
    Bool :$explain,
    RuleNames :$enable-rule,
    RuleNames :$disable-rule,
    Columns :$indent = <4>,
    Columns :$width = <80>,
    :I(:@include),
    --> Nil
) {
    format-paths @paths, Check, :$explain, :$enable-rule, :$disable-rule, :$indent, :$width, :@include;
}

#| Rewrite the files in place
multi sub MAIN(
    *@paths,
    Bool :w(:$write)! where .so,
    Bool :$explain,
    RuleNames :$enable-rule,
    RuleNames :$disable-rule,
    Columns :$indent = <4>,
    Columns :$width = <80>,
    :I(:@include),
    --> Nil
) {
    format-paths @paths, Write, :$explain, :$enable-rule, :$disable-rule, :$indent, :$width, :@include;
}

#| List every edit with the rule that made it
multi sub MAIN(
    *@paths,
    Bool :$explain! where .so,
    RuleNames :$enable-rule,
    RuleNames :$disable-rule,
    Columns :$indent = <4>,
    Columns :$width = <80>,
    :I(:@include),
    --> Nil
) {
    format-paths @paths, Explain, :explain, :$enable-rule, :$disable-rule, :$indent, :$width, :@include;
}

#| Show the rules
multi sub MAIN(Bool :$list-rules! where .so --> Nil) {
    for RakuFmt::Rules::builtin-rules() {
        say sprintf '  %-20s %s%s', .name, .description, .default ?? '' !! ' (off by default)';
    }
}

sub format-paths(
    @paths,
    Mode:D $mode,
    Bool :$explain,
    RuleNames :$enable-rule,
    RuleNames :$disable-rule,
    UInt :$indent,
    UInt :$width,
    :@include,
    --> Nil
) {
    my @rules = RakuFmt::Rules::builtin-rules().grep({ (.default || .name ∈ $enable-rule) && .name ∉ $disable-rule });
    my $fmt   = RakuFmt.new(:@rules, :options(:$indent, :$width));
    exit 1 if per-file @paths, :@include, -> $file { format-file $fmt, $mode, $file, :$explain };
}

#| Returns True if the file would change under --check or could not be
#| formatted.
sub format-file(RakuFmt:D $fmt, Mode:D $mode, Input $file, Bool :$explain --> Bool:D) {
    my $result = try $fmt.format($file.slurp(:close), :name(name-of($file)));
    without $result {
        note $!.message;
        return True;
    }
    explain name-of($file), $result if $explain;
    so report $mode, $file, $result
}

multi sub report(Print, Input $, RakuFmt::Result:D $result --> Nil) {
    print $result.formatted;
}

multi sub report(Check, Input $file, RakuFmt::Result:D $result --> Bool:D) {
    say "{name-of($file)} would be reformatted" if $result.changed;
    $result.changed
}

multi sub report(Write, IO::Handle:D $, RakuFmt::Result:D $result --> Nil) {
    print $result.formatted;
}

multi sub report(Write, IO::Path:D $file, RakuFmt::Result:D $result --> Nil) {
    $file.spurt($result.formatted) if $result.changed;
}

multi sub report(Explain, Input $, RakuFmt::Result:D $ --> Nil) { }

#| Runs C<&handle> on the one file C<@paths> names, and returns True if
#| C<&handle> returns something true. Several files are each handled by a
#| process of their own, and True is returned if any of those fail.
sub per-file(@paths, &handle, :@include --> Bool:D) {
    my @raku = $*EXECUTABLE.absolute,
      |$*REPO.repo-chain.grep(CompUnit::Repository::FileSystem).map({ '-I' ~ .prefix.absolute });

    # Parsing a file runs its `use` statements, so their modules must be
    # found.
    for @include.reverse {
        CompUnit::RepositoryRegistry.use-repository(
          CompUnit::RepositoryRegistry.repository-for-spec(.IO.absolute));
    }

    my @files = @paths ?? @paths.map(&files-in) !! $*IN;
    return so handle(@files.head) if @files == 1;

    # Parsing a file runs its BEGIN time code, which leaves its packages
    # behind for the files parsed after it.
    my @options = command-line-options($*MAIN-ARGS.hash);
    my @failed  = @files.grep: { run(|@raku, $*PROGRAM.absolute, |@options, '--', argument-of($_)).exitcode };
    so @failed
}

#| MAIN's named arguments, written back as command line options.
sub command-line-options(%named --> Seq:D) {
    %named.map: -> (:key($name), :$value) {
        |$value.map: { $_ ~~ Bool ?? ($_ ?? "--$name" !! "--/$name") !! "--$name=$_" }
    }
}

multi sub files-in('-' --> IO::Handle:D) { $*IN }
multi sub files-in(Str:D $path where *.IO.d --> Slip:D) { raku-files($path.IO).sort.Slip }
multi sub files-in(Str:D $path --> IO::Path:D) { $path.IO }

sub raku-files(IO::Path:D $dir --> Seq:D) {
    $dir.dir.map({
        .d ?? raku-files($_).Slip
           !! .extension eq any(<raku rakumod rakutest>) ?? $_ !! Empty
    })
}

multi sub name-of(IO::Handle:D $ --> Str:D) { '<stdin>' }
multi sub name-of(IO::Path:D $file --> Str:D) { ~$file }

multi sub argument-of(IO::Handle:D $ --> Str:D) { '-' }
multi sub argument-of(IO::Path:D $file --> Str:D) { ~$file }

sub explain(Str:D $name, RakuFmt::Result:D $result --> Nil) {
    for $result.steps -> (:source($src), :@edits) {
        for @edits {
            my $before = $src.text.substr(.from, .to - .from);
            say sprintf '%s:%d:%d [%s] %s: %s -> %s', $name,
              $src.line-of(.from) + 1, $src.column-of(.from) + 1,
              .rule.name, .why, shorten($before), shorten(.text);
        }
    }
}

sub shorten(Str:D $s --> Str:D) {
    my $r = $s.raku;
    $r.chars > 50 ?? $r.substr(0, 47) ~ '..."' !! $r
}
