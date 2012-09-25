#!/usr/bin/perl

use strict;
use warnings;
use English qw( -no_match_vars );    # Avoids regex performance penalty
use Data::Dumper;
use FindBin qw($RealBin);
use Getopt::Long;
use Cwd qw(realpath getcwd);
use File::Spec;

our $VERSION = '0.5';

run_dfm( $RealBin, @ARGV ) unless defined caller;

my %opts;
my $profile_filename;
my $repo_dir;
my $home;

sub run_dfm {
    my ( $realbin, @argv ) = @_;

    # set options to nothing so that running multiple times in tests
    # does not reuse options
    %opts = ();

    my $command;

    foreach my $arg (@argv) {
        next if $arg =~ /^-/;
        $command = $arg;
    }

    if ( !$command ) {
        $command = 'install';
    }

    # parse global options first
    Getopt::Long::Configure('pass_through');
    GetOptionsFromArray( \@argv, \%opts, 'verbose', 'quiet', 'dry-run',
        'help', 'version' );
    Getopt::Long::Configure('no_pass_through');

    $home = realpath( $ENV{HOME} );

    if ( $ENV{'DFM_REPO'} ) {
        $repo_dir = $ENV{'DFM_REPO'};
        $repo_dir =~ s/$home\///;
    }
    elsif ( -e "$realbin/t/02.updates_mergeandinstall.t" ) {

        # dfm is being invoked from its own repo, not a dotfiles repo; try and
        # figure out what repo in the users's homedir is the dotfiles repo
        #
        # TODO: alternate strategy: see if there are files in $home that are
        # already symlinked and use those as a guide
        foreach my $potential_dotfiles_repo (qw(.dotfiles dotfiles)) {
            if (   -d "$home/$potential_dotfiles_repo"
                && -d "$home/$potential_dotfiles_repo/.git" )
            {
                $repo_dir = "$home/$potential_dotfiles_repo";
                $repo_dir =~ s/$home\///;
            }
        }

        if ( !$repo_dir ) {
            ERROR(
                "unable to discover dotfiles repo and dfm is running from its own repo"
            );
            exit(-2);
        }
    }
    else {
        $repo_dir = $realbin;
        $repo_dir =~ s/$home\///;
        $repo_dir =~ s/\/bin//;
    }

    DEBUG("Repo dir: $repo_dir");

    $profile_filename = '.bashrc';

    if ( lc($OSNAME) eq 'darwin' ) {
        $profile_filename = '.profile';
    }

    if ( $opts{'help'} ) {
        show_usage();
        exit;
    }

    if ( $opts{'version'} ) {
        show_version();
        exit;
    }

    if ( $command eq 'install' ) {

        DEBUG("Running in [$RealBin] and installing in [$home]");

        # install files
        install( $home, $repo_dir );
    }
    elsif ( $command eq 'updates' ) {
        GetOptionsFromArray( \@argv, \%opts, 'no-fetch' );

        fetch_updates( \%opts );
    }
    elsif ( $command eq 'mi' || $command eq 'mergeandinstall' ) {
        GetOptionsFromArray( \@argv, \%opts, 'merge', 'rebase' );

        merge_and_install( \%opts );
    }
    elsif ( $command eq 'umi' || $command eq 'updatemergeandinstall' ) {
        GetOptionsFromArray( \@argv, \%opts, 'merge', 'no-fetch' );

        fetch_updates( \%opts );
        merge_and_install( \%opts );
    }
    elsif ( $command eq 'un' || $command eq 'uninstall' ) {
        INFO( "Uninstalling dotfiles..."
                . ( $opts{'dry-run'} ? ' (dry run)' : '' ) );

        DEBUG("Running in [$RealBin] and installing in [$home]");

        # uninstall files
        uninstall_files( $home . '/' . $repo_dir, $home );

        # remove the bash loader
        unconfigure_bash_loader();
    }
    else {

        # assume it's a git command and call accordingly
        chdir( $home . '/' . $repo_dir );
        system( 'git', @argv );
    }
}

sub get_changes {
    my $what = shift;

    return `git log --pretty='format:%h: %s' $what`;
}

