.DEFAULT_GOAL: build

##################################
# DEFAULTS
##################################

GIT_VERSION := $(shell git describe --match "v[0-9]*" --tags $(git rev-list --tags --max-count=1))
GIT_VERSION_DEV := $(shell git describe --match "[0-9].[0-9]-dev*")
GIT_BRANCH := $(shell git branch | grep \* | cut -d ' ' -f2)
GIT_HASH := $(GIT_BRANCH)/$(shell git log -1 --pretty=format:"%H")
TIMESTAMP := $(shell date '+%Y-%m-%d_%I:%M:%S%p')
CONTROLLER_GEN=controller-gen
CONTROLLER_GEN_REQ_VERSION := v0.9.1-0.20220629131006-1878064c4cdf
VERSION ?= $(shell git describe --match "v[0-9]*")

REGISTRY?=ghcr.io
REPO=$(REGISTRY)/kyverno
IMAGE_TAG_LATEST_DEV=$(shell git describe --match "[0-9].[0-9]-dev*" | cut -d '-' -f-2)
IMAGE_TAG_DEV=$(GIT_VERSION_DEV)
IMAGE_TAG?=$(GIT_VERSION)
GOARCH ?= $(shell go env GOARCH)
GOOS ?= $(shell go env GOOS)
ifeq ($(GOOS), darwin)
SED=gsed
else
SED=sed
endif
PACKAGE ?=github.com/kyverno/kyverno
export LD_FLAGS = -s -w -X $(PACKAGE)/pkg/version.BuildVersion=$(GIT_VERSION) -X $(PACKAGE)/pkg/version.BuildHash=$(GIT_HASH) -X $(PACKAGE)/pkg/version.BuildTime=$(TIMESTAMP)
export LD_FLAGS_DEV = -s -w -X $(PACKAGE)/pkg/version.BuildVersion=$(GIT_VERSION_DEV) -X $(PACKAGE)/pkg/version.BuildHash=$(GIT_HASH) -X $(PACKAGE)/pkg/version.BuildTime=$(TIMESTAMP)
K8S_VERSION ?= $(shell kubectl version --short | grep -i server | cut -d" " -f3 | cut -c2-)
export K8S_VERSION
TEST_GIT_BRANCH ?= main

KIND_VERSION=v0.14.0
KIND_IMAGE?=kindest/node:v1.24.0

##################################
# KYVERNO
##################################

.PHONY: unused-package-check
unused-package-check:
	@echo "------------------"
	@echo "--> Check unused packages for the all kyverno components"
	@echo "------------------"
	@tidy=$$(go mod tidy); \
	if [ -n "$${tidy}" ]; then \
		echo "go mod tidy checking failed!"; echo "$${tidy}"; echo; \
	fi

KYVERNO_PATH:= cmd/kyverno
build: kyverno
PWD := $(CURDIR)

##################################
# INIT CONTAINER
##################################

INITC_PATH := cmd/initContainer
INITC_IMAGE := kyvernopre
initContainer: fmt vet
	GOOS=$(GOOS) go build -o $(PWD)/$(INITC_PATH)/kyvernopre -ldflags="$(LD_FLAGS)" $(PWD)/$(INITC_PATH)

.PHONY: ko-build-initContainer

ko-build-initContainer: KO_DOCKER_REPO=$(REPO)/$(INITC_IMAGE)
ko-build-initContainer:
	@ko build ./$(INITC_PATH) --bare --tags=latest,$(IMAGE_TAG) --platform=linux/amd64,linux/arm64,linux/s390x

ko-build-initContainer-amd64: KO_DOCKER_REPO=$(REPO)/$(INITC_IMAGE)
ko-build-initContainer-amd64:
	@ko build ./$(INITC_PATH) --bare --tags=latest,$(IMAGE_TAG) --platform=linux/amd64

ko-build-initContainer-local: KO_DOCKER_REPO=kind.local
ko-build-initContainer-local: kind-e2e-cluster
	@ko build ./$(INITC_PATH) --platform=linux/$(GOARCH) --tags=latest,$(IMAGE_TAG_DEV) --preserve-import-paths
INITC_KIND_IMAGE = kind.local/github.com/kyverno/kyverno/cmd/initcontainer

