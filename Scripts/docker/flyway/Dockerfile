# Flyway Enterprise image + git.
#
# WHY THIS EXISTS
#   Flyway/flyway.toml uses Flyway's git resolver (${git.branch:ad}) so the database name follows the
#   current git branch. That resolver runs the `git` command, which the official redgate/flyway image
#   doesn't contain. This file adds git, and nothing else, on top of the official image.
#
# HOW IT'S USED
#   Scripts/lib/common.sh builds this automatically the first time a Flyway script runs:
#     docker build --build-arg BASE_IMAGE=<FLYWAY_BASE_IMAGE> -t <FLYWAY_IMAGE> Scripts/docker/flyway
#   The Flyway version is pinned in ONE place: FLYWAY_BASE_IMAGE in Scripts/lib/common.sh.
#
# ADAPTING IT
#   - Internal registry / mirror: set FLYWAY_BASE_IMAGE to your mirrored copy of redgate/flyway
#     (it must be the commercial redgate/flyway image, NOT flyway/flyway, which is the Community edition).
#   - Different base distro: the apt-get line below assumes the Debian/Ubuntu-based official image.
#   - Corporate proxy / custom CA: add the proxy settings or certificates before the RUN line.
ARG BASE_IMAGE=redgate/flyway:13.12.2
FROM ${BASE_IMAGE}

USER root

# git: required by the ${git.branch} resolver.
# safe.directory '*': the repository is bind-mounted from the host and owned by a different user than
# the one inside the container, which git would otherwise refuse to read ("dubious ownership").
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory '*'
