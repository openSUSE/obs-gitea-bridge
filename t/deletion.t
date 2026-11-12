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
use BSPreset;

my $repo = { clone_url => 'https://gitea.example.org/org/repo.git', full_name => 'org/repo' };

# --- push events ---
is(BSPreset::gitea_event_kind({ ref => 'refs/heads/factory', repository => $repo }), 'push', 'push event');
is(BSPreset::gitea_event_kind({ event => 'push', ref => 'refs/heads/factory', repository => $repo }), 'push', 'push event with event field');
is(BSPreset::gitea_event_kind({ ref => 'refs/heads/factory' }), undef, 'ref without repository is no push');
is(BSPreset::gitea_event_kind({ ref => 'refs/heads/factory', repository => {} }), undef, 'push without clone url');

# --- branch and tag deletions ---
is(BSPreset::gitea_event_kind({ event => 'delete', ref => 'feature', ref_type => 'branch', repository => $repo }),
   'branch_delete', 'branch delete with event field');
is(BSPreset::gitea_event_kind({ ref => 'feature', ref_type => 'branch', repository => $repo }),
   'branch_delete', 'branch delete without event field');
is(BSPreset::gitea_event_kind({ event => 'delete', ref => 'v1.0', ref_type => 'tag', repository => $repo }),
   'tag_delete', 'tag delete');
is(BSPreset::gitea_event_kind({ event => 'delete', ref => 'deadbeef', ref_type => 'commit', repository => $repo }),
   'other_delete', 'unknown delete ref type');

# --- creations must not look like deletions ---
is(BSPreset::gitea_event_kind({ event => 'create', ref => 'x', ref_type => 'branch', sha => 'abc', repository => $repo }),
   undef, 'branch create with event field');
is(BSPreset::gitea_event_kind({ ref => 'x', ref_type => 'branch', sha => 'abc', repository => $repo }),
   undef, 'branch create without event field but sha');
is(BSPreset::gitea_event_kind({ ref => 'x', ref_type => 'branch', master_branch => 'main', repository => $repo }),
   undef, 'create without event field but master_branch');

# --- repository events ---
is(BSPreset::gitea_event_kind({ event => 'repository', action => 'deleted', repository => $repo }),
   'repo_delete', 'repository delete with event field');
is(BSPreset::gitea_event_kind({ action => 'deleted', repository => $repo }),
   'repo_delete', 'repository delete without event field');
is(BSPreset::gitea_event_kind({ event => 'repository', action => 'created', repository => $repo }),
   'repo_event', 'repository created');
is(BSPreset::gitea_event_kind({ event => 'repository', action => 'archived', repository => $repo }),
   'repo_event', 'repository archived');
# a deleted team must not be mistaken for a deleted repository
is(BSPreset::gitea_event_kind({ event => 'team', action => 'deleted', repository => $repo }),
   undef, 'team delete is no repository delete');

# --- everything else ---
is(BSPreset::gitea_event_kind({ event => 'ping' }), undef, 'ping event');
is(BSPreset::gitea_event_kind({}), undef, 'empty payload');
is(BSPreset::gitea_event_kind(undef), undef, 'undef payload');
is(BSPreset::gitea_event_kind('nonsense'), undef, 'scalar payload');

# --- project names ---
is(BSPreset::branch_project_name('git', 'adrianSuSE', 'test', 'factory'), 'git:adrianSuSE:test:factory', 'branch project name');
is(BSPreset::branch_project_name('git', 'or:g', 're:po', 'b'), 'git:or_g:re_po:b', 'colons in org and repo are replaced');
is(BSPreset::branch_project_name('git', 'org', 'repo', 'feature/x'), 'git:org:repo:feature/x', 'branch name is kept as is');
is(BSPreset::branch_project_name('git', 'org', 'repo'), undef, 'missing branch');
is(BSPreset::branch_project_name(undef, 'org', 'repo', 'b'), undef, 'missing prefix');
is(BSPreset::repo_project_prefix('git', 'adrianSuSE', 'test'), 'git:adrianSuSE:test:', 'repo project prefix');
is(BSPreset::repo_project_prefix('git', 'or:g', 're:po'), 'git:or_g:re_po:', 'repo project prefix sanitises colons');
is(BSPreset::repo_project_prefix('git', 'org'), undef, 'missing repo');

# --- git host extraction ---
is(BSPreset::git_host('https://src.opensuse.org/adrianSuSE/test.git'), 'https://src.opensuse.org', 'https clone url');
is(BSPreset::git_host('http://localhost:3000/org/repo.git'), 'http://localhost:3000', 'clone url with port');
is(BSPreset::git_host('ssh://git@g.example.com/org/repo.git'), 'ssh://git@g.example.com', 'ssh url with user');
is(BSPreset::git_host('https://token@host.example.org/org/repo.git'), 'https://token@host.example.org', 'url with user info');
is(BSPreset::git_host('git@g.example.com:org/repo.git'), 'git@g.example.com', 'scp style url');
is(BSPreset::git_host(undef), undef, 'undef has no host');
is(BSPreset::git_host(''), undef, 'empty url has no host');

# --- scmsync source matching ---
my $host = 'http://localhost:3000';
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo.git#factory', $host, 'org', 'repo', 'factory'), 1, 'matching scmsync url');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo#factory', $host, 'org', 'repo', 'factory'), 1, 'url without .git suffix');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo.git#main', $host, 'org', 'repo', 'factory'), 0, 'different branch');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo.git#factory2', $host, 'org', 'repo', 'factory'), 0, 'branch name prefix is no match');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo.git#factory?onlybuild=x', $host, 'org', 'repo', 'factory'), 1, 'branch with query parameters');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/other.git#factory', $host, 'org', 'repo', 'factory'), 0, 'different repository');
is(BSPreset::scmsync_from_source('https://github.com/org/repo.git#factory', $host, 'org', 'repo', 'factory'), 0, 'different host');
is(BSPreset::scmsync_from_source(undef, $host, 'org', 'repo', 'factory'), 0, 'no scmsync');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo.git#anybranch', $host, 'org', 'repo', undef), 1, 'any branch matches');
is(BSPreset::scmsync_from_source('http://localhost:3000/org/repo.git', $host, 'org', 'repo', undef), 0, 'url without branch is no source');

done_testing();
