#!/usr/bin/perl -w
#
# Test cases for the Manifest module (_manifest -> project xml).
#
use strict;
use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use Manifest;

my $manifest = <<'YAML';
presets:
  - name: openSUSE_Factory
    default: "true"
    arch: x86_64
    architectures:
      - x86_64
      - i586
    repo:
      - https://download.opensuse.org/repositories/openSUSE:Factory/standard
YAML

# --- presets ---
my $presets = Manifest::presets($manifest);
is(ref($presets), 'ARRAY', 'manifest with presets returns an arrayref');
is($presets->[0]{name}, 'openSUSE_Factory', 'first preset has expected name');
is_deeply($presets->[0]{architectures}, ['x86_64', 'i586'], 'preset architectures parsed');

is(Manifest::presets("other: key\n"), undef, 'manifest without presets key -> undef');
is(Manifest::presets("presets:\n"), undef, 'empty presets list -> undef');
is(Manifest::presets("- a\n- b\n"), undef, 'manifest that is a list -> undef');

eval { Manifest::presets("key: [unclosed") };
like($@, qr/cannot parse _manifest/, 'invalid yaml dies with parse error');

# --- subdirectories / package source dirs ---
is(Manifest::subdirectories($manifest), undef, 'no subdirectories in default manifest');

my $msub = <<'YAML';
presets:
  - name: openSUSE_Factory
    repo:
      - https://download.opensuse.org/repositories/openSUSE:Factory/standard
subdirectories:
  - partA
  - partB
YAML
is_deeply(Manifest::subdirectories($msub), ['partA', 'partB'], 'subdirectories parsed');

is(Manifest::subdirectories("presets:\n"), undef, 'no subdirectories key -> undef');
eval { Manifest::subdirectories("key: [unclosed") };
like($@, qr/cannot parse _manifest/, 'invalid yaml dies in subdirectories parse');

my $pkg_dirs = Manifest::package_source_dirs(['partA', 'partB'],
  partA => ['pkg1', 'pkg2'], partB => ['pkg3']);
is_deeply($pkg_dirs, ['partA/pkg1', 'partA/pkg2', 'partB/pkg3'], 'package source dirs from subdirectories');

my $top_dirs = Manifest::package_source_dirs(undef, '' => ['pkg1', 'pkg2'], partA => ['x']);
is_deeply($top_dirs, ['pkg1', 'pkg2'], 'no subdirectories -> top level package dirs');

my $sub_only = Manifest::package_source_dirs(['partA'], partA => ['pkg1'], '' => ['other']);
is_deeply($sub_only, ['partA/pkg1'], 'entries outside subdirectories are ignored');

my $norm_dirs = Manifest::package_source_dirs(['./partA/'], partA => ['pkg1']);
is_deeply($norm_dirs, ['partA/pkg1'], 'leading ./ and trailing / in subdirectories are normalized');

# --- changed_package_sources (fork change detection) ---
my $changed = Manifest::changed_package_sources(['a', 'b', 'new'],
  { a => 'abc', b => 'def', new => 'ghi' },
  { a => 'abc', b => 'xyz' });
is_deeply($changed, ['b', 'new'], 'changed packages are those differing or missing upstream');

my $unchanged = Manifest::changed_package_sources(['a', 'b'],
  { a => 'abc', b => 'def' }, { a => 'abc', b => 'def' });
is_deeply($unchanged, [], 'unchanged packages detected');

# --- scmsync_with_onlybuild (fork onlybuild restriction) ---
is(Manifest::scmsync_with_onlybuild('https://gitea.example.com/o/r.git#main', ['pkg1', 'pkg2']),
   'https://gitea.example.com/o/r.git?onlybuild=pkg1&onlybuild=pkg2#main',
   'onlybuild params added before the branch fragment');
is(Manifest::scmsync_with_onlybuild('https://gitea.example.com/o/r.git#main',
   ['devel_area_A/hello', 'devel_area_B/git-example-1', 'devel_area_A/git-example-1']),
   'https://gitea.example.com/o/r.git?onlybuild=hello&onlybuild=git-example-1#main',
   'only the package name is used, duplicate names are collapsed');
is(Manifest::scmsync_with_onlybuild('https://gitea.example.com/o/r.git#main', []),
   'https://gitea.example.com/o/r.git#main',
   'no changed packages -> scmsync unchanged');
