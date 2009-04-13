use strict;
use warnings FATAL => 'all';
use File::Spec::Functions;
use Apache::Test;
use Apache::TestUtil;
use Apache::TestRequest 'GET';
my $atv = $Apache::Test::VERSION + 0;

my $config   = Apache::Test::config();
my $hostport = Apache::TestRequest::hostport($config) || '';
t_debug("connecting to $hostport");

my %mirrors;
my $mirror_file = catfile Apache::Test::vars('t_dir'),
    'conf', 'auto_mirror.txt';
open(my $fh, $mirror_file) or die "Cannot open $mirror_file: $!";
while (<$fh>) {
    my ($host, $cn) = split ' ', $_, 2;
    $mirrors{$host}++;
}
close $fh;

Apache::TestRequest::user_agent(reset => 1,
                                requests_redirectable => 0);
my $file = 'my/silly/file.txt';
my $number = 8;
plan tests => 3 * $number;

for (1 .. $number) {
  my $received = GET "/mirror/$file";
  ok t_cmp(
           $received->code,
           302,
           'testing redirect',
          );
  my $content = $received->content;
  my $loc = '';
  if ($content =~ m{href="([^"]+)}i) {
      $loc = $1;
  }
  if ($atv < 1.12) {
    ok t_cmp(
             qr/$file/,
             $loc,
             "testing presence of '$file'",
             );
  }
  else {
    ok t_cmp(
             $loc,
             qr/$file/,
             "testing presence of '$file'",
             );
  }

  (my $host = $loc) =~ s{/$file}{};
  my $present = exists $mirrors{$host} ? 1 : 0;
  ok t_cmp(
           $present,
           1,
           'testing redirect to known host',
          );
}
