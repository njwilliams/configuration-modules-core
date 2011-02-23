# ${license-info}
# ${developer-info}
# ${author-info}


package NCM::Component::accounts;

use strict;
use warnings;

use NCM::Component;

use LC::Exception;
use EDG::WP4::CCM::Element;
use CAF::FileWriter;
use CAF::FileEditor;
use CAF::Process;
use Fcntl qw(SEEK_SET);
use File::Basename;
use File::Path;
use LC::Find;
use LC::File qw(copy makedir);


our @ISA = qw(NCM::Component);
our $EC=LC::Exception::Context->new->will_store_all;

our $NoActionSupported = 1;

# Commands we might run. We'll resort always to libusers' variants.

# Adding users. We don't want their home directories created. The
# component will take care of it, as we'll have to copy the files from
# /etc/skel anyways.
use constant USERADD => qw(lnewusers -M);

# Deleting users. We don't want their home directories removed, just
# in case.
use constant USERDEL => qw(luserdel -G);


# Adding groups
use constant GROUPADD => "lgroupadd";

# Deleting groups
use constant GROUPDEL => "lgroupdel";

# Changing passwords
use constant CHPASSWD => qw(chpasswd -e);

# Changing user properties
use constant USERMOD => 'usermod';

# Modifying the UID of an account
use constant CHUID => (USERMOD, "-u");

# Changing group properties
use constant GROUPMOD => qw(lgroupmod -g);

# Change the shell for root
use constant CHROOTSHELL => qw(lusermod root -s);

# UID for user structures, GID for group structures.
use constant ID => 2;
# List of groups for users, list of members for groups.
use constant IDLIST => 3;
# Name of the group or user
use constant NAME => 0;
# Home directory of the user
use constant HOME => 5;
# Shell
use constant SHELL => 6;
# GCOS
use constant GCOS => 4;
# Home directory, on getpw* output
use constant PWHOME => 7;

use constant EXTRA_FIELD => 9;

# Pan path for the component configuration.
use constant PATH => "/software/components/accounts";

use constant PASSWD_FILE => "/etc/passwd";
use constant GROUP_FILE => "/etc/group";
use constant LOGINDEFS_FILE => "/etc/login.defs";

use constant GIDPARAM => '-g';
use constant SKELDIR => "/etc/skel";

# Parameters for usermod
use constant GROUPSOPT => '-G';
use constant HOMEOPT => '-d';
use constant MOVEHOMEOPT => '-m';
use constant SHELLOPT => '-s';
use constant GCOSOPT => '-c';
use constant IDOPT => '-u';

# Stupid replacement for getpwent and getgrent. It expects a file name
# as its argument, typically either /etc/passwd or /etc/group.
#
# It returns a function which will return one entry per call, a la
# getpwent or getgrent, but without considering all the LDAP accounts.
sub wrap_getent
{
    my ($self, $file) = @_;
    my $fh = CAF::FileEditor->new($file, log => $self);
    $fh->cancel();
    seek($fh, 0, SEEK_SET);

    return sub {
	my $l = <$fh>;
	defined $l or return;
	chomp($l);
	$self->debug (4, "Read line: $l");
	return split(":", $l);
    };
}

# Returns all the system elements, either groups or users. To do so,
# it receives a reference to either getpwent or getgrent as its
# argument.
sub list_system_members
{
    my ($self, $func) = @_;

    my %h;

    while (my @i = $func->()) {
	$h{$i[NAME]} = { system => \@i,
			 to_delete => 1};
    }
    return %h;
}

# Returns whether the existing group must be modified. Receives as
# arguments the group definition in the profile and a reference to the
# output of getgr() for that group.
sub must_modify_group
{
    my ($self, $profile, $system) = @_;

    $self->debug(2, "Profile: ", join(" ", %$profile),
		 " System: ", join(" ", @$system));
    return exists($profile->{gid}) &&
	($profile->{gid} != $system->[ID]);
}

