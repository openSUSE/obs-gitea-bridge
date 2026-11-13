#!/usr/bin/perl -w
#
# End to end tests for the handling of renamed and transferred repositories:
# the bridge has to delete the OBS projects of the old name and create the
# projects of the new name from the branches of the moved git repository. A
# fake OBS api keeps a small searchable project store, a fake Gitea repository
# store provides the git side; a rename is simulated by moving the bare
# repository the way gitea does it.
#
use strict;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
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
my $testdir = tempdir('obs-gitea-bridge-rename-XXXXXX', TMPDIR => 1, CLEANUP => 1);

# isolated copy of the bridge, its own config.pm below
for my $f (grep { !m{/config\.pm$} } glob("$srcdir/*.pm"), "$srcdir/gitea_obs_bridge") {
  my $base = (File::Spec->splitpath($f))[2];
  copy($f, File::Spec->catfile($testdir, $base)) or die "cannot copy $f: $!";
}
chmod 0755, File::Spec->catfile($testdir, 'gitea_obs_bridge');

my $gitea_root = File::Spec->catdir($testdir, 'gitea');
my $obs_state = File::Spec->catdir($testdir, 'obs-state');
my $obs_log = File::Spec->catfile($testdir, 'obs-requests.log');
my $orgdir = File::Spec->catdir($gitea_root, 'gitea-repositories', 'testorg');
make_path($orgdir, $obs_state);

my @children;
END { kill 'TERM', @$_ for @children; }

sub free_port {
  my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
        or die "cannot probe a free port: $!";
  my $port = $s->sockport;
  close($s);
  return $port;
}

# --- fake gitea repositories --------------------------------------------------

# create a bare repository at $orgdir/$name.git with the given files committed
# on branch main, returns the work directory
sub make_repo {
  my ($name, $files) = @_;
  my $work = File::Spec->catdir($testdir, 'work', $name);
  my $bare = File::Spec->catfile($orgdir, "$name.git");
  make_path($work);
  is(system('git', 'init', '-q', $work), 0, "git init $name") or return;
  is(system('git', '-C', $work, 'checkout', '-q', '-B', 'main'), 0, "checkout $name#main") or return;
  write_files($work, $files);
  is(system('git', '-C', $work, 'add', '-A'), 0, 'git add') or return;
  is(system('git', '-C', $work, 'commit', '-q', '-m', 'test'), 0, 'git commit') or return;
  is(system('git', 'clone', '-q', '--bare', $work, $bare), 0, "clone --bare $name") or return;
  return $work;
}

sub write_files {
  my ($dir, $files) = @_;
  for my $file (keys %{ $files || {} }) {
    open(my $fh, '>', File::Spec->catfile($dir, $file)) or die "cannot write $file: $!";
    print $fh $files->{$file};
    close($fh);
  }
}

# gitea moved the bare repository to the new name
sub move_repo {
  my ($from, $to) = @_;
  ok(rename(File::Spec->catfile($orgdir, "$from.git"), File::Spec->catfile($orgdir, "$to.git")),
     "bare repository $from.git moved to $to.git");
}

my $manifest = <<'YAML';
presets:
  - name: openSUSE_Tumbleweed
    default: "true"
    architectures:
      - x86_64
    repo:
      - https://download.example.org/testorg/standard
YAML

my $set_manifest = $manifest . "package_set:\n  branch: main\n";

my $config1 = "Macros: %distro_test 1\n";

# --- fake OBS api with a searchable project store ------------------------------

# the store is a tree below $obs_state: one directory per project, below that
# one file per project file and one directory per package; a PUT project _meta
# creates the project. The fake only sees the paths after BSRPC has dropped
# the /public prefix of $obsurl.
sub state_path {
  my ($path) = @_;
  return undef unless defined $path && $path =~ s{^/source/}{} && length $path && $path !~ m{\.\.};
  return File::Spec->catfile($obs_state, split(m{/}, $path));
}

