use v6.e.PREVIEW;

#| A shape with a name
class Shape {   
  has Str $.name;
      has Int $.sides=0;   # how many
  has @.points;  # the corners

    method describe(Str $prefix,Int :$precision=2,Bool :$verbose=False,Str :$unit="cm" --> Str) {
      my $area=self.area.round(10**-$precision);
        my $text = qq:to/END/;
            $prefix $!name   
              # not a comment, heredoc text
            area: {$area # a comment inside interpolated code
            } $unit
            END
      $text ~= "  (verbose)   " if $verbose;
     return $text;
    }

  method area { 0 }
}

sub matches-hash(Str $s) {
    # A `#` inside a regex literal or a character class is not a comment
  so $s ~~ / \# <[#]> '#' # but this one is
  /
}

my @shapes = [
Shape.new(name => "triangle",sides => 3),
    Shape.new(name=>'square' , sides=>4),
];

for @shapes -> $shape {
say $shape.describe("Shape:",:verbose);   #`( an embedded
 comment )
    say "sides: " ~ $shape.sides*2 div 2;
}
say matches-hash("#x#");   
say 1..10;


