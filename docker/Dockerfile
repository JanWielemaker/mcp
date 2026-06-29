FROM debian:trixie-slim

#  Same dependency set as the plweb Dockerfile: every optional SWI
#  package (xpce, JPL, janus, ssh, ODBC, BDB, PCRE, archive, ...)
#  gets built so that the help server can serve documentation for
#  every predicate in those packages.  pldoc indexes only packages
#  that actually built; if e.g. libcairo is missing here, queries
#  about xpce predicates return "no manual entry".

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates unzip \
        build-essential cmake autoconf ninja-build pkg-config \
        gdb \
        cleancss node-requirejs uglifyjs \
        ncurses-dev libedit-dev \
        libgoogle-perftools-dev \
        libgmp-dev \
        libssl-dev \
        unixodbc-dev \
        zlib1g-dev libarchive-dev \
        libossp-uuid-dev \
        libcairo2-dev libpango1.0-dev libsdl3-dev libsdl3-image-dev \
        libdb-dev \
        libpcre2-dev \
        libyaml-dev \
        libutf8proc-dev \
        libpython3-dev \
        default-jdk junit4 \
        libssh-dev openssh-client \
        locales && \
    rm -rf /var/lib/apt/lists/*

RUN     sed -i -e 's/# en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen && \
        locale-gen
ENV     LC_ALL=en_GB.UTF-8
ENV     LANG=en_GB.UTF-8
ENV     LANGUAGE=en_GB:en

# SWI-Prolog: clone, then build/install in a separate step so the
# clone layer is cached across rebuilds.

RUN     mkdir -p /usr/local/src && cd /usr/local/src && \
        git clone --recursive https://github.com/SWI-Prolog/swipl-devel.git

# MCP pack.  Cloned to /srv/mcp and symlinked into the standard pack
# directory so `library(mcp/...)` resolves at swipl startup.

RUN     mkdir -p /srv && cd /srv && \
        git clone https://github.com/JanWielemaker/MCP.git mcp && \
        mkdir -p /root/.local/share/swi-prolog/pack && \
        ln -sf /srv/mcp /root/.local/share/swi-prolog/pack/mcp

# Update.  Bump the SWIPL_VERSION / MCP_VERSION env vars to force the
# corresponding layer to rebuild (`make update-swipl` / `make update-mcp`
# in this directory do the sed-and-rebuild dance).

ENV     SWIPL_VERSION="Tue 23 Jun 11:54:15 CEST 2026"
RUN     git config --global pull.ff only && \
        cd /usr/local/src/swipl-devel && (git pull || git pull) && \
        git submodule update --init --recursive && \
        rm -rf build && mkdir build && cd build && \
        cmake -DCMAKE_INSTALL_PREFIX=/usr \
              -DCMAKE_BUILD_TYPE=PGO \
              -DSWIPL_DOC_SERVER=OFF \
              -DCHANGELOG=ON \
              -G Ninja .. && \
        ninja && ninja install

ENV     MCP_VERSION="Mon Jun 29 14:00:00 CEST 2026"
RUN     cd /srv/mcp && (git pull || git pull)

# Running.

COPY    health.sh /health.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s \
            CMD /health.sh

EXPOSE  3410
WORKDIR /srv/mcp

#  http_unix_daemon parses --port / --ip / etc. from argv.  Running
#  in foreground (no --daemon) lets Docker manage the process
#  lifecycle.

ENTRYPOINT ["swipl", "examples/swipl_help_public.pl"]
CMD        ["--port=3410", "--ip=0.0.0.0"]
