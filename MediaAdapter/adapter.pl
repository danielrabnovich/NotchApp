#!/usr/bin/perl
# Usage: adapter.pl <path-to-MediaAdapter.dylib> stream|send
use strict;
use DynaLoader;
my ($lib, $fn) = @ARGV;
my $handle = DynaLoader::dl_load_file($lib, 0) or die "load failed: " . DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($handle, "adapter_$fn") or die "no symbol adapter_$fn";
DynaLoader::dl_install_xsub("main::run", $sym);
run();