sub url_decode {
  my ($s) = @_;
  $s =~ s/\+/ /g;
  $s =~ s/%([0-9a-fA-F]{2})/chr(hex($1))/ge;
  return $s;
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
        my ($path, $query) = split(/\?/, $target // '', 2);
        if (open(my $log, '>>', $obs_log)) { print $log "$method $path\n"; close($log); }
        my ($status, $ans) = ('404 Not Found', "<status code=\"not_found\"><summary>no state</summary></status>\n");
        if (defined $path && $path =~ m{/configuration$}) {
          ($status, $ans) = ('200 OK',
            "<configuration><download_url>https://download.example.org/</download_url></configuration>\n");
        } elsif (defined $path && $path =~ m{/search/project$}) {
          # only the starts-with match the bridge sends is supported
          my ($prefix) = url_decode($query // '') =~ /match=starts-with\(\@name,'([^']*)'\)/;
          my @hits;
          if (defined $prefix && length($prefix) && opendir(my $dh, $obs_state)) {
            @hits = sort grep { /^\Q$prefix\E/ && -d File::Spec->catfile($obs_state, $_) } readdir($dh);
            closedir($dh);
          }
          ($status, $ans) = ('200 OK',
            "<collection>\n" . join('', map { qq{<project name="$_"/>\n} } @hits) . "</collection>\n");
        } elsif (defined $path && $path =~ m{^/source/} && defined $method) {
          my $state = state_path($path);
          if (!defined $state) {
            ($status, $ans) = ('400 Bad Request', "bad path\n");
          } elsif ($method eq 'PUT') {
            make_path(dirname($state));
            if (open(my $fh, '>', $state)) { print $fh $body; close($fh); ($status, $ans) = ('200 OK', "ok\n"); }
          } elsif ($method eq 'GET') {
            if (-d $state) {
              my @entries;
              if (opendir(my $dh, $state)) { @entries = grep { $_ !~ /^\.\.?$/ } readdir($dh); closedir($dh); }
              ($status, $ans) = ('200 OK',
                "<directory>\n" . join('', map { qq{<entry name="$_"/>\n} } @entries) . "</directory>\n");
            } elsif (-f $state) {
              local $/;
              if (open(my $fh, '<', $state)) { $ans = <$fh>; close($fh); ($status, $ans) = ('200 OK', $ans // ''); }
            }
          } elsif ($method eq 'DELETE') {
            if (-d $state) { remove_tree($state); ($status, $ans) = ('200 OK', "ok\n"); }
            elsif (-f $state) { unlink($state); ($status, $ans) = ('200 OK', "ok\n"); }
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

# --- start the bridge ----------------------------------------------------------

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

# --- helpers -------------------------------------------------------------------

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

sub have_request {
  my ($request) = @_;
  return grep { $_ eq $request } @{ obs_requests() };
}

# the bridge works the queue synchronously, so the OBS api calls have happened
# once the webhook request returns
sub send_event {
  my ($payload, $event) = @_;
  my $http = HTTP::Tiny->new(timeout => 30);
  my $res = $http->request('POST', "http://127.0.0.1:$bridge_port/repositoryevent",
    { headers => { 'Content-Type' => 'application/json' }, content => JSON::XS::encode_json($payload) });
  return $res;
}

sub push_event {
  my ($fullname) = @_;
  return send_event({
    'event' => 'push', 'ref' => 'refs/heads/main',
    'repository' => { 'full_name' => $fullname,
                      'clone_url' => "http://localhost/$fullname.git",
                      'default_branch' => 'main' },
  });
}

# a rename payload as gitea sends it: the repository carries the new name,
# the changes the old repository name
sub rename_event {
  my ($new_fullname, $old_repo) = @_;
  return send_event({
    'event' => 'repository',
    'action' => 'renamed',
    'repository' => { 'full_name' => $new_fullname,
                      'clone_url' => "http://localhost/$new_fullname.git",
                      'default_branch' => 'main' },
    'changes' => { 'name' => { 'from' => $old_repo } },
  });
}

# --- a plain repository: the project follows the new name ----------------------
my $meta_work = make_repo('meta', { '_manifest' => $manifest });
my $res = push_event('testorg/meta');
ok($res->{'success'}, 'push event is acknowledged');
ok(have_request('PUT /source/git:testorg:meta:main/_meta'), 'the project of the branch was created');

# an unrelated dev branch without _manifest must not become a project
is(system('git', '-C', $meta_work, 'checkout', '-q', '-b', 'dev'), 0, 'create branch dev');
unlink File::Spec->catfile($meta_work, '_manifest') or die "cannot remove _manifest: $!";
is(system('git', '-C', $meta_work, 'add', '-A'), 0, 'git rm the manifest on dev');
is(system('git', '-C', $meta_work, 'commit', '-q', '-m', 'no manifest'), 0, 'commit on dev');
is(system('git', '-C', $meta_work, 'push', '-q', File::Spec->catfile($orgdir, 'meta.git'), 'refs/heads/dev:refs/heads/dev'), 0, 'publish dev');

move_repo('meta', 'meta2');
$res = rename_event('testorg/meta2', 'meta');
ok($res->{'success'}, 'rename event is acknowledged');
ok(have_request('DELETE /source/git:testorg:meta:main'), 'the project of the old name was deleted');
ok(have_request('PUT /source/git:testorg:meta2:main/_meta'), 'the project of the new name was created');
ok(!have_request('PUT /source/git:testorg:meta2:dev/_meta'), 'a branch without _manifest did not become a project');

# --- a package_set project: packages and _config follow the new name -----------
make_repo('pkg-a', { 'README' => "package a\n" });
make_repo('setmeta', { '_manifest' => $set_manifest, '_config' => $config1 });
$res = push_event('testorg/setmeta');
ok($res->{'success'}, 'push event for the package_set repository is acknowledged');
ok(have_request('PUT /source/git:testorg:setmeta:main/_meta'), 'the package_set project was created');
ok(have_request('PUT /source/git:testorg:setmeta:main/pkg-a/_meta'), 'the member package was created');
is(read_file(state_path('/source/git:testorg:setmeta:main/_config')), $config1, 'the _config reached the project');

move_repo('setmeta', 'setmeta2');
$res = rename_event('testorg/setmeta2', 'setmeta');
ok($res->{'success'}, 'rename of the package_set repository is acknowledged');
ok(have_request('DELETE /source/git:testorg:setmeta:main'), 'the package_set project of the old name was deleted');
ok(have_request('PUT /source/git:testorg:setmeta2:main/_meta'), 'the package_set project was created under the new name');
ok(have_request('PUT /source/git:testorg:setmeta2:main/pkg-a/_meta'), 'the member package came along');
is(read_file(state_path('/source/git:testorg:setmeta2:main/_config')), $config1, 'the _config came along to the new project');

# --- a repository without _manifest: only the org packages are refreshed -------
move_repo('pkg-a', 'pkg-b');
$res = rename_event('testorg/pkg-b', 'pkg-a');
ok($res->{'success'}, 'rename of the member repository is acknowledged');
ok(have_request('PUT /source/git:testorg:setmeta2:main/pkg-b/_meta'), 'the organisation project knows the new member name');
ok(have_request('DELETE /source/git:testorg:setmeta2:main/pkg-a'), 'the package of the old member name was removed');
ok(!have_request('PUT /source/git:testorg:pkg-b:main/_meta'), 'no project was created for the repository without _manifest');

# --- rename payloads without a real change are acknowledged but skipped --------
my $before = scalar @{ obs_requests() };
$res = rename_event('testorg/pkg-b', 'pkg-b');   # old name equals new name
ok($res->{'success'}, 'a rename without a real change is acknowledged');
$res = send_event({ 'event' => 'repository', 'action' => 'renamed',
  'repository' => { 'full_name' => 'testorg/pkg-b', 'clone_url' => 'http://localhost/testorg/pkg-b.git' } });
ok($res->{'success'}, 'a rename without changes is acknowledged');
is(scalar @{ obs_requests() }, $before, 'neither of them touched the OBS api');

# --- a transfer to another owner moves the whole project tree -------------------
my $neworgdir = File::Spec->catdir($gitea_root, 'gitea-repositories', 'neworg');
ok(rename($orgdir, $neworgdir), 'the organisation directory was moved');
$res = send_event({ 'event' => 'repository',
  'action' => 'transferred',
  'repository' => { 'full_name' => 'neworg/setmeta2', 'clone_url' => 'http://localhost/neworg/setmeta2.git' },
  'changes' => { 'owner' => { 'from' => { 'organization' => { 'login' => 'testorg' } } } },
});
ok($res->{'success'}, 'transfer event is acknowledged');
ok(have_request('DELETE /source/git:testorg:setmeta2:main'), 'the project of the old owner was deleted');
ok(have_request('PUT /source/git:neworg:setmeta2:main/_meta'), 'the project was created below the new owner');
ok(have_request('PUT /source/git:neworg:setmeta2:main/pkg-b/_meta'), 'the member packages came along');

done_testing();
