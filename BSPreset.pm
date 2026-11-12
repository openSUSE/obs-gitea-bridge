#
# Copyright (c) 2022 Adrian Schroeter, SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
#
# Convert a bridge _manifest into a buildservice project definition.
#

package BSPreset;

use strict;

use YAML::XS ();
use XML::Structured;
use BSXML;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(manifest_presets preset_data preset_xml manifest_package_set resolve_package_set select_members sanitize_package_name scmsync_url_for package_meta_xml normalize_gitprefix gitea_event_kind branch_project_name repo_project_prefix git_host scmsync_from_source);

# Prefix stripped from repo URLs to derive the OBS path project/repository.
# Made configurable via config.pm ($BSPreset::gitprefix).
our $gitprefix = 'https://download.opensuse.org/repositories/';

# Normalize the download url prefix which gets stripped from repository urls
# to derive the OBS path project/repository. The OBS api reports the
# download_url without a trailing slash while the repository urls contain one
# before the project name, so the prefix must always end in exactly one slash
# or the derived project names keep a leading slash.
sub normalize_gitprefix {
  my ($prefix) = @_;
  return undef unless defined $prefix && length $prefix;
  $prefix =~ s{/+$}{};
  return "$prefix/";
}

# Parse a _manifest yaml string and return the presets list.
# Returns undef when the manifest is not a hash or does not contain
# a presets list (in which case the project should be deleted).
sub manifest_presets {
  my ($manifest) = @_;
  my $data = eval { YAML::XS::Load($manifest) };
  die("cannot parse _manifest: $@\n") if $@;
  return undef unless ref($data) eq 'HASH';
  return undef unless ref($data->{'presets'}) eq 'ARRAY';
  return $data->{'presets'};
}

# Return the subdirectories array from a _manifest string, or undef when the
# manifest does not define any (package sources then live at the top level).
sub manifest_subdirectories {
  my ($manifest) = @_;
  my $data = eval { YAML::XS::Load($manifest) };
  die("cannot parse _manifest: $@\n") if $@;
  return undef unless ref($data) eq 'HASH';
  return $data->{'subdirectories'} if ref($data->{'subdirectories'}) eq 'ARRAY';
  return undef;
}

# Return the package_set section from a _manifest string as a hashref, or
# undef when the manifest does not define one. The section declares all
# repositories of a Gitea organisation with a given branch as build packages.
# Dies when the section has an invalid shape or names no branch.
sub manifest_package_set {
  my ($manifest) = @_;
  my $data = eval { YAML::XS::Load($manifest) };
  die("cannot parse _manifest: $@\n") if $@;
  return undef unless ref($data) eq 'HASH';
  my $set = $data->{'package_set'};
  return undef unless defined $set;
  die("invalid package_set section in _manifest\n") unless ref($set) eq 'HASH';
  die("package_set section in _manifest needs a branch\n") unless defined $set->{'branch'} && !ref($set->{'branch'}) && length $set->{'branch'};
  return $set;
}

