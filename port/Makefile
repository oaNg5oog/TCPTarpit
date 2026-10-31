COMMENT=	generic layer-4 TCP tarpit for abusive clients

V=		1.0
DISTNAME=	tcptarpit-${V}
CATEGORIES=	net security

# Local port: no distfile, the files are installed directly from the
# parent source repository.
MASTER_SITES=
EXTRACT_ONLY=

PERMIT_PACKAGE=	Yes

NO_BUILD=	Yes
NO_TEST=	Yes

do-install:
	${INSTALL_SCRIPT} ${.CURDIR}/../tcptarpit.pl ${PREFIX}/bin/tcptarpit.pl
	${INSTALL_MAN} ${.CURDIR}/../tcptarpit.8 ${PREFIX}/man/man8/tcptarpit.8
	${INSTALL_DATA_DIR} ${PREFIX}/share/examples/tcptarpit
	${INSTALL_DATA} ${.CURDIR}/../tcptarpit.conf.sample \
		${PREFIX}/share/examples/tcptarpit/tcptarpit.conf
	${INSTALL_SCRIPT} ${.CURDIR}/../tcptarpit ${DESTDIR}${RCDIR}/tcptarpit

.include <bsd.port.mk>
