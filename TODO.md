Fork handling with presets
==========================

Currently a fork is not creating a new project set. It only creates once
a modification is done (eg. pushing a commit or creating a branch).

This is actually a good default behaviour to keep build load small.

But it creates the entire project set atm, which can be unwanted and
create too much load (eg. when products/SLFO get forked).

Possible future:

scan all referenced repositories and enable build only for the modified
package branches.

a) in package_set: mode we need to create/delete the package meta

b) otherwise we need to maintain the package list via onlybuild query
   parameter list in scmsync url.

In both cases it means that we need to handle it also on any git push.
This most likely has the consequence that we need some kind of caching
to avoid scanning all git repositories and branches on each push.

