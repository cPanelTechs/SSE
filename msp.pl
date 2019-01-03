#!/usr/local/cpanel/3rdparty/bin/perl
package SSE;

use strict;
use warnings;

use Data::Dumper;

use Getopt::Long;
use Cpanel::AdvConfig::dovecot                      ();
use Cpanel::DnsRoots::Resolver                      ();
use Cpanel::FileUtils::Dir                          ();
use Cpanel::IONice                                  ();
use Cpanel::IO                                      ();
use Cpanel::NAT                qw{:get_all_public_ips};
use Whostmgr::Ips                                   ();  
use Term::ANSIColor                     qw{:constants};

our $VERSION = '1.9';

# Variables
$Term::ANSIColor::AUTORESET = 1;

our $LOG_DIR               = q{/var/log/};
our $CPANEL_CONFIG_FILE    = q{/var/cpanel/cpanel.config};
our $EXIM_LOCALOPTS_FILE   = q{/etc/exim.conf.localopts};
our $DOVECOT_CONF          = q{/var/cpanel/conf/dovecot/main};

our $EXIM_MAINLOG          = q{exim_mainlog};
our $AUTH_PASSWORD_REGEX   = qr{\sA=dovecot_login:([^\s]+)\s};
our $AUTH_SENDMAIL_REGEX   = qr{\scwd=([^\s]+)\s};
our $AUTH_LOCAL_USER_REGEX = qr{\sU=([^\s]+)\s.*B=authenticated_local_user};
our $SUBJECT_REGEX         = qr{\s<=\s.*T="([^"]+)"\s};

our @RBLS                  = qw{ b.barracudacentral.org
                                 bl.spamcop.net
                                 dnsbl.sorbs.net
                                 spam.dnsbl.sorbs.net
                                 ips.backscatterer.org
                                 zen.spamhaus.org
                               };

# Initialize
our $LIMIT = 10;
our $THRESHOLD = 1;
our $ROTATED_LIMIT = 5; # I've seen users with hundreds of rotated logs before, we should safeguard to prevent msp from working against unreasonably large data set
our @AUTH_PASSWORD_HITS;
our @AUTH_SENDMAIL_HITS;
our @AUTH_LOCAL_USER_HITS;
our @SUBJECT_HITS;

# Options
my %opts;
my ( $all, $auth, $conf, $forwards, $help, $limit, $logdir, @rbl, $rotated, $rude, $threshold, $verbose );
GetOptions(
    \%opts,
    'all',
    'auth',
    'forwards',
    'help',
    'conf',
    'limit=i{1}',
    'logdir=s{1}',
    'rbl=s',
    'rotated',
    'rude',
    'threshold=i{1}',
    'verbose'
) or die("Please see --help\n");

# Make this a modulino
__PACKAGE__->main(@ARGV) unless caller();
1;

sub print_help {
    print BOLD BRIGHT_BLUE ON_BLACK "[MSP-$VERSION] ";
    print BOLD WHITE ON_BLACK "Mail Status Probe: Mail authentication statistics and configuration checker\n";
    print "Usage: ./msp.pl --auth --rotated --rude\n";
    print "       ./msp.pl --conf --rbl [all|bl.spamcop.net,zen.spamhaus.org]\n\n";
    printf( "\t%-15s %s\n",  "--help", "print this help message");
#    printf( "\t%-15s %s\n", "--all", "run all checks");
    printf( "\t%-15s %s\n",  "--auth", "print mail authentication statistics");
    printf( "\t%-15s %s\n",  "--conf", "print mail configuration info (e.g. require_secure_auth, smtpmailgidonly, etc.)");
#    printf( "\t%-15s %s\n", "--forwards", "print forward relay statistics");
#    printf( "\t%-15s %s\n", "--ignore", "ignore common statistics (e.g. cwd=/var/spool/exim)");
    printf( "\t%-15s %s\n",  "--limit", "limit statistics checks to n results (defaults to 10, set to 0 for no limit)");
    printf( "\t%-15s %s\n",  "--logdir", "specify an alternative logging directory, (defaults to /var/log)");
#    printf( "\t%-15s %s\n", "--quiet", "only print alarming information or statistics (requires --threshold)");
    printf( "\t%-15s %s\n",  "--rbl", "check IP's against provided blacklists(comma delimited)");
    printf( "\t%-15s %s\n",  "--rotated", "check rotated exim logs");
    printf( "\t%-15s %s\n",  "--rude", "forgo nice/ionice settings");
    printf( "\t%-15s %s\n",  "--threshold", "limit statistics output to n threshold(defaults to 1)");
    printf( "\t%-15s %s\n",  "--verbose", "display all information");
    print "\n";
    exit;
}    

