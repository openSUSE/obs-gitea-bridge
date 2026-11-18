#!/usr/bin/perl -w
#
# Test cases for the deletion support helpers: gitea webhook payload
# classification, project name derivation and scmsync source matching.
#
use strict;
use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use Manifest;

my $repo = { clone_url => 'https://gitea.example.org/org/repo.git', full_name => 'org/repo' };

# --- push events ---
is(Manifest::gitea_event_kind({ ref => 'refs/heads/factory', repository => $repo }), 'push', 'push event');
is(Manifest::gitea_event_kind({ event => 'push', ref => 'refs/heads/factory', repository => $repo }), 'push', 'push event with event field');
is(Manifest::gitea_event_kind({ ref => 'refs/heads/factory' }), undef, 'ref without repository is no push');
is(Manifest::gitea_event_kind({ ref => 'refs/heads/factory', repository => {} }), undef, 'push without clone url');

# --- branch and tag deletions ---
is(Manifest::gitea_event_kind({ event => 'delete', ref => 'feature', ref_type => 'branch', repository => $repo }),
   'branch_delete', 'branch delete with event field');
is(Manifest::gitea_event_kind({ ref => 'feature', ref_type => 'branch', repository => $repo }),
   'branch_delete', 'branch delete without event field');
is(Manifest::gitea_event_kind({ event => 'delete', ref => 'v1.0', ref_type => 'tag', repository => $repo }),
   'tag_delete', 'tag delete');
is(Manifest::gitea_event_kind({ event => 'delete', ref => 'deadbeef', ref_type => 'commit', repository => $repo }),
   'other_delete', 'unknown delete ref type');

# --- creations must not look like deletions ---
is(Manifest::gitea_event_kind({ event => 'create', ref => 'x', ref_type => 'branch', sha => 'abc', repository => $repo }),
   undef, 'branch create with event field');
is(Manifest::gitea_event_kind({ ref => 'x', ref_type => 'branch', sha => 'abc', repository => $repo }),
   undef, 'branch create without event field but sha');
is(Manifest::gitea_event_kind({ ref => 'x', ref_type => 'branch', master_branch => 'main', repository => $repo }),
   undef, 'create without event field but master_branch');

# --- repository events ---
is(Manifest::gitea_event_kind({ event => 'repository', action => 'deleted', repository => $repo }),
   'repo_delete', 'repository delete with event field');
is(Manifest::gitea_event_kind({ action => 'deleted', repository => $repo }),
   'repo_delete', 'repository delete without event field');
is(Manifest::gitea_event_kind({ event => 'repository', action => 'created', repository => $repo }),
   'repo_event', 'repository created');
is(Manifest::gitea_event_kind({ event => 'repository', action => 'archived', repository => $repo }),
   'repo_event', 'repository archived');
# a deleted team must not be mistaken for a deleted repository
is(Manifest::gitea_event_kind({ event => 'team', action => 'deleted', repository => $repo }),
   undef, 'team delete is no repository delete');

# --- everything else ---
is(Manifest::gitea_event_kind({ event => 'ping' }), undef, 'ping event');
is(Manifest::gitea_event_kind({}), undef, 'empty payload');
is(Manifest::gitea_event_kind(undef), undef, 'undef payload');
is(Manifest::gitea_event_kind('nonsense'), undef, 'scalar payload');

# --- project names ---
is(Manifest::branch_project_name('git', 'adrianSuSE', 'test', 'factory'), 'git:adrianSuSE:test:factory', 'branch project name');
is(Manifest::branch_project_name('git', 'or:g', 're:po', 'b'), 'git:or_g:re_po:b', 'colons in org and repo are replaced');
is(Manifest::branch_project_name('git', 'org', 'repo', 'feature/x'), 'git:org:repo:feature_x', 'slashes in branch names are replaced');
is(Manifest::branch_project_name('git', 'org', 'repo'), undef, 'missing branch');
is(Manifest::branch_project_name(undef, 'org', 'repo', 'b'), undef, 'missing prefix');
is(Manifest::repo_project_prefix('git', 'adrianSuSE', 'test'), 'git:adrianSuSE:test:', 'repo project prefix');
is(Manifest::repo_project_prefix('git', 'or:g', 're:po'), 'git:or_g:re_po:', 'repo project prefix sanitises colons');
is(Manifest::repo_project_prefix('git', 'org'), undef, 'missing repo');