# Returns whether the existing user must be modified. Receives as
# arguments the user definition in the profile, and a reference to the
# output of getpw() for that account.
sub must_modify_user
{
    my ($self, $profile, $system) = @_;

    $self->debug(2, "Checking for changes on account: ",
		 "Home: $system->[HOME]",
		 " comment: $system->[GCOS]",
		 " id: $system->[ID]",
		 " shell:  $system->[SHELL]",
		 " groups: ", keys(%{$system->[EXTRA_FIELD]}));
    $self->debug(2, "Profile specifies: ",
		 $profile->{homeDir} ? "Home: $profile->{homeDir}" : "");

    return 1 if defined($profile->{uid}) && $profile->{uid} != $system->[ID];
    return 1 if defined($profile->{comment}) &&
	$profile->{comment} ne $system->[GCOS];
    return 1 if defined($profile->{homeDir}) &&
	$profile->{homeDir} ne $system->[HOME];
    return 1 if defined($profile->{shell}) &&
	$profile->{shell} ne $system->[SHELL];

    foreach my $i (@{$profile->{groups}}) {
	return 1 if !$system->[EXTRA_FIELD]->{$i}--;
    }

    return grep($_, values(%{$system->[EXTRA_FIELD]}));
}

# Returns the same hash reference as the input, as a sorted list of
# elements [ $hash_key, $hash_value ]
sub sort_hash
{
    my ($self, $h) = @_;

    my @r;

    while (my ($k, $v) = each(%$h)) {
	push(@r, [$k, $v]);
    }

    return sort({$b->[0] cmp $a->[0]} @r);
}

# Returns true if the system account $sys belongs to the pool
# described to the profile account $pf. That is:
#
# - $pf belongs to a pool (and has a poolStart field)
# - $sys is $pf' base name plus a few digits
# - The number of the account is in an acceptable range.
sub belong_to_pool
{
    my ($self, $pf, $sys) = @_;

    return exists($pf->[1]->{poolStart}) &&
	($sys->[0] =~ m{^$pf->[0](\d{$pf->[1]->{poolDigits}})$}) &&
	    (($1 >= $pf->[1]->{poolStart}) &&
		 ($1 < ($pf->[1]->{poolStart} + $pf->[1]->{poolSize})));
}

# Returns whether the pool in the system should be modified because it
# doesn't match the description in the profile. For now, this only
# means the UIDs have changed.
sub must_modify_pool
{
    my ($self, $pf, $sys) = @_;

    return 0 unless exists($pf->[1]->{uid});

    $sys->[0] =~ m{(\d+)$};

    if ($1 - $pf->[1]->{poolStart} + $pf->[1]->{uid} !=
	    $sys->[1]->{system}->[ID]) {
	return 1;
    }
    return 0;
}

# Returns three structures with the users that need actions, as it
# happens with classify_groups It considers pool accounts as well.
sub classify_accounts
{
    my ($self, $accounts, $protected, $profile) = @_;

    my ($delete, $create, $modify);
    $modify = {};
    $create = {};
    my @sys = $self->sort_hash($accounts);
    my @pf = $self->sort_hash($profile);

    my $i = pop(@pf);
    my $j = pop(@sys);
    my $was_in_pool = 0;

    $self->verbose(join(" ", map($_->[0], @pf)));
    $self->verbose(join(" ", keys(%$protected)));


    while ($i || $j) {
	if ($i && $j) {
	    $self->debug(2, "Profile: $i->[0], system: $j->[0]");
	    if ($i->[0] eq $j->[0]) {
		if ($self->must_modify_user($i->[1], $j->[1]->{system})) {
		    $self->verbose("Account $i->[0] must be modified");
		    $modify->{$i->[0]} = $i->[1];
		} else {
		    $self->verbose("Nothing to do account $i->[0]");
		}
		$self->debug(2, "Removing the next element out of both arrays");
		$i = pop(@pf);
		$j = pop(@sys);
	    } elsif ($self->belong_to_pool($i, $j)) {
		if ($self->must_modify_pool($i, $j)) {
		    $self->verbose("Modifying pool $i->[0]");
		    push(@$delete, $j->[0]);
		    $create->{$i->[0]} = $i->[1];
		}
		$j = pop(@sys);
		$was_in_pool = 1;
	    } elsif ($i->[0] lt $j->[0]) {
		if ($was_in_pool) {
		    $self->verbose("Finished pool $i->[0]");
		    $was_in_pool = 0;
		} else {
		    $self->verbose("Account $i->[0] must be created");
		    $create->{$i->[0]} = $i->[1] unless $was_in_pool;
		}
		$i = pop(@pf);
	    } else {
		if (!exists($protected->{$j->[0]})) {
		    $self->verbose("Account $j->[0] may be deleted");
		    push(@$delete, $j->[0]);
		}
		$j = pop(@sys);
	    }
	} elsif ($i) {
	    $self->verbose("Past the end of system accounts, adding $i->[0]");
	    $create->{$i->[0]} = $i->[1];
	    $i = pop(@pf);
	} else {
	    $self->verbose("Past the end of profile accounts");
	    if (!exists($protected->{$j->[0]})) {
		push(@$delete, $j->[0]);
		$self->verbose("removing $j->[0]");
	    }
	    $j = pop(@sys);
	}
    }

    return ($modify, $delete, $create);
}


