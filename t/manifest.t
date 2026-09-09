#!/usr/bin/perl -w
#
# Test cases for the BSPreset module (_manifest -> project xml).
#
use strict;
use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

use Test::More;
use BSPreset;

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

# --- manifest_presets ---
my $presets = BSPreset::manifest_presets($manifest);
is(ref($presets), 'ARRAY', 'manifest with presets returns an arrayref');
is($presets->[0]{name}, 'openSUSE_Factory', 'first preset has expected name');
is_deeply($presets->[0]{architectures}, ['x86_64', 'i586'], 'preset architectures parsed');

is(BSPreset::manifest_presets("other: key\n"), undef, 'manifest without presets key -> undef');
is(BSPreset::manifest_presets("presets:\n"), undef, 'empty presets list -> undef');
is(BSPreset::manifest_presets("- a\n- b\n"), undef, 'manifest that is a list -> undef');

eval { BSPreset::manifest_presets("key: [unclosed") };
like($@, qr/cannot parse _manifest/, 'invalid yaml dies with parse error');

# --- manifest_subdirectories / package source dirs ---
is(BSPreset::manifest_subdirectories($manifest), undef, 'no subdirectories in default manifest');

my $msub = <<'YAML';
presets:
  - name: openSUSE_Factory
    repo:
      - https://download.opensuse.org/repositories/openSUSE:Factory/standard
subdirectories:
  - partA
  - partB
YAML
is_deeply(BSPreset::manifest_subdirectories($msub), ['partA', 'partB'], 'subdirectories parsed');

is(BSPreset::manifest_subdirectories("presets:\n"), undef, 'no subdirectories key -> undef');
eval { BSPreset::manifest_subdirectories("key: [unclosed") };
like($@, qr/cannot parse _manifest/, 'invalid yaml dies in subdirectories parse');

my $pkg_dirs = BSPreset::package_source_dirs(['partA', 'partB'],
  partA => ['pkg1', 'pkg2'], partB => ['pkg3']);
is_deeply($pkg_dirs, ['partA/pkg1', 'partA/pkg2', 'partB/pkg3'], 'package source dirs from subdirectories');

my $top_dirs = BSPreset::package_source_dirs(undef, '' => ['pkg1', 'pkg2'], partA => ['x']);
is_deeply($top_dirs, ['pkg1', 'pkg2'], 'no subdirectories -> top level package dirs');

my $sub_only = BSPreset::package_source_dirs(['partA'], partA => ['pkg1'], '' => ['other']);
is_deeply($sub_only, ['partA/pkg1'], 'entries outside subdirectories are ignored');

my $norm_dirs = BSPreset::package_source_dirs(['./partA/'], partA => ['pkg1']);
is_deeply($norm_dirs, ['partA/pkg1'], 'leading ./ and trailing / in subdirectories are normalized');

# --- changed_package_sources (fork change detection) ---
my $changed = BSPreset::changed_package_sources(['a', 'b', 'new'],
  { a => 'abc', b => 'def', new => 'ghi' },
  { a => 'abc', b => 'xyz' });
is_deeply($changed, ['b', 'new'], 'changed packages are those differing or missing upstream');

my $unchanged = BSPreset::changed_package_sources(['a', 'b'],
  { a => 'abc', b => 'def' }, { a => 'abc', b => 'def' });
is_deeply($unchanged, [], 'unchanged packages detected');

# --- scmsync_with_onlybuild (fork onlybuild restriction) ---
is(BSPreset::scmsync_with_onlybuild('https://gitea.example.com/o/r.git#main', ['pkg1', 'pkg2']),
   'https://gitea.example.com/o/r.git?onlybuild=pkg1&onlybuild=pkg2#main',
   'onlybuild params added before the branch fragment');
is(BSPreset::scmsync_with_onlybuild('https://gitea.example.com/o/r.git#main',
   ['devel_area_A/hello', 'devel_area_B/git-example-1', 'devel_area_A/git-example-1']),
   'https://gitea.example.com/o/r.git?onlybuild=hello&onlybuild=git-example-1#main',
   'only the package name is used, duplicate names are collapsed');