# --- sanitize_project_part ---
is(Manifest::sanitize_project_part('factory'), 'factory', 'safe name unchanged');
is(Manifest::sanitize_project_part('feature/x'), 'feature_x', 'slash replaced');
is(Manifest::sanitize_project_part('PR_imb#4'), 'PR_imb_4', 'hash replaced');
is(Manifest::sanitize_project_part('a b'), 'a_b', 'space replaced');
is(Manifest::sanitize_project_part('or:g'), 'or_g', 'colon replaced');
is(Manifest::sanitize_project_part('_ObsPrj'), '-ObsPrj', 'leading underscore becomes a dash');
is(Manifest::sanitize_project_part('.hidden'), '-hidden', 'leading dot becomes a dash');
is(Manifest::sanitize_project_part('~x='), '-x_', 'unsafe leading character becomes a dash');
is(Manifest::sanitize_project_part('a..b'), 'a..b', 'dots inside are kept');
is(Manifest::sanitize_project_part('x~y=z,w'), 'x_y_z_w', 'multiple unsafe characters');
is(Manifest::sanitize_project_part(''), undef, 'empty part');
is(Manifest::sanitize_project_part(undef), undef, 'undef part');
is(Manifest::branch_project_name('git', 'HPC', '_ObsPrj', 'PR_imb#4'), 'git:HPC:-ObsPrj:PR_imb_4', 'hpc style names sanitised');
is(Manifest::branch_project_name('git', 'org', 'repo', 'a/../../home:evil'), 'git:org:repo:a_.._.._home_evil', 'path traversal stays inside one component');
is(Manifest::repo_project_prefix('git', 'HPC', '_ObsPrj'), 'git:HPC:-ObsPrj:', 'repo prefix sanitised like the project name');

# --- project and package name scope ---
ok(Manifest::project_name_in_scope('git', 'git:org:repo:branch'), 'project below the prefix is in scope');
ok(Manifest::project_name_in_scope('git', 'git:org:repo:branch_1.x-y+z'), 'safe special characters are in scope');
ok(!Manifest::project_name_in_scope('git', 'home:user:project'), 'project outside the prefix is refused');
ok(!Manifest::project_name_in_scope('git', 'git'), 'the bare prefix is no project');
ok(!Manifest::project_name_in_scope('git', 'git:org:repo:feature/x'), 'slash never addresses another resource');
ok(!Manifest::project_name_in_scope('git', 'git:org:repo:a/../../home:evil'), 'traversal is refused');
ok(!Manifest::project_name_in_scope('git', 'git:org:repo:PR_imb#4'), 'hash is refused');
ok(!Manifest::project_name_in_scope('git', 'git:org:repo:x?y'), 'query characters are refused');
ok(!Manifest::project_name_in_scope('git', 'git:org:repo:x y'), 'spaces are refused');
ok(Manifest::project_name_in_scope('git', 'git:org..repo:x'), 'dots inside a component are accepted, OBS accepts them too');
ok(!Manifest::project_name_in_scope('git', 'git:org:.repo:x'), 'a component starting with a dot is refused');
ok(!Manifest::project_name_in_scope('git', 'git::repo:x'), 'empty components are refused');
ok(!Manifest::project_name_in_scope('git', 'gitprefix:org:x'), 'prefix must be followed by a separator');
ok(!Manifest::project_name_in_scope('git', undef), 'undef is refused');
ok(!Manifest::project_name_in_scope(undef, 'git:org:x'), 'undef prefix refuses everything');
is(Manifest::branch_project_name('git', 'org', 'repo', 'PR_imb#4'), 'git:org:repo:PR_imb_4', 'sanitised branch names are in scope again');
ok(Manifest::project_name_in_scope('git', Manifest::repo_project_prefix('git', 'org', 'repo') . 'branch'), 'repo prefix and project name agree');
ok(Manifest::package_name_in_scope('my_package-1.2+rpm'), 'safe package name');
ok(!Manifest::package_name_in_scope('.'), 'a dot is no package');
ok(!Manifest::package_name_in_scope('..'), 'dot dot is no package');
ok(!Manifest::package_name_in_scope('a/b'), 'package names never carry a path');
ok(!Manifest::package_name_in_scope('a#b'), 'package names never carry a fragment');
ok(!Manifest::package_name_in_scope(undef), 'undef package name');