# Returns three structures with the groups that need some actions
# (modification, deletion, creation). It receives as arguments the
# existing groups, those which must NOT be removed no matter what and
# the entities present in the profile.
sub classify_groups
{
    my ($self, $groups, $protected, $profile) = @_;

    my ($modify, $delete, $create);

    while (my ($k, $v) = each(%$profile)) {
	if (exists($groups->{$k})) {
	    $groups->{$k}->{to_delete} = 0;
	    push(@$modify, {system => $groups->{$k}->{system},
			    profile => $v})
		if $self->must_modify_group($v, $groups->{$k}->{system});
	} else {
	    $create->{$k} = $v;
	}
    }

    while (my ($k, $v) = each(%$groups)) {
	push(@$delete, $k) if $v->{to_delete} && !exists($protected->{$k})
	    && $k ne 'root';
    }
    return ($modify, $delete, $create);
}

# Checks for conflicts in the resulting status list.
#
# It returns 0 if everything is expected to go all right, -1 in case
# of expected errors.
#
# Accepts the hash of entities (users or groups in the system), the
# scheduled modifications, the scheduled deletions, the scheduled
# creations and the field in the profile with the numeric ID. This
# last one must be either "gid" or "uid".
sub conflicts
{
    my ($self, $sys, $modify, $delete, $create, $field) = @_;

    my (%rs, $rt, $nam, $id, @id);

    $rt = 0;
    while (my ($k, $v) = each(%$sys)) {
	$self->debug(2, "Filling $k: ", $v->{system}->[ID]);
	$rs{$v->{system}->[ID]} = $k;
    }

    foreach my $i (@$delete) {
	$self->debug(2, "Deleting $i");
	$rs{$sys->{$i}->{system}->[ID]} = undef;
    }

    foreach my $i (@$modify) {
	if (exists($i->{profile}->{$field})) {
	    if (defined($rs{$i->{profile}->{$field}}) &&
		    $rs{$i->{profile}->{$field}} ne $i->{system}->[NAME]) {
		$self->error("Trying to assign used $field $i->{profile}->{$field} to ",
			     $i->{system}->[NAME], " conflicting with ",
			     $rs{$i->{profile}->{$field}});
		$rt = -1;
	    } else {
		$rs{$i->{profile}->{$field}} = $i->{system}->[NAME];
	    }
	}
    }

    while (my ($k, $v) = each(%$create)) {
	$self->debug(4, "Analysing $k($field)");
	if (exists($v->{$field})) {
	    $self->debug(4, "Checking for clashes with $field");
	    if (defined($rs{$v->{$field}}) && ($rs{$v->{$field}} ne $k)) {
		$self->error("Trying to assign used $field $v->{$field} to $k, ",
			     "conflicting with $rs{$v->{$field}}");
		$rt = -1;
	    } else {
		$rs{$v->{$field}} = $k;
	    }
	}
    }
    return $rt;
}


# Adds to each user the list of groups he belongs to.
sub add_group_info_to_users
{
    my ($self, $users, $groups) = @_;

    while (my ($group, $info) = each(%$groups)) {
	next unless $info->{system}->[IDLIST];
	my @members = split(",", $info->{system}->[IDLIST]);
	foreach my $i (@members) {
	    $self->debug(2, "Adding user $i to group $group");
	    $users->{$i}->{system}->[EXTRA_FIELD]->{$group} = 1;
	}
    }
}

sub conflict_accounts
{
    my ($self, $sys, $modify, $delete, $create, $field) = @_;

    my (@to_delete, %to_create, @to_modify);

    if ($delete) {
	@to_delete = @$delete;
    }
    push(@to_delete,  keys(%$modify));
    %to_create = (%$create, %$modify);
    return $self->conflicts($sys, undef, \@to_delete, \%to_create, $field);
}

