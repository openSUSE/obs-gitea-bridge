OBS Gitea Bridge
================

This bridge is glueing Open Build Service(OBS) and Gitea together.

Currently the only task it handles is notifing OBS about changes
in gitea repositories. All packages or projects references are
handled without the need of any manual setups by the user.

Setup
=====

1. copy config.pm.template to config.pm
2. configure a shared cookie string
3. set the same string in your OBS 2.11 instance in /srv/www/obs/api/config/options.yml
   as

      scm_bridge_cookie: YOUR_STRING


_manifest
=========

Build projects are configured by a `_manifest` file in the branch of a git
repository. It is a YAML file with these sections:

presets:
  List of build repositories. Each preset becomes a repository in the OBS
  project meta. `architectures` lists the build architectures, `repo` refers
  to download base urls (mapped to OBS path entries) or to the name of
  another preset in the same manifest (a same-project path entry).

subdirectories:
  Base directories below which the package sources of the repository live.
  Only used for fork change detection.

package_set:
  Use all repositories of a Gitea organisation that have a given branch as
  build packages of the project:

    package_set:
      # organisation: defaults to the owner/organisation of the repository
      #               carrying the _manifest
      # server:       defaults to (and must be) the Gitea instance hosting
      #               the repository, remote servers are not supported yet
      organisation: my-org
      branch: factory   # or "default" for each repository's default branch
      exclude:          # optional list of repositories to skip
        - old-stuff

  The project meta is created from the presets without a project level
  scmsync. The bridge enumerates the organisation's repositories with that
  branch below $gitea_root and creates one OBS package per repository with a
  package level scmsync url (GIT_URL#BRANCH), deleting packages whose
  repository or branch disappeared. Pushes to any repository of the
  organisation re-scan the organisation for a manifest declaring the
  package_set, so the manifest can live in a single repository of the
  organisation. Fork handling does not apply to package_set projects.

  Show the resulting package list without touching OBS:

    gitea_obs_bridge --show-project https://gitea.example.com/org/repo.git#factory


   

