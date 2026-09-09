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

# Build the $BSXML::proj conformant data structure for a list of presets.
# $extrapaths is an optional hashref mapping repository name to a list of
# additional {project, repository} path entries (e.g. for building a fork
# against its upstream project). $scmsync is an optional GIT_URL#BRANCH
# value put into the project's scmsync element.
sub preset_data {
  my ($projectname, $presets, $extrapaths, $scmsync) = @_;
  my $data = { 'name' => $projectname, 'title' => undef, 'description' => undef };
  $data->{'scmsync'} = $scmsync if defined $scmsync && length $scmsync;
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
        push @path, @{$extrapaths->{$repo->{'name'}}};
        $repo->{'path'} = \@path;
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

# Compute additional path entries that replicate the upstream project's
# repository layout for a fork build. $pmeta is the project meta of the
# upstream project $parent_project the fork builds against. For every preset
# repository that exists upstream, an entry pointing into $parent_project is
# added; same-project path entries of the upstream repository are replicated
# pointing at the new project $projectname. Returns undef when none of the
# presets exist in the upstream project, otherwise a hashref mapping preset
# repository name to a list of {project, repository} path entries.
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