# Schedules what has to be done. Returns a hash listing:
#
# Accounts to be removed. This list will be empty if the
# remove_unknown flag is false in the profile.
#
# Groups to be removed. This list will be empty if the remove_unknown
# flag is false in the profile.
#
# Groups to be modified
# Groups to be created
# Accounts to be modified
# Accounts to be created
#
# Returns undef in case of errors, so the component can fail without
# breaking the system.
sub schedule
{
    my ($self, $tree) = @_;

    my %ret;

    my %u = $self->list_system_members($self->wrap_getent(PASSWD_FILE));
    my %g = $self->list_system_members($self->wrap_getent(GROUP_FILE));

    $self->add_group_info_to_users(\%u, \%g);

    @ret{"modify_groups", "delete_groups", "create_groups"} =
	$self->classify_groups(\%g, $tree->{kept_groups}, $tree->{groups});
    @ret{"modify_accounts",
	 "delete_accounts",
	 "create_accounts"} =
	$self->classify_accounts(\%u, $tree->{kept_users}, $tree->{users});

    $tree->{remove_unknown} or @ret{"delete_groups","delete_accounts"} =
	([], []);

    return if $self->conflicts(\%g, @ret{"modify_groups", "delete_groups",
					     "create_groups"}, 'gid');
    return if $self->conflict_accounts(\%u,
				       @ret{"modify_accounts",
					    "delete_accounts",
					    "create_accounts"},
				       'uid');
    return %ret;
}

# Deletes the accounts marked for deletion. It removes as many as
# possible. Returns undef in case of any single error in the deletion
# process.
sub delete_stuff
{
    my ($self, $accounts, @command) = @_;

    my $rt = 1;

    foreach my $i (@$accounts) {
	my $cmd = CAF::Process->new([@command, $i], log => $self);
	$cmd->run();
	if ($?) {
	    $self->error("Error when deleting account $i");
	    $rt = undef;
	}
    }
    return $rt;
}

# Modifies groups.
sub modify_groups
{
    my ($self, $groups) = @_;

    my $rt = 1;

    foreach my $i (@$groups) {
	my $cmd = CAF::Process->new([GROUPMOD, $i->{profile}->{gid},
				     $i->{system}->[NAME]],
				    log => $self);
	$cmd->run();
	if ($?) {
	    $self->error("Failed to adjust group ", $i->{system}->[NAME]);
	    $rt = undef;
	}
    }
    return $rt;
}

# Creates groups
sub create_groups
{
    my ($self, $groups) = @_;

    $self->verbose("Creating needed groups");
    while (my ($g, $desc) = each(%$groups)) {
	my $cmd = CAF::Process->new([GROUPADD], log => $self);
	$cmd->pushargs(GIDPARAM, $desc->{gid}) if exists($desc->{gid});
	$cmd->pushargs($g);
	$cmd->run();
	if ($?) {
	    $self->error("Failed to create group $g");
	    return;
	}
    }
    return 1;
}

sub sanitize_path
{
    my ($self, $path) = @_;

    if ($path !~ m{^(/[-\w\./]+)$}) {
	$self->error("Unsafe path: $path");
	return;
    }
    return $1;
}

# Creates the home directory for a given account.  The home directory
# is created first, and then all the contents on /etc/skel are copied,
# and permissions are adjusted.
#
# Only at the end of the process the user is given access to the
# already set-up directory.
#
# Returns true in case of success, false otherwise.
# Receives the account name and the path to the home dir.
sub create_home
{
    my ($self, $account) = @_;
    my ($uid, $gid, $dir) = (getpwnam($account))[ID,IDLIST,PWHOME];

    $self->verbose("Creating home directory for $account at $dir");

    if ($dir !~ m{^(/[-/\w\.]+$)}) {
	$self->error("Unsafe to create home directory: $dir ",
		     "for account: $account");
	return;
    }

    $dir = $1;

    # Parent directories, if created, need to be readable by the new
    # user. The next step ensures the home directory is readable only
    # by the owner.
    if (!makedir($dir, 0755)) {
	$self->error("Failed to create home directory: $dir ",
		     "for account $account");
	return;
    }

    # Close the access while we copy everything from /etc/skel. This
    # step is needed, as the home directory might already exist.
    chown(0, 0, $dir);
    chmod(0700, $dir);

    my $find = LC::Find->new();
    $find->callback(
	sub {
	    my $d = $self->sanitize_path("$dir/$LC::Find::SubDir") or return;
	    my $f = $self->sanitize_path("$d/$LC::Find::Name") or return;
	    my $src =  $self->sanitize_path(join("/", $LC::Find::TopDir,
						 $LC::Find::SubDir,
						 $LC::Find::Name)) or return;
	    if (! -e $f) {
		if (-d $src) {
		    $self->verbose("Creating directory $f for $src");
		    if (!makedir($f, 0700)) {
			$self->error("Couldn't create directory $f");
			return;
		    }
		} else {
		    copy($src, $f, preserve => 1);
		}
	    }
	    chown($uid, $gid, $f);
	}
       );

    $find->find(SKELDIR);
    chown($uid, $gid, $dir);
    return 1;
}

