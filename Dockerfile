# Stage 1: Build webapp
FROM docker.io/node:lts-alpine AS webapp

WORKDIR /build/webapp
COPY webapp/package.json webapp/package-lock.json ./
RUN npm ci
COPY webapp/ ./
RUN npm run build

# Stage 2: Build Go binaries
FROM docker.io/golang:alpine AS builder
ARG GARM_REF
# Space separated list of provider repositories to build. An entry may pin a
# branch, tag or commit with "owner/repo@ref"; entries without a ref use main
# for GARM_REF=main and the provider's latest release otherwise.
ARG GARM_PROVIDERS="cloudbase/garm-provider-azure cloudbase/garm-provider-openstack cloudbase/garm-provider-lxd cloudbase/garm-provider-incus cloudbase/garm-provider-aws cloudbase/garm-provider-gcp flatcar/garm-provider-linode mercedes-benz/garm-provider-k8s nexthop-ai/garm-provider-cloudstack"

LABEL stage=builder

RUN apk add --no-cache musl-dev gcc libtool m4 autoconf g++ make libblkid util-linux-dev git linux-headers upx curl jq
RUN git config --global --add safe.directory /build && git config --global --add advice.detachedHead false
RUN echo ${GARM_REF}

ADD . /build/garm

RUN git -C /build/garm checkout ${GARM_REF}

# Copy webapp build output to assets directory (after git checkout to override any checked-in assets)
COPY --from=webapp /build/webapp/build/ /build/garm/webapp/assets/

RUN cd /build/garm \
    && go build -o /bin/garm \
      -tags osusergo,netgo,sqlite_omit_load_extension \
      -ldflags "-linkmode external -extldflags '-static' -s -w -X github.com/cloudbase/garm/util/appdefaults.Version=$(git describe --tags --match='v[0-9]*' --dirty --always)" \
      /build/garm/cmd/garm && upx /bin/garm
RUN cd /build/garm/cmd/garm-cli \
    && go build -o /bin/garm-cli \
      -tags osusergo,netgo,sqlite_omit_load_extension \
      -ldflags "-linkmode external -extldflags '-static' -s -w -X github.com/cloudbase/garm/util/appdefaults.Version=$(git describe --tags --match='v[0-9]*' --dirty --always)" \
      . && upx /bin/garm-cli
RUN set -ex; \
    mkdir -p /opt/garm/providers.d; \
    for entry in $GARM_PROVIDERS; \
    do \
        repo="${entry%@*}"; \
        export PROVIDER_NAME="$(basename $repo)"; \
        export PROVIDER_SUBDIR=""; \
        if [ "$entry" != "$repo" ]; then \
          export PROVIDER_REF="${entry#*@}"; \
        elif [ "$GARM_REF" == "main" ]; then \
          export PROVIDER_REF="main"; \
        else \
          export PROVIDER_REF="$(curl -s -L https://api.github.com/repos/$repo/releases/latest | jq -r '.tag_name')"; \
        fi; \
        git clone "https://github.com/$repo" "/build/$PROVIDER_NAME" \
        && git -C "/build/$PROVIDER_NAME" checkout "$PROVIDER_REF"; \
        case $PROVIDER_NAME in \
        "garm-provider-k8s") \
            export PROVIDER_SUBDIR="cmd/garm-provider-k8s"; \
            export PROVIDER_LDFLAGS="-linkmode external -extldflags \"-static\" -s -w"; \
            ;; \
        "garm-provider-linode") \
            export PROVIDER_LDFLAGS="-linkmode external -extldflags \"-static\" -s -w"; \
            ;; \
        *) \
            export PROVIDER_VERSION=$(git -C /build/$PROVIDER_NAME describe --tags --match='v[0-9]*' --dirty --always); \
            export PROVIDER_LDFLAGS="-linkmode external -extldflags \"-static\" -s -w -X main.Version=$PROVIDER_VERSION"; \
            ;; \
        esac; \
        cd "/build/$PROVIDER_NAME/$PROVIDER_SUBDIR" \
        && go build -ldflags="$PROVIDER_LDFLAGS" -o /opt/garm/providers.d/$PROVIDER_NAME . \
        && upx /opt/garm/providers.d/$PROVIDER_NAME; \
    done

FROM busybox

COPY --from=builder /bin/garm /bin/garm
COPY --from=builder /bin/garm-cli /bin/garm-cli
COPY --from=builder /opt/garm/providers.d/ /opt/garm/providers.d/
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

COPY contrib/vizmo/garm-entrypoint.sh /bin/garm-entrypoint.sh

ENTRYPOINT ["/bin/sh", "/bin/garm-entrypoint.sh"]
