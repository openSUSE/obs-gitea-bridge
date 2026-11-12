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

package BSGit;

use strict;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(git_show git_capture git_get_default_branch git_ref_exists git_lstree_sources org_repo_names org_repo_members);

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

# Run a git command and return its standard output as an arrayref of lines,
# or undef on failure (git's error output is suppressed).
sub git_capture {
  my (@args) = @_;
  my $pid = open(my $fh, '-|');
  if (!defined $pid) {
    die("cannot fork: $!\n");
  }
  if ($pid == 0) {
    open(STDERR, '>', '/dev/null');
    exec('git', @args);
    exit 255;
  }
  my @lines = <$fh>;
  close($fh);
  return undef if ($? >> 8) != 0;
  chomp @lines;
  return \@lines;
}

# Return the short name of the default branch of the given git repository,
# or undef when it cannot be determined.
sub git_get_default_branch {
  my ($gitdir) = @_;
  return undef unless defined $gitdir;
  my $out = git_capture('--git-dir=' . $gitdir, 'symbolic-ref', '--short', 'HEAD');
  return undef unless $out && defined $out->[0] && length $out->[0];
  return $out->[0];
}

# Return whether the given ref exists in the git repository.
sub git_ref_exists {
  my ($gitdir, $ref) = @_;
  return 0 unless defined $gitdir && defined $ref && length $ref;
  return defined git_capture('--git-dir=' . $gitdir, 'show-ref', '--verify', '-q', $ref);
}

# List the package source entries at the given tree level of the given git
# repository, as an arrayref of names (empty arrayref when the level has no
# package sources), or undef on failure. Plain files are not package sources.
# Both directories and submodules are package sources: a submodule entry is a
# single commit reference inside the tree.
sub git_lstree_sources {
  my ($gitdir, $tree) = @_;
  return undef unless defined $gitdir && defined $tree;
  my $out = git_capture('--git-dir=' . $gitdir, 'ls-tree', "$tree");
  my @sources;
  if ($out) {
    for my $line (@$out) {
      next unless $line =~ m{^\S+\s+(?:tree|commit)\s+\S+\t(.+)$};
      push @sources, $1;
    }
  }
  return \@sources;
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
