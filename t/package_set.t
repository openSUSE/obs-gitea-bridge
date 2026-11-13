#!/usr/bin/perl -w
#
# Test cases for the BSGit module (Gitea repository lookup on disk).
# Builds a fake Gitea repository store out of bare git repositories.
#
use strict;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use BSGit;
use BSPreset;

plan skip_all => 'git is not available' unless `git --version 2>/dev/null` =~ /^git version/;

$ENV{GIT_AUTHOR_NAME} = 'test';
$ENV{GIT_AUTHOR_EMAIL} = 'test@example.com';
$ENV{GIT_COMMITTER_NAME} = 'test';
$ENV{GIT_COMMITTER_EMAIL} = 'test@example.com';

my $root = tempdir(CLEANUP => 1);

# create a bare repository at $root/gitea-repositories/$org/$name.git with a
# commit on each of the given branches; HEAD points at the first branch
sub make_repo {
  my ($org, $name, @branches) = @_;
  my $work = "$root/work/$name";
  my $repodir = "$root/gitea-repositories/$org";
  mkdir $repodir unless -d $repodir;
  mkdir $work unless -d $work;
  is(system('git', 'init', '-q', $work), 0, "git init $name") or return;
  for my $branch (@branches) {
    is(system('git', '-C', $work, 'checkout', '-q', '-B', $branch), 0, "checkout $name#$branch") or return;
    open(my $fh, '>', "$work/file-$branch") or die("cannot write: $!\n");
    print $fh "$branch\n";
    close($fh);
    is(system('git', '-C', $work, 'add', '.'), 0, "add $name#$branch") or return;
    is(system('git', '-C', $work, 'commit', '-q', '-m', $branch), 0, "commit $name#$branch") or return;
  }
  my $bare = "$repodir/$name.git";
  is(system('git', 'clone', '-q', '--bare', $work, $bare), 0, "clone --bare $name") or return;
  is(system('git', "--git-dir=$bare", 'symbolic-ref', 'HEAD', "refs/heads/$branches[0]"), 0, "set HEAD of $name") or return;
}

make_repo('testorg', 'repo-a', 'main', 'factory');
make_repo('testorg', 'repo-b', 'factory');
make_repo('testorg', 'repo-c', 'main');

# --- org_repo_names ---
is_deeply(BSGit::org_repo_names($root, 'TestOrg'), ['repo-a', 'repo-b', 'repo-c'], 'org repo names found and sorted');
is_deeply(BSGit::org_repo_names($root, 'testorg'), ['repo-a', 'repo-b', 'repo-c'], 'owner matching is case insensitive like gitea');
is_deeply(BSGit::org_repo_names($root, 'missing-org'), [], 'unknown organisation -> empty list');

# --- git_ref_exists ---
ok(BSGit::git_ref_exists("$root/gitea-repositories/testorg/repo-a.git", 'refs/heads/factory'), 'existing branch found');
ok(!BSGit::git_ref_exists("$root/gitea-repositories/testorg/repo-c.git", 'refs/heads/factory'), 'missing branch not found');

# --- git_get_default_branch ---
is(BSGit::git_get_default_branch("$root/gitea-repositories/testorg/repo-a.git"), 'main', 'default branch of repo-a');
is(BSGit::git_get_default_branch("$root/gitea-repositories/testorg/repo-b.git"), 'factory', 'default branch of repo-b');

# --- org_repo_members ---
my $members = BSGit::org_repo_members($root, 'TestOrg', 'factory');
is_deeply([ map { $_->{'name'} } @$members ], ['repo-a', 'repo-b'], 'members are the repos having the branch');
is_deeply($members->[0], { 'name' => 'repo-a', 'branch' => 'factory' }, 'member carries name and branch');

is_deeply(BSGit::org_repo_members($root, 'TestOrg', 'main'), [ { 'name' => 'repo-a', 'branch' => 'main' }, { 'name' => 'repo-c', 'branch' => 'main' } ], 'members for another branch');

my $defaults = BSGit::org_repo_members($root, 'TestOrg', 'default');
is_deeply($defaults, [
  { 'name' => 'repo-a', 'branch' => 'main' },
  { 'name' => 'repo-b', 'branch' => 'factory' },
  { 'name' => 'repo-c', 'branch' => 'main' },
], 'branch default uses the default branch of every repo');

is_deeply(BSGit::org_repo_members($root, 'missing-org', 'factory'), [], 'members of unknown organisation -> empty');

# --- combined with BSPreset selection ---
my $resolved = BSPreset::resolve_package_set({ 'branch' => 'factory', 'exclude' => ['repo-b'] }, 'https://gitea.example.com/TestOrg/meta.git');
my $selected = BSPreset::select_members(BSGit::org_repo_members($root, $resolved->{'organisation'}, $resolved->{'branch'}), $resolved);
is_deeply([ map { $_->{'name'} } @$selected ], ['repo-a'], 'exclude list filters the enumerated members');
my $own_resolved = BSPreset::resolve_package_set({ 'branch' => 'factory' }, 'https://gitea.example.com/TestOrg/repo-a.git');
my $own_selected = BSPreset::select_members(BSGit::org_repo_members($root, $own_resolved->{'organisation'}, $own_resolved->{'branch'}), $own_resolved);
is_deeply([ map { $_->{'name'} } @$own_selected ], ['repo-b'], 'the manifest repository is no member of its own package_set');
is(BSPreset::scmsync_url_for('https://gitea.example.com/TestOrg/repo-a.git', $resolved->{'organisation'}, 'repo-a', 'factory'),
   'https://gitea.example.com/TestOrg/repo-a.git#factory', 'member scmsync url');

# --- dir_access_error / repo_access_error ---
is(BSGit::dir_access_error($root), undef, 'readable directory -> no access error');
is(BSGit::dir_access_error("$root/does-not-exist"), undef, 'missing directory -> no access error');
is(BSGit::repo_access_error("$root/gitea-repositories/testorg/repo-a.git"), undef, 'readable repository -> no access error');
is(BSGit::repo_access_error("$root/does-not-exist.git"), undef, 'missing repository -> no access error');

SKIP: {
  skip 'root bypasses file permissions', 3 if $> == 0;
  my $glock = "$root/gitea-repositories/locked-org";
  mkdir $glock or die("cannot mkdir: $!\n");
  chmod 000, $glock;
  like(BSGit::dir_access_error($glock), qr/Permission denied/, 'unreadable organisation directory reported');
  like(BSGit::repo_access_error("$glock/x.git"), qr/Permission denied/, 'repository below unreadable directory reported');
  chmod 0755, $glock;
  is(BSGit::dir_access_error($glock), undef, 'readable again -> no access error');
}

done_testing();
