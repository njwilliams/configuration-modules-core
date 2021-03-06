# ${license-info}
# ${developer-info}
# ${author-info}


package NCM::Component::nrpe;

use strict;
use warnings;
use NCM::Component;
use EDG::WP4::CCM::Property;
use NCM::Check;
use CAF::FileWriter;
use CAF::Process;
use LC::Exception qw (throw_error);

our @ISA = qw (NCM::Component);
our $EC = LC::Exception::Context->new->will_store_all;

use constant PATH => '/software/components/nrpe/options/';
use constant FILE => '/etc/nagios/nrpe.cfg';

sub Configure {
    my ($self, $config) = @_;
    my $st = $config->getElement (PATH)->getTree;

    # Open file
    my $fw = CAF::FileWriter->open (FILE, log => $self);

    # Output caution header
    print $fw ("# /etc/nagios/nrpe.cfg\n");
    print $fw ("# written by ncm-nrpe. Do not edit!\n");

    # Output unreferenced options
    while (my ($key, $value) = each (%{$st})) {
      print $fw ("$key=$value\n") unless (ref($value) eq "ARRAY" || ref($value) eq "HASH");
    }

    # Output allowed_hosts array as a comma separated string
    print $fw ("allowed_hosts=" . join (",", @{$st->{allowed_hosts}}) . "\n");

    # Output nrpe_commands
    while (my ($cmdname, $cmdline) = each (%{$st->{command}})) {
        print $fw ("command[$cmdname]=$cmdline\n");
    }

    # Output external files' includes
    foreach my $fn (@{$st->{include}}) {
        print $fw ("include=$fn\n");
    }

    # Output directory includes
    foreach my $dn (@{$st->{include_dir}}) {
        print $fw ("include_dir=$dn\n");
    }

    # Close the output file
    $fw->close ();

    # Restart daemon
    my $proc = CAF::Process->new ([qw(/sbin/service nrpe restart)], log => $self);
    $proc->execute ();

    if ($?) {
	$self->error("Failed to restart NRPE");
	return 0;
    }

    # Success
    return 1;
}

1;