sub get_current_branch {
    my $current_branch = `git symbolic-ref HEAD`;
    chomp $current_branch;

    # convert 'refs/heads/personal' to 'personal'
    $current_branch =~ s/^.+\///g;

    DEBUG("current branch: $current_branch");

    return $current_branch;
}

sub check_remote_branch {
    my $branch        = shift;
    my $branch_remote = `git config branch.$branch.remote`;
    chomp $branch_remote;

    DEBUG("remote for branch $branch: $branch_remote");

    if ( $branch_remote eq "" ) {
        WARN("no remote found for branch $branch");
        exit(-1);
    }
}

# a few log4perl-alikes
sub ERROR {
    printf "ERROR: %s\n", shift;
}

sub WARN {
    printf "WARN: %s\n", shift;
}

sub INFO {
    printf "INFO: %s\n", shift if !$opts{quiet};
}

sub DEBUG {
    printf "DEBUG: %s\n", shift if $opts{verbose};
}

sub fetch_updates {
    my $opts = shift;

    chdir( $home . '/' . $repo_dir );

    if ( !$opts->{'no-fetch'} ) {
        DEBUG('fetching changes');
        system("git fetch") if !$opts->{'dry-run'};
    }

    my $current_branch = get_current_branch();
    check_remote_branch($current_branch);

    print get_changes("$current_branch..$current_branch\@{u}"), "\n";
}

sub merge_and_install {
    my $opts = shift;

    chdir( $home . '/' . $repo_dir );

    my $current_branch = get_current_branch();
    check_remote_branch($current_branch);

    my $sync_command = $opts->{'rebase'} ? 'rebase' : 'merge';

    if ( get_changes("$current_branch..$current_branch\@{u}") ) {

        # check for local commits
        if ( my $local_changes
            = get_changes("$current_branch\@{u}..$current_branch") )
        {

            # if a decision wasn't made about how to deal with local commits
            if ( !$opts->{'merge'} && !$opts->{'rebase'} ) {
                WARN(
                    "local changes detected, run with either --merge or --rebase"
                );
                print $local_changes, "\n";
                exit;
            }
        }

        INFO("using $sync_command to bring in changes");
        system("git $sync_command $current_branch\@{u}")
            if !$opts->{'dry-run'};

        INFO("re-installing dotfiles");
        install( $home, $repo_dir ) if !$opts->{'dry-run'};
    }
    else {
        INFO("no changes to merge");
    }
}

sub install {
    my ( $home, $repo_dir ) = @_;

    INFO(
        "Installing dotfiles..." . ( $opts{'dry-run'} ? ' (dry run)' : '' ) );

    DEBUG("Running in [$RealBin] and installing in [$home]");

    install_files( $home . '/' . $repo_dir, $home );

    # link in the bash loader
    if ( -e "$home/$repo_dir/.bashrc.load" ) {
        configure_bash_loader();
    }
}