# TODO(jason): LD_FLAGS_DEV
ko-build-initContainer-dev: KO_DOCKER_REPO=$(REPO)/$(INITC_IMAGE)
ko-build-initContainer-dev:
	@ko build ./$(INITC_PATH) --platform=linux/amd64,linux/arm64,linux/s390x --tags=latest,$(IMAGE_TAG_DEV),$(IMAGE_TAG_LATEST_DEV)

##################################
# KYVERNO CONTAINER
##################################

.PHONY: ko-build-kyverno
KYVERNO_PATH := cmd/kyverno
KYVERNO_IMAGE := kyverno

kyverno: fmt vet
	GOOS=$(GOOS) go build -o $(PWD)/$(KYVERNO_PATH)/kyverno -ldflags"$(LD_FLAGS)" $(PWD)/$(KYVERNO_PATH)

ko-build-kyverno: KO_DOCKER_REPO=$(REPO)/$(KYVERNO_IMAGE)
ko-build-kyverno:
	@ko build ./$(KYVERNO_PATH) --bare --tags=latest,$(IMAGE_TAG) --platform=linux/amd64,linux/arm64,linux/s390x

ko-build-kyverno-amd64: KO_DOCKER_REPO=$(REPO)/$(KYVERNO_IMAGE)
ko-build-kyverno-amd64:
	@ko build ./$(KYVERNO_PATH) --bare --tags=latest,$(IMAGE_TAG) --platform=linux/amd64

ko-build-kyverno-local: KO_DOCKER_REPO=kind.local
ko-build-kyverno-local: kind-e2e-cluster
	@ko build ./$(KYVERNO_PATH) --platform=linux/$(GOARCH) --tags=latest,$(IMAGE_TAG_DEV) --preserve-import-paths

KYVERNO_KIND_IMAGE = kind.local/github.com/kyverno/kyverno/cmd/kyverno

# TODO(jason): LD_FLAGS_DEV
ko-build-kyverno-dev: KO_DOCKER_REPO=$(REPO)/$(KYVERNO_IMAGE)
ko-build-kyverno-dev:
	@ko build ./$(KYVERNO_PATH) --platform=linux/amd64,linux/arm64,linux/s390x --tags=latest,$(IMAGE_TAG_DEV),$(IMAGE_TAG_LATEST_DEV)

##################################
# Generate Docs for types.go
##################################

.PHONY: gen-crd-api-reference-docs
gen-crd-api-reference-docs: ## Install gen-crd-api-reference-docs
	go install github.com/ahmetb/gen-crd-api-reference-docs@latest

.PHONY: gen-crd-api-reference-docs
generate-api-docs: gen-crd-api-reference-docs ## Generate api reference docs
	rm -rf docs/crd
	mkdir docs/crd
	gen-crd-api-reference-docs -v 6 -api-dir ./api/kyverno/v1alpha2 -config docs/config.json -template-dir docs/template -out-file docs/crd/v1alpha2/index.html
	gen-crd-api-reference-docs -v 6 -api-dir ./api/kyverno/v1beta1 -config docs/config.json -template-dir docs/template -out-file docs/crd/v1beta1/index.html
	gen-crd-api-reference-docs -v 6 -api-dir ./api/kyverno/v1 -config docs/config.json -template-dir docs/template -out-file docs/crd/v1/index.html

.PHONY: verify-api-docs
verify-api-docs: generate-api-docs ## Check api reference docs are up to date
	git --no-pager diff docs
	@echo 'If this test fails, it is because the git diff is non-empty after running "make generate-api-docs".'
	@echo 'To correct this, locally run "make generate-api-docs", commit the changes, and re-run tests.'
	git diff --quiet --exit-code docs

##################################
# CLI
##################################
.PHONY: ko-build-cli
CLI_PATH := cmd/cli/kubectl-kyverno
KYVERNO_CLI_IMAGE := kyverno-cli

cli:
	GOOS=$(GOOS) go build -o $(PWD)/$(CLI_PATH)/kyverno -ldflags="$(LD_FLAGS)" $(PWD)/$(CLI_PATH)

ko-build-cli: KO_DOCKER_REPO=$(REPO)/$(KYVERNO_CLI_IMAGE)
ko-build-cli:
	@ko build ./$(CLI_PATH) --bare --tags=latest,$(IMAGE_TAG) --platform=linux/amd64,linux/arm64,linux/s390x