# Split a git url into its host and owner parts. The host is returned without
# a scheme or user, the owner is the first path element below the host.
# Returns undef when the url cannot be parsed.
sub giturl_host_owner {
  my ($url) = @_;
  return undef unless defined $url;
  my ($host, $path);
  if ($url =~ m{^(?:https?|ssh|git)://[^@/]+@([^/]+)/(.+)$}) {
    ($host, $path) = ($1, $2);
  } elsif ($url =~ m{^(?:https?|ssh|git)://([^/]+)/(.+)$}) {
    ($host, $path) = ($1, $2);
  } elsif ($url =~ m{^[^@/]+\@([^:]+):(.+)$}) {
    ($host, $path) = ($1, $2);
  } else {
    return undef;
  }
  $path =~ s{/+$}{};
  $path =~ s/\.git$//;
  my ($owner) = split('/', $path, 2);
  return undef unless defined $host && length $host && defined $owner && length $owner;
  return ($host, $owner);
}

# Resolve the defaults of a package_set from a _manifest against the git url
# of the repository carrying the manifest: an unset server and organisation
# default to the Gitea host and owner of that repository, so an empty section
# refers to the Gitea server and organisation the local repository is hosted
# on. Only the local Gitea instance is supported, so a server different from
# the repository host is an error. Returns the resolved set as a hashref with
# server, organisation, branch and exclude (a name -> 1 hashref).
sub resolve_package_set {
  my ($set, $clone_url) = @_;
  return undef unless ref($set) eq 'HASH';
  my ($host, $owner) = giturl_host_owner($clone_url);
  die("cannot determine gitea host and organisation from '$clone_url'\n") unless defined $host;
  my $server = $set->{'server'};
  if (defined $server && length $server) {
    die("invalid server '$server' in package_set\n") if ref($server);
    my ($serverhost) = ($server =~ m{^(?:\w+://)?(?:[^@/]+@)?([^/:]+)});
    die("invalid server '$server' in package_set\n") unless defined $serverhost && length $serverhost;
    die("remote package_set server '$server' not supported, this instance serves '$host'\n") if $serverhost ne $host;
  }
  my $organisation = $set->{'organisation'};
  die("invalid organisation in package_set\n") if defined $organisation && ref($organisation);
  $organisation = $owner unless defined $organisation && length $organisation;
  my %exclude;
  if (defined $set->{'exclude'}) {
    die("invalid exclude list in package_set\n") unless ref($set->{'exclude'}) eq 'ARRAY';
    $exclude{$_} = 1 for grep { defined $_ && !ref $_ && length $_ } @{$set->{'exclude'}};
  }
  return { 'server' => $host, 'organisation' => $organisation, 'branch' => $set->{'branch'}, 'exclude' => \%exclude };
}

# Filter the candidate members (arrayref of {name, branch} hashrefs as
# returned by BSGit::org_repo_members) through the exclude list of a resolved
# package_set. Returns a sorted arrayref.
sub select_members {
  my ($members, $resolved) = @_;
  return [] unless ref($members) eq 'ARRAY';
  my $exclude = ref($resolved) eq 'HASH' ? $resolved->{'exclude'} : undef;
  $exclude = {} unless ref($exclude) eq 'HASH';
  return [ sort { $a->{'name'} cmp $b->{'name'} } grep { ref($_) eq 'HASH' && defined $_->{'name'} && length $_->{'name'} && !$exclude->{$_->{'name'}} } @$members ];
}

# Turn a git repository name into a valid OBS package name.
sub sanitize_package_name {
  my ($name) = @_;
  return undef unless defined $name;
  $name =~ s/[^+._a-zA-Z0-9-]/_/g;
  return $name;
}

# Build the "GIT_URL#BRANCH" scmsync url of a package_set member repository
# on the same Gitea instance as the given reference clone url. The url is
# rebuilt from the scheme, user and host of the reference url, so a Gitea
# hosted below a sub-path is not preserved. Supports both scheme style and scp
# style urls.
sub scmsync_url_for {
  my ($clone_url, $org, $repo, $branch) = @_;
  return undef unless defined $org && length $org && defined $repo && length $repo && defined $branch && length $branch;
  return undef unless defined $clone_url;
  if ($clone_url =~ m{^((?:https?|ssh|git)://(?:[^@/]+@)?[^/]+)/}) {
    return "$1/$org/$repo.git#$branch";
  }
  if ($clone_url =~ m{^([^@/]+\@[^:/]+):}) {
    return "$1:$org/$repo.git#$branch";
  }
  return undef;
}

# Serialize the OBS package meta xml for a git backed package with its own
# package level scmsync url.
sub package_meta_xml {
  my ($projectname, $packagename, $scmsync) = @_;
  return XMLout($BSXML::pack, { 'name' => $packagename, 'project' => $projectname, 'scmsync' => $scmsync });
}

# Compute the list of package source directories. $subdirectories is the
# manifest subdirectories array (undef means the top level). %entries maps a
# base directory to the list of its top level entries, '' being the
# repository root. Every entry inside any of the base directories is a
# package source.
sub package_source_dirs {
  my ($subdirectories, %entries) = @_;
  my @dirs;
  if (ref($subdirectories) eq 'ARRAY' && @$subdirectories) {
    for my $sub (@$subdirectories) {
      next unless defined $sub;
      my $base = $sub;
      $base =~ s{^\./}{};
      $base =~ s{/$}{};
      push @dirs, map { "$base/$_" } grep { length } @{$entries{$base} || []};
    }
  } else {
    push @dirs, grep { length } @{$entries{''} || []};
  }
  return \@dirs;
}

# Given the latest hash for each package source directory in the fork
# (%hashes_a) and in the repository it was forked from (%hashes_b), return
# the package source directories that differ or that do not exist in the
# forked-from repository at all.
sub changed_package_sources {
  my ($dirs, $hashes_a, $hashes_b) = @_;
  my @changed;
  for my $dir (@$dirs) {
    my $a = $hashes_a->{$dir};
    next unless defined $a && length $a;
    my $b = $hashes_b->{$dir};
    push @changed, $dir if !defined $b || $a ne $b;
  }
  return \@changed;
}

# Append an onlybuild=... CGI parameter for each changed package source to a
# scmsync url (GIT_URL#BRANCH), so a fork build only builds the packages that
# actually changed. Package sources may live below manifest subdirectories; the
# onlybuild parameter takes the package name (the last path component), not
# the subdirectory path. Returns the modified url unchanged when there is
# nothing to restrict or when it already has an onlybuild parameter.
sub scmsync_with_onlybuild {
  my ($scmsync, $changed) = @_;
  return $scmsync unless defined $scmsync;
  return $scmsync unless ref($changed) eq 'ARRAY' && @$changed;
  return $scmsync if $scmsync =~ /\?onlybuild=/;
  my @packages;
  my %seen;
  for my $dir (@$changed) {
    next unless defined $dir && length $dir;
    (my $pkg = $dir) =~ s{.*/}{};
    next unless length $pkg && !$seen{$pkg}++;
    push @packages, $pkg;
  }
  return $scmsync unless @packages;
  my $params = join('&', map { "onlybuild=$_" } @packages);
  if ($scmsync =~ s{#}{?$params#}) {
    return $scmsync;
  }
  return "$scmsync?$params";
}

# Build the $BSXML::proj conformant data structure for a list of presets.
# $extrapaths is an optional hashref mapping repository name to a list of
# {project, repository} path entries. In the fork case these entries REPLACE
# the path entries derived from the manifest repo urls (e.g. the fork builds
# against its upstream project and this project's own repositories, not
# against the base distribution). $scmsync is an optional GIT_URL#BRANCH
# value put into the project's scmsync element.
sub preset_data {
  my ($projectname, $presets, $extrapaths, $scmsync) = @_;
  my $data = { 'name' => $projectname, 'title' => undef, 'description' => undef };
  $data->{'scmsync'} = $scmsync if defined $scmsync && length $scmsync;
  my %preset_names = map { $_->{'name'} => 1 } grep { ref($_) eq 'HASH' && $_->{'name'} } @$presets;
  my @repository;
  for my $preset (@$presets) {
    next unless ref($preset) eq 'HASH' && $preset->{'name'};
    my $repo = { 'name' => $preset->{'name'} };
    my $architectures = $preset->{'architectures'};
    $architectures = [] unless ref($architectures) eq 'ARRAY';
    $repo->{'arch'} = [ @$architectures ] if @$architectures;
    my $repo_urls = $preset->{'repo'};
    $repo_urls = [ $repo_urls ] if defined $repo_urls && !ref($repo_urls);
    $repo_urls = [] unless ref($repo_urls) eq 'ARRAY';
    my @path;
    for my $url (@$repo_urls) {
      next unless defined $url && length $url;
      if ($preset_names{$url} && $url !~ m{://} && $url ne $preset->{'name'}) {
        # reference to another repository of this same project, defined in
        # the same _manifest
        push @path, { 'project' => $projectname, 'repository' => $url };
        next;
      }
      $url =~ s{^\Q$gitprefix\E}{};
      $url =~ s{^/+}{};
      $url =~ s{/$}{};
      my $slash = rindex($url, '/');
      next unless $slash > 0;
      my $project    = substr($url, 0, $slash);
      my $repository = substr($url, $slash + 1);
      next unless length $project && length $repository;
      push @path, { 'project' => $project, 'repository' => $repository };
    }
    $repo->{'path'} = \@path if @path;
    if ($extrapaths && ref($extrapaths->{$repo->{'name'}}) eq 'ARRAY') {
      # fork case: the path entries built against the forked-from project and
      # this project's own repositories replace the original path entries
      $repo->{'path'} = [ @{$extrapaths->{$repo->{'name'}}} ];
    }
    push @repository, $repo;
  }
  $data->{'repository'} = \@repository if @repository;
  return $data;
}

# Serialize a list of presets into a project xml string.
sub preset_xml {
  my ($projectname, $presets, $extrapaths, $scmsync) = @_;
  return XMLout($BSXML::proj, preset_data($projectname, $presets, $extrapaths, $scmsync));
}

# Compute the path entries that replicate the upstream project's repository
# layout for a fork build. $pmeta is the project meta of the upstream project
# $parent_project the fork builds against. For every preset repository that
# exists upstream, an entry pointing into $parent_project is provided;
# same-project path entries of the upstream repository are replicated pointing
# at the new project $projectname. These entries replace the path entries of
# the fork project (see preset_data). Returns undef when none of the presets
# exist in the upstream project, otherwise a hashref mapping preset repository
# name to a list of {project, repository} path entries.
sub extrapaths_from_parent_meta {
  my ($projectname, $presets, $pmeta, $parent_project) = @_;
  my %parent_repos = map { $_->{'name'} => $_ } grep { $_->{'name'} } @{$pmeta->{'repository'} || []};
  my $extrapaths;
  for my $preset (@$presets) {
    next unless ref($preset) eq 'HASH' && $preset->{'name'};
    next unless $parent_repos{$preset->{'name'}};
    $extrapaths = {} unless $extrapaths;
    push @{$extrapaths->{$preset->{'name'}}}, { 'project' => $parent_project, 'repository' => $preset->{'name'} };
    # Replicate same-project path entries from the upstream repository, so the
    # new project inherits from its own repository the same way the upstream
    # project inherits from its own.
    for my $path (@{$parent_repos{$preset->{'name'}}->{'path'} || []}) {
      next unless ref($path) eq 'HASH' && $path->{'project'} && $path->{'repository'};
      next unless $path->{'project'} eq $parent_project;
      push @{$extrapaths->{$preset->{'name'}}}, { 'project' => $projectname, 'repository' => $path->{'repository'} };
    }
  }
  return $extrapaths;
}

# Classify a Gitea webhook payload (the decoded json as hashref) into the kind
# of event the bridge cares about:
#   push           a push to a branch
#   branch_delete  a branch was deleted
#   tag_delete     a tag was deleted
#   repo_delete    the repository itself was deleted
#   repo_event     another repository event (created, renamed, archived, ...)
# Branch and tag deletions arrive as "delete" events carrying a ref_type,
# repository events carry an action. Payloads of older Gitea versions have no
# event field; their delete events are then recognised by the absence of the
# sha and master_branch fields which the corresponding create events have.
# Returns undef when the payload cannot be classified.
sub gitea_event_kind {
  my ($batch) = @_;
  return undef unless ref($batch) eq 'HASH';
  my $event = $batch->{'event'};
  my $action = $batch->{'action'};
  if (defined $batch->{'ref_type'}) {
    if (defined $event) {
      return undef unless $event eq 'delete';
    } else {
      return undef if defined($batch->{'sha'}) || defined($batch->{'master_branch'});
    }
    return 'branch_delete' if $batch->{'ref_type'} eq 'branch';
    return 'tag_delete'    if $batch->{'ref_type'} eq 'tag';
    return 'other_delete';
  }
  if ((!defined($event) || $event eq 'repository') && defined $action) {
    return $action eq 'deleted' ? 'repo_delete' : 'repo_event';
  }
  if (!defined($event) || $event eq 'push') {
    my $repository = $batch->{'repository'};
    return 'push' if defined($batch->{'ref'}) && ref($repository) eq 'HASH' && defined($repository->{'clone_url'});
  }
  return undef;
}

# Build the OBS project name of a git branch: $prefix:$org:$repo:$branch,
# with ':' in the organisation and repository name replaced by '_' like
# everywhere else in the bridge. Returns undef on missing arguments.
sub branch_project_name {
  my ($prefix, $org, $repo, $branch) = @_;
  return undef unless defined($prefix) && defined($org) && defined($repo) && defined($branch);
  (my $org2 = $org) =~ s/:/_/g;
  (my $repo2 = $repo) =~ s/:/_/g;
  return "$prefix:$org2:$repo2:$branch";
}

# Build the OBS project name prefix covering the branch projects of all
# branches of a repository.
sub repo_project_prefix {
  my ($prefix, $org, $repo) = @_;
  return undef unless defined($prefix) && defined($org) && defined($repo);
  (my $org2 = $org) =~ s/:/_/g;
  (my $repo2 = $repo) =~ s/:/_/g;
  return "$prefix:$org2:$repo2:";
}

# Return the scheme://host (or user@host for scp style urls) part of a git
# clone url, or undef when it cannot be determined.
sub git_host {
  my ($clone_url) = @_;
  return undef unless defined $clone_url;
  return $1 if $clone_url =~ m{^((?:https?|ssh|git)://(?:[^@/]+@)?[^/]+)};
  return $1 if $clone_url =~ m{^([^@/]+\@[^:/]+):};
  return undef;
}

# True when a package level scmsync url synchronises from the repository
# $org/$repo on the gitea host $host, restricted to $branch when one is given.
# The branch part of the url may be followed by query parameters.
sub scmsync_from_source {
  my ($scmsync, $host, $org, $repo, $branch) = @_;
  return 0 unless defined($scmsync) && defined($host) && defined($org) && defined($repo);
  my $base = "$host/$org/$repo";
  if (defined $branch && length $branch) {
    return $scmsync =~ m{^\Q$base\E(?:\.git)?\#\Q$branch\E(?:\?|$)} ? 1 : 0;
  }
  return $scmsync =~ m{^\Q$base\E(?:\.git)?\#} ? 1 : 0;
}

1;