is(BSPreset::scmsync_with_onlybuild('https://gitea.example.com/o/r.git#main', []),
   'https://gitea.example.com/o/r.git#main',
   'no changed packages -> scmsync unchanged');
is(BSPreset::scmsync_with_onlybuild('https://gitea.example.com/o/r.git?onlybuild=pkg1#main', ['pkg2']),
   'https://gitea.example.com/o/r.git?onlybuild=pkg1#main',
   'existing onlybuild param is not duplicated');
is(BSPreset::scmsync_with_onlybuild('https://gitea.example.com/o/r.git', ['pkg1']),
   'https://gitea.example.com/o/r.git?onlybuild=pkg1',
   'scmsync without fragment gets onlybuild appended');
is(BSPreset::scmsync_with_onlybuild(undef, ['pkg1']), undef, 'undef scmsync stays undef');

# --- preset_data ---
my $data = BSPreset::preset_data('git:Owner:Repo:main', $presets);
is($data->{name}, 'git:Owner:Repo:main', 'project name is set');
is($data->{repository}[0]{name}, 'openSUSE_Factory', 'repository name is the preset name');
is_deeply($data->{repository}[0]{arch}, ['x86_64', 'i586'], 'arch comes from architectures');
is($data->{repository}[0]{path}[0]{project}, 'openSUSE:Factory', 'path project derives from repo');
is($data->{repository}[0]{path}[0]{repository}, 'standard', 'path repository is the trailing part');

my $d2 = BSPreset::preset_data('p', [{ name => 'r' }]);
ok(!exists($d2->{repository}[0]{arch}), 'no arch when preset has no architectures');

my $d3 = BSPreset::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/home:user/standard' }]);
is($d3->{repository}[0]{path}[0]{project}, 'home:user', 'slashes/colons in project are preserved');
is($d3->{repository}[0]{path}[0]{repository}, 'standard', 'repository is the trailing path component');

my $d4 = BSPreset::preset_data('p', [{ name => 'r', repo => [
    'https://download.opensuse.org/repositories/A/x86_64',
    'https://download.opensuse.org/repositories/B/i586',
] }]);
is(scalar(@{$d4->{repository}[0]{path}}), 2, 'multiple repo urls produce multiple paths');

my $d5 = BSPreset::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/noslash' }]);
ok(!exists($d5->{repository}[0]{path}), 'repo without a trailing slash produces no path');

my $d6 = BSPreset::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/P/aarch64/' }]);
is($d6->{repository}[0]{path}[0]{repository}, 'aarch64', 'trailing slash on repo url is handled');

# --- repo referencing another repository of the same manifest ---
my $d_same = BSPreset::preset_data('p', [
  { name => 'repoA', repo => ['repoB', 'https://download.opensuse.org/repositories/X/Y'] },
  { name => 'repoB' },
]);
is($d_same->{repository}[0]{path}[0]{project}, 'p', 'same-manifest repo name reference produces same-project path');
is($d_same->{repository}[0]{path}[0]{repository}, 'repoB', 'same-manifest repo name reference points at referenced repo');
is($d_same->{repository}[0]{path}[1]{project}, 'X', 'url repo entry still parsed alongside name reference');

my $d_self = BSPreset::preset_data('p', [
  { name => 'repoA', repo => ['repoA'] },
]);
ok(!exists($d_self->{repository}[0]{path}), 'self-reference to own repository produces no path');

my $d_unresolved = BSPreset::preset_data('p', [{ name => 'repoA', repo => ['unknown'] }]);
ok(!exists($d_unresolved->{repository}[0]{path}), 'unresolved bare repo name produces no path');

my $d_url_named = BSPreset::preset_data('p', [
  { name => 'base' },
  { name => 'top', repo => ['https://download.opensuse.org/repositories/base/x86_64'] },
]);
is($d_url_named->{repository}[1]{path}[0]{project}, 'base', 'url repo is not treated as same-manifest name reference');

my $d_same_xml = BSPreset::preset_xml('p', [
  { name => 'repoA', repo => ['repoB'] },
  { name => 'repoB' },
]);
like($d_same_xml, qr/<path project="p" repository="repoB"\/>/, 'same-manifest reference appears in xml');

