use strict;
use warnings;
use DynaLoader;

# usage: seek.pl LIB.dylib SYMBOL SECONDS
my ($lib, $symbol_name, $seconds) = @ARGV;
$ENV{NP_SEEK_SECONDS} = $seconds;
my $handle = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name) or die "no symbol $symbol_name\n";
DynaLoader::dl_install_xsub("main::go", $symbol);
{
    no strict "refs";
    &{"main::go"}();
}
