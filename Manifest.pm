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

package Manifest;

use strict;

use YAML::XS ();
use BSUtil;
use BSXML;

# Prefix stripped from repo URLs to derive the OBS path project/repository.
# Made configurable via config.pm ($Manifest::gitprefix).
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
sub presets {
  my ($manifest) = @_;
  my $data = eval { YAML::XS::Load($manifest) };
  die("cannot parse _manifest: $@\n") if $@;
  return undef unless ref($data) eq 'HASH';
  return undef unless ref($data->{'presets'}) eq 'ARRAY';
  return $data->{'presets'};
}

# Return the subdirectories array from a _manifest string, or undef when the
# manifest does not define any (package sources then live at the top level).
sub subdirectories {
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
sub package_set {
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

# Split a git url into its host, owner and repository parts. The host is
# returned without a scheme or user, the owner is the first path element below
# the host, the repository is undef for a url which addresses just an owner.
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
  my ($owner, $repo) = split('/', $path, 2);
  return undef unless defined $host && length $host && defined $owner && length $owner;
  return ($host, $owner, (defined($repo) && length($repo)) ? $repo : undef);
}

# Resolve the defaults of a package_set from a _manifest against the git url
# of the repository carrying the manifest: an unset server and organisation
# default to the Gitea host and owner of that repository, so an empty section
# refers to the Gitea server and organisation the local repository is hosted
# on. Only the local Gitea instance is supported, so a server different from
# the repository host is an error. Returns the resolved set as a hashref with
# server, organisation, branch, exclude (a name -> 1 hashref) and manifest (the
# lower case "ORG/REPO" of the repository whose _manifest declares the set).
sub resolve_package_set {
  my ($set, $clone_url) = @_;
  return undef unless ref($set) eq 'HASH';
  my ($host, $owner, $repo) = giturl_host_owner($clone_url);
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
  return { 'server' => $host, 'organisation' => $organisation, 'branch' => $set->{'branch'}, 'exclude' => \%exclude,
    'manifest' => (defined($repo) && length($repo)) ? lc("$owner/$repo") : undef };
}

# Filter the candidate members (arrayref of {name, branch} hashrefs as
# returned by Gitea::org_repo_members) through the exclude list of a resolved
# package_set. The repository whose _manifest declares the set is never a
# member: it configures the project and is not one of its packages. Returns a
# sorted arrayref.
sub select_members {
  my ($members, $resolved) = @_;
  return [] unless ref($members) eq 'ARRAY';
  my $exclude = ref($resolved) eq 'HASH' ? $resolved->{'exclude'} : undef;
  $exclude = {} unless ref($exclude) eq 'HASH';
  my $manifest = ref($resolved) eq 'HASH' ? $resolved->{'manifest'} : undef;
  my $org = ref($resolved) eq 'HASH' && defined $resolved->{'organisation'} ? lc($resolved->{'organisation'}) : '';
  return [ sort { $a->{'name'} cmp $b->{'name'} } grep {
    ref($_) eq 'HASH' && defined $_->{'name'} && length $_->{'name'}
      && !$exclude->{$_->{'name'}}
      && !(defined($manifest) && "$org/$_->{'name'}" eq $manifest)
  } @$members ];
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
  return BSUtil::toxml({ 'name' => $packagename, 'project' => $projectname, 'scmsync' => $scmsync }, $BSXML::pack);
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
  return BSUtil::toxml(preset_data($projectname, $presets, $extrapaths, $scmsync), $BSXML::proj);
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

# Map one component of a project name (organisation, repository or branch) to
# characters OBS accepts in project names which also cannot change the
# resource an api url addresses: ':' would add a project name component, '/'
# and '#' move the request elsewhere. OBS wants every component to start with
# a letter, a number or one of '+-', so a leading '.' or '_' becomes '-'.
# Distinct repositories can map to the same project name after this, the
# mapping is deterministic for creation, deletion and the project search.
sub sanitize_project_part {
  my ($part) = @_;
  return undef unless defined($part) && length($part);
  $part =~ s/[^A-Za-z0-9._+-]/_/g;
  $part =~ s/^[_+.]+/-/;
  return $part;
}

# True when $projectname is below the given autosetup prefix and composed
# only of characters which are safe inside the path part of an api url and
# which OBS accepts in project names: every ':' separated component starts
# with a letter, a number or one of '+-' and continues with letters, numbers
# or one of '._+-'. Names are derived from repository events, so nothing
# outside this scope may ever be created, read or deleted.
sub project_name_in_scope {
  my ($prefix, $projectname) = @_;
  return 0 unless defined($prefix) && defined($projectname);
  return 0 unless index($projectname, "$prefix:") == 0;
  return $projectname =~ m{\A[a-zA-Z0-9+-][A-Za-z0-9._+-]*(?::[a-zA-Z0-9+-][A-Za-z0-9._+-]*)*\z} ? 1 : 0;
}

# True when $packagename is safe to put into the path of an api url. '.' and
# '..' would address another directory, they are never package names.
sub package_name_in_scope {
  my ($packagename) = @_;
  return 0 unless defined($packagename) && length($packagename);
  return 0 if $packagename eq '.' || $packagename eq '..';
  return $packagename =~ m{\A[A-Za-z0-9._+-]+\z} ? 1 : 0;
}

# Build the OBS project name of a git branch: $prefix:$org:$repo:$branch,
# with every part sanitised for OBS project names and the api url.
# Returns undef on missing arguments.
sub branch_project_name {
  my ($prefix, $org, $repo, $branch) = @_;
  return undef unless defined($prefix) && defined($org) && defined($repo) && defined($branch);
  my $s_org = sanitize_project_part($org);
  my $s_repo = sanitize_project_part($repo);
  my $s_branch = sanitize_project_part($branch);
  return undef unless defined($s_org) && defined($s_repo) && defined($s_branch);
  return "$prefix:$s_org:$s_repo:$s_branch";
}

# Build the OBS project name prefix covering the branch projects of all
# branches of a repository.
sub repo_project_prefix {
  my ($prefix, $org, $repo) = @_;
  return undef unless defined($prefix) && defined($org) && defined($repo);
  my $s_org = sanitize_project_part($org);
  my $s_repo = sanitize_project_part($repo);
  return undef unless defined($s_org) && defined($s_repo);
  return "$prefix:$s_org:$s_repo:";
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
