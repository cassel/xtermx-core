# XTermX node in a container.
#
#   docker build -f Server/Dockerfile -t xtermx .
#   docker run -d --name xtermx -p 47820:47820 -p 47821:47821 \
#       -v xtermx-home:/home/xtermx xtermx serve --address <server address>
#   docker exec -it xtermx xtermx pair --address <server address>
#
# The terminals run inside the container: install the agents you want (Claude Code, Codex…)
# in a derived image, or prefer Server/install.sh to run on the host itself.

FROM swift:6.3-noble AS build
WORKDIR /work
COPY Packages/XTermXKit .
RUN swift build -c release --product xtermx --static-swift-stdlib \
 && cp .build/release/xtermx /usr/local/bin/xtermx

FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash zsh git curl ca-certificates less nano tmux locales \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash xtermx
COPY --from=build /usr/local/bin/xtermx /usr/local/bin/xtermx
USER xtermx
WORKDIR /home/xtermx
ENV LANG=C.UTF-8 SHELL=/bin/bash
EXPOSE 47820 47821
ENTRYPOINT ["xtermx"]
CMD ["serve"]
