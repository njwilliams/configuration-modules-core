#!/usr/bin/perl
# -*- mode: cperl -*-
use strict;
use warnings;
use Test::More;
use Test::Quattor;
use NCM::Component::metaconfig;
use CAF::Object;

eval {use JSON::Any};
plan skip_all => "JSON::Any not found" if $@;

$CAF::Object::NoAction = 1;


=pod

=head1 DESCRIPTION

Test that a JSON config file can be generated by this component.

=cut


my $cmp = NCM::Component::metaconfig->new('metaconfig');

my $cfg = {
	   owner => 'root',
	   group => 'root',
	   mode => 0644,
	   contents => {
			foo => 1,
			bar => 2,
			baz => {
				a => [0..3]
				}
			},
	   daemon => ['httpd'],
	   module => "json",
	  };

my $restart = 1;

no warnings 'redefine';
*NCM::Component::metaconfig::needs_restarting = sub {
    return $restart;
};
use warnings 'redefine';

$cmp->handle_service("/foo/bar", $cfg);

my $fh = get_file("/foo/bar");

isa_ok($fh, "CAF::FileWriter", "Correct class");
my $js = JSON::Any->Load("$fh");
is($js->{foo}, 1, "JSON file correctly created and reread");
is($cmp->{daemons}->{'httpd'}, 1, "File marks httpd for restarting");

$restart = 0;

$cfg->{daemon} = 'foo';

$cmp->handle_service("/foo/bar", $cfg);
ok(!exists($cmp->{daemon}->{foo}), "The daemon won't be restarted");

done_testing();