# function to install files
sub install_files {
    my ( $source_dir, $target_dir, $initial_skips ) = @_;
    $initial_skips ||= [];

    DEBUG("Installing from $source_dir into $target_dir");

    my $symlink_base;

    # if the paths have no first element in common
    if ( ( File::Spec->splitdir($source_dir) )[1] ne
        ( File::Spec->splitdir($target_dir) )[1] )
    {
        $symlink_base = $source_dir;    # use absolute path
    }
    else {

        # otherwise, calculate the relative path between the two directories
        $symlink_base = File::Spec->abs2rel( $source_dir, $target_dir );
    }

    my $backup_dir = $target_dir . '/.backup';
    DEBUG("Backup dir: $backup_dir");

    my $cwd_before_install = getcwd();
    chdir($target_dir);

    # build up skip list
    my $skip_files    = { map { $_ => 1 } @$initial_skips };
    my $recurse_files = [];
    my $execute_files = [];
    my $chmod_files   = {};

    if ( -e "$source_dir/.dfminstall" ) {
        open( my $skip_fh, '<', "$source_dir/.dfminstall" );
        foreach my $line (<$skip_fh>) {
            chomp($line);
            if ( length($line) ) {
                my ( $filename, @options ) = split( q{ }, $line );
                DEBUG(".dfminstall file $filename has @options");
                if ( !defined $options[0] ) {
                    WARN(
                        "using implied recursion in .dfminstall is deprecated, change '$filename' to '$filename recurse' in $source_dir/.dfminstall."
                    );
                    push( @$recurse_files, $filename );
                    $skip_files->{$filename} = 1;
                }
                elsif ( $options[0] eq 'skip' ) {
                    $skip_files->{$filename} = 1;
                }
                elsif ( $options[0] eq 'recurse' ) {
                    push( @$recurse_files, $filename );
                    $skip_files->{$filename} = 1;
                }
                elsif ( $options[0] eq 'exec' ) {
                    push( @$execute_files, $filename );
                }
                elsif ( $options[0] eq 'chmod' ) {
                    if ( !$options[1] ) {
                        ERROR(
                            "chmod option requires a mode (e.g. 0600) in $source_dir/.dfminstall"
                        );
                        exit 1;
                    }
                    if ( $options[1] !~ /^[0-7]{4}$/ ) {
                        ERROR(
                            "bad mode '$options[1]' (should be 4 digit octal, like 0600) in $source_dir/.dfminstall"
                        );
                        exit 1;
                    }
                    $chmod_files->{$filename} = $options[1];
                }
            }
        }
        close($skip_fh);
        $skip_files->{skip} = 1;

        DEBUG("Skipped file: $_") for keys %$skip_files;
    }

    if ( !-e $backup_dir ) {
        DEBUG("Creating $backup_dir");
        mkdir($backup_dir) if !$opts{'dry-run'};
    }

    my $dirh;
    opendir $dirh, $source_dir;
    foreach my $direntry ( readdir($dirh) ) {

        # skip current and parent
        next if $direntry eq '.' or $direntry eq '..';

        # skip vim swap files
        next if $direntry =~ /.*\.sw.$/;

        # always skip .dfminstall files
        next if $direntry eq '.dfminstall';

        # always skip .gitignore files
        next if $direntry eq '.gitignore';

        # always skip the .git repo
        next if $direntry eq '.git';

        # skip any other files
        next if $skip_files->{$direntry};

        DEBUG(" Working on $direntry");

        if ( !-l $direntry ) {
            if ( -e $direntry ) {
                INFO("  Backing up $direntry.");
                system("mv '$direntry' '$backup_dir/$direntry'")
                    if !$opts{'dry-run'};
            }
            INFO("  Symlinking $direntry ($symlink_base/$direntry).");
            symlink( "$symlink_base/$direntry", "$direntry" )
                if !$opts{'dry-run'};
        }
    }

    cleanup_dangling_symlinks( $source_dir, $target_dir, $skip_files );

    foreach my $recurse (@$recurse_files) {
        if ( -d "$source_dir/$recurse" ) {
            DEBUG("recursing into $source_dir/$recurse");
            if ( -l "$target_dir/$recurse" ) {
                DEBUG("removing symlink $target_dir/$recurse");
                unlink("$target_dir/$recurse");
            }
            if ( !-d "$target_dir/$recurse" ) {
                DEBUG("making directory $target_dir/$recurse");
                mkdir("$target_dir/$recurse");
            }
            install_files( "$source_dir/$recurse", "$target_dir/$recurse" );
        }
        else {
            WARN(
                "couldn't recurse into $source_dir/$recurse, not a directory"
            );
        }
    }

    foreach my $execute (@$execute_files) {
        my $cwd = getcwd();

        if ( -x "$source_dir/$execute" ) {
            DEBUG("Executing $source_dir/$execute in $cwd");
            system("'$source_dir/$execute'");
        }
        elsif ( -o "$source_dir/$execute" ) {
            system("chmod +x '$source_dir/$execute'");

            DEBUG("Executing $source_dir/$execute in $cwd");
            system("'$source_dir/$execute'");
        }
    }

    foreach my $chmod_file ( keys %$chmod_files ) {
        my $new_perms = $chmod_files->{$chmod_file};

        # TODO maybe skip if perms are already ok
        DEBUG("Setting permissions on $chmod_file to $new_perms");
        chmod oct($new_perms), $chmod_file;
    }

    # restore previous working directory
    chdir($cwd_before_install);
}

