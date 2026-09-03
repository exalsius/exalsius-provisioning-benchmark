# Makefile for the exalsius provisioning benchmark end-to-end workflow.
# The workflow runs only inside the bundled container: `make build` produces the
# image, then `make docker-run` (or the s1/s2/s3 shortcuts) runs a scenario in it.

# Recipes use bash (the docker targets rely on bash parameter expansion).
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

IMAGE ?= exalsius-benchmark-workflow:latest
SCENARIO ?= s1
# Extra flags forwarded to the in-container run.sh (e.g. --keep, --dry-run,
# --from/--to/--only <phase>).
RUN_FLAGS ?=
# Run identifier (run directory name). Empty → prompted inside the container.
RUN_ID ?=
# Consecutive-run reproducibility check (docker-verify): number of back-to-back
# runs, and the run-id base (run dirs are <base>-run-1 .. <base>-run-COUNT).
COUNT ?= 2
RUN_ID_BASE ?=
# SSH key for the nodes: no default — prompted if unset.
SSH_KEY_PATH ?=
RUNS_DIR := $(CURDIR)/runs

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

.PHONY: lint
lint: ## Shellcheck all scripts (requires shellcheck)
	@shellcheck bin/*.sh lib/*.sh || true

.PHONY: build
build: ## Build the workflow container image
	docker build -t $(IMAGE) .

.PHONY: docker-run
docker-run: build ## Build the image, then run a scenario in it (SCENARIO=s1|s2|s3; env: HF_TOKEN, NODE_ENDPOINTS, SSH_USERNAME, ...)
	@key="$(SSH_KEY_PATH)"; \
	if [ -z "$$key" ]; then read -r -p "Path to the SSH private key for the nodes: " key; fi; \
	key="$${key/#\~/$$HOME}"; \
	[ -f "$$key" ] || { echo "SSH key not found: $$key"; exit 1; }; \
	echo "mounting SSH key: $$key"; \
	tty=; [ -t 0 ] && [ -t 1 ] && tty=-it; \
	docker run --rm $$tty \
	  -e HF_TOKEN -e NODE_ENDPOINTS -e SSH_USERNAME -e RUN_ID="$(RUN_ID)" \
	  -e SSH_KEY_PATH=/root/.ssh/id_rsa \
	  -e MODEL_ID -e REPLICAS -e GPU_COUNT_PER_REPLICA -e NODES_PER_REPLICA -e WORKSPACE_CPU \
	  -v "$$key":/root/.ssh/id_rsa:ro \
	  -v $(RUNS_DIR):/workflow/runs \
	  $(IMAGE) $(SCENARIO) $(RUN_FLAGS)

.PHONY: s1 s2 s3
s1: ## Run scenario 1 (single-node) in the container
	@$(MAKE) --no-print-directory docker-run SCENARIO=s1
s2: ## Run scenario 2 (replicated) in the container
	@$(MAKE) --no-print-directory docker-run SCENARIO=s2
s3: ## Run scenario 3 (sharded) in the container
	@$(MAKE) --no-print-directory docker-run SCENARIO=s3

.PHONY: docker-verify
docker-verify: build ## Run a scenario COUNT times back-to-back for reproducibility (COUNT=2; needs env: HF_TOKEN, NODE_ENDPOINTS, SSH_USERNAME)
	@key="$(SSH_KEY_PATH)"; \
	if [ -z "$$key" ]; then read -r -p "Path to the SSH private key for the nodes: " key; fi; \
	key="$${key/#\~/$$HOME}"; \
	[ -f "$$key" ] || { echo "SSH key not found: $$key"; exit 1; }; \
	tty=; [ -t 0 ] && [ -t 1 ] && tty=-it; \
	docker run --rm $$tty \
	  --entrypoint /workflow/bin/run-repeat.sh \
	  -e HF_TOKEN -e NODE_ENDPOINTS -e SSH_USERNAME -e RUN_ID_BASE="$(RUN_ID_BASE)" \
	  -e SSH_KEY_PATH=/root/.ssh/id_rsa \
	  -e MODEL_ID -e REPLICAS -e GPU_COUNT_PER_REPLICA -e NODES_PER_REPLICA -e WORKSPACE_CPU \
	  -v "$$key":/root/.ssh/id_rsa:ro \
	  -v $(RUNS_DIR):/workflow/runs \
	  $(IMAGE) $(SCENARIO) $(COUNT) $(RUN_FLAGS)

.PHONY: docker-cleanup
docker-cleanup: build ## Tear down the cluster from a run (k0sctl reset) in the container
	@key="$(SSH_KEY_PATH)"; \
	if [ -z "$$key" ]; then read -r -p "Path to the SSH private key for the nodes: " key; fi; \
	key="$${key/#\~/$$HOME}"; \
	[ -f "$$key" ] || { echo "SSH key not found: $$key"; exit 1; }; \
	tty=; [ -t 0 ] && [ -t 1 ] && tty=-it; \
	docker run --rm $$tty \
	  -e SSH_KEY_PATH=/root/.ssh/id_rsa -e RUN_ID="$(RUN_ID)" \
	  -v "$$key":/root/.ssh/id_rsa:ro \
	  -v $(RUNS_DIR):/workflow/runs \
	  $(IMAGE) $(SCENARIO) --only cleanup

.PHONY: clean-artifacts
clean-artifacts: ## Delete local run artifacts (runs/ — via a container, as runs are root-owned)
	@rm -rf runs/* 2>/dev/null \
	  || docker run --rm -v $(RUNS_DIR):/runs busybox sh -c 'rm -rf /runs/*' \
	  || { echo "could not remove runs/ (root-owned) — try: sudo rm -rf runs/*"; exit 1; }
