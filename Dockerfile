ARG BUILDER_IMAGE="hexpm/elixir:1.19.5-erlang-28.2-debian-bookworm-20260202"
ARG RUNNER_IMAGE="debian:bookworm-slim"

# --- build stage ---
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git nodejs npm \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN npm install --prefix assets
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

# --- runtime stage ---
FROM ${RUNNER_IMAGE}

ARG AUDIOWAVEFORM_VERSION=1.10.2
ARG AUDIOWAVEFORM_DEB="audiowaveform_${AUDIOWAVEFORM_VERSION}-1-12_amd64.deb"

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
      ffmpeg unzip curl && \
    curl -fsSL -o /tmp/audiowaveform.deb \
      "https://github.com/bbc/audiowaveform/releases/download/${AUDIOWAVEFORM_VERSION}/${AUDIOWAVEFORM_DEB}" && \
    (dpkg -i /tmp/audiowaveform.deb || apt-get install -f -y) && \
    rm /tmp/audiowaveform.deb && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN useradd --create-home noter && mkdir -p /app/data && chown noter:noter /app/data
USER noter

COPY --from=builder --chown=noter:noter /app/_build/prod/rel/noter ./

ENV PHX_SERVER=true

CMD ["/bin/sh", "-c", "bin/noter eval 'Noter.Release.migrate()' && bin/noter start"]