is(Manifest::scmsync_with_onlybuild('https://gitea.example.com/o/r.git?onlybuild=pkg1#main', ['pkg2']),
   'https://gitea.example.com/o/r.git?onlybuild=pkg1#main',
   'existing onlybuild param is not duplicated');
is(Manifest::scmsync_with_onlybuild('https://gitea.example.com/o/r.git', ['pkg1']),
   'https://gitea.example.com/o/r.git?onlybuild=pkg1',
   'scmsync without fragment gets onlybuild appended');
is(Manifest::scmsync_with_onlybuild(undef, ['pkg1']), undef, 'undef scmsync stays undef');

# --- preset_data ---
my $data = Manifest::preset_data('git:Owner:Repo:main', $presets);
is($data->{name}, 'git:Owner:Repo:main', 'project name is set');
is($data->{repository}[0]{name}, 'openSUSE_Factory', 'repository name is the preset name');
is_deeply($data->{repository}[0]{arch}, ['x86_64', 'i586'], 'arch comes from architectures');
is($data->{repository}[0]{path}[0]{project}, 'openSUSE:Factory', 'path project derives from repo');
is($data->{repository}[0]{path}[0]{repository}, 'standard', 'path repository is the trailing part');

my $d2 = Manifest::preset_data('p', [{ name => 'r' }]);
ok(!exists($d2->{repository}[0]{arch}), 'no arch when preset has no architectures');

my $d3 = Manifest::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/home:user/standard' }]);
is($d3->{repository}[0]{path}[0]{project}, 'home:user', 'slashes/colons in project are preserved');
is($d3->{repository}[0]{path}[0]{repository}, 'standard', 'repository is the trailing path component');

my $d4 = Manifest::preset_data('p', [{ name => 'r', repo => [
    'https://download.opensuse.org/repositories/A/x86_64',
    'https://download.opensuse.org/repositories/B/i586',
] }]);
is(scalar(@{$d4->{repository}[0]{path}}), 2, 'multiple repo urls produce multiple paths');

my $d5 = Manifest::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/noslash' }]);
ok(!exists($d5->{repository}[0]{path}), 'repo without a trailing slash produces no path');

my $d6 = Manifest::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/P/aarch64/' }]);
is($d6->{repository}[0]{path}[0]{repository}, 'aarch64', 'trailing slash on repo url is handled');

# --- repo referencing another repository of the same manifest ---
my $d_same = Manifest::preset_data('p', [
  { name => 'repoA', repo => ['repoB', 'https://download.opensuse.org/repositories/X/Y'] },
  { name => 'repoB' },
]);
is($d_same->{repository}[0]{path}[0]{project}, 'p', 'same-manifest repo name reference produces same-project path');
is($d_same->{repository}[0]{path}[0]{repository}, 'repoB', 'same-manifest repo name reference points at referenced repo');
is($d_same->{repository}[0]{path}[1]{project}, 'X', 'url repo entry still parsed alongside name reference');

my $d_self = Manifest::preset_data('p', [
  { name => 'repoA', repo => ['repoA'] },
]);
ok(!exists($d_self->{repository}[0]{path}), 'self-reference to own repository produces no path');

my $d_unresolved = Manifest::preset_data('p', [{ name => 'repoA', repo => ['unknown'] }]);
ok(!exists($d_unresolved->{repository}[0]{path}), 'unresolved bare repo name produces no path');

my $d_url_named = Manifest::preset_data('p', [
  { name => 'base' },
  { name => 'top', repo => ['https://download.opensuse.org/repositories/base/x86_64'] },
]);
is($d_url_named->{repository}[1]{path}[0]{project}, 'base', 'url repo is not treated as same-manifest name reference');

my $d_same_xml = Manifest::preset_xml('p', [
  { name => 'repoA', repo => ['repoB'] },
  { name => 'repoB' },
]);
like($d_same_xml, qr/<path project="p" repository="repoB"\/>/, 'same-manifest reference appears in xml');

# --- configurable gitprefix ---
my $saved_prefix = $Manifest::gitprefix;
$Manifest::gitprefix = 'https://my.example.org/repos/';
my $d7 = Manifest::preset_data('p', [{ name => 'r', repo => 'https://my.example.org/repos/openSUSE:Factory/standard' }]);
is($d7->{repository}[0]{path}[0]{project}, 'openSUSE:Factory', 'custom gitprefix derives project');
is($d7->{repository}[0]{path}[0]{repository}, 'standard', 'custom gitprefix derives repository');
my $d8 = Manifest::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/X/other' }]);
is($d8->{repository}[0]{path}[0]{project}, 'https://download.opensuse.org/repositories/X', 'url outside custom prefix is appended as-is');