# --- configurable gitprefix ---
my $saved_prefix = $BSPreset::gitprefix;
$BSPreset::gitprefix = 'https://my.example.org/repos/';
my $d7 = BSPreset::preset_data('p', [{ name => 'r', repo => 'https://my.example.org/repos/openSUSE:Factory/standard' }]);
is($d7->{repository}[0]{path}[0]{project}, 'openSUSE:Factory', 'custom gitprefix derives project');
is($d7->{repository}[0]{path}[0]{repository}, 'standard', 'custom gitprefix derives repository');
my $d8 = BSPreset::preset_data('p', [{ name => 'r', repo => 'https://download.opensuse.org/repositories/X/other' }]);
is($d8->{repository}[0]{path}[0]{project}, 'https://download.opensuse.org/repositories/X', 'url outside custom prefix is appended as-is');
$BSPreset::gitprefix = $saved_prefix;

# --- preset_xml ---
my $xml = BSPreset::preset_xml('git:Owner:Repo:main', $presets);
like($xml, qr/<project name="git:Owner:Repo:main">/, 'xml has project name');
like($xml, qr/<repository name="openSUSE_Factory">/, 'xml has repository element per preset');
like($xml, qr/<path project="openSUSE:Factory" repository="standard"\/>/, 'xml path from repo');
like($xml, qr/<arch>x86_64<\/arch>/, 'xml arch 1');
like($xml, qr/<arch>i586<\/arch>/, 'xml arch 2');

is(BSPreset::preset_xml('p', [{ name => 'r', architectures => ['x86_64'] }]),
   "<project name=\"p\">\n  <title/>\n  <description/>\n  <repository name=\"r\">\n    <arch>x86_64</arch>\n  </repository>\n</project>\n",
   'exact xml output for a single repository');

is(BSPreset::preset_xml('p', []),
   "<project name=\"p\">\n  <title/>\n  <description/>\n</project>\n",
   'empty presets produce a project with empty title/description');

# --- extrapaths (fork builds against upstream project) ---
my $fp = BSPreset::preset_data('p',
  [{ name => 'openSUSE_Factory', repo => 'https://download.opensuse.org/repositories/X/Y' }],
  { openSUSE_Factory => [ { project => 'git:Owner:Upstream:main', repository => 'openSUSE_Factory' } ] });
is($fp->{repository}[0]{path}[0]{project}, 'git:Owner:Upstream:main', 'upstream project path replaces the original');
is($fp->{repository}[0]{path}[0]{repository}, 'openSUSE_Factory', 'upstream project repository matches preset name');
is(scalar(@{$fp->{repository}[0]{path}}), 1, 'original path entries are dropped in fork builds');
ok(!exists($fp->{repository}[0]{extranonexistent}), 'unreferenced repos get no upstream path');

my $fp2 = BSPreset::preset_data('git:Owner:Forked:main',
  [{ name => 'openSUSE_Factory', repo => 'https://download.opensuse.org/repositories/X/Y' }],
  { openSUSE_Factory => [
      { 'project' => 'git:Owner:Upstream:main', 'repository' => 'openSUSE_Factory' },
      { 'project' => 'git:Owner:Forked:main', 'repository' => 'Factory' },
  ] });
is_deeply($fp2->{repository}[0]{path}, [
  { 'project' => 'git:Owner:Upstream:main', 'repository' => 'openSUSE_Factory' },
  { 'project' => 'git:Owner:Forked:main', 'repository' => 'Factory' },
], 'fork path entries replace originals, including same-project replications');

my $fx = BSPreset::preset_xml('p', [{ name => 'r' }],
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
my $ep = BSPreset::extrapaths_from_parent_meta('git:Owner:Forked:main',
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
my $fs = BSPreset::preset_xml('p', [{ name => 'r' }], undef, 'https://gitea.example.com/owner/repo.git#main');
like($fs, qr/<scmsync>https:\/\/gitea\.example\.com\/owner\/repo\.git#main<\/scmsync>/, 'xml contains scmsync element');
my $fsd = BSPreset::preset_data('p', [{ name => 'r' }], undef, 'x#y');
is($fsd->{scmsync}, 'x#y', 'scmsync stored in data');

done_testing();
