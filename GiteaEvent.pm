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
# Classify and describe the Gitea webhook payloads the bridge receives.
#

package GiteaEvent;

use strict;

# Classify a Gitea webhook payload (the decoded json as hashref) into the kind
# of event the bridge cares about:
#   push           a push to a branch
#   branch_delete  a branch was deleted
#   tag_delete     a tag was deleted
#   repo_delete    the repository itself was deleted
#   repo_rename    the repository was renamed or transferred to another owner
#   repo_event     another repository event (created, archived, ...)
# Branch and tag deletions arrive as "delete" events carrying a ref_type,
# repository events carry an action. Payloads of older Gitea versions have no
# event field; their delete events are then recognised by the absence of the
# sha and master_branch fields which the corresponding create events have.
# Returns undef when the payload cannot be classified.
sub kind {
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
    return 'repo_delete' if $action eq 'deleted';
    return 'repo_rename' if $action eq 'renamed' || $action eq 'transferred';
    return 'repo_event';
  }
  if (!defined($event) || $event eq 'push') {
    my $repository = $batch->{'repository'};
    return 'push' if defined($batch->{'ref'}) && ref($repository) eq 'HASH' && defined($repository->{'clone_url'});
  }
  return undef;
}

# Determine the "ORG/REPO" name a renamed or transferred repository had
# before the change. The payload of these repository events carries the new
# name in the repository object and the previous one in its changes: the old
# repository name for a rename inside the same owner, the old owner for a
# transfer to another one. Returns undef when the payload does not describe
# such a change we can undo.
sub old_fullname {
  my ($batch) = @_;
  my $kind = kind($batch);
  return undef unless defined($kind) && $kind eq 'repo_rename';
  my $repository = $batch->{'repository'};
  my $fullname = ref($repository) eq 'HASH' ? $repository->{'full_name'} : undef;
  return undef unless defined($fullname) && $fullname =~ m{^([^/]+)/([^/]+)$};
  my ($org, $repo) = ($1, $2);
  my $changes = $batch->{'changes'};
  return undef unless ref($changes) eq 'HASH';
  if ($batch->{'action'} eq 'renamed') {
    my $name = ref($changes->{'name'}) eq 'HASH' ? $changes->{'name'}->{'from'} : undef;
    return undef unless defined($name) && length($name) && $name ne $repo;
    return "$org/$name";
  }
  # transferred: the old owner is given as a user or an organisation object
  my $from = ref($changes->{'owner'}) eq 'HASH' ? $changes->{'owner'}->{'from'} : undef;
  return undef unless ref($from) eq 'HASH';
  for my $key ('organization', 'user') {
    my $login = ref($from->{$key}) eq 'HASH' ? $from->{$key}->{'login'} : undef;
    return "$login/$repo" if defined($login) && length($login) && $login ne $org;
  }
  return undef;
}

# One log line for every incoming webhook request, printed before anything
# else may abort the handling, so that the journal always shows which events
# arrived. The line names the classified event kind, the repository and the
# branch or tag when the payload carries one. Events which are not queued are
# labelled ignored, matching the answer the caller gives for them. $hevent is
# the raw x-gitea-event header, used when the payload itself names no event.
sub logline {
  my ($batch, $hevent) = @_;
  if (ref($batch) ne 'HASH') {
    return "Event: cannot parse the payload of the x-gitea-event '$hevent' request\n"
      if defined($hevent) && length($hevent);
    return "Event: cannot parse the event payload\n";
  }
  my $kind = kind($batch);
  my $what;
  if (defined($kind)) {
    $what = $kind;
  } elsif (defined($batch->{'event'}) && length($batch->{'event'})) {
    $what = 'ignored ' . $batch->{'event'};
  } elsif (defined($hevent) && length($hevent)) {
    $what = 'ignored ' . $hevent;
  } else {
    $what = 'unknown event';
  }
  my $repository = $batch->{'repository'};
  my $fullname = ref($repository) eq 'HASH' ? $repository->{'full_name'} : undef;
  my $line = 'Event: ' . $what . ' for '
    . (defined($fullname) && length($fullname) ? $fullname : 'unknown repository');
  if (defined($batch->{'ref'}) && length($batch->{'ref'})) {
    # show branch and tag names as the handlers see them
    my $ref = $batch->{'ref'};
    $ref =~ s{^refs/heads/}{};
    $ref =~ s{^refs/tags/}{};
    $ref =~ s{^refs/}{};
    $line .= '#' . $ref;
  }
  return $line . "\n";
}

1;