# the OBS api reports the download_url without a trailing slash (daemon case)
$Manifest::gitprefix = 'https://download.opensuse.org/repositories';
my $d_ns = Manifest::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/openSUSE:Factory/standard' }]);
is($d_ns->{repository}[0]{path}[0]{project}, 'openSUSE:Factory', 'gitprefix without trailing slash still splits the project');
is($d_ns->{repository}[0]{path}[0]{repository}, 'standard', 'repository part unaffected by slash-less gitprefix');
$Manifest::gitprefix = $saved_prefix;

# --- normalize_gitprefix ---
is(Manifest::normalize_gitprefix('https://x.example.org/repositories'), 'https://x.example.org/repositories/', 'trailing slash is added');
is(Manifest::normalize_gitprefix('https://x.example.org/repositories/'), 'https://x.example.org/repositories/', 'single trailing slash kept');
is(Manifest::normalize_gitprefix('https://x.example.org/repositories///'), 'https://x.example.org/repositories/', 'multiple trailing slashes collapsed');
is(Manifest::normalize_gitprefix(''), undef, 'empty prefix -> undef');
is(Manifest::normalize_gitprefix(undef), undef, 'undef stays undef');

# --- preset_xml ---
my $xml = Manifest::preset_xml('git:Owner:Repo:main', $presets);
like($xml, qr/<project name="git:Owner:Repo:main">/, 'xml has project name');
like($xml, qr/<repository name="openSUSE_Factory">/, 'xml has repository element per preset');
like($xml, qr/<path project="openSUSE:Factory" repository="standard"\/>/, 'xml path from repo');
like($xml, qr/<arch>x86_64<\/arch>/, 'xml arch 1');
like($xml, qr/<arch>i586<\/arch>/, 'xml arch 2');

is(Manifest::preset_xml('p', [{ name => 'r', architectures => ['x86_64'] }]),
   "<project name=\"p\">\n  <title/>\n  <description/>\n  <repository name=\"r\">\n    <arch>x86_64</arch>\n  </repository>\n</project>\n",
   'exact xml output for a single repository');

is(Manifest::preset_xml('p', []),
   "<project name=\"p\">\n  <title/>\n  <description/>\n</project>\n",
   'empty presets produce a project with empty title/description');

# --- extrapaths (fork builds against upstream project) ---
my $fp = Manifest::preset_data('p',
  [{ name => 'openSUSE_Factory', repo => 'https://download.opensuse.org/repositories/X/Y' }],
  { openSUSE_Factory => [ { project => 'git:Owner:Upstream:main', repository => 'openSUSE_Factory' } ] });
is($fp->{repository}[0]{path}[0]{project}, 'git:Owner:Upstream:main', 'upstream project path replaces the original');
is($fp->{repository}[0]{path}[0]{repository}, 'openSUSE_Factory', 'upstream project repository matches preset name');
is(scalar(@{$fp->{repository}[0]{path}}), 1, 'original path entries are dropped in fork builds');
ok(!exists($fp->{repository}[0]{extranonexistent}), 'unreferenced repos get no upstream path');

my $fp2 = Manifest::preset_data('git:Owner:Forked:main',
  [{ name => 'openSUSE_Factory', repo => 'https://download.opensuse.org/repositories/X/Y' }],
  { openSUSE_Factory => [
      { 'project' => 'git:Owner:Upstream:main', 'repository' => 'openSUSE_Factory' },
      { 'project' => 'git:Owner:Forked:main', 'repository' => 'Factory' },
  ] });
is_deeply($fp2->{repository}[0]{path}, [
  { 'project' => 'git:Owner:Upstream:main', 'repository' => 'openSUSE_Factory' },
  { 'project' => 'git:Owner:Forked:main', 'repository' => 'Factory' },
], 'fork path entries replace originals, including same-project replications');

my $fx = Manifest::preset_xml('p', [{ name => 'r' }],
  { r => [ { project => 'git:Owner:Upstream:main', repository => 'r' } ] });
like($fx, qr/<path project="git:Owner:Upstream:main" repository="r"\/>/, 'xml contains upstream path');