# Adds the account to the list of groups given as arguments.
sub add_to_groups
{
    my ($self, $account, $groups) = @_;

    my @gids = map((getgrnam($_))[ID], @$groups);

    my $cmd = CAF::Process->new([USERMOD, GROUPSOPT, join(",", @gids),
				 $account],
				log => $self);
    $cmd->run();
    if ($?) {
	$self->error("Failed to add $a to groups", join(", ", @$groups));
    }
}

# lnewuser seems to be broken on RHES4, and doesn't set the correct
# UIDs or group memberships. We fix it here.
sub work_around_stupid_rhes4_bug
{
    my ($self, $accounts) = @_;

    my $rh = LC::File::file_contents("/etc/redhat-release");
    $rh =~ m{^Red Hat Enterprise Linux ES release 4} or return;
    $self->verbose("On RHES 4, UIDs may be wrong. Fixing");
    while (my ($a, $pf) = each(%$accounts)) {
	my $cmd = CAF::Process->new([USERMOD], log => $self);
	$cmd->pushargs(IDOPT, $pf->{uid});
	$cmd->pushargs($a);
	$cmd->run();
	if ($?) {
	    $self->error("Failed to set up properly account $a");
	}
    }
}

# Creates users, with their homes if needed.
sub create_accounts
{
    my ($self, $accounts, $tree) = @_;
    my (@users, $out);

    $self->verbose("Creating needed accounts");
    while (my ($a, $pf) = each(%$accounts)) {
	$self->verbose("Processing account $a");
	my @flds;
	my $group = exists($pf->{groups}) ?
	    (getgrnam($pf->{groups}->[0]))[ID] : "";

	if (!defined($group)) {
	    $self->error("Couldn't get group $pf->{groups}->[0] ",
			 "as specified in the profile. Skipping account $a");
	    next;
	}
	if (exists($pf->{poolStart})) {
	    $self->verbose("Account $a is a pool with $pf->{poolSize} members");
	    for my $i (0..$pf->{poolSize}-1) {
		my $tail = sprintf("%0$pf->{poolDigits}d", $pf->{poolStart}+$i);
		@flds = ("$a$tail", "x",
			 $pf->{uid} + $i,
			 $group,
			 (exists($pf->{comment}) ? $pf->{comment} : ""),
			 (exists($pf->{homeDir}) ? "$pf->{homeDir}$tail" : ""),
			 (exists($pf->{shell}) ? $pf->{shell} : ""));
		push(@users, join(":", @flds));
	    }
	} else {
	    @flds = ($a, "x",
		     $pf->{uid},
		     $group,
		     (exists($pf->{comment}) ? $pf->{comment} : ""),
		     (exists($pf->{homeDir}) ? $pf->{homeDir} : ""),
		     (exists($pf->{shell}) ? $pf->{shell} : ""));
	    push(@users, join(":", @flds));
	}
    }

    my $cmd = CAF::Process->new([USERADD], stdin => join("\n", @users),
				stderr => \$out);
    $cmd->execute();


    if ($out =~ m{Error creating account for}) {
	$self->error("Failed to create some accounts: $out");
    }

    # We have to go on: some accounts may have not been created, but
    # some others may still be there and we have to fix them.
    $self->work_around_stupid_rhes4_bug($accounts);
    while (my ($a, $pf) = each(%$accounts)) {
	if (exists($pf->{poolSize})) {
	    for my $i (0..$pf->{poolSize}-1) {
		my $tail = sprintf("%0$pf->{poolDigits}d", $i);
		$self->create_home("$a$tail") if $pf->{createHome};
		$self->add_to_groups("$a$tail", $pf->{groups})
		    if exists($pf->{groups}) &&
			(scalar(@{$pf->{groups}}) > 1);
	    }
	} else {
	    $self->create_home($a) if $pf->{createHome};
	    $self->add_to_groups($a, $pf->{groups})
		if exists($pf->{groups}) &&
		    (scalar(@{$pf->{groups}}));
	}
    }

    return 1;
}