sub main {
   if ( (!%opts) || ($opts{help}) ) {
        print_help();
    }
    if ($opts{conf}) {
        # Check Tweak Settings
        print_bold_white("Checking Tweak Settings...");
        print "--------------------------\n";
        my %cpconf = get_conf( $CPANEL_CONFIG_FILE );
        if ( $cpconf{'smtpmailgidonly'} ne 1 ) {
            print_warn("Restrict outgoing SMTP to root, exim, and mailman (FKA SMTP Tweak) is disabled!"); 
        } elsif ( $opts{verbose} ) {
            print_info("Restrict outgoing SMTP to root, exim, and mailman (FKA SMTP Tweak) is enabled");
        }
        if ( $cpconf{'nobodyspam'} ne 1 ) {
            print_warn("Prevent “nobody” from sending mail is disabled!"); 
        } elsif ( $opts{verbose} ) {
            print_info("Prevent “nobody” from sending mail is enabled");
        }
        if ( $cpconf{'popbeforesmtp'} ne 0 ) {
            print_warn("Pop-before-SMTP is enabled!"); 
        } elsif ( $opts{verbose} ) {
            print_info("Pop-before-SMTP is disabled");
        }
        if ( $cpconf{'domainowner_mail_pass'} ne 0 ) {
            print_warn("Mail authentication via domain owner password is enabled!"); 
        } elsif ( $opts{verbose} ) {
            print_info("Mail authentication via domain owner password is disabled");
        }
        print "\n";

        # Check Exim Configuration
        print_bold_white("Checking Exim Configuration...");
        print "------------------------------\n";
        my %exim_localopts_conf = get_conf( $EXIM_LOCALOPTS_FILE );
        if ( $exim_localopts_conf{'allowweakciphers'} ne 0 ) {
            print_warn("Allow weak SSL/TLS ciphers is enabled!"); 
        } elsif ( $opts{verbose} ) {
            print_info("Allow weak SSL/TLS ciphers is disabled");
        }   
        if ( $exim_localopts_conf{'require_secure_auth'} ne 1 ) {
            print_warn("Require clients to connect with SSL or issue the STARTTLS is disabled!"); 
        } elsif ( $opts{verbose} ) {
            print_info("Require clients to connect with SSL or issue the STARTTLS is enabled");
        }
        if ( $exim_localopts_conf{'systemfilter'} ne q{/etc/cpanel_exim_system_filter} ) {
           print_warn("Custom System Filter File in use: $exim_localopts_conf{'systemfilter'}");
        } elsif ( $opts{verbose} ) {
           print_info("System Filter File is set to the default path: $exim_localopts_conf{'systemfilter'}");
        }
        print "\n";

        # Check Dovecot Configuration
        print_bold_white("Checking Dovecot Configuration...");
        print "---------------------------------\n";
        my $dovecot = Cpanel::AdvConfig::dovecot::get_config();
        if ( $dovecot->{'protocols'} !~ m/imap/ ) {
            print_warn("IMAP Protocol is disabled!");
        }
        if ( $dovecot->{'disable_plaintext_auth'} !~ m/no/ ) {
            print_warn("Allow Plaintext Authentication is enabled!");
        } elsif ( $opts{verbose} ) {
            print_info("Allow Plaintext Authentication is disabled");
        }
        print "\n";
    }

    if ($opts{auth}) {
        print_bold_white("Checking Mail Authentication statistics...");
        print "------------------------------------------\n";
        $opts{logdir} //= $LOG_DIR;
        $opts{logdir} =~ s@/*$@/@;
        if (!-d $opts{logdir}) {
            print_warn("$opts{logdir}: No such file or directory. Skipping spam check...\n");
            return;
        }
        auth_check( $opts{logdir} );
        print BOLD WHITE ON_BLACK "Emails sent via Password Authentication:\n";
        if (@AUTH_PASSWORD_HITS) {
            sort_uniq(@AUTH_PASSWORD_HITS);
        } else {
            print "None\n";
        }
        print "\n";
        print BOLD WHITE ON_BLACK "Directories where email was sent via sendmail/script:\n";
        if (@AUTH_SENDMAIL_HITS) {
            sort_uniq(@AUTH_SENDMAIL_HITS);
        } else {
            print "None\n";
        }
        print "\n";
        print BOLD WHITE ON_BLACK "Users who sent mail via local SMTP:\n";
        if (@AUTH_LOCAL_USER_HITS) {
            sort_uniq(@AUTH_LOCAL_USER_HITS);
        } else {
            print "None\n";
        }
        print "\n";
        print BOLD WHITE ON_BLACK "Subjects by commonality:\n";
        sort_uniq(@SUBJECT_HITS);
        print "\n";
    }

    if ($opts{rbl}) {
        @rbl = split( /,/, $opts{rbl});
        rbl_check(@rbl);
    }
    return;
}

sub auth_check {
    my $logdir = shift;
    my @logfiles;
    my $logcount = 0;
    for my $file ( grep { m/^exim_mainlog/ } @{ Cpanel::FileUtils::Dir::get_directory_nodes($logdir) } ) {
        if ( $opts{rotated} ) { 
            if ( ( $file =~ m/mainlog-/ ) && ( $logcount ne $ROTATED_LIMIT ) ) {
                push @logfiles, $file;
                $logcount++;
            }
        }
        push @logfiles, $file if ( $file =~ m/mainlog$/ );
    }
    print_warn("Safeguard triggered... --rotated is limited to $ROTATED_LIMIT logs") if ( $logcount eq $ROTATED_LIMIT );
    my %cpconf = get_conf( $CPANEL_CONFIG_FILE );
    if ( ( !$opts{rude} ) && ( Cpanel::IONice::ionice( 'best-effort', exists $cpconf{'ionice_import_exim_data'} ? $cpconf{'ionice_import_exim_data'} : 6 ) ) ) {
        print("Setting I/O priority to reduce system load: " . Cpanel::IONice::get_ionice() . "\n\n");
        setpriority( 0, 0, 19 );
    }
    my $fh;
    lOG: for my $log ( @logfiles ) {
        if ( $log =~ /[.]gz$/ ) {
            my @cmd = ( qw{ gunzip -c -f }, $logdir . $log );
            if ( !open $fh, '-|', @cmd ) {
                print_warn("Skipping $logdir/$log: Cannot open pipe to read stdout from command '@{ [ join ' ', @cmd ] }' : $!");
                next LOG;
            }
        } else {
            if ( !open $fh, '<', $logdir . $log ) {
                print_warn("Skipping $logdir/$log: Cannot open for reading $!");
                next LOG;
            }
        }
        while ( my $block = Cpanel::IO::read_bytes_to_end_of_line( $fh, 65_535 ) ) {
            foreach my $line ( split( m{\n}, $block ) ) {
                push @AUTH_PASSWORD_HITS, $1 if ($line =~ $AUTH_PASSWORD_REGEX);
                push @AUTH_SENDMAIL_HITS, $1 if ($line =~ $AUTH_SENDMAIL_REGEX);
                push @AUTH_LOCAL_USER_HITS, $1 if ($line =~ $AUTH_LOCAL_USER_REGEX);
                push @SUBJECT_HITS, $1 if ($line =~ $SUBJECT_REGEX);
            }
        }
        close($fh);
    }
     return;
}

sub rbl_check {
    my @rbls = @_;
    my @ips;

    # Fetch IP's... should we only check mailips? this is more thorough...
    # could ignore local through bogon regex?
    my $ipref = Whostmgr::Ips::get_detailed_ip_cfg();
    foreach my $iphash ( @{$ipref} ) {
        push @ips, Cpanel::NAT::get_public_ip( $iphash->{'ip'} );
    }
    # Uncomment the following for testing positive hits
    # push @ips, qw { 127.0.0.2 };

    # If "all" is found in the --rbl arg, ignore rest, use default rbl list
    # maybe we should append so that user can specify all and ones which are not included in the list?
    @rbls = @RBLS if (grep /\ball\b/i, @rbls);

    print_bold_white("Checking IP's against RBL's...");
    print "------------------------------\n";

    foreach my $ip (@ips) {
        print "$ip:\n";
        my $ip_rev = join('.', reverse split('\.', $ip));
        foreach my $rbl (@rbls) {
            # Do we need to call this on each lookup or can we move this outside the loop?
            my $res = Cpanel::DnsRoots::Resolver->new();
            if (grep { /127.0.0.2/ } $res->recursive_query( "$ip_rev" . '.' . "$rbl", 'A')) {
                 printf("\t%-25s ", $rbl);
                 print_bold_red('LISTED');
            } else {
                 printf("\t%-25s ", $rbl);
                 print_bold_green('GOOD');
            }
        }
    }
}

sub sort_uniq {
    my @input = @_;
    my %count;
    my $line = 1;
    $opts{limit} //= $LIMIT;
    $opts{threshold} //= $THRESHOLD;
    foreach ( @input ) { $count{$_}++; }
    for ( sort { $count{$b} <=> $count{$a} } keys %count ) {
        if ( $line ne $opts{limit} ) {
            printf ("%7d %s\n", "$count{$_}", "$_") if ( $count{$_} >= $opts{threshold} );
            $line++;
        } else { 
            printf( "%7d %s\n", "$count{$_}", "$_") if ( $count{$_} >= $opts{threshold} );
            last;
        }
    }
}

# cpanel.confg and exim.conf.localopts
sub get_conf {
    my $conf = shift;
    my %cpconf;
    if ( open( my $cpconf_fh, '<', $conf ) ) {
        local $/ = undef;
        %cpconf = map { ( split( /=/, $_, 2 ) )[ 0, 1 ] } split( /\n/, readline($cpconf_fh) );
        close $cpconf_fh;
        return %cpconf;
    } else {
        print_warn("Could not open file: $conf");
    }
}

# pretty prints
sub print_warn {
    my $text = shift // '';
    return if $text eq '';

    print BOLD RED ON_BLACK '[WARN] * ';
    print WHITE ON_BLACK "$text\n";
    return;
}

sub print_info {
    my $text = shift // '';
    return if $text eq '';

    print BOLD GREEN ON_BLACK '[INFO] * ';
    print WHITE ON_BLACK "$text\n";
    return;
}

sub print_std {
    my $text = shift // '';
    return if $text eq '';

    print BOLD BRIGHT_BLUE ON_BLACK '[MSP]  * ';
    print BOLD WHITE ON_BLACK "$text\n";
    return;
}

sub print_bold_white {
    my $text = shift // '';
    return if $text eq '';

    print BOLD WHITE ON_BLACK "$text\n";
    return;
}

sub print_bold_red {
    my $text = shift // '';
    return if $text eq '';

    print BOLD RED ON_BLACK "$text\n";
    return;
}

sub print_bold_green {
    my $text = shift // '';
    return if $text eq '';

    print BOLD GREEN ON_BLACK "$text\n";
    return;
}