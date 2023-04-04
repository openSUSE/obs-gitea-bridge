codedir = /usr/share/obs-gitea-bridge/
servicedir = /usr/lib/systemd/system/

all:

install:
	install -d $(DESTDIR)$(codedir)
	install -m 0644 BSCpio.pm BSHTTP.pm BSServer.pm BSUtil.pm BSDispatch.pm BSRPC.pm BSSSL.pm BSXML.pm config.pm.template $(DESTDIR)$(codedir)
	install -m 0755 gitea_obs_bridge $(DESTDIR)$(codedir)
	install -d $(DESTDIR)$(servicedir)
	install -m 0644 obs-gitea-bridge.service $(DESTDIR)$(servicedir)

.PHONY: all install