# --- git host extraction ---
is(Manifest::git_host('https://src.opensuse.org/adrianSuSE/test.git'), 'https://src.opensuse.org', 'https clone url');
is(Manifest::git_host('http://localhost:3000/org/repo.git'), 'http://localhost:3000', 'clone url with port');
is(Manifest::git_host('ssh://git@g.example.com/org/repo.git'), 'ssh://git@g.example.com', 'ssh url with user');
is(Manifest::git_host('https://token@host.example.org/org/repo.git'), 'https://token@host.example.org', 'url with user info');
is(Manifest::git_host('git@g.example.com:org/repo.git'), 'git@g.example.com', 'scp style url');
is(Manifest::git_host(undef), undef, 'undef has no host');
is(Manifest::git_host(''), undef, 'empty url has no host');

# --- scmsync source matching ---
my $host = 'http://localhost:3000';
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo.git#factory', $host, 'org', 'repo', 'factory'), 1, 'matching scmsync url');
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo#factory', $host, 'org', 'repo', 'factory'), 1, 'url without .git suffix');
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo.git#main', $host, 'org', 'repo', 'factory'), 0, 'different branch');
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo.git#factory2', $host, 'org', 'repo', 'factory'), 0, 'branch name prefix is no match');
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo.git#factory?onlybuild=x', $host, 'org', 'repo', 'factory'), 1, 'branch with query parameters');
is(Manifest::scmsync_from_source('http://localhost:3000/org/other.git#factory', $host, 'org', 'repo', 'factory'), 0, 'different repository');
is(Manifest::scmsync_from_source('https://github.com/org/repo.git#factory', $host, 'org', 'repo', 'factory'), 0, 'different host');
is(Manifest::scmsync_from_source(undef, $host, 'org', 'repo', 'factory'), 0, 'no scmsync');
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo.git#anybranch', $host, 'org', 'repo', undef), 1, 'any branch matches');
is(Manifest::scmsync_from_source('http://localhost:3000/org/repo.git', $host, 'org', 'repo', undef), 0, 'url without branch is no source');

# --- incoming event log lines ---
is(Manifest::event_logline({ ref => 'refs/heads/slfo-main', repository => $repo }),
   "Event: push for org/repo#slfo-main\n", 'push event line');
is(Manifest::event_logline({ event => 'delete', ref_type => 'branch', ref => 'PR_imb#4', repository => $repo }),
   "Event: branch_delete for org/repo#PR_imb#4\n", 'branch delete line');
is(Manifest::event_logline({ event => 'repository', action => 'deleted', repository => $repo }),
   "Event: repo_delete for org/repo\n", 'repository delete line');
is(Manifest::event_logline({ event => 'delete', ref_type => 'tag', ref => 'v1.0', repository => $repo }),
   "Event: tag_delete for org/repo#v1.0\n", 'tag delete line');
is(Manifest::event_logline({ event => 'ping', repository => $repo }),
   "Event: ignored ping for org/repo\n", 'ignored event line');
is(Manifest::event_logline({ repository => $repo }, 'ping'),
   "Event: ignored ping for org/repo\n", 'ignored event named only by the header');
is(Manifest::event_logline({}, undef),
   "Event: unknown event for unknown repository\n", 'event without any name');
is(Manifest::event_logline({ ref => 'refs/heads/x', repository => { clone_url => 'u' } }),
   "Event: push for unknown repository#x\n", 'repository without full name');
is(Manifest::event_logline(undef, 'push'),
   "Event: cannot parse the payload of the x-gitea-event 'push' request\n", 'unparsable payload with header');
is(Manifest::event_logline(undef), "Event: cannot parse the event payload\n", 'unparsable payload without header');
is(Manifest::event_logline('not a hash', 'push'),
   "Event: cannot parse the payload of the x-gitea-event 'push' request\n", 'json scalar payload');

done_testing();
