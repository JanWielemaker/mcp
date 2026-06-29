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

# Unprivileged user for the runtime.  library(http/http_unix_daemon)
# refuses to bind a listening socket as uid 0; create a dedicated
# account and switch into it before ENTRYPOINT.
#
# git's "dubious ownership" check fires when the mcp user runs git
# commands inside repositories owned by root (the swipl-devel tree
# is cloned and built as root and stays root-owned at runtime).
# Mark every directory safe for the mcp user so the git_* tools in
# the MCP help server can read history without re-chowning huge
# trees.

RUN     useradd --create-home --shell /bin/bash --uid 1000 mcp && \
        runuser -u mcp -- \
            git config --global --add safe.directory '*'

# MCP pack.  Cloned to /srv/mcp (owned by the mcp user so `git pull`
# at update time works without root) and symlinked into the mcp
# user's pack directory so `library(mcp/...)` resolves at swipl
# startup.

RUN     mkdir -p /srv && cd /srv && \
        git clone https://github.com/JanWielemaker/MCP.git mcp && \
        chown -R mcp:mcp /srv/mcp && \
        install -d -o mcp -g mcp /home/mcp/.local/share/swi-prolog/pack && \
        ln -sf /srv/mcp /home/mcp/.local/share/swi-prolog/pack/mcp

# Update.  Bump the SWIPL_VERSION / MCP_VERSION env vars to force the
# corresponding layer to rebuild (`make update-swipl` / `make update-mcp`
# in this directory do the sed-and-rebuild dance).

#  We don't `ninja install`: running swipl straight out of the build
#  tree leaves the `cmake_source_directory` Prolog flag pointing at
#  /usr/local/src/swipl-devel, which is what the `source` server's
#  swipl-source root resolution uses (no CMakeCache.txt parsing
#  fallback needed) AND saves the ~150 MB an install would copy
#  under /usr.  The runtime PATH update below makes `swipl` resolve
#  to the build-tree binary.

ENV     SWIPL_VERSION="Tue 23 Jun 11:54:15 CEST 2026"
RUN     git config --global pull.ff only && \
        cd /usr/local/src/swipl-devel && (git pull || git pull) && \
        git submodule update --init --recursive && \
        rm -rf build && mkdir build && cd build && \
        cmake -DCMAKE_BUILD_TYPE=PGO \
              -DSWIPL_DOC_SERVER=OFF \
              -DCHANGELOG=ON \
              -G Ninja .. && \
        ninja

ENV     PATH=/usr/local/src/swipl-devel/build/src:$PATH

ENV     MCP_VERSION="Mon Jun 29 14:00:00 CEST 2026"
RUN     cd /srv/mcp && \
        runuser -u mcp -- git pull --ff-only || \
        runuser -u mcp -- git pull --ff-only

# Running.

COPY    health.sh /health.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s \
            CMD /health.sh

EXPOSE  3410
USER    mcp
WORKDIR /srv/mcp

#  http_unix_daemon parses --port / --ip / etc. from argv.  Running
#  in foreground (no --daemon) lets Docker manage the process
#  lifecycle.  No --user flag needed: the container is already
#  running as the unprivileged `mcp` account.

ENTRYPOINT ["swipl", "examples/swipl_help_public.pl"]
CMD        ["--port=3410", "--ip=0.0.0.0"]
