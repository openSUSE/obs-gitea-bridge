#!/usr/bin/perl -w
#
# End to end tests for the webhook event queue of gitea_obs_bridge: events
# delivered concurrently to several preforked server children must each be
# processed exactly once, with unique queue file names, and events that arrive
# while another process holds the queue lock must be picked up by that process
# instead of being processed a second time. A fake OBS api on localhost stands
# in for the real server.
#
use strict;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use HTTP::Tiny;
use IO::Socket::INET;
use JSON::XS ();
use POSIX ();
use Time::HiRes qw(sleep time);

my $srcdir = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

# isolated copy of the bridge with its own config, so a config.pm of the
# developer or the packaged installation never takes part in the test
my $testdir = tempdir('obs-gitea-bridge-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
for my $f (grep { !m{/config\.pm$} } glob("$srcdir/*.pm"), "$srcdir/gitea_obs_bridge") {
  my $base = (File::Spec->splitpath($f))[2];
  copy($f, File::Spec->catfile($testdir, $base)) or die "cannot copy $f: $!";
}
chmod 0755, File::Spec->catfile($testdir, 'gitea_obs_bridge');

my @children;
END { kill 'TERM', @$_ for @children; }

my $jobs_seen = 0;

sub free_port {
  my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
        or die "cannot probe a free port: $!";
  my $port = $s->sockport;
  close($s);
  return $port;
}

sub read_log {
  my ($path) = @_;
  open(my $fh, '<', $path) or return '';
  local $/;
  my $content = <$fh>;
  return $content // '';
}

# a minimal OBS api: GET /configuration answers immediately, POST /source
# sleeps $delay seconds to simulate a long running scmsync trigger
sub start_fake_obs {
  my ($port, $delay) = @_;
  my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port,
                                   Listen => 16, Reuse => 1) or die "fake obs listen: $!";
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid == 0) {
    open(STDOUT, '>', File::Spec->catfile($testdir, 'fake-obs.log')) or POSIX::_exit(1);
    open(STDERR, '>&', STDOUT) or POSIX::_exit(1);
    while (my $conn = $sock->accept) {
      my $cpid = fork();
      next unless defined $cpid;
      if ($cpid == 0) {
        close($sock);
        local $/ = "\r\n";
        my $req = <$conn>;
        my %hdr;
        while (my $line = <$conn>) {
          last if $line =~ /^\r?\n$/;
          my ($k, $v) = split(/:\s*/, $line, 2);
          $hdr{lc $k} = $v if defined $v;
        }
        if ($hdr{'content-length'}) {
          my $rest = $hdr{'content-length'};
          my $buf;
          while ($rest > 0) { my $n = read($conn, $buf, $rest, length($buf // '')); last unless $n; $rest -= $n; }
        }
        my ($status, $body) = ('404 Not Found', "unsupported\n");
        if (defined $req && $req =~ m{^GET \S*/configuration}) {
          $body = "<configuration><download_url>https://download.example.org/</download_url></configuration>\n";
          $status = '200 OK';
        } elsif (defined $req && $req =~ m{^POST \S*/source}) {
          Time::HiRes::sleep($delay) if $delay;
          ($status, $body) = ('200 OK', "ok\n");
        }
        print $conn "HTTP/1.0 $status\r\nContent-Type: text/xml\r\n"
                  . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
        close($conn);
        POSIX::_exit(0);
      }
      close($conn);
    }
    POSIX::_exit(0);
  }
  close($sock);
  return $pid;
}

# (re)start fake OBS and the bridge, wait until the bridge answers requests
my ($bridge_port, $obs_port, $queue_dir);
sub start_bridge {
  my ($source_delay, $logfile) = @_;
  $bridge_port ||= free_port();
  $obs_port = free_port();
  $queue_dir ||= File::Spec->catdir($testdir, 'queue');
  open(my $cfg, '>', File::Spec->catfile($testdir, 'config.pm')) or die $!;
  print $cfg "package config;\n"
           . "our \$shared_cookie = 'testcookie';\n"
           . "our \$port = $bridge_port;\n"
           . "our \$obsurl = 'http://127.0.0.1:$obs_port/public';\n"
           . "our \$queue_dir = '$queue_dir';\n"
           . "our \$gitea_root = '" . File::Spec->catdir($testdir, 'gitea') . "';\n"
           . "1;\n";
  close($cfg);
  push @children, [start_fake_obs($obs_port, $source_delay)];
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid == 0) {
    chdir($testdir) or POSIX::_exit(1);
    open(STDOUT, '>>', $logfile) or POSIX::_exit(1);
    open(STDERR, '>&', STDOUT) or POSIX::_exit(1);
    exec($^X, File::Spec->catfile($testdir, 'gitea_obs_bridge')) or POSIX::_exit(1);
  }
  push @children, [$pid];
  my $http = HTTP::Tiny->new(timeout => 2);
  my $deadline = time() + 15;
  while (time() < $deadline) {
    return 1 if $http->get("http://127.0.0.1:$bridge_port/")->{'success'};
    sleep 0.2;
  }
  return 0;
}

sub stop_bridge {
  my @set = splice(@children);
  kill 'TERM', $_->[0] for @set;
  Time::HiRes::sleep(0.5);
}

sub tag_delete_event {
  my ($name) = @_;
  return JSON::XS::encode_json({
    'event' => 'delete', 'ref' => 'v1', 'ref_type' => 'tag',
    'repository' => { 'full_name' => "org/$name", 'clone_url' => "http://localhost/org/$name.git" },
  });
}

sub push_event {
  my ($name) = @_;
  return JSON::XS::encode_json({
    'event' => 'push', 'ref' => 'refs/heads/main',
    'repository' => { 'full_name' => "org/$name", 'clone_url' => "http://localhost/org/$name.git",
                      'default_branch' => 'main' },
  });
}

sub post_one {
  my ($payload) = @_;
  my $http = HTTP::Tiny->new(timeout => 25);
  return $http->request('POST', "http://127.0.0.1:$bridge_port/repositoryevent",
    { headers => { 'Content-Type' => 'application/json' }, content => $payload });
}

# POST events concurrently from forked children, returns name => success
sub post_events {
  my (%jobs) = @_;
  $jobs_seen++;
  my $resultfile = File::Spec->catfile($testdir, "results-$jobs_seen");
  my @pids;
  for my $name (sort keys %jobs) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
      my $res = post_one($jobs{$name});
      my $ok = $res->{'success'};
      if (open(my $fh, '>>', $resultfile)) {
        (my $why = "[$res->{'status'}] $res->{'reason'} $res->{'content'}") =~ s/\s+/ /g;
        print $fh "$name " . ($ok ? 'ok' : "fail $why") . "\n";
        close($fh);
      }
      # _exit skips the cleanup END block, which would kill the bridge
      POSIX::_exit($ok ? 0 : 1);
    }
    push @pids, $pid;
  }
  waitpid($_, 0) for @pids;
  my %result;
  if (open(my $fh, '<', $resultfile)) {
    while (<$fh>) { chomp; my ($n, $r) = split(/ /, $_, 2); $result{$n} = $r; }
    close($fh);
  }
  return \%result;
}

