use strict;
use warnings;
use ExtUtils::MakeMaker;
use Config;
use Cwd;
use File::Copy;
use File::Path;
use File::Find;
use File::Basename;
require 5.006001;

use constant WIN32 => ($^O =~ /Win32/i);
require Win32 if WIN32;

my $min_at_version = 1.13;
my $min_mp2_version = 1.999022;
my $min_mp1_version = 1.26;

my @INC_ORIG = @INC;

my (%config, $ans, $GEOIP_DBFILE, $GEOIP_DBCITYFILE, @src_files);
my $db_file = 'GeoIP.dat';
my $db_dir = WIN32 ? $ENV{ProgramFiles} . '/GeoIP' : '/usr/local/share/GeoIP';
$db_dir =~ s!\\!/!g;

if (-d $db_dir) {
  if (-e "$db_dir/$db_file") {
    $ans = prompt("Should I use the GeoIP.dat under $db_dir?", 'yes');
    if ($ans =~ /^y/i) {
      $GEOIP_DBFILE = $db_dir . '/' . $db_file;
    }
    else {
      place_db();
    }
  }
  else {
    copy($db_file, $db_dir) or die "Cannot copy $db_file to $db_dir: $!";
    $GEOIP_DBFILE = $db_dir . '/' . $db_file;
  }
}
else {
  place_db();
}

sub place_db {
  my $wanted = WIN32 ? $db_dir :
    prompt('Where should I install GeoIP.dat?', $db_dir);
  $wanted =~ s!\\!/!g;
  $wanted =~ s!/$!!;
  if (-d $wanted) {
    $db_dir = $wanted;
    if (-e "$wanted/$db_file") {
      $ans = prompt("Overwrite $wanted/$db_file?", 'no');
      if ($ans =~ /^y/i) {
	copy($db_file, $wanted) or die "Cannot copy $db_file to $wanted: $!";
      }
      $GEOIP_DBFILE = $wanted . '/' . $db_file;
    }
    else {
      copy($db_file, $wanted) or die "Cannot copy $db_file to $wanted: $!";
      $GEOIP_DBFILE = $wanted . '/' . $db_file;
    }
  }
  elsif (-e $wanted) {
    die qq{A file by the name of "$wanted" exists};
  }
  else {
    $ans = prompt(qq[Create "$wanted"?], 'yes');
    if ($ans =~ /^y/i) {
      mkpath($wanted, 1, 0755) or die "mkpath $wanted failed: $!";
      copy($db_file, $wanted) or die "Cannot copy $db_file to $wanted: $!";
      $GEOIP_DBFILE = $wanted . '/' . $db_file;
      $db_dir = $wanted;
    }
    else {
      die "Need $db_file installed somewhere to work";
    }
  }
}

if (WIN32) {
  $GEOIP_DBFILE = Win32::GetShortPathName($GEOIP_DBFILE);
}

my $to_edit = { 'Mirror.pm' => 
		{'my $GEOIP_DBFILE;' => 
		 qq{my \$GEOIP_DBFILE = "$GEOIP_DBFILE";}},
		'IP.pm' => {'my $GEOIP_DBFILE;' => 
			    qq{my \$GEOIP_DBFILE = "$GEOIP_DBFILE";}},
	      };
my $prereq = {};
my ($libdir, $files_to_clean) = mp_copy($to_edit);
my $mpv = ($libdir eq 'Apache') ? $min_mp1_version : $min_mp2_version;
push @$files_to_clean, 't/TEST';

$config{LIBS} = WIN32 ? ' -lzlib' : ' -lz';
$config{DEFINE} = qq{ -DGEOIPDATADIR=\\"$db_dir\\"} unless WIN32;

my $have_stdint_h;
my @inc = ($Config{usrinc});
push @inc, split ' ', $Config{locincpth};
for (@inc) {
  if (-e "$_/stdint.h") {
    $have_stdint_h = 1;
    last;
  }
}
$config{DEFINE} .= ' -DHAVE_STDINT_H' if $have_stdint_h;

eval {require Apache::Test;};
if ($@) {
  print <<'WARN';

Apparently you are missing Apache::Test, which is needed
to run the test suite. I can add this to the list of
prerequisites, if you like.

WARN

  my $ans = prompt('Add Apache::Test to prerequisites?', 'yes');
  if ($ans =~ /^y/i) {
    $prereq->{'Apache::Test'} = $min_at_version;
  }
  else {
    print "The test suite will be disabled\n";
  }
}

my $name = ($libdir eq 'Apache') ? 'Apache::GeoIP' : 'Apache2::GeoIP';
my $objs = join ' ', ( qw(libGeoIP.o libGeoIPCity.o),
                       ($libdir eq 'Apache2' ? 
                        'Apache2_GeoIP.o' : 'Apache_GeoIP.o') );
my $eu_version = $ExtUtils::MakeMaker::VERSION;
my %opts = (
              NAME           => $name,
              DISTNAME       => 'Apache-GeoIP',
	      VERSION_FROM   => "$libdir/GeoIP.pm",
              PREREQ_PM      => $prereq,
	      ($] >= 5.005 ?    
               (ABSTRACT   => 'Look up country by IP address',
                AUTHOR     => 'Randy Kobes <r.kobes@uwinnipeg.ca>') 
	       : ()),
	      clean          => { FILES => "@$files_to_clean"},
              OBJECT         => $objs,
              ($eu_version >= 6.11 ?
                (NO_META     => 1,)
                : ()),
	      dist           => {
				 SUFFIX   => 'gz',
				 COMPRESS => 'gzip -9f',
				},
	      %config,
           );

