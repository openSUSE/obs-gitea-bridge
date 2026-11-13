#!/usr/bin/perl -w
#
# End to end tests for the _config file handling of package_set projects:
# such projects have no project level scmsync, so the bridge has to upload
# the _config file from the branch of the manifest repository itself. A fake
# OBS api on localhost records the requests and keeps the stored _config
# file, a fake Gitea repository store provides the git side.
#
use strict;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use HTTP::Tiny;
use IO::Socket::INET;
use JSON::XS ();
use POSIX ();
use Time::HiRes qw(sleep time);

plan skip_all => 'git is not available' unless `git --version 2>/dev/null` =~ /^git version/;

$ENV{GIT_AUTHOR_NAME} = 'test';
$ENV{GIT_AUTHOR_EMAIL} = 'test@example.com';
$ENV{GIT_COMMITTER_NAME} = 'test';
$ENV{GIT_COMMITTER_EMAIL} = 'test@example.com';

my $srcdir = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $testdir = tempdir('obs-gitea-bridge-config-XXXXXX', TMPDIR => 1, CLEANUP => 1);

# isolated copy of the bridge, its own config.pm below
for my $f (grep { !m{/config\.pm$} } glob("$srcdir/*.pm"), "$srcdir/gitea_obs_bridge") {
  my $base = (File::Spec->splitpath($f))[2];
  copy($f, File::Spec->catfile($testdir, $base)) or die "cannot copy $f: $!";
}
chmod 0755, File::Spec->catfile($testdir, 'gitea_obs_bridge');

my $gitea_root = File::Spec->catdir($testdir, 'gitea');
my $obs_state = File::Spec->catdir($testdir, 'obs-state');
my $obs_log = File::Spec->catfile($testdir, 'obs-requests.log');
make_path($gitea_root, $obs_state);

my @children;
END { kill 'TERM', @$_ for @children; }

sub free_port {
  my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
        or die "cannot probe a free port: $!";
  my $port = $s->sockport;
  close($s);
  return $port;
}

# --- fake gitea repositories -------------------------------------------------

# create a bare repository at $gitea_root/gitea-repositories/$org/$name.git
# with the given files committed on branch main, returns the work directory
sub make_repo {
  my ($org, $name, $files) = @_;
  my $work = File::Spec->catdir($testdir, 'work', $name);
  my $bare = File::Spec->catdir($gitea_root, 'gitea-repositories', $org, "$name.git");
  make_path($work);
  is(system('git', 'init', '-q', $work), 0, "git init $name") or return;
  is(system('git', '-C', $work, 'checkout', '-q', '-B', 'main'), 0, "checkout $name#main") or return;
  write_files($work, $files, []);
  commit_repo($work);
  is(system('git', 'clone', '-q', '--bare', $work, $bare), 0, "clone --bare $name") or return;
  return ($work, $bare);
}

sub write_files {
  my ($dir, $files, $remove) = @_;
  for my $file (@$remove) {
    unlink File::Spec->catfile($dir, $file);
  }
  for my $file (keys %{ $files || {} }) {
    open(my $fh, '>', File::Spec->catfile($dir, $file)) or die "cannot write $file: $!";
    print $fh $files->{$file};
    close($fh);
  }
}

sub commit_repo {
  my ($work) = @_;
  is(system('git', '-C', $work, 'add', '-A'), 0, 'git add') or return;
  is(system('git', '-C', $work, 'commit', '-q', '--allow-empty', '-m', 'test'), 0, 'git commit') or return;
}

sub push_repo {
  my ($work, $bare) = @_;
  is(system('git', '-C', $work, 'push', '-q', '--force', $bare, 'refs/heads/main:refs/heads/main'), 0, 'push to bare') or return;
}

my $manifest = <<'YAML';
presets:
  - name: openSUSE_Tumbleweed
    default: "true"
    architectures:
      - x86_64
    repo:
      - https://download.example.org/testorg/standard
package_set:
  branch: main
YAML

my $config1 = "Macros: %distro_test 1\n";

my ($meta_work, $meta_bare) = make_repo('testorg', 'meta', { '_manifest' => $manifest, '_config' => $config1 });
make_repo('testorg', 'pkg-a', { 'README' => "package a\n" });

# --- fake OBS api with request log and stored _config ------------------------

sub obs_state_file {
  my ($path) = @_;
  (my $flat = $path) =~ s{[^A-Za-z0-9]+}{_}g;
  return File::Spec->catfile($obs_state, $flat);
}

