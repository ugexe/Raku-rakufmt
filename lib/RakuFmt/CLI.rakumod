use v6.e.PREVIEW;
use RakuFmt;
use RakuFmt::Rules;

#| A number of columns, as `val` makes it from the command line. `UInt`
#| would accept `True`, which makes `--indent 2` set `--indent` to `True`
#| and take the 2 as a path.
my subset Columns of IntStr where * >= 0;

#| What is done with a file once it is formatted.
my enum Mode <Print Check>;

#| A file to format, or standard input.
my subset Input where IO::Path:D | IO::Handle:D;

proto sub MAIN(| --> Nil) is export {*}

#| Print the formatted files
multi sub MAIN(
    *@paths,                    #= files or directories, none or - reads stdin
    Columns :$indent = <4>,     #= spaces per indentation level
    Columns :$width = <80>,     #= line width for signature-wrap and align-comments
    :I(:@include),              #= where the modules the files use can be found
    --> Nil
) {
    format-paths @paths, Print, :$indent, :$width, :@include;
}

#| List the files that would change, exit 1 if any
multi sub MAIN(
    *@paths,
    Bool :$check! where .so,
    Columns :$indent = <4>,
    Columns :$width = <80>,
    :I(:@include),
    --> Nil
) {
    format-paths @paths, Check, :$indent, :$width, :@include;
}

sub format-paths(
    @paths,
    Mode:D $mode,
    UInt :$indent,
    UInt :$width,
    :@include,
    --> Nil
) {
    my @rules = RakuFmt::Rules::builtin-rules().grep(*.default);
    my $fmt   = RakuFmt.new(:@rules, :options(:$indent, :$width));
    exit 1 if per-file @paths, :@include, -> $file { format-file $fmt, $mode, $file };
}

#| Returns True if the file would change under --check or could not be
#| formatted.
sub format-file(RakuFmt:D $fmt, Mode:D $mode, Input $file --> Bool:D) {
    my $result = try $fmt.format($file.slurp(:close), :name(name-of($file)));
    without $result {
        note $!.message;
        return True;
    }
    so report $mode, $file, $result
}

multi sub report(Print, Input $, RakuFmt::Result:D $result --> Nil) {
    print $result.formatted;
}

multi sub report(Check, Input $file, RakuFmt::Result:D $result --> Bool:D) {
    say "{name-of($file)} would be reformatted" if $result.changed;
    $result.changed
}

#| Runs C<&handle> on each file C<@paths> names, and returns True if
#| C<&handle> returns something true for any of them.
sub per-file(@paths, &handle, :@include --> Bool:D) {
    # Parsing a file runs its `use` statements, so their modules must be
    # found.
    for @include.reverse {
        CompUnit::RepositoryRegistry.use-repository(
          CompUnit::RepositoryRegistry.repository-for-spec(.IO.absolute));
    }

    my @files = @paths ?? @paths.map(&files-in) !! $*IN;
    my @failed = @files.grep(&handle);
    so @failed
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