# Sets up the root password.
sub root_password
{
    my ($self, $rootpwd) = @_;

    $self->verbose("Setting up root password");
    CAF::Process->new([CHPASSWD], stdin => "root:$rootpwd\n")->execute();
    if ($?) {
	$self->error("Failed to set root password");
    }
}

# Sets up the root shell.
sub root_shell
{
    my ($self, $rootshell) = @_;

    my $shells = CAF::FileEditor->new("/etc/shells", log => $self);
    $shells->cancel();

    if (${$shells->string_ref()} !~ m{^$rootshell$}m) {
	$self->warn("$rootshell is not a known shell. Changing anyways");
    }

    $self->verbose("Setting up root shell to $rootshell");

    CAF::Process->new([CHROOTSHELL, $rootshell], log => $self)->run();
    if ($?) {
	$self->error("Failed to set root shell");
    }
}

# Sets login_defs, if needed
sub login_defs
{
    my ($self, $defs) = @_;

    my $fh = CAF::FileEditor->open(LOGINDEFS_FILE, log => $self,
				   backup => '.old');
    my $cnts = ${$fh->string_ref()};

    my @lines = split("\n", $cnts);

    while (my ($k, $v) = each(%$defs)) {
	my $e = uc($k);
	$self->debug(2, "Destroying key: $e");
	@lines = grep($_ !~ m{^[^#]*$e\W}, @lines);
	push(@lines, "$e $v");
    }
    $fh->set_contents(join("\n", @lines, ""));
    $fh->close();
}

# Sets all the passwords for the users defined in the profile. This is
# done inconditionally on every run of the component, as it's
# relatively cheap to do it and we don't need to look at the shadow
# file to guess who actually needs to modify it.
sub set_passwords
{
    my ($self, $accounts) = @_;

    my @pass;

    while (my ($a, $v) = each(%$accounts)) {
	if ($v->{poolSize}) {
	    for my $i (0..$v->{poolSize}-1) {
		push(@pass, sprintf("%s%0$v->{poolDigits}d:%s",
				    $a, $i+$v->{poolStart}, $v->{password}));
	    }
	} else {
	    push(@pass, "$a:$v->{password}") if exists($v->{password});
	}
    }

    if (@pass) {
	$self->verbose("Changing passwords");
	push(@pass, "");
	my $cmd = CAF::Process->new([CHPASSWD], stdin => join("\n", @pass)) if @pass;
	$cmd->execute();
	if ($?) {
	    $self->error("Failed to execute ", join(" ", CHPASSWD));
	    return;
	}
    }
}



# Configure method
sub Configure
{
    my ($self, $config) = @_;

    my $t = $config->getElement(PATH)->getTree();

    my %tasks = $self->schedule($t) or return 0;
    my @tmp;

    if ($NoAction) {
	$self->info("--noaction specified, doing nothing");
    } else {
	$self->delete_stuff($tasks{delete_accounts}, USERDEL);
	@tmp = keys(%{$tasks{modify_accounts}});
	$self->delete_stuff(\@tmp, USERDEL);
	$self->delete_stuff($tasks{delete_groups}, GROUPDEL);
	$self->root_password($t->{rootpwd}) if exists($t->{rootpwd});
	$self->root_shell($t->{rootshell}) if exists($t->{rootshell});
	$self->login_defs($t->{login_defs}) if exists($t->{login_defs});
	$self->modify_groups($tasks{modify_groups}, $t) or return 0;
	$self->create_groups($tasks{create_groups}) or return 0;
	#$self->modify_accounts($tasks{modify_accounts}, $t) or return 0;
	$self->create_accounts($tasks{create_accounts}) or return 0;
	$self->create_accounts($tasks{modify_accounts}) or return 0;
	$self->set_passwords($t->{users}) or return 0;
    }
    return 1;
}

1;