ko-build-cli-amd64: KO_DOCKER_REPO=$(REPO)/$(KYVERNO_CLI_IMAGE)
ko-build-cli-amd64:
	@ko build ./$(CLI_PATH) --bare --tags=latest,$(IMAGE_TAG) --platform=linux/amd64

ko-build-cli-local: KO_DOCKER_REPO=ko.local
ko-build-cli-local:
	@ko build ./$(CLI_PATH) --platform=linux/$(GOARCH) --tags=latest,$(IMAGE_TAG_DEV)

# TODO(jason): LD_FLAGS_DEV
ko-build-cli-dev: KO_DOCKER_REPO=$(REPO)/$(KYVERNO_CLI_IMAGE)
ko-build-cli-dev:
	@ko build ./$(CLI_PATH) --platform=linux/amd64,linux/arm64,linux/s390x --tags=latest,$(IMAGE_TAG_DEV),$(IMAGE_TAG_LATEST_DEV)

##################################
ko-build-all: ko-build-initContainer ko-build-kyverno ko-build-cli

ko-build-all-amd64: ko-build-initContainer-amd64 ko-build-kyverno-amd64 ko-build-cli-amd64

##################################
# Create e2e Infrastructure
##################################

.PHONY: kind-install
kind-install: ## Install kind
ifeq (, $(shell which kind))
	go install sigs.k8s.io/kind@$(KIND_VERSION)
endif

.PHONY: kind-e2e-cluster
kind-e2e-cluster: kind-install ## Create kind cluster for e2e tests
	kind create cluster --image=$(KIND_IMAGE)

.PHONY: e2e-kustomize
e2e-kustomize: kustomize ## Build kustomize manifests for e2e tests
	cd config && \
	kustomize edit set image $(INITC_KIND_IMAGE):$(IMAGE_TAG_DEV) && \
	kustomize edit set image $(KYVERNO_KIND_IMAGE):$(IMAGE_TAG_DEV)
	kustomize build config/ -o config/install.yaml

.PHONY: create-e2e-infrastructure
create-e2e-infrastructure: ko-build-initContainer-local ko-build-kyverno-local e2e-kustomize ## Setup infrastructure for e2e tests

##################################
# Testing & Code-Coverage
##################################

## variables
BIN_DIR := $(GOPATH)/bin
GO_ACC := $(BIN_DIR)/go-acc@latest
CODE_COVERAGE_FILE:= coverage
CODE_COVERAGE_FILE_TXT := $(CODE_COVERAGE_FILE).txt
CODE_COVERAGE_FILE_HTML := $(CODE_COVERAGE_FILE).html

## targets
$(GO_ACC):
	@echo "	installing testing tools"
	go install -v github.com/ory/go-acc@latest
	$(eval export PATH=$(GO_ACC):$(PATH))
# go test provides code coverage per packages only.
# go-acc merges the result for pks so that it be used by
# go tool cover for reporting

test: test-clean test-unit test-e2e ## Clean tests cache then run unit and e2e tests

test-clean: ## Clean tests cache
	@echo "	cleaning test cache"
	go clean -testcache ./...

.PHONY: test-cli
test-cli: test-cli-policies test-cli-local test-cli-local-mutate test-cli-local-generate test-cli-test-case-selector-flag test-cli-registry

.PHONY: test-cli-policies
test-cli-policies: cli
	cmd/cli/kubectl-kyverno/kyverno test https://github.com/kyverno/policies/$(TEST_GIT_BRANCH)

.PHONY: test-cli-local
test-cli-local: cli
	cmd/cli/kubectl-kyverno/kyverno test ./test/cli/test

.PHONY: test-cli-local-mutate
test-cli-local-mutate: cli
	cmd/cli/kubectl-kyverno/kyverno test ./test/cli/test-mutate

.PHONY: test-cli-local-generate
test-cli-local-generate: cli
	cmd/cli/kubectl-kyverno/kyverno test ./test/cli/test-generate

