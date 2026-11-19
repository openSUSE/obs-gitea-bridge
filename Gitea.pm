#
# Copyright (c) 2022 Adrian Schroeter, SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
#
# Read access to the git repositories of a Gitea instance. The bridge runs
# on the Gitea server itself, so the repositories are read directly from the
# bare git object stores below $gitea_root/gitea-repositories.
#

package Gitea;

use strict;

use Errno qw(EACCES ENOENT ENOTDIR);

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(git_show git_capture git_get_default_branch git_ref_exists git_branches git_lstree_sources org_repo_names org_repo_members dir_access_error repo_access_error);

# Read the given file from the given branch of a git repository. Returns
# undef when the repository or the file does not exist (git's error output
# is suppressed).
sub git_show {
  my ($gitdir, $branch, $file) = @_;
  my $pid = open(my $fh, '-|');
  if (!defined $pid) {
    die("cannot fork: $!\n");
  }
  if ($pid == 0) {
    open(STDERR, '>', '/dev/null');
    exec('git', "--git-dir=$gitdir", 'show', "$branch:$file");
    exit 255;
  }
  my $data = do { local $/; <$fh> };
  close($fh);
  return undef if ($? >> 8) != 0;
  return $data;
}

# Run a git command on the given git directory and return its standard
# output as an arrayref of lines, or undef on failure (git's error output is
# suppressed). The --git-dir argument is always added as git's first
# argument, so the command never depends on the current directory.
sub git_capture {
  my ($gitdir, @args) = @_;
  my $pid = open(my $fh, '-|');
  if (!defined $pid) {
    die("cannot fork: $!\n");
  }
  if ($pid == 0) {
    open(STDERR, '>', '/dev/null');
    exec('git', "--git-dir=$gitdir", @args);
    exit 255;
  }
  my @lines = <$fh>;
  close($fh);
  return undef if ($? >> 8) != 0;
  chomp @lines;
  return \@lines;
}

# Read the contents of a single ref file, whitespace stripped, or undef when
# the file does not exist or is empty.
sub read_ref_file {
  my ($path) = @_;
  open(my $fh, '<', $path) or return undef;
  my $line = <$fh>;
  close($fh);
  return undef unless defined $line;
  $line =~ s/\s+$//;
  return length($line) ? $line : undef;
}

