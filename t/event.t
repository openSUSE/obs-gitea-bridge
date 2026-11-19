#!/usr/bin/perl -w
#
# Test cases for the GiteaEvent module: webhook payload classification, the
# old name of a renamed or transferred repository and the incoming event log
# lines.
#
use strict;
use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use GiteaEvent;

my $repo = { clone_url => 'https://gitea.example.org/org/repo.git', full_name => 'org/repo' };

# --- push events ---
is(GiteaEvent::kind({ ref => 'refs/heads/factory', repository => $repo }), 'push', 'push event');
is(GiteaEvent::kind({ event => 'push', ref => 'refs/heads/factory', repository => $repo }), 'push', 'push event with event field');
is(GiteaEvent::kind({ ref => 'refs/heads/factory' }), undef, 'ref without repository is no push');
is(GiteaEvent::kind({ ref => 'refs/heads/factory', repository => {} }), undef, 'push without clone url');

# --- branch and tag deletions ---
is(GiteaEvent::kind({ event => 'delete', ref => 'feature', ref_type => 'branch', repository => $repo }),
   'branch_delete', 'branch delete with event field');
is(GiteaEvent::kind({ ref => 'feature', ref_type => 'branch', repository => $repo }),
   'branch_delete', 'branch delete without event field');
is(GiteaEvent::kind({ event => 'delete', ref => 'v1.0', ref_type => 'tag', repository => $repo }),
   'tag_delete', 'tag delete');
is(GiteaEvent::kind({ event => 'delete', ref => 'deadbeef', ref_type => 'commit', repository => $repo }),
   'other_delete', 'unknown delete ref type');

# --- creations must not look like deletions ---
is(GiteaEvent::kind({ event => 'create', ref => 'x', ref_type => 'branch', sha => 'abc', repository => $repo }),
   undef, 'branch create with event field');
is(GiteaEvent::kind({ ref => 'x', ref_type => 'branch', sha => 'abc', repository => $repo }),
   undef, 'branch create without event field but sha');
is(GiteaEvent::kind({ ref => 'x', ref_type => 'branch', master_branch => 'main', repository => $repo }),
   undef, 'create without event field but master_branch');

# --- repository events ---
is(GiteaEvent::kind({ event => 'repository', action => 'deleted', repository => $repo }),
   'repo_delete', 'repository delete with event field');
is(GiteaEvent::kind({ action => 'deleted', repository => $repo }),
   'repo_delete', 'repository delete without event field');
is(GiteaEvent::kind({ event => 'repository', action => 'created', repository => $repo }),
   'repo_event', 'repository created');
is(GiteaEvent::kind({ event => 'repository', action => 'archived', repository => $repo }),
   'repo_event', 'repository archived');
# a deleted team must not be mistaken for a deleted repository
is(GiteaEvent::kind({ event => 'team', action => 'deleted', repository => $repo }),
   undef, 'team delete is no repository delete');

# --- everything else ---
is(GiteaEvent::kind({ event => 'ping' }), undef, 'ping event');
is(GiteaEvent::kind({}), undef, 'empty payload');
is(GiteaEvent::kind(undef), undef, 'undef payload');
is(GiteaEvent::kind('nonsense'), undef, 'scalar payload');

# --- old name of a renamed or transferred repository ---
is(GiteaEvent::old_fullname({ event => 'repository', action => 'renamed', repository => $repo,
                                   changes => { name => { from => 'old-repo' } } }),
   'org/old-repo', 'rename inside the same owner');
is(GiteaEvent::old_fullname({ event => 'repository', action => 'transferred', repository => $repo,
                                   changes => { owner => { from => { organization => { login => 'other-org' } } } } }),
   'other-org/repo', 'transfer to another organisation');
is(GiteaEvent::old_fullname({ event => 'repository', action => 'transferred', repository => $repo,
                                   changes => { owner => { from => { user => { login => 'someone' } } } } }),
   'someone/repo', 'transfer to another user');
is(GiteaEvent::old_fullname({ event => 'repository', action => 'renamed', repository => $repo }),
   undef, 'rename without changes');
is(GiteaEvent::old_fullname({ event => 'repository', action => 'created', repository => $repo,
                                   changes => { name => { from => 'old-repo' } } }),
   undef, 'a created repository has no old name');
is(GiteaEvent::old_fullname({ event => 'repository', action => 'renamed', repository => $repo,
                                   changes => { name => { from => 'repo' } } }),
   undef, 'a rename to the same name is no change');

# --- incoming event log lines ---
is(GiteaEvent::logline({ ref => 'refs/heads/slfo-main', repository => $repo }),
   "Event: push for org/repo#slfo-main\n", 'push event line');
is(GiteaEvent::logline({ event => 'delete', ref_type => 'branch', ref => 'PR_imb#4', repository => $repo }),
   "Event: branch_delete for org/repo#PR_imb#4\n", 'branch delete line');
is(GiteaEvent::logline({ event => 'repository', action => 'deleted', repository => $repo }),
   "Event: repo_delete for org/repo\n", 'repository delete line');
is(GiteaEvent::logline({ event => 'delete', ref_type => 'tag', ref => 'v1.0', repository => $repo }),
   "Event: tag_delete for org/repo#v1.0\n", 'tag delete line');
is(GiteaEvent::logline({ event => 'ping', repository => $repo }),
   "Event: ignored ping for org/repo\n", 'ignored event line');
is(GiteaEvent::logline({ repository => $repo }, 'ping'),
   "Event: ignored ping for org/repo\n", 'ignored event named only by the header');
is(GiteaEvent::logline({}, undef),
   "Event: unknown event for unknown repository\n", 'event without any name');
is(GiteaEvent::logline({ ref => 'refs/heads/x', repository => { clone_url => 'u' } }),
   "Event: push for unknown repository#x\n", 'repository without full name');
is(GiteaEvent::logline(undef, 'push'),
   "Event: cannot parse the payload of the x-gitea-event 'push' request\n", 'unparsable payload with header');
is(GiteaEvent::logline(undef), "Event: cannot parse the event payload\n", 'unparsable payload without header');
is(GiteaEvent::logline('not a hash', 'push'),
   "Event: cannot parse the payload of the x-gitea-event 'push' request\n", 'json scalar payload');

done_testing();
