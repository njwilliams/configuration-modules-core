#!/usr/bin/perl
# -*- mode: cperl -*-
use strict;
use warnings;
use Test::More;
use Test::Quattor qw(profile_0lines profile_1line);
use NCM::Component::sudo;

=pod

=head1 DESCRIPTION

Tests the generation of privilege lines.

=cut

my $cmp = NCM::Component::sudo->new('sudo');

my $cfg = get_config_for_profile('profile_0lines');

my $l = $cmp->generate_privilege_lines($cfg);

is(scalar(@$l), 0, "No privige lines when empty");

$cfg = get_config_for_profile('profile_1line');

$l = $cmp->generate_privilege_lines($cfg);

is(scalar(@$l), 2, "ALl privilege lines got added");
like($l->[0], qr{opts}, "Options added when present");
unlike($l->[1], qr{opts}, "No options added when present");

done_testing();