sub configure_bash_loader {
    chdir($home);

    my $bashrc_contents = _read_bashrc_contents();

    # check if the loader is in
    if ( $bashrc_contents !~ /\.bashrc\.load/ ) {
        INFO("Appending loader to $profile_filename");
        $bashrc_contents .= "\n. \$HOME/.bashrc.load\n";
    }

    _write_bashrc_contents($bashrc_contents);
}

sub uninstall_files {
    my ( $source_dir, $target_dir ) = @_;

    DEBUG("Uninstalling from $target_dir");

    my $backup_dir = $target_dir . '/.backup';
    DEBUG("Backup dir: $backup_dir");

    chdir($target_dir);

    # build up recurse list
    my $recurse_files = [];
    if ( -e "$source_dir/.dfminstall" ) {
        open( my $dfminstall_fh, '<', "$source_dir/.dfminstall" );
        foreach my $line (<$dfminstall_fh>) {
            chomp($line);
            if ( length($line) ) {
                my ( $filename, $option ) = split( q{ }, $line );
                if ( !defined $option || $option ne 'skip' ) {
                    push( @$recurse_files, $filename );
                }
            }
        }
        close($dfminstall_fh);
    }

    my $dirh;
    opendir $dirh, $target_dir;
    foreach my $direntry ( readdir($dirh) ) {

        DEBUG(" Working on $direntry");

        if ( -l $direntry ) {
            my $link_target = readlink($direntry);
            DEBUG("$direntry points a $link_target");
            my ( $volume, @elements ) = File::Spec->splitpath($link_target);
            my $element = pop @elements;

            my $target_base = realpath(
                File::Spec->rel2abs( File::Spec->catpath( '', @elements ) ) );

            DEBUG("target_base $target_base $source_dir");
            if ( $target_base eq $source_dir ) {
                INFO("  Removing $direntry ($link_target).");
                unlink($direntry) if !$opts{'dry-run'};
            }

            my $backup_path = File::Spec->catpath( '', '.backup', $element );
            if ( -e $backup_path ) {
                INFO("  Restoring $direntry from backup.");
                rename( $backup_path, $element ) if !$opts{'dry-run'};
            }
        }
    }

    foreach my $recurse (@$recurse_files) {
        if ( -d "$target_dir/$recurse" ) {
            DEBUG("recursing into $target_dir/$recurse");
            uninstall_files( "$source_dir/$recurse", "$target_dir/$recurse" );
        }
        else {
            WARN(
                "couldn't recurse into $target_dir/$recurse, not a directory"
            );
        }
    }
}

sub cleanup_dangling_symlinks {
    my ( $source_dir, $target_dir, $skip_files ) = @_;
    $skip_files ||= {};

    DEBUG(" Cleaning up dangling symlinks in $target_dir");

    my $dirh;
    opendir $dirh, $target_dir;
    foreach my $direntry ( readdir($dirh) ) {

        DEBUG(" Working on $direntry");

        # if symlink is dangling or is now skipped
        if ( -l $direntry && ( !-e $direntry || $skip_files->{$direntry} ) ) {
            my $link_target = readlink($direntry);
            DEBUG("$direntry points at $link_target");
            my ( $volume, @elements ) = File::Spec->splitpath($link_target);
            my $element = pop @elements;

            my $target_base = realpath(
                File::Spec->rel2abs( File::Spec->catpath( '', @elements ) ) );

            DEBUG("target_base $target_base $source_dir");
            if ( $target_base eq $source_dir ) {
                INFO(
                    "  Cleaning up dangling symlink $direntry ($link_target)."
                );
                unlink($direntry) if !$opts{'dry-run'};
            }
        }
    }
}

sub unconfigure_bash_loader {
    chdir($home);

    my $bashrc_contents = _read_bashrc_contents();

    # remove bash loader if found
    $bashrc_contents =~ s{\n. \$HOME/.bashrc.load\n}{}gs;

    _write_bashrc_contents($bashrc_contents);
}

sub _write_bashrc_contents {
    my $bashrc_contents = shift;

    if ( !$opts{'dry-run'} ) {
        open( my $bashrc_out, '>', $profile_filename );
        print $bashrc_out $bashrc_contents;
        close $bashrc_out;
    }
}

