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
our @EXPORT = qw(manifest_presets preset_data preset_xml);

# Prefix stripped from repo URLs to derive the OBS path project/repository.
# Made configurable via config.pm ($BSPreset::gitprefix).
our $gitprefix = 'https://download.opensuse.org/repositories/';

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

1;