# --- extrapaths_from_parent_meta (fork same-project replication) ---
my $pm = { 'repository' => [
  { 'name' => 'openSUSE_Factory', 'path' => [
      { 'project' => 'git:Owner:Upstream:main', 'repository' => 'Factory' },
      { 'project' => 'openSUSE:Factory', 'repository' => 'standard' },
  ] },
  { 'name' => 'Factory', 'path' => [ { 'project' => 'openSUSE:Factory', 'repository' => 'standard' } ] },
] };
my $ep = Manifest::extrapaths_from_parent_meta('git:Owner:Forked:main',
  [ { name => 'openSUSE_Factory' }, { name => 'Factory' }, { name => 'Missing' } ],
  $pm, 'git:Owner:Upstream:main');
is_deeply($ep->{'openSUSE_Factory'}, [
  { 'project' => 'git:Owner:Upstream:main', 'repository' => 'openSUSE_Factory' },
  { 'project' => 'git:Owner:Forked:main', 'repository' => 'Factory' },
], 'same-project path of upstream repo replicated pointing at the new project');
is_deeply($ep->{'Factory'}, [
  { 'project' => 'git:Owner:Upstream:main', 'repository' => 'Factory' },
], 'repo without same-project entry only gets upstream path');
ok(!exists($ep->{'Missing'}), 'preset not present in upstream gets no paths');

