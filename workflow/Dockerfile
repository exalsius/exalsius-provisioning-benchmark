# Containerised runner for the end-to-end benchmark workflow.
# Bundles every tool the workflow needs so a run is reproducible on any host
# with a container runtime: k0sctl, kubectl, helm, python3, jq, envsubst, ssh.
FROM alpine:3.20

ARG KUBECTL_VERSION=v1.30.4
ARG HELM_VERSION=v3.16.2
ARG K0SCTL_VERSION=v0.19.4
ARG TARGETARCH=amd64

# aiperf runs in-cluster (as a Job), so the runner image itself needs no Python.
RUN apk add --no-cache \
      bash curl ca-certificates jq gettext openssh-client coreutils grep sed \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar xz -C /tmp && mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && curl -fsSL "https://github.com/k0sproject/k0sctl/releases/download/${K0SCTL_VERSION}/k0sctl-linux-${TARGETARCH}" \
      -o /usr/local/bin/k0sctl && chmod +x /usr/local/bin/k0sctl \
 && rm -rf /tmp/*

WORKDIR /workflow
COPY . /workflow

# runs/ is a mount point for artifacts; scripts live under bin/.
ENV WORKFLOW_ROOT=/workflow
ENTRYPOINT ["/workflow/bin/run.sh"]