# Look up a ref name in a packed-refs file. The lines are "<sha> <refname>",
# "#" comment lines and "^<sha>" peel lines which belong to the preceding tag
# ref are skipped. Returns the sha or undef.
sub read_packed_ref {
  my ($path, $ref) = @_;
  open(my $fh, '<', $path) or return undef;
  my $found;
  while (my $line = <$fh>) {
    next if $line =~ /^[#\^]/;
    chomp $line;
    my ($sha, $name) = split(' ', $line, 2);
    next unless defined $name;
    if ($name eq $ref) {
      $found = $sha;
      last;
    }
  }
  close($fh);
  return $found;
}

# Return the short name of the default branch of the given git repository,
# or undef when it cannot be determined. Reads the HEAD file directly: on a
# large instance every fork saved matters, the organisation scans check the
# refs of thousands of repositories.
sub git_get_default_branch {
  my ($gitdir) = @_;
  return undef unless defined $gitdir && length $gitdir;
  my $head = read_ref_file("$gitdir/HEAD");
  return undef unless defined $head;
  return undef unless $head =~ m{^ref: refs/heads/(.+)$};
  return $1;
}

# Return whether the given ref exists in the git repository. The loose ref
# file and packed-refs are read directly instead of forking git, so this
# stays cheap when run over thousands of repositories.
sub git_ref_exists {
  my ($gitdir, $ref) = @_;
  return 0 unless defined $gitdir && defined $ref && length $ref;
  my $loose = read_ref_file("$gitdir/$ref");
  return 1 if defined $loose && $loose !~ /^ref:/;
  return defined(read_packed_ref("$gitdir/packed-refs", $ref)) ? 1 : 0;
}

# List the branch names of a git repository. Returns an empty list for a
# repository without branches and undef when the repository cannot be read.
sub git_branches {
  my ($gitdir) = @_;
  return undef unless defined $gitdir && length $gitdir;
  my $lines = git_capture($gitdir, 'for-each-ref', '--format=%(refname:lstrip=2)', 'refs/heads/');
  return undef unless defined $lines;
  return [ grep { length $_ } @$lines ];
}

# List the package source entries at the given tree level of the given git
# repository, as an arrayref of names (empty arrayref when the level has no
# package sources), or undef on failure. Plain files are not package sources.
# Both directories and submodules are package sources: a submodule entry is a
# single commit reference inside the tree.
sub git_lstree_sources {
  my ($gitdir, $tree) = @_;
  return undef unless defined $gitdir && defined $tree;
  my $out = git_capture($gitdir, 'ls-tree', "$tree");
  my @sources;
  if ($out) {
    for my $line (@$out) {
      next unless $line =~ m{^\S+\s+(?:tree|commit)\s+\S+\t(.+)$};
      push @sources, $1;
    }
  }
  return \@sources;
}

# Report a permission problem on a directory path: returns an error string
# when the directory cannot be opened by us, undef when it opens fine or
# simply does not exist. Missing or blocked parent directories show up here
# as an EACCES on the open, so callers can distinguish "not there" (normal,
# e.g. a repository without a _manifest) from "not readable for the bridge
# user" (a setup problem worth logging). Gitea creates its repository store
# as user gitea with mode 0700, see the permissions section in the README.
sub dir_access_error {
  my ($dir) = @_;
  return undef unless defined $dir && length $dir;
  if (opendir(my $dh, $dir)) {
    closedir($dh);
    return undef;
  }
  return undef if $! == ENOENT || $! == ENOTDIR;
  return "$dir: $!\n";
}

# Report a read problem on a bare git repository: like dir_access_error, but
# also checks that the HEAD file can actually be read, since git needs
# directory traversal and file read access, not just directory listing.
sub repo_access_error {
  my ($gitdir) = @_;
  return undef unless defined $gitdir && length $gitdir;
  my $err = dir_access_error($gitdir);
  return $err if defined $err;
  return undef unless -d $gitdir;
  # reading the repository needs traversal plus read access on the objects
  if (!open(my $fh, '<', "$gitdir/HEAD")) {
    return "$gitdir/HEAD: $!\n" unless $! == ENOENT;
  } else {
    close($fh);
  }
  return undef;
}

# List the names of the git repositories a Gitea organisation owns, i.e. the
# directories ending in .git below $root/gitea-repositories/$org, as a sorted
# arrayref (empty when the organisation does not exist). Gitea stores the
# repositories below the lower case owner name.
sub org_repo_names {
  my ($root, $org) = @_;
  return [] unless defined $root && defined $org && length $org;
  my $dir = "$root/gitea-repositories/" . lc($org);
  return [] unless -d $dir;
  opendir(my $dh, $dir) or return [];
  my @names = sort map { substr($_, 0, -4) } grep { /\.git$/ && -d "$dir/$_" } readdir($dh);
  closedir($dh);
  return \@names;
}

# Determine the members of an organisation wide package set: all repositories
# of the organisation that have the given branch. A branch of "default" uses
# the default branch of every repository. Returns a sorted arrayref of
# {name, branch} hashrefs.
sub org_repo_members {
  my ($root, $org, $branch) = @_;
  return [] unless defined $root && defined $org && length $org && defined $branch && length $branch;
  my $dir = "$root/gitea-repositories/" . lc($org);
  my @members;
  for my $name (@{ org_repo_names($root, $org) }) {
    my $gitdir = "$dir/$name.git";
    my $b = $branch;
    if ($b eq 'default') {
      $b = git_get_default_branch($gitdir);
      next unless defined $b && length $b;
    }
    next unless git_ref_exists($gitdir, "refs/heads/$b");
    push @members, { 'name' => $name, 'branch' => $b };
  }
  return \@members;
}

1;
