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


   