@INC = @INC_ORIG;

eval {require ModPerl::MM;};
if ($@) {
  WriteMakefile(%opts);
}
else {
  ModPerl::MM::WriteMakefile(%opts);
}

# use Apache::Test to test things, but if not available,
# print out a message to that effect for 'make test'

sub MY::test {
  eval {require Apache::TestMM; import Apache::TestMM qw(test clean)};
  unless ($@) {
    Apache::TestMM::filter_args();
    Apache::TestMM::generate_script('t/TEST');
    return Apache::TestMM->test;
  }
  
  return <<'EOF';
test::
	@echo This test suite requires Apache::Test,
	@echo available from the mod_perl 2 sources
	@echo or from CPAN.
EOF

}

#######################################################################
# The following routine assumes the existence of two subdirectories:
#   Apache: for mod_perl-1 things
#   Apache2: for mod_perl-2 things
# which_modperl() is called to determine which of the two
# directories to use, depending on availability of
# mod_perl and/or user input. The files under the
# chosen directory are then copied under the lib/ directory
# for subsequent installation. If there is a t/ directory
# under either Apache/ or Apache2/, the files under
# this directory are copied beneath the top-level t/.
# 
# An optional argument may be specified which is a
# hash reference containing a list of files that require
# editing before being copied. The form of this is
#
#   $to_edit =  { file1 => { sub1 => 'pat1', sub2 => 'pat2'},
#                 file2 => { sub3 => 'pat3', sub4 => 'pat4'},
#               };
#
# which will replace "sub1" by "pat1" in file1, etc.
# Simple filenames alone may be specified, except when
# an ambiguity exists, in which case a full path (relative
# to the top-level directory) should be given.
#
# The routine returns a list containing two items - which
# of the directories (Apache or Apache2) is used, and also
# an array reference of files copied to the lib/ or t/ directories
#
########################################################################

sub mp_copy {
  my $to_edit = shift;
  my $ans;
  my $apache_dir = which_modperl();

  @src_files = ();
  my @dest_files = ();
  finddepth(\&wanted, $apache_dir);

  foreach my $src (@src_files) {
    my $dir = dirname($src);
    my $dest_dir;
    if ($dir =~ m!/t/?(.*)!) {
      $dest_dir = "t/$1";
    }
    else {
      $dest_dir = 'lib/' . $dir;
    }
    unless (-d $dest_dir) {
      mkpath($dest_dir, 1, 0755) or die "mkpath $dest_dir failed: $!";
    }
    my $base = basename($src);
    my $dest_file = $dest_dir . '/' . $base;
    push @dest_files, $dest_file;
    my $key = $src;
    if ( $to_edit and ($to_edit->{$key} or $to_edit->{$base})) {
      my $subs = $to_edit->{$key} || $to_edit->{$base};
      open(OLD, $src) or die "Cannot open $src: $!";
      open(NEW, ">$dest_file") or die "Cannot open $dest_file: $!";
      while (<OLD>) {
	foreach my $pattern (keys %{$subs}) {
	  s/\Q$pattern\E/$subs->{$pattern}/g;
	}
	print NEW $_;
      }
      close OLD;
      close NEW;
    }
    else {
      copy($src, $dest_file) or die "Cannot copy $src to $dest_file: $!";
    }
  }
  return ($apache_dir, \@dest_files);
}

sub wanted {
  my $name = $File::Find::name;
  not (-d $_ or $name =~ m!CVS|svn!i) and push @src_files, $name; 
}

sub which_modperl {
  my $ans;
  eval {require mod_perl2;};
  unless ($@) {
    $ans = prompt('Install mod_perl-2 version?', 'yes');
    return 'Apache2' if ($ans =~ /^y/);
  }
  eval {require Apache::src;};
  unless ($@) {
    $ans = prompt('Install mod_perl-1 version?', 'yes');
    return 'Apache' if ($ans =~ /^y/);
  }

  print <<"END";

******************************************************************
The required mod_perl installation was not detected.
For mod_perl-2, the minimal version needed is $min_mp2_version,
while for mod_perl-1, the minimal version is $min_mp1_version.
I can add mod_perl to the list of prerequisites, if you like.
******************************************************************

END

  eval {require Apache2;};
  unless ($@) {
    print <<"END";
******************************************************************
!!! WARNING !!!!!
To use the mod_perl-2 version of this module, you must upgrade your
existing mod_perl-2 installation to at least the RC5 CPAN version.
See http://perl.apache.org/docs/2.0/rename.html for some very
important information you need to know for upgrading.
******************************************************************

END

  }
  $ans = prompt("Add mod_perl-2 [v $min_mp2_version] to prerequisites?",
                'yes');
  if ($ans =~ /^y/) {
    $prereq->{'Apache2::RequestRec'} = 0;
    return 'Apache2';
  }
  else {
    $ans = prompt("Add mod_perl-1 [v $min_mp1_version] to prerequisites?",
                  'yes');
    if ($ans =~ /^y/) {
      $prereq->{'Apache::src'} = 0;
      return 'Apache';
    }
  }
  die "You need either mod_perl 1 or 2 for this module";
}