.PHONY: test-cli-test-case-selector-flag
test-cli-test-case-selector-flag: cli
	cmd/cli/kubectl-kyverno/kyverno test ./test/cli/test --test-case-selector "policy=disallow-latest-tag, rule=require-image-tag, resource=test-require-image-tag-pass"

.PHONY: test-cli-registry
test-cli-registry: cli
	cmd/cli/kubectl-kyverno/kyverno test ./test/cli/registry --registry

test-unit: $(GO_ACC) ## Run unit tests
	@echo "	running unit tests"
	go-acc ./... -o $(CODE_COVERAGE_FILE_TXT)

code-cov-report: ## Generate code coverage report
	@echo "	generating code coverage report"
	GO111MODULE=on go test -v -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out -o $(CODE_COVERAGE_FILE_TXT)
	go tool cover -html=coverage.out -o $(CODE_COVERAGE_FILE_HTML)

# Test E2E
test-e2e:
	$(eval export E2E="ok")
	go test ./test/e2e/verifyimages -v
	go test ./test/e2e/metrics -v
	go test ./test/e2e/mutate -v
	go test ./test/e2e/generate -v
	$(eval export E2E="")

test-e2e-local:
	$(eval export E2E="ok")
	kubectl apply -f https://raw.githubusercontent.com/kyverno/kyverno/main/config/github/rbac.yaml
	kubectl port-forward -n kyverno service/kyverno-svc-metrics  8000:8000 &
	go test ./test/e2e/verifyimages -v
	go test ./test/e2e/metrics -v
	go test ./test/e2e/mutate -v
	go test ./test/e2e/generate -v
	kill  $!
	$(eval export E2E="")

helm-test-values:
	sed -i -e "s|nameOverride:.*|nameOverride: kyverno|g" charts/kyverno/values.yaml
	sed -i -e "s|fullnameOverride:.*|fullnameOverride: kyverno|g" charts/kyverno/values.yaml
	sed -i -e "s|namespace:.*|namespace: kyverno|g" charts/kyverno/values.yaml
	sed -i -e "s|tag:  # replaced in e2e tests.*|tag: $(IMAGE_TAG_DEV)|" charts/kyverno/values.yaml
	sed -i -e "s|repository: ghcr.io/kyverno/kyvernopre  # init: replaced in e2e tests|repository: $(INITC_KIND_IMAGE)|" charts/kyverno/values.yaml
	sed -i -e "s|repository: ghcr.io/kyverno/kyverno  # kyverno: replaced in e2e tests|repository: $(KYVERNO_KIND_IMAGE)|" charts/kyverno/values.yaml

# godownloader create downloading script for kyverno-cli
godownloader:
	godownloader .goreleaser.yml --repo kyverno/kyverno -o ./scripts/install-cli.sh  --source="raw"

.PHONY: kustomize
kustomize: ## Install kustomize
ifeq (, $(shell which kustomize))
	go install sigs.k8s.io/kustomize/kustomize/v4@latest
endif

.PHONY: kustomize-crd
kustomize-crd: kustomize ## Create install.yaml
	# Create CRD for helm deployment Helm
	kustomize build ./config/release | kustomize cfg grep kind=CustomResourceDefinition | $(SED) -e "1i{{- if .Values.installCRDs }}" -e '$$a{{- end }}' > ./charts/kyverno/templates/crds.yaml
	# Generate install.yaml that have all resources for kyverno
	kustomize build ./config > ./config/install.yaml
	# Generate install_debug.yaml that for developer testing
	kustomize build ./config/debug > ./config/install_debug.yaml

# guidance https://github.com/kyverno/kyverno/wiki/Generate-a-Release
release:
	kustomize build ./config > ./config/install.yaml
	kustomize build ./config/release > ./config/release/install.yaml

release-notes:
	@bash -c 'while IFS= read -r line ; do if [[ "$$line" == "## "* && "$$line" != "## $(VERSION)" ]]; then break ; fi; echo "$$line"; done < "CHANGELOG.md"' \
	true

##################################
# CODEGEN
##################################

.PHONY: kyverno-crd
kyverno-crd: controller-gen ## Generate Kyverno CRDs
	$(CONTROLLER_GEN) crd paths=./api/kyverno/... crd:crdVersions=v1 output:dir=./config/crds