# wait until the log holds $count processed events, for up to 20s
sub wait_processed {
  my ($logfile, $count) = @_;
  my $deadline = time() + 20;
  while (time() < $deadline) {
    my $log = read_log($logfile);
    my @m = $log =~ /^Processed: /gm;
    return $log if @m >= $count;
    sleep 0.2;
  }
  return read_log($logfile);
}

sub pending_queue_files {
  opendir(my $dir, $queue_dir) or return ();
  return grep { /\.json$/ } readdir($dir);
}

# --- test: events delivered concurrently are each processed exactly once ---
ok(start_bridge(0, File::Spec->catfile($testdir, 'bridge1.log')), 'bridge answers requests');

my $results = post_events(map { ("r$_" => tag_delete_event("r$_")) } (1 .. 8));
is(scalar(grep { $_ eq 'ok' } values %$results), 8, 'all 8 concurrent events are acknowledged')
  or diag(explain($results));

my $log = wait_processed(File::Spec->catfile($testdir, 'bridge1.log'), 8);
my @processed = $log =~ /^Processed: tag_delete event for \S+ from (\S+)\n/gm;
my %seen;
$seen{$_}++ for @processed;
is(scalar(@processed), 8, 'every event is processed exactly once');
is(scalar(keys %seen), 8, 'no queue file is processed by two processes');
my $i = 0;
like($_, qr/^\d+-\d+-\d+\.json$/, 'queue file name ' . ++$i . ' is unique and sortable') for @processed;
unlike($log, qr/failed to delete/, 'no queue file was already gone on delete');
is(scalar(pending_queue_files()), 0, 'the queue is empty afterwards');

# --- test: events arriving while the queue lock is busy are handed over ---
my $logfile2 = File::Spec->catfile($testdir, 'bridge2.log');
stop_bridge();
ok(start_bridge(4, $logfile2), 'bridge with a slow scmsync answers requests');

# one push keeps the queue lock busy while the fake OBS sleeps
my $pushpid = fork();
die "fork: $!" unless defined $pushpid;
if ($pushpid == 0) {
  my $ok = post_one(push_event('push1'))->{'success'};
  POSIX::_exit($ok ? 0 : 1);
}
Time::HiRes::sleep(1);
$results = post_events(h1 => tag_delete_event('h1'), h2 => tag_delete_event('h2'), h3 => tag_delete_event('h3'));
is(scalar(grep { $_ eq 'ok' } values %$results), 3, 'events are acknowledged while the queue lock is held');
waitpid($pushpid, 0);

$log = wait_processed($logfile2, 4);
@processed = $log =~ /^Processed: \S+ event for \S+ from (\S+)\n/gm;
%seen = ();
$seen{$_}++ for @processed;
is(scalar(@processed), 4, 'the working process picks up the handed over events');
is(scalar(keys %seen), 4, 'no event of the hand over run is processed twice');
unlike($log, qr/failed to delete/, 'the hand over run deletes each queue file once');
like($log, qr/another process is working the queue/, 'busy children hand their events over');
is(scalar(pending_queue_files()), 0, 'the queue is empty after the hand over');

done_testing();