sub start_fake_obs {
  my ($port) = @_;
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
        my $body = '';
        if ($hdr{'content-length'}) {
          my $rest = $hdr{'content-length'};
          while ($rest > 0) { my $n = read($conn, $body, $rest, length($body)); last unless $n; $rest -= $n; }
        }
        my ($method, $target) = ($req || '') =~ m{^(\S+)\s+(\S+)};
        my ($path) = split(/\?/, $target // '', 2);
        if (open(my $log, '>>', $obs_log)) { print $log "$method $path\n"; close($log); }
        my ($status, $ans) = ('404 Not Found', "unsupported\n");
        if (defined $path && $path =~ m{/configuration$}) {
          ($status, $ans) = ('200 OK',
            "<configuration><download_url>https://download.example.org/</download_url></configuration>\n");
        } elsif (defined $path && $path =~ m{/source/[^/]+/_config$}) {
          my $state = obs_state_file($path);
          if ($method eq 'GET') {
            if (open(my $fh, '<', $state)) { local $/; $ans = <$fh>; close($fh); ($status, $ans) = ('200 OK', $ans // ''); }
          } elsif ($method eq 'PUT') {
            if (open(my $fh, '>', $state)) { print $fh $body; close($fh); ($status, $ans) = ('200 OK', "ok\n"); }
          } elsif ($method eq 'DELETE') {
            unlink($state);
            ($status, $ans) = ('200 OK', "ok\n");
          }
        } elsif (defined $path && $path =~ m{/source/}) {
          if ($method eq 'GET') {
            if ($path =~ m{/_meta$}) {
              ($status, $ans) = ('404 Not Found', "<status code=\"not_found\"><summary>no state</summary></status>\n");
            } else {
              ($status, $ans) = ('200 OK', "<directory/>\n");
            }
          } else {
            ($status, $ans) = ('200 OK', "ok\n");
          }
        } elsif (defined $method && $method eq 'POST') {
          ($status, $ans) = ('200 OK', "ok\n");
        }
        print $conn "HTTP/1.0 $status\r\nContent-Type: text/xml\r\n"
                  . "Content-Length: " . length($ans) . "\r\nConnection: close\r\n\r\n$ans";
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

# --- start the bridge ---------------------------------------------------------

my ($bridge_port, $obs_port);
sub start_bridge {
  $bridge_port ||= free_port();
  $obs_port ||= free_port();
  open(my $cfg, '>', File::Spec->catfile($testdir, 'config.pm')) or die $!;
  print $cfg "package config;\n"
           . "our \$shared_cookie = 'testcookie';\n"
           . "our \$port = $bridge_port;\n"
           . "our \$obsurl = 'http://127.0.0.1:$obs_port/public';\n"
           . "our \$queue_dir = '" . File::Spec->catdir($testdir, 'queue') . "';\n"
           . "our \$gitea_root = '$gitea_root';\n"
           . "our \$autosetup_prefix = 'git';\n"
           . "our \$api_username = 'bridge';\n"
           . "our \$api_password = 'testpw';\n"
           . "1;\n";
  close($cfg);
  push @children, [start_fake_obs($obs_port)];
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid == 0) {
    chdir($testdir) or POSIX::_exit(1);
    open(STDOUT, '>>', File::Spec->catfile($testdir, 'bridge.log')) or POSIX::_exit(1);
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

ok(start_bridge(), 'bridge answers requests');

# --- helpers ------------------------------------------------------------------

sub read_file {
  my ($path) = @_;
  open(my $fh, '<', $path) or return undef;
  local $/;
  my $content = <$fh>;
  close($fh);
  return $content;
}

sub obs_requests {
  my $log = read_file($obs_log) // '';
  return [ split(/\n/, $log) ];
}

sub count_requests {
  my ($pattern) = @_;
  return scalar grep { $_ =~ $pattern } @{ obs_requests() };
}

# the push event of the repository carrying the manifest; the bridge works
# through the queue synchronously, so the OBS api calls have happened once
# the request returns
sub push_meta_event {
  my $http = HTTP::Tiny->new(timeout => 30);
  return $http->request('POST', "http://127.0.0.1:$bridge_port/repositoryevent",
    { headers => { 'Content-Type' => 'application/json' },
      content => JSON::XS::encode_json({
        'event' => 'push', 'ref' => 'refs/heads/main',
        'repository' => { 'full_name' => 'testorg/meta',
                          'clone_url' => 'http://localhost/testorg/meta.git',
                          'default_branch' => 'main' },
      }) });
}

my $project = 'git:testorg:meta:main';
my $config_state = obs_state_file("/source/$project/_config");

# --- the _config of the manifest branch is uploaded to the project -----------
my $res = push_meta_event();
ok($res->{'success'}, 'push event is acknowledged');
like(join("\n", @{ obs_requests() }), qr{^\QPUT /source/$project/_meta\E$}m, 'the project meta was updated');
is(read_file($config_state), $config1, 'the _config file reached the project');
like(join("\n", @{ obs_requests() }), qr{^\QPUT /source/$project/pkg-a/_meta\E$}m, 'the member package was set up');
is(count_requests(qr{^\QPUT /source/$project/meta/_meta\E$}), 0, 'the manifest repository did not become a package');

# --- an unchanged _config does not create another revision -------------------
$res = push_meta_event();
ok($res->{'success'}, 'second push event is acknowledged');
is(count_requests(qr{^\QPUT /source/$project/_config\E$}), 1, 'the unchanged _config was not uploaded again');
ok(count_requests(qr{^\QGET /source/$project/_config\E$}) >= 2, 'the current _config was compared on every event');

# --- a changed _config is uploaded again --------------------------------------
my $config2 = "Macros: %distro_test 2\n";
write_files($meta_work, { '_config' => $config2 }, []);
commit_repo($meta_work);
push_repo($meta_work, $meta_bare);
$res = push_meta_event();
ok($res->{'success'}, 'push after a _config change is acknowledged');
is(read_file($config_state), $config2, 'the changed _config reached the project');
is(count_requests(qr{^\QPUT /source/$project/_config\E$}), 2, 'the changed _config was uploaded');

# --- a _config removed from the branch is removed from the project -----------
write_files($meta_work, {}, ['_config']);
commit_repo($meta_work);
push_repo($meta_work, $meta_bare);
$res = push_meta_event();
ok($res->{'success'}, 'push after a _config removal is acknowledged');
is(read_file($config_state), undef, 'the _config was removed from the project');
like(join("\n", @{ obs_requests() }), qr{^\QDELETE /source/$project/_config\E$}m, 'the removal was a delete on the project file');

# --- and it comes back when the branch gains it again -------------------------
write_files($meta_work, { '_config' => $config1 }, []);
commit_repo($meta_work);
push_repo($meta_work, $meta_bare);
$res = push_meta_event();
ok($res->{'success'}, 'push after a _config re-add is acknowledged');
is(read_file($config_state), $config1, 'the _config was uploaded again');

done_testing();
