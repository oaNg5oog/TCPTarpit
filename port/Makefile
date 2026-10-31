COMMENT=	generic layer-4 TCP tarpit for abusive clients

V=		1.0
DISTNAME=	tcptarpit-${V}
CATEGORIES=	net security

# Local port: no distfile, the files are installed directly from the
# source repository via TCPTARPIT_SRCDIR below.
DISTFILES=

PERMIT_PACKAGE=	Yes

NO_BUILD=	Yes
NO_TEST=	Yes

# Repository source directory (daemon, rc script, man page, config
# sample).  Defaults to the directory above the port for in-repo use.
# The port itself must be built from inside the ports tree
# (PORTSDIR_PATH, e.g. /usr/ports/mystuff/net/tcptarpit), so point
# this at the checkout there:
#   make package TCPTARPIT_SRCDIR=/root/projects/TCPTarpit
TCPTARPIT_SRCDIR ?= ${.CURDIR}/..

do-install:
	${INSTALL_SCRIPT} ${TCPTARPIT_SRCDIR}/tcptarpit.pl ${PREFIX}/bin/tcptarpit.pl
	${INSTALL_MAN} ${TCPTARPIT_SRCDIR}/tcptarpit.8 ${PREFIX}/man/man8/tcptarpit.8
	${INSTALL_DATA_DIR} ${PREFIX}/share/examples/tcptarpit
	${INSTALL_DATA} ${TCPTARPIT_SRCDIR}/tcptarpit.conf.sample \
		${PREFIX}/share/examples/tcptarpit/tcptarpit.conf
	${INSTALL_SCRIPT} ${TCPTARPIT_SRCDIR}/tcptarpit ${DESTDIR}${RCDIR}/tcptarpit

.include <bsd.port.mk>