sub _read_bashrc_contents {
    my $bashrc_contents;
    {
        local $INPUT_RECORD_SEPARATOR = undef;
        if ( open( my $bashrc_in, '<', $profile_filename ) ) {
            $bashrc_contents = <$bashrc_in>;
            close $bashrc_in;
        }
        else {
            $bashrc_contents = '';
        }
    }
    return $bashrc_contents;
}

sub show_usage {
    show_version();
    print <<END;

Usage:
    dfm install [--verbose|--quiet] [--dry-run]
    dfm uninstall [--verbose|--quiet] [--dry-run]
    dfm updates [--verbose|--quiet] [--dry-run] [--no-fetch]
    dfm mergeandinstall [--verbose|--quiet] [--dry-run] [--merge|--rebase]
    dfm updatemergeandinstall [--verbose|--quiet] [--dry-run] [--merge|--rebase] [--no-fetch]
    dfm [git subcommand] [git options]

For full documentation, run "perldoc ~/$repo_dir/bin/dfm".
END
}

sub show_version {
    print "dfm version $VERSION\n";
}

# work-alike for function from perl 5.8.9 and later
# added for compatibility with CentOS 5, which is stuck on 5.8.8
sub GetOptionsFromArray {
    my ( $argv, $opts, @options ) = @_;

    local @ARGV = @$argv;
    GetOptions( $opts, @options );
}

1;

__END__

=head1 NAME

    dfm - A script to manage a dotfiles repository

=head1 SYNOPSIS

    dfm install [--verbose|--quiet] [--dry-run]

    dfm uninstall [--verbose|--quiet] [--dry-run]
     - or -
    dfm un [--verbose|--quiet] [--dry-run]

    dfm updates [--verbose|--quiet] [--dry-run] [--no-fetch]

    dfm mergeandinstall [--verbose|--quiet] [--dry-run] [--merge|--rebase]
     - or -
    dfm mi [--verbose|--quiet] [--dry-run] [--merge|--rebase]

    dfm [git subcommand] [git options]

=head1 DESCRIPTION

    Manages installing files from and operating on a repository that contains
    dotfiles.

=head1 COMMON OPTIONS

All the subcommands implemented by dfm have the following options:

  --verbose     Show extra information about what dfm is doing
  --quiet       Show as little info as possible.
  --dry-run     Don't do anything.
  --version     Print version information.

=head1 COMMANDS

=over

=item dfm uninstall

This removes all traces of dfm and the dotfiles.  It basically is the reverse
of 'dfm install'.

=item dfm install

This is the default command.  Running 'dfm' is the same as running 'dfm
install'.

This installs everything in the repository into the current user's home
directory by making symlinks.  To skip any files, add their names to a file
named '.dfminstall'.  For instance, to skip 'README.md', put this in
.dfminstall:

    README.md skip

To recurse into a directory and install files inside rather than symlinking the
directory itself, just add its name to .dfminstall.  For instance, to make 'dfm
install' symlink files inside of ~/.ssh instead of making ~/.ssh a symlink, put
this in .dfminstall:

    .ssh

=item dfm updates [--no-fetch]

This fetches any changes from the upstream remote and then shows a shortlog of
what updates would come in if merged into the current branch.  Use '--no-fetch'
to skip the fetch and just show what's new.

=item dfm mergeandinstall [--merge|--rebase]

This merges or rebases the upstream changes in and re-installs dotfiiles.  A
convenient alias is 'mi'.

=item dfm updatemergeandinstall [--merge|--rebase] [--no-fetch]

This combines 'updates' and 'mergeandinstall'.  A convenient alias is 'umi'.

=item dfm [git subcommand] [git options]

This runs any git command as if it was inside the dotfiles repository.  For
instance, this makes it easy to commit changes that are made by running 'dfm
commit'.

=back

=head1 AUTHOR

Nate Jones <nate@endot.org>

=head1 COPYRIGHT

Copyright (c) 2010 L</AUTHOR> as listed above.

=head1 LICENSE

This program is free software distributed under the Artistic License 2.0.

=cut