# --- scmsync ---
my $fs = Manifest::preset_xml('p', [{ name => 'r' }], undef, 'https://gitea.example.com/owner/repo.git#main');
like($fs, qr/<scmsync>https:\/\/gitea\.example\.com\/owner\/repo\.git#main<\/scmsync>/, 'xml contains scmsync element');
my $fsd = Manifest::preset_data('p', [{ name => 'r' }], undef, 'x#y');
is($fsd->{scmsync}, 'x#y', 'scmsync stored in data');

# --- package_set ---
my $mset = <<'YAML';
presets:
  - name: openSUSE_Factory
    repo:
      - https://download.opensuse.org/repositories/openSUSE:Factory/standard
package_set:
  organisation: my-org
  branch: factory
  exclude:
    - old-stuff
YAML
my $set = Manifest::package_set($mset);
is(ref($set), 'HASH', 'package_set parsed as a hashref');
is($set->{'organisation'}, 'my-org', 'organisation parsed');
is($set->{'branch'}, 'factory', 'branch parsed');
is_deeply($set->{'exclude'}, ['old-stuff'], 'exclude list parsed');

is(Manifest::package_set($manifest), undef, 'manifest without package_set -> undef');
eval { Manifest::package_set("package_set:\n  organisation: o\n") };
like($@, qr/needs a branch/, 'package_set without branch dies');
eval { Manifest::package_set("package_set:\n  - a\n") };
like($@, qr/invalid package_set/, 'package_set that is a list dies');
eval { Manifest::package_set("key: [unclosed") };
like($@, qr/cannot parse _manifest/, 'invalid yaml dies in package_set parse');

# --- giturl_host_owner ---
is_deeply([Manifest::giturl_host_owner('https://git.example.com/MyOrg/my-repo.git')], ['git.example.com', 'MyOrg', 'my-repo'], 'https url split');
is_deeply([Manifest::giturl_host_owner('http://git.example.com/org/repo')], ['git.example.com', 'org', 'repo'], 'http url without .git split');
is_deeply([Manifest::giturl_host_owner('git@git.example.com:Org/repo.git')], ['git.example.com', 'Org', 'repo'], 'scp style url split');
is_deeply([Manifest::giturl_host_owner('ssh://git@git.example.com/org/repo.git')], ['git.example.com', 'org', 'repo'], 'ssh url with user split');
is_deeply([Manifest::giturl_host_owner('https://git.example.com/onlyowner')], ['git.example.com', 'onlyowner', undef], 'url without repository');
is(Manifest::giturl_host_owner('nonsense'), undef, 'unparsable url -> undef');
is(Manifest::giturl_host_owner(undef), undef, 'undef url -> undef');

# --- resolve_package_set ---
my $rs = Manifest::resolve_package_set({ 'branch' => 'factory' }, 'https://git.example.com/MyOrg/main-repo.git');
is($rs->{'server'}, 'git.example.com', 'server defaults to the repository host');
is($rs->{'organisation'}, 'MyOrg', 'organisation defaults to the repository owner');
is($rs->{'branch'}, 'factory', 'branch kept');
is_deeply($rs->{'exclude'}, {}, 'no exclude list by default');
is($rs->{'manifest'}, 'myorg/main-repo', 'the manifest repository is remembered lower case');

my $rs2 = Manifest::resolve_package_set({ 'organisation' => 'other-org', 'branch' => 'stable' }, 'git@git.example.com:MyOrg/main-repo.git');
is($rs2->{'organisation'}, 'other-org', 'explicit organisation overrides the owner default');

my $rs3 = Manifest::resolve_package_set({ 'server' => 'https://git.example.com', 'branch' => 'x', 'exclude' => ['a', 'b'] }, 'https://git.example.com/o/r.git');
is_deeply($rs3->{'exclude'}, { 'a' => 1, 'b' => 1 }, 'exclude list becomes a lookup hash');

eval { Manifest::resolve_package_set({ 'server' => 'https://git.other.org', 'branch' => 'x' }, 'https://git.example.com/o/r.git') };
like($@, qr/remote package_set server/, 'a foreign server dies as unsupported');

eval { Manifest::resolve_package_set({ 'branch' => 'x' }, 'nonsense') };
like($@, qr/cannot determine gitea host/, 'unparsable clone url dies');

# --- select_members ---
my @members_in = ( { name => 'b-repo', branch => 'factory' }, { name => 'a-repo', branch => 'factory' }, { name => 'old-stuff', branch => 'factory' } );
my $selected = Manifest::select_members(\@members_in, { 'exclude' => { 'old-stuff' => 1 } });
is_deeply([ map { $_->{'name'} } @$selected ], ['a-repo', 'b-repo'], 'members excluded and sorted');
my $all = Manifest::select_members(\@members_in, undef);
is_deeply([ map { $_->{'name'} } @$all ], ['a-repo', 'b-repo', 'old-stuff'], 'no exclude keeps all, sorted by name');

# the repository of the _manifest is never a member of its own package_set
my $own_rs = Manifest::resolve_package_set({ 'branch' => 'factory' }, 'https://git.example.com/MyOrg/a-repo.git');
is_deeply([ map { $_->{'name'} } @{ Manifest::select_members(\@members_in, $own_rs) } ], ['b-repo', 'old-stuff'],
  'the manifest repository is filtered out');
my $other_rs = Manifest::resolve_package_set({ 'branch' => 'factory', 'organisation' => 'OtherOrg' }, 'https://git.example.com/MyOrg/a-repo.git');
is_deeply([ map { $_->{'name'} } @{ Manifest::select_members(\@members_in, $other_rs) } ], ['a-repo', 'b-repo', 'old-stuff'],
  'a manifest of another organisation does not filter the members');

# --- sanitize_package_name ---
is(Manifest::sanitize_package_name('hello-world_2.3'), 'hello-world_2.3', 'valid name passes through');
is(Manifest::sanitize_package_name('foo:bar'), 'foo_bar', 'colon replaced');
is(Manifest::sanitize_package_name('a b/c'), 'a_b_c', 'space and slash replaced');

# --- scmsync_url_for ---
is(Manifest::scmsync_url_for('https://git.example.com/o/r.git', 'my-org', 'some-repo', 'factory'),
   'https://git.example.com/my-org/some-repo.git#factory', 'http style member url');
is(Manifest::scmsync_url_for('git@git.example.com:o/r.git', 'my-org', 'some-repo', 'factory'),
   'git@git.example.com:my-org/some-repo.git#factory', 'scp style member url');
is(Manifest::scmsync_url_for('http://git.example.com/gitea/o/r.git', 'org', 'r', 'b'),
   'http://git.example.com/org/r.git#b', 'member url uses the host root (sub-path hosting not supported)');
is(Manifest::scmsync_url_for(undef, 'org', 'r', 'b'), undef, 'undef clone url -> undef');

# --- package_meta_xml ---
my $pxml = Manifest::package_meta_xml('git:org:root:main', 'some-repo', 'https://git.example.com/org/some-repo.git#main');
like($pxml, qr/<package name="some-repo" project="git:org:root:main">/, 'package meta has name and project attributes');
like($pxml, qr/<scmsync>https:\/\/git\.example\.com\/org\/some-repo\.git#main<\/scmsync>/, 'package meta contains scmsync element');

done_testing();