.PHONY: report-crd
report-crd: controller-gen ## Generate policy reports CRDs
	$(CONTROLLER_GEN) crd paths=./api/policyreport/... crd:crdVersions=v1 output:dir=./config/crds

.PHONY: install-controller-gen
install-controller-gen: ## Install controller-gen
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_REQ_VERSION) ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
	CONTROLLER_GEN=$(GOPATH)/bin/controller-gen

.PHONY: controller-gen
controller-gen: ## Setup controller-gen
ifeq (, $(shell which controller-gen))
	@{ \
	echo "controller-gen not found!";\
	echo "installing controller-gen $(CONTROLLER_GEN_REQ_VERSION)...";\
	make install-controller-gen;\
	}
else ifneq (Version: $(CONTROLLER_GEN_REQ_VERSION), $(shell controller-gen --version))
	@{ \
		echo "controller-gen $(shell controller-gen --version) found!";\
		echo "required controller-gen $(CONTROLLER_GEN_REQ_VERSION)";\
		echo "installing controller-gen $(CONTROLLER_GEN_REQ_VERSION)...";\
		make install-controller-gen;\
	}
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

.PHONY: deepcopy-autogen
deepcopy-autogen: controller-gen goimports ## Generate deep copy code
	$(CONTROLLER_GEN) object:headerFile="scripts/boilerplate.go.txt" paths="./..." && $(GO_IMPORTS) -w ./api/

.PHONY: codegen
codegen: kyverno-crd report-crd deepcopy-autogen generate-api-docs gen-helm ## Update all generated code and docs

.PHONY: verify-api
verify-api: kyverno-crd report-crd deepcopy-autogen ## Check api is up to date
	git --no-pager diff api
	@echo 'If this test fails, it is because the git diff is non-empty after running "make codegen".'
	@echo 'To correct this, locally run "make codegen", commit the changes, and re-run tests.'
	git diff --quiet --exit-code api

.PHONY: verify-config
verify-config: kyverno-crd report-crd ## Check config is up to date
	git --no-pager diff config
	@echo 'If this test fails, it is because the git diff is non-empty after running "make codegen".'
	@echo 'To correct this, locally run "make codegen", commit the changes, and re-run tests.'
	git diff --quiet --exit-code config

.PHONY: verify-codegen
verify-codegen: verify-api verify-config verify-api-docs verify-helm ## Verify all generated code and docs are up to date

.PHONY: goimports
goimports: ## Install goimports if needed
ifeq (, $(shell which goimports))
	@{ \
	echo "goimports not found!";\
	echo "installing goimports...";\
	go install golang.org/x/tools/cmd/goimports@latest;\
	}
else
GO_IMPORTS=$(shell which goimports)
endif

.PHONY: fmt
fmt: goimports ## Run go fmt
	go fmt ./... && $(GO_IMPORTS) -w ./

.PHONY: vet
vet: ## Run go vet
	go vet ./...

##################################
# HELM
##################################

.PHONY: gen-helm-docs
gen-helm-docs: ## Generate Helm docs
	@docker run -v ${PWD}:/work -w /work jnorwood/helm-docs:v1.6.0 -s file

.PHONY: gen-helm
gen-helm: gen-helm-docs kustomize-crd ## Generate Helm charts stuff

.PHONY: verify-helm
verify-helm: gen-helm ## Check Helm charts are up to date
	git --no-pager diff charts
	@echo 'If this test fails, it is because the git diff is non-empty after running "make gen-helm".'
	@echo 'To correct this, locally run "make gen-helm", commit the changes, and re-run tests.'
	git diff --quiet --exit-code charts

##################################
# HELP
##################################

.PHONY: help
help: ## Shows the available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: kind-deploy
kind-deploy: ko-build-initContainer-local ko-build-kyverno-local
	helm upgrade --install kyverno --namespace kyverno --wait --create-namespace ./charts/kyverno \
		--set image.repository=$(KYVERNO_KIND_IMAGE) \
		--set image.tag=$(IMAGE_TAG_DEV) \
		--set initImage.repository=$(INITC_KIND_IMAGE) \
		--set initImage.tag=$(IMAGE_TAG_DEV) \
		--set extraArgs={--autogenInternals=false}
	helm upgrade --install kyverno-policies --namespace kyverno --create-namespace ./charts/kyverno-policies

